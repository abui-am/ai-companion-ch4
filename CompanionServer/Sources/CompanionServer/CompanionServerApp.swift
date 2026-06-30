import CompanionEnv
import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging

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
            ]
        )

        let openAI = OpenAIRESTService(apiKey: config.openAIAPIKey, logger: serverLogger)
        let speakers = SpeakerRegistry(logger: serverLogger)

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
            let session = VoiceSession(
                outbound: WebSocketSessionOutboundWriter(base: outbound),
                openAI: openAI,
                speakers: speakers,
                logger: serverLogger
            )
            try await session.start()

            do {
                for try await message in inbound.messages(maxSize: 1 << 20) {
                    try await handle(message, session: session, logger: serverLogger)
                }
            } catch {
                serverLogger.info("inbound stream ended", metadata: ["error": "\(error)"])
            }
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
            return "ok"
        }
        router.get("/ping") { _, _ in
            serverLogger.debug("GET /ping")
            return "pong"
        }

        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
            configuration: .init(address: .hostname("0.0.0.0", port: 8080))
        )
        try await app.runService()
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
            logger.debug("session.start ignored — session begins on upgrade")
        case .audioStart:
            await session.handleAudioStart()
        case .audioStop:
            await session.handleAudioStop()
        case .transcriptInput:
            let transcript = try JSONDecoder().decode(TranscriptInput.self, from: data)
            await session.handleTranscriptInput(transcript.text)
        case .abort:
            let abort = try JSONDecoder().decode(AbortMessage.self, from: data)
            await session.handleAbort(reason: abort.reason)
        default:
            logger.warning("unhandled inbound event", metadata: ["type": .string(envelope.type.rawValue)])
        }
    }
}
