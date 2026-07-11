import CompanionDatabase
import CompanionEnv
import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging

struct VersionResponse: ResponseEncodable, Sendable {
    let version: String
    let protocolVersion: String
    let pipelineProfile: String
    let uptimeSeconds: Int
}

@main
struct CompanionServerApp {
    static func main() async throws {
        var logger = Logger(label: "CompanionServer")
        LogConfig.apply(to: &logger)
        let serverLogger = logger

        let config: AppConfig
        do {
            config = try await AppConfig.load()
        } catch let error as AppConfigError {
            logger.critical("\(error.description)")
            exit(1)
        }
        logger.info(
            "config loaded",
            metadata: [
                "companion_host": .string(config.companionHost),
                "log_level": .string("\(LogConfig.level())"),
                "stack_version": .string(
                    "protocol=\(CompanionStack.protocolVersion) pipeline=\(CompanionStack.pipelineProfile)"
                ),
                "realtime_model": .string(config.openAIRealtimeModel),
                "realtime_voice": .string(config.openAIRealtimeVoice),
                "tts_provider": .string(config.ttsProvider.rawValue),
                "cartesia_model": .string(config.cartesiaModelId),
                "web_search": .string(config.webSearchEnabled ? "enabled" : "disabled"),
                "response_language": .string(config.responseLanguage),
                "companion_timezone": .string(config.companionTimezone),
            ]
        )

        let databaseSettings: DatabaseSettings
        do {
            databaseSettings = try DatabaseSettings(urlString: config.databaseURL)
        } catch {
            logger.critical("invalid DATABASE_URL: \(error)")
            exit(1)
        }
        let database = DatabaseService(settings: databaseSettings, logger: logger)
        await database.start()
        do {
            try await database.ping()
        } catch {
            logger.critical("postgres connection failed: \(error)")
            await database.shutdown()
            exit(1)
        }
        logger.info(
            "postgres connected",
            metadata: [
                "host": .string(databaseSettings.host),
                "port": .string("\(databaseSettings.port)"),
                "database": .string(databaseSettings.database),
            ]
        )

        do {
            try await database.enableVectorExtension()
        } catch {
            logger.critical("pgvector extension setup failed: \(error)")
            await database.shutdown()
            exit(1)
        }

        let calendar = CalendarRepository(database: database, logger: logger)
        let userConfig = ConfigRepository(database: database, logger: logger)
        let profile = ProfileRepository(database: database, logger: logger)
        let tasks = TaskRepository(database: database, logger: logger)
        let reminders = ReminderRepository(database: database, logger: logger)
        let pushDevices = PushDeviceRepository(database: database, logger: logger)
        await migrateOrExit("calendar", calendar.migrate, database: database, logger: logger)
        await migrateOrExit("config", userConfig.migrate, database: database, logger: logger)
        await migrateOrExit("profile", profile.migrate, database: database, logger: logger)
        await migrateOrExit("task", tasks.migrate, database: database, logger: logger)
        await migrateOrExit("reminder", reminders.migrate, database: database, logger: logger)
        await migrateOrExit("push device", pushDevices.migrate, database: database, logger: logger)

        let reminderScheduler = ReminderScheduler(
            reminders: reminders,
            config: userConfig,
            logger: serverLogger
        )
        let sessionRegistry = ActiveVoiceSessionRegistry(logger: serverLogger)
        let apnsService: (any APNsSending)?
        if let apnsConfig = APNsConfiguration.load(from: config) {
            apnsService = APNsService(configuration: apnsConfig, logger: serverLogger)
            serverLogger.info(
                "apns configured",
                metadata: [
                    "key_id": .string(apnsConfig.keyID),
                    "team_id": .string(apnsConfig.teamID),
                    "default_bundle_id": .string(apnsConfig.defaultBundleID ?? ""),
                ]
            )
        } else {
            serverLogger.info("apns not configured — push delivery disabled")
            apnsService = nil
        }
        let reminderWorker = ReminderWorker(
            reminders: reminders,
            config: userConfig,
            pushDevices: pushDevices,
            sessionRegistry: sessionRegistry,
            apns: apnsService,
            logger: serverLogger
        )
        await reminderWorker.start()

        let conversations = ConversationRepository(database: database, logger: logger)
        let memories = MemoryRepository(database: database, logger: logger)
        await migrateOrExit("conversation", conversations.migrate, database: database, logger: logger)
        await migrateOrExit("memory", memories.migrate, database: database, logger: logger)
        let embeddings = OpenAIEmbeddingService(
            apiKey: config.openAIAPIKey,
            model: config.openAIEmbeddingModel,
            logger: logger
        )

        if let root = PackagePaths.packageRoot() {
            let debugDir = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent("debug-audio", isDirectory: true)
            try? FileManager.default.createDirectory(at: debugDir, withIntermediateDirectories: true)
            logger.info("debug audio dumps enabled", metadata: ["dir": .string(debugDir.path)])
            print("Debug audio WAV dumps → \(debugDir.path)/")
        }

        let conversationAudio: ConversationAudioStore
        do {
            let root = try ConversationAudioStore.defaultRootDirectory()
            conversationAudio = ConversationAudioStore(rootDirectory: root, logger: logger)
            logger.info("conversation audio enabled", metadata: ["dir": .string(root.path)])
        } catch {
            logger.critical("failed to create conversation-audio directory: \(error)")
            await database.shutdown()
            exit(1)
        }

        let speakers = SpeakerRegistry(logger: serverLogger)
        let personaStore = PersonaStore(logger: serverLogger)

        let wsRouter = Router(context: BasicWebSocketRequestContext.self)
        wsRouter.ws("/ws") { request, _ in
            if let token = bearerToken(from: request), token == config.deviceToken {
                serverLogger.info("ws upgrade authorized", metadata: ["path": "/ws"])
                return .upgrade([:])
            }
            serverLogger.warning("ws upgrade rejected — invalid or missing bearer token")
            return .dontUpgrade
        } onUpgrade: { inbound, outbound, _ in
            serverLogger.info("ws connection upgraded")
            let outboundWriter = WebSocketSessionOutboundWriter(base: outbound)
            let deviceCommands = DeviceCommandGateway(outbound: outboundWriter, logger: serverLogger)
            var subAgentList: [any SubAgent] = [
                TaskAgent(
                    tasks: tasks,
                    reminderScheduler: reminderScheduler,
                    timeZoneIdentifier: config.companionTimezone,
                    logger: serverLogger
                ),
                CalendarAgent(
                    calendar: calendar,
                    reminderScheduler: reminderScheduler,
                    timeZoneIdentifier: config.companionTimezone,
                    logger: serverLogger
                ),
                MemoryAgent(memories: memories, embeddings: embeddings, config: userConfig, logger: serverLogger),
                MotionAgent(gateway: deviceCommands, logger: serverLogger),
                EmotionAgent(gateway: deviceCommands, logger: serverLogger),
                PersonaAgent(personas: personaStore, logger: serverLogger),
            ]
            if config.webSearchEnabled {
                subAgentList.append(
                    WebSearchAgent(
                        apiKey: config.openAIAPIKey,
                        model: config.openAISearchModel,
                        logger: serverLogger
                    )
                )
            }
            let subAgents = SubAgentRegistry(agents: subAgentList)
            let realtime = OpenAIRealtimeService(
                apiKey: config.openAIAPIKey,
                model: config.openAIRealtimeModel,
                voice: config.openAIRealtimeVoice,
                responseLanguage: config.responseLanguage,
                timeZoneIdentifier: config.companionTimezone,
                textOnlyOutput: config.usesCartesiaTTS,
                subAgents: subAgents,
                logger: serverLogger
            )
            let cartesiaTTS: (any TTSStreamingService)? = if config.usesCartesiaTTS, let cartesiaKey = config.cartesiaAPIKey {
                CartesiaService(
                    apiKey: cartesiaKey,
                    voiceId: config.cartesiaVoiceId,
                    modelId: config.cartesiaModelId,
                    logger: serverLogger
                )
            } else {
                nil
            }
            let voiceSessionId = UUID().uuidString
            let session = VoiceSession(
                sessionId: voiceSessionId,
                outbound: outboundWriter,
                realtime: realtime,
                tts: cartesiaTTS,
                speakers: speakers,
                config: userConfig,
                conversations: conversations,
                conversationAudio: conversationAudio,
                memories: memories,
                personas: personaStore,
                logger: serverLogger
            )
            try await session.start()
            await sessionRegistry.register(
                sessionId: voiceSessionId,
                session: session,
                gateway: deviceCommands
            )

            do {
                for try await message in inbound.messages(maxSize: 1 << 20) {
                    try await handle(message, session: session, logger: serverLogger)
                }
            } catch {
                serverLogger.info("inbound stream ended", metadata: ["error": "\(error)"])
            }
            await sessionRegistry.unregister(sessionId: voiceSessionId)
            await session.handleDisconnect()
            serverLogger.info("ws connection closed")
        }

        wsRouter.ws("/speaker") { request, _ in
            if let token = bearerToken(from: request), token == config.deviceToken {
                serverLogger.info("speaker upgrade authorized", metadata: ["path": "/speaker"])
                return .upgrade([:])
            }
            serverLogger.warning("speaker upgrade rejected — invalid or missing bearer token")
            return .dontUpgrade
        } onUpgrade: { inbound, outbound, _ in
            let speakerId = UUID()
            await speakers.register(id: speakerId, outbound: WebSocketSessionOutboundWriter(base: outbound))
            serverLogger.info("speaker connected", metadata: ["id": .string(speakerId.uuidString)])

            let ready = try JSONEncoder().encode(SpeakerReady())
            let readyText = String(decoding: ready, as: UTF8.self)
            try await outbound.write(.text(readyText))

            do {
                for try await _ in inbound.messages(maxSize: 1 << 20) {
                    // Speaker clients listen only; ignore any inbound frames.
                }
            } catch {
                serverLogger.info("speaker stream ended", metadata: ["error": "\(error)"])
            }
            await speakers.unregister(id: speakerId)
            serverLogger.info("speaker disconnected", metadata: ["id": .string(speakerId.uuidString)])
        }

        let router = Router()
        router.get("/health") { _, _ in
            serverLogger.debug("GET /health")
            do {
                try await database.ping()
                return "ok"
            } catch {
                serverLogger.warning("health check failed", metadata: ["error": "\(error)"])
                throw HTTPError(.serviceUnavailable, message: "database unavailable")
            }
        }
        router.get("/ping") { _, _ in
            serverLogger.debug("GET /ping")
            return "pong"
        }
        let startedAt = Date()
        router.get("/version") { _, _ in
            serverLogger.debug("GET /version")
            return VersionResponse(
                version: CompanionStack.serverVersion,
                protocolVersion: CompanionStack.protocolVersion,
                pipelineProfile: CompanionStack.pipelineProfile,
                uptimeSeconds: Int(Date().timeIntervalSince(startedAt))
            )
        }
        CalendarRoutes.register(
            on: router,
            calendar: calendar,
            reminderScheduler: reminderScheduler,
            deviceToken: config.deviceToken,
            logger: serverLogger
        )
        ConfigRoutes.register(
            on: router,
            config: userConfig,
            reminderScheduler: reminderScheduler,
            personas: personaStore,
            sessionRegistry: sessionRegistry,
            deviceToken: config.deviceToken,
            logger: serverLogger
        )
        PersonaRoutes.register(
            on: router,
            personas: personaStore,
            deviceToken: config.deviceToken,
            logger: serverLogger
        )
        ProfileRoutes.register(
            on: router,
            profile: profile,
            deviceToken: config.deviceToken,
            logger: serverLogger
        )
        TaskRoutes.register(
            on: router,
            tasks: tasks,
            reminderScheduler: reminderScheduler,
            deviceToken: config.deviceToken,
            logger: serverLogger
        )
        PushRoutes.register(
            on: router,
            pushDevices: pushDevices,
            deviceToken: config.deviceToken,
            logger: serverLogger
        )
        ConversationRoutes.register(
            on: router,
            conversations: conversations,
            audioStore: conversationAudio,
            deviceToken: config.deviceToken,
            logger: serverLogger
        )
        MemoryRoutes.register(
            on: router,
            memories: memories,
            config: userConfig,
            deviceToken: config.deviceToken,
            logger: serverLogger
        )

        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
            configuration: .init(address: .hostname("0.0.0.0", port: 8080))
        )
        try await app.runService()
        await reminderWorker.stop()
        await database.shutdown()
    }

    /// Runs a repository migration; on failure logs, shuts down the database, and exits.
    static func migrateOrExit(
        _ name: String,
        _ migrate: () async throws -> Void,
        database: DatabaseService,
        logger: Logger
    ) async {
        do {
            try await migrate()
        } catch {
            logger.critical("\(name) migration failed: \(error)")
            await database.shutdown()
            exit(1)
        }
    }

    static func bearerToken(from request: Request) -> String? {
        request.headers[.authorization]?.split(separator: " ").last.map(String.init)
    }

    static func handle(_ frame: WebSocketMessage, session: VoiceSession, logger: Logger) async throws {
        switch frame {
        case .text(let text):
            logger.debug("ws recv text", metadata: ["bytes": "\(text.utf8.count)", "json": .string(text)])
            try await handleJSON(text, session: session, logger: logger)
        case .binary(let buffer):
            let data = Data(buffer.readableBytesView)
            logger.debug("ws recv binary", metadata: ["bytes": "\(data.count)"])
            await session.handleOpusFrame(data)
        }
    }

    static func handleJSON(_ text: String, session: VoiceSession, logger: Logger) async throws {
        let data = Data(text.utf8)
        let envelope = try JSONDecoder().decode(InboundEnvelope.self, from: data)
        logger.info("ws recv event", metadata: ["type": .string(envelope.type.rawValue)])
        switch envelope.type {
        case .sessionStart:
            let start = try JSONDecoder().decode(SessionStart.self, from: data)
            await session.handleSessionStart(start)
        case .audioStart:
            await session.handleAudioStart()
        case .audioStop:
            await session.handleAudioStop()
        case .abort:
            let abort = try JSONDecoder().decode(AbortMessage.self, from: data)
            await session.handleAbort(reason: abort.reason)
        case .transcriptInput:
            logger.warning("transcript.input is not supported — use audio uplink (see docs/ARCHIVED_LEGACY_PIPELINE.md)")
            try await session.sendUnsupportedTranscriptInput()
        default:
            logger.warning("unhandled inbound event", metadata: ["type": .string(envelope.type.rawValue)])
        }
    }
}
