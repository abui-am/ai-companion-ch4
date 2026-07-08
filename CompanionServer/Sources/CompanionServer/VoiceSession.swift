import CompanionDatabase
import CompanionEnv
import Foundation
import Logging

enum SessionPhase: CustomStringConvertible {
    case connected
    case capturing
    case processing
    case streamingTTS

    var description: String {
        switch self {
        case .connected: "connected"
        case .capturing: "capturing"
        case .processing: "processing"
        case .streamingTTS: "streamingTTS"
        }
    }
}

/// A completed tool call captured mid-turn, kept alongside the raw JSON strings it was built
/// from so `persistConversationTurn` can write them to Postgres without re-serializing the
/// already-parsed `StructuredToolCall` sent over the WebSocket.
private struct BufferedToolCall {
    let call: StructuredToolCall
    let argumentsJSON: String
    let outputJSON: String
}

actor VoiceSession {
    private let sessionId = UUID().uuidString
    private let outbound: SessionOutboundWriter
    private let realtime: OpenAIRealtimeService
    private let tts: (any TTSStreamingService)?
    private let speakers: SpeakerRegistry
    private let downlinkPacer: DownlinkPacer
    private let config: ConfigRepository
    private let conversations: ConversationRepository
    private let conversationAudio: ConversationAudioStore
    private let memories: MemoryRepository
    private let logger: Logger

    /// Cap on facts injected into the system prompt at session start — keeps prompt growth
    /// bounded regardless of how many memories exist. See `refreshMemoryContext`.
    private static let sessionMemoryLimit = 8

    private var phase: SessionPhase = .connected
    private var pipelineTask: Task<Void, Never>?
    private var activeContextId: String?
    private var turnCounter = 0
    private var uplinkFrameCounter = 0
    private var uplinkPCMDump = Data()
    private var uplinkCaptureStartedAt: Date?
    /// Decouples ESP WS reads from OpenAI forwarding — see `forwardUplink`.
    private var uplinkStreamContinuation: AsyncStream<Data>.Continuation?
    private var uplinkForwardTask: Task<Void, Never>?
    private var downlinkPCMDump = Data()
    private var downlinkTurnId: String?
    private var toolCallsThisTurn: [BufferedToolCall] = []
    private var dumpOnlyMode = false
    /// Set from `ConfigRecord.personalizationData` in `applyUserConfig()` — gates whether
    /// turns are persisted via `conversations`/`conversationAudio`.
    private var saveConversationHistory = false
    private var conversationSessionStarted = false

    init(
        outbound: SessionOutboundWriter,
        realtime: OpenAIRealtimeService,
        tts: (any TTSStreamingService)? = nil,
        speakers: SpeakerRegistry,
        config: ConfigRepository,
        conversations: ConversationRepository,
        conversationAudio: ConversationAudioStore,
        memories: MemoryRepository,
        logger: Logger
    ) {
        self.outbound = outbound
        self.realtime = realtime
        self.tts = tts
        self.speakers = speakers
        self.config = config
        self.conversations = conversations
        self.conversationAudio = conversationAudio
        self.memories = memories
        self.downlinkPacer = DownlinkPacer(
            outbound: outbound,
            speakers: speakers,
            sampleRate: AudioParams.downlink.sampleRate,
            logger: logger
        )
        self.logger = logger
    }

    func start() async throws {
        phase = .connected
        logger.info("session started", metadata: ["session_id": .string(sessionId)])
        Task { await realtime.connect() }
        let ready = SessionReady(sessionId: sessionId, audio: .downlink)
        try await send(ready)
    }

    func handleSessionStart(_ start: SessionStart) async {
        dumpOnlyMode = start.mode == "dump_only"
        if dumpOnlyMode {
            logger.info(
                "dump-only session — uplink WAV dump only, no pipeline",
                metadata: ["session_id": .string(sessionId)]
            )
            print("[session] dump-only mode — AI pipeline disabled")
        }

        await realtime.connect()
        await applyUserConfig()
        await refreshMemoryContext()

        if let language = start.language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
            logger.info(
                "session response language override",
                metadata: ["session_id": .string(sessionId), "language": .string(language)]
            )
            await realtime.setResponseLanguage(language)
        }
    }

    /// Applies personality and language to the Realtime session (requires an active socket).
    private func applyUserConfig() async {
        do {
            let record = try await config.get()
            await realtime.setPersonality(record.personality)
            await realtime.setResponseLanguage(record.language.promptLabel)
            await realtime.refreshTimeContext()
            saveConversationHistory = record.personalizationData
            logger.info(
                "session config applied",
                metadata: [
                    "session_id": .string(sessionId),
                    "personality": .string(record.personality.rawValue),
                    "language": .string(record.language.rawValue),
                    "save_conversation_history": .string("\(record.personalizationData)"),
                ]
            )
        } catch {
            logger.warning(
                "failed to load user config — using defaults",
                metadata: ["session_id": .string(sessionId), "error": "\(error)"]
            )
        }
    }

    /// Injects the most recent memories into the system prompt so recall works on a fresh
    /// connection without the model needing to call `memory.search` first — see
    /// `OpenAIRealtimeService.refreshMemoryContext`. Skipped when personalization is off;
    /// never fails the session on a lookup error.
    private func refreshMemoryContext(trigger: String? = nil) async {
        guard saveConversationHistory else {
            await realtime.refreshMemoryContext(memories: [])
            return
        }
        do {
            let recent = try await memories.list(limit: Self.sessionMemoryLimit)
            await realtime.refreshMemoryContext(memories: recent)
            if let trigger {
                logger.info(
                    "memory context refreshed",
                    metadata: [
                        "session_id": .string(sessionId),
                        "trigger": .string(trigger),
                        "count": "\(recent.count)",
                    ]
                )
            }
        } catch {
            logger.warning(
                "failed to load memory context — continuing without it",
                metadata: [
                    "session_id": .string(sessionId),
                    "trigger": .string(trigger ?? "session_start"),
                    "error": "\(error)",
                ]
            )
            await realtime.refreshMemoryContext(memories: [])
        }
    }

    func handleAudioStart() {
        phase = .capturing
        uplinkFrameCounter = 0
        uplinkPCMDump.removeAll(keepingCapacity: true)
        uplinkCaptureStartedAt = Date()
        stopUplinkForwarder()
        if !dumpOnlyMode {
            startUplinkForwarder()
        }
        logger.info("audio.start", metadata: ["session_id": .string(sessionId), "phase": .string("\(phase)")])
    }

    func handleOpusFrame(_ data: Data) {
        guard phase == .capturing else {
            logger.debug(
                "ignored uplink frame — not capturing",
                metadata: ["session_id": .string(sessionId), "phase": .string("\(phase)"), "bytes": "\(data.count)"]
            )
            return
        }
        let expectedBytes = AudioParams.uplink.sampleRate / 1000 * AudioParams.uplink.frameMs * 2
        if data.count != expectedBytes {
            logger.warning(
                "uplink frame size mismatch",
                metadata: [
                    "session_id": .string(sessionId),
                    "frame": "\(uplinkFrameCounter + 1)",
                    "bytes": "\(data.count)",
                    "expected": "\(expectedBytes)",
                ]
            )
        }
        uplinkFrameCounter += 1
        uplinkPCMDump.append(data)
        logger.debug(
            "uplink frame",
            metadata: ["session_id": .string(sessionId), "frame": "\(uplinkFrameCounter)", "bytes": "\(data.count)"]
        )
        if dumpOnlyMode {
            return
        }
        uplinkStreamContinuation?.yield(data)
    }

    private static let uplinkForwardBatchFrames = 4

    private func startUplinkForwarder() {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        uplinkStreamContinuation = continuation
        uplinkForwardTask = Task { [realtime, logger, sessionId] in
            await Self.forwardUplink(
                stream,
                realtime: realtime,
                batchFrames: Self.uplinkForwardBatchFrames,
                logger: logger,
                sessionId: sessionId
            )
        }
    }

    private func stopUplinkForwarder() {
        uplinkStreamContinuation?.finish()
        uplinkStreamContinuation = nil
        uplinkForwardTask?.cancel()
        uplinkForwardTask = nil
    }

    /// Drains the uplink stream on a background task so the device WS read loop
    /// is not blocked on OpenAI JSON/base64 round-trips.
    private static func forwardUplink(
        _ stream: AsyncStream<Data>,
        realtime: OpenAIRealtimeService,
        batchFrames: Int,
        logger: Logger,
        sessionId: String
    ) async {
        var batch: [Data] = []
        batch.reserveCapacity(batchFrames)
        var forwarded = 0

        func flush() async {
            guard !batch.isEmpty else { return }
            let count = batch.count
            await realtime.appendAudioFrames(batch)
            forwarded += count
            logger.debug(
                "uplink forwarded batch",
                metadata: [
                    "session_id": .string(sessionId),
                    "batch_frames": "\(count)",
                    "forwarded_total": "\(forwarded)",
                ]
            )
            batch.removeAll(keepingCapacity: true)
        }

        for await frame in stream {
            if Task.isCancelled { break }
            batch.append(frame)
            if batch.count >= batchFrames {
                await flush()
            }
        }
        await flush()
    }

    private func waitForUplinkDrain() async {
        uplinkStreamContinuation?.finish()
        uplinkStreamContinuation = nil
        await uplinkForwardTask?.value
        uplinkForwardTask = nil
    }

    func handleAudioStop() {
        guard phase == .capturing else {
            logger.warning(
                "audio.stop ignored — not capturing",
                metadata: ["session_id": .string(sessionId), "phase": .string("\(phase)")]
            )
            return
        }
        turnCounter += 1
        let turnId = "turn-\(turnCounter)"
        let frameCount = uplinkFrameCounter
        let expectedFrames: Int? = uplinkCaptureStartedAt.map { started in
            max(1, Int(Date().timeIntervalSince(started) * 1000.0 / Double(AudioParams.uplink.frameMs)))
        }
        uplinkCaptureStartedAt = nil
        logger.info(
            "audio.stop",
            metadata: [
                "session_id": .string(sessionId),
                "turn_id": .string(turnId),
                "frames": "\(frameCount)",
                "expected_frames": expectedFrames.map { "\($0)" } ?? "unknown",
                "phase": .string("\(phase)"),
            ]
        )
        if let expectedFrames, frameCount + 2 < expectedFrames {
            logger.warning(
                "uplink frame deficit — ESP likely dropped frames before they reached the server",
                metadata: [
                    "session_id": .string(sessionId),
                    "turn_id": .string(turnId),
                    "frames": "\(frameCount)",
                    "expected_frames": "\(expectedFrames)",
                    "missing_frames": "\(expectedFrames - frameCount)",
                ]
            )
        }
        logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.audio_stop", "turn_id": .string(turnId)])
        dumpDebugUplinkAudio(uplinkPCMDump, turnId: turnId)

        if dumpOnlyMode {
            phase = .connected
            uplinkFrameCounter = 0
            uplinkPCMDump.removeAll(keepingCapacity: true)
            stopUplinkForwarder()
            logger.info(
                "dump-only turn complete",
                metadata: ["session_id": .string(sessionId), "turn_id": .string(turnId)]
            )
            return
        }

        if frameCount == 0 {
            logger.warning(
                "audio.stop with zero uplink frames — skipping AI turn",
                metadata: ["session_id": .string(sessionId), "turn_id": .string(turnId)]
            )
            phase = .connected
            uplinkFrameCounter = 0
            uplinkPCMDump.removeAll(keepingCapacity: true)
            stopUplinkForwarder()
            Task {
                try? await send(ErrorMessage(code: "no_uplink_audio", message: "No mic audio received — hold longer and try again"))
            }
            return
        }

        phase = .processing
        pipelineTask = Task { [weak self] in
            await self?.waitForUplinkDrain()
            await self?.runRealtimeTurn(turnId: turnId)
        }
    }

    func sendUnsupportedTranscriptInput() async throws {
        try await send(ErrorMessage(code: "unsupported_event", message: "transcript.input removed — use audio uplink"))
        phase = .connected
    }

    func handleAbort(reason: String) async {
        logger.info(
            "abort",
            metadata: ["session_id": .string(sessionId), "reason": .string(reason), "phase": .string("\(phase)")]
        )
        pipelineTask?.cancel()
        pipelineTask = nil
        stopUplinkForwarder()
        await realtime.cancelResponse()
        if let contextId = activeContextId, let tts {
            await tts.cancelTurn(contextId: contextId)
            activeContextId = nil
        }
        await downlinkPacer.cancel()
        dumpDownlinkCaptureIfNeeded()
        phase = .connected
        Task {
            try? await send(TTSEnd(sessionId: sessionId))
            await mirrorTTSEnd()
        }
    }

    func handleDisconnect() {
        pipelineTask?.cancel()
        pipelineTask = nil
        stopUplinkForwarder()
        Task { await realtime.close() }
        Task { await downlinkPacer.cancel() }
        if conversationSessionStarted {
            Task { [conversations, sessionId, logger] in
                do {
                    try await conversations.endSession(id: sessionId)
                } catch {
                    logger.warning(
                        "failed to end conversation session",
                        metadata: ["session_id": .string(sessionId), "error": "\(error)"]
                    )
                }
            }
        }
        logger.info("session disconnected", metadata: ["session_id": .string(sessionId)])
    }

    private func runRealtimeTurn(turnId: String) async {
        if tts != nil {
            await runRealtimeCartesiaTurn(turnId: turnId)
        } else {
            await runRealtimeOpenAITurn(turnId: turnId)
        }
    }

    /// OpenAI Realtime text-only → Cartesia Sonic TTS. LLM tokens stream to Cartesia
    /// while a parallel task forwards Cartesia PCM to the downlink pacer.
    private func runRealtimeCartesiaTurn(turnId: String) async {
        guard let tts else { return }
        let t0 = Date()
        logger.info("realtime+cartesia turn start", metadata: ["session_id": .string(sessionId), "turn_id": .string(turnId)])

        do {
            phase = .streamingTTS
            await beginDownlinkCapture(turnId: turnId)
            try await send(TTSStart(sessionId: sessionId))
            await mirrorTTSStart()
            logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.tts_start", "turn_id": .string(turnId)])

            let contextId = "\(sessionId)-\(turnId)"
            activeContextId = contextId
            let audioEvents = await tts.beginTurn(contextId: contextId)
            var downlinkFrames = 0

            let downlinkTask = Task { [weak self, sessionId] () -> Int in
                var frameCount = 0
                for await event in audioEvents {
                    switch event {
                    case .audio(let pcm):
                        if frameCount == 0 {
                            self?.logger.info(
                                "e2e stage",
                                metadata: ["session_id": .string(sessionId), "stage": "server.first_downlink_audio", "turn_id": .string(turnId)]
                            )
                        }
                        frameCount += await self?.sendDownlinkPCM(pcm) ?? 0
                    case .done:
                        break
                    case .error(let message):
                        self?.logger.error("cartesia tts error", metadata: ["session_id": .string(sessionId), "error": .string(message)])
                    }
                }
                return frameCount
            }

            logger.info("realtime commitAndCreateResponse — waiting for text events", metadata: ["session_id": .string(sessionId)])
            let events = await realtime.commitAndCreateResponse()
            var inputText = ""
            var assistantText = ""

            for await event in events {
                try Task.checkCancellation()
                switch event {
                case .audio:
                    logger.warning("unexpected realtime audio in cartesia tts mode", metadata: ["session_id": .string(sessionId)])
                case .inputTranscript(let text):
                    inputText = text
                    logger.info("realtime input transcript", metadata: ["session_id": .string(sessionId), "text": .string(text)])
                    try? await send(TranscriptFinal(sessionId: sessionId, text: text))
                    logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.transcript_ready", "turn_id": .string(turnId)])
                case .assistantTranscript(let delta):
                    assistantText += delta
                    logger.debug("realtime text delta → cartesia", metadata: ["session_id": .string(sessionId), "delta": .string(delta)])
                    await tts.sendTranscriptChunk(delta, contextId: contextId, isFinal: false)
                case .toolCallStarted(let name, let detail):
                    logger.info(
                        "tool call in progress",
                        metadata: ["session_id": .string(sessionId), "name": .string(name), "detail": .string(detail)]
                    )
                    try? await send(ToolStart(sessionId: sessionId, turnId: turnId, tool: name, label: detail))
                case .toolCallCompleted(let name, let detail, let argumentsJSON, let output):
                    await recordToolCallCompleted(
                        name: name, detail: detail, argumentsJSON: argumentsJSON, output: output, turnId: turnId
                    )
                case .done:
                    logger.info("realtime text stream done", metadata: ["session_id": .string(sessionId)])
                case .error(let msg):
                    logger.error("realtime event error", metadata: ["session_id": .string(sessionId), "msg": .string(msg)])
                }
            }

            await tts.sendTranscriptChunk("", contextId: contextId, isFinal: true)
            downlinkFrames = await downlinkTask.value
            activeContextId = nil

            await persistConversationTurn(turnId: turnId, inputText: inputText, assistantText: assistantText)

            guard phase == .streamingTTS else { return }
            await downlinkPacer.endTurn()
            dumpDownlinkCaptureIfNeeded()
            try await send(TTSEnd(sessionId: sessionId))
            await mirrorTTSEnd()
            phase = .connected
            logger.info(
                "realtime+cartesia turn complete",
                metadata: [
                    "session_id": .string(sessionId),
                    "turn_id": .string(turnId),
                    "total_ms": "\(Int(Date().timeIntervalSince(t0) * 1000))",
                    "downlink_frames": "\(downlinkFrames)",
                ]
            )
            logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.tts_end", "turn_id": .string(turnId)])
        } catch is CancellationError {
            if let contextId = activeContextId {
                await tts.cancelTurn(contextId: contextId)
                activeContextId = nil
            }
            await downlinkPacer.cancel()
            dumpDownlinkCaptureIfNeeded()
            logger.info("realtime+cartesia turn cancelled", metadata: ["session_id": .string(sessionId)])
        } catch {
            if let contextId = activeContextId {
                await tts.cancelTurn(contextId: contextId)
                activeContextId = nil
            }
            await downlinkPacer.cancel()
            dumpDownlinkCaptureIfNeeded()
            logger.error("realtime+cartesia turn failed", metadata: ["session_id": .string(sessionId), "error": "\(error)"])
            try? await send(ErrorMessage(code: "realtime_failed", message: "\(error)"))
            phase = .connected
        }
    }

    /// OpenAI Realtime end-to-end: speech in, model audio out.
    private func runRealtimeOpenAITurn(turnId: String) async {
        let t0 = Date()
        logger.info("realtime turn start", metadata: ["session_id": .string(sessionId), "turn_id": .string(turnId)])

        do {
            phase = .streamingTTS
            await beginDownlinkCapture(turnId: turnId)
            try await send(TTSStart(sessionId: sessionId))
            await mirrorTTSStart()
            logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.tts_start", "turn_id": .string(turnId)])

            logger.info("realtime commitAndCreateResponse — waiting for events", metadata: ["session_id": .string(sessionId)])
            let events = await realtime.commitAndCreateResponse()
            logger.info("realtime stream open — iterating events", metadata: ["session_id": .string(sessionId)])
            var inputText = ""
            var assistantText = ""
            var downlinkFrames = 0

            for await event in events {
                try Task.checkCancellation()
                switch event {
                case .audio(let pcm):
                    if downlinkFrames == 0 {
                        logger.info("realtime first audio chunk received", metadata: ["session_id": .string(sessionId), "bytes": "\(pcm.count)"])
                        logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.first_downlink_audio", "turn_id": .string(turnId)])
                    }
                    let chunks = await sendDownlinkPCM(pcm)
                    downlinkFrames += chunks
                    logger.debug("realtime audio pcm=\(pcm.count)b encoded_chunks=\(chunks)", metadata: ["session_id": .string(sessionId)])
                case .inputTranscript(let text):
                    inputText = text
                    logger.info("realtime input transcript", metadata: ["session_id": .string(sessionId), "text": .string(text)])
                    try? await send(TranscriptFinal(sessionId: sessionId, text: text))
                    logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.transcript_ready", "turn_id": .string(turnId)])
                case .assistantTranscript(let delta):
                    assistantText += delta
                    logger.debug("realtime assistant delta", metadata: ["session_id": .string(sessionId), "delta": .string(delta)])
                case .toolCallStarted(let name, let detail):
                    logger.info(
                        "tool call in progress",
                        metadata: ["session_id": .string(sessionId), "name": .string(name), "detail": .string(detail)]
                    )
                    try? await send(ToolStart(sessionId: sessionId, turnId: turnId, tool: name, label: detail))
                case .toolCallCompleted(let name, let detail, let argumentsJSON, let output):
                    await recordToolCallCompleted(
                        name: name, detail: detail, argumentsJSON: argumentsJSON, output: output, turnId: turnId
                    )
                case .done:
                    logger.info("realtime stream done", metadata: ["session_id": .string(sessionId)])
                case .error(let msg):
                    logger.error("realtime event error", metadata: ["session_id": .string(sessionId), "msg": .string(msg)])
                }
            }
            logger.info("realtime event loop finished", metadata: ["session_id": .string(sessionId), "downlink_frames": "\(downlinkFrames)"])

            await persistConversationTurn(turnId: turnId, inputText: inputText, assistantText: assistantText)

            guard phase == .streamingTTS else { return }
            await downlinkPacer.endTurn()
            dumpDownlinkCaptureIfNeeded()
            try await send(TTSEnd(sessionId: sessionId))
            await mirrorTTSEnd()
            phase = .connected
            logger.info(
                "realtime turn complete",
                metadata: [
                    "session_id": .string(sessionId),
                    "turn_id": .string(turnId),
                    "total_ms": "\(Int(Date().timeIntervalSince(t0) * 1000))",
                    "downlink_frames": "\(downlinkFrames)",
                ]
            )
            logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.tts_end", "turn_id": .string(turnId)])
        } catch is CancellationError {
            await downlinkPacer.cancel()
            dumpDownlinkCaptureIfNeeded()
            logger.info("realtime turn cancelled", metadata: ["session_id": .string(sessionId)])
        } catch {
            await downlinkPacer.cancel()
            dumpDownlinkCaptureIfNeeded()
            logger.error("realtime turn failed", metadata: ["session_id": .string(sessionId), "error": "\(error)"])
            try? await send(ErrorMessage(code: "realtime_failed", message: "\(error)"))
            phase = .connected
        }
    }

    private func beginDownlinkCapture(turnId: String) async {
        downlinkTurnId = turnId
        downlinkPCMDump.removeAll(keepingCapacity: true)
        toolCallsThisTurn.removeAll(keepingCapacity: true)
        await downlinkPacer.beginTurn()
    }

    /// Builds the structured tool call, buffers it for `persistConversationTurn`, and sends
    /// `tool.done` over the WebSocket. Shared by both the Cartesia and OpenAI turn event loops.
    /// `handled_ms` tracks only this synchronous portion — the memory context refresh below is
    /// fire-and-forget precisely so it does not inflate this number or delay the next event in
    /// this turn's stream (audio/transcript deltas queued behind this await would otherwise
    /// stall on a Postgres round trip + Realtime `session.update`).
    private func recordToolCallCompleted(
        name: String,
        detail: String,
        argumentsJSON: String,
        output: String,
        turnId: String
    ) async {
        let handledStart = Date()
        let call = ConversationToolCallBuilder.build(
            id: ConversationToolCallBuilder.makeId(),
            name: name,
            detail: detail,
            argumentsJSON: argumentsJSON,
            outputJSON: output,
            createdAt: Date()
        )
        toolCallsThisTurn.append(BufferedToolCall(call: call, argumentsJSON: argumentsJSON, outputJSON: output))
        try? await send(ToolDone(sessionId: sessionId, turnId: turnId, call: call))
        logger.info(
            "tool call completed",
            metadata: [
                "session_id": .string(sessionId),
                "name": .string(name),
                "status": .string(call.status),
                "handled_ms": "\(Int(Date().timeIntervalSince(handledStart) * 1000))",
            ]
        )
        scheduleMemoryContextRefreshIfMutated(name: name, argumentsJSON: argumentsJSON, status: call.status)
    }

    /// Re-inject saved facts into the Realtime system prompt after remember/forget so the
    /// model can recall them in the same session without a reconnect. Runs detached from the
    /// turn's event loop — see `recordToolCallCompleted` — so a slow memory list or session
    /// update never delays this turn's own audio/response streaming.
    private func scheduleMemoryContextRefreshIfMutated(name: String, argumentsJSON: String, status: String) {
        guard name == "memory", status == "success", saveConversationHistory else { return }
        guard let args = SubAgentJSON.parseArguments(argumentsJSON),
              let action = args["action"] as? String
        else { return }
        guard action == "remember" || action == "forget" else { return }
        Task { [weak self] in
            await self?.refreshMemoryContext(trigger: "memory_\(action)")
        }
    }

    private func sendDownlinkPCM(_ pcm: Data) async -> Int {
        downlinkPCMDump.append(pcm)
        return (try? await downlinkPacer.enqueue(pcm: pcm)) ?? 0
    }

    private func dumpDownlinkCaptureIfNeeded() {
        guard let turnId = downlinkTurnId else { return }
        dumpDebugDownlinkAudio(downlinkPCMDump, turnId: turnId)
        downlinkTurnId = nil
    }

    /// Persists the transcript and WAV audio for one turn when the user has opted in via
    /// `privacy.personalizationData`. Never throws — a storage failure must not fail the
    /// voice turn itself, so errors are only logged.
    private func persistConversationTurn(turnId: String, inputText: String, assistantText: String) async {
        guard saveConversationHistory else { return }
        let hasContent = !inputText.isEmpty || !assistantText.isEmpty || !uplinkPCMDump.isEmpty
            || !downlinkPCMDump.isEmpty || !toolCallsThisTurn.isEmpty
        guard hasContent else { return }
        do {
            try await conversations.ensureSession(id: sessionId)
            conversationSessionStarted = true
            let uplinkPath = conversationAudio.saveUplink(sessionId: sessionId, turnId: turnId, pcm: uplinkPCMDump)
            let downlinkPath = conversationAudio.saveDownlink(sessionId: sessionId, turnId: turnId, pcm: downlinkPCMDump)
            if !inputText.isEmpty || uplinkPath != nil {
                try await conversations.appendMessage(
                    sessionId: sessionId,
                    turnId: turnId,
                    role: "user",
                    content: inputText,
                    audioPath: uplinkPath
                )
            }
            if !assistantText.isEmpty || downlinkPath != nil {
                try await conversations.appendMessage(
                    sessionId: sessionId,
                    turnId: turnId,
                    role: "assistant",
                    content: assistantText,
                    audioPath: downlinkPath
                )
            }
            for buffered in toolCallsThisTurn {
                try await conversations.appendToolCall(
                    id: buffered.call.id,
                    sessionId: sessionId,
                    turnId: turnId,
                    name: buffered.call.tool,
                    detail: buffered.call.label,
                    arguments: buffered.argumentsJSON,
                    output: buffered.outputJSON,
                    createdAt: buffered.call.createdAt
                )
            }
        } catch {
            logger.warning(
                "failed to persist conversation turn",
                metadata: ["session_id": .string(sessionId), "turn_id": .string(turnId), "error": "\(error)"]
            )
        }
    }

    private func dumpDebugUplinkAudio(_ pcm: Data, turnId: String) {
        guard !pcm.isEmpty else { return }
        do {
            let directory = try Self.debugAudioDirectory()
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let filename = "\(timestamp)-\(sessionId)-\(turnId)-uplink.wav"
            let fileURL = directory.appendingPathComponent(filename)
            try WAVWriter.wrap(pcm: pcm, sampleRate: AudioParams.uplink.sampleRate).write(to: fileURL)
            print("[debug-audio] uplink → \(fileURL.path) (\(pcm.count) bytes PCM)")
            logger.info(
                "uplink debug audio saved",
                metadata: [
                    "session_id": .string(sessionId),
                    "turn_id": .string(turnId),
                    "path": .string(fileURL.path),
                    "bytes": "\(pcm.count)",
                ]
            )
        } catch {
            logger.warning(
                "failed to save uplink debug audio",
                metadata: ["session_id": .string(sessionId), "turn_id": .string(turnId), "error": "\(error)"]
            )
        }
    }

    private func dumpDebugDownlinkAudio(_ pcm: Data, turnId: String) {
        guard !pcm.isEmpty else { return }
        do {
            let directory = try Self.debugAudioDirectory()
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let filename = "\(timestamp)-\(sessionId)-\(turnId)-downlink.wav"
            let fileURL = directory.appendingPathComponent(filename)
            try WAVWriter.wrap(pcm: pcm, sampleRate: AudioParams.downlink.sampleRate).write(to: fileURL)
            print("[debug-audio] downlink → \(fileURL.path) (\(pcm.count) bytes PCM)")
            logger.info(
                "downlink debug audio saved",
                metadata: [
                    "session_id": .string(sessionId),
                    "turn_id": .string(turnId),
                    "path": .string(fileURL.path),
                    "bytes": "\(pcm.count)",
                ]
            )
        } catch {
            logger.warning(
                "failed to save downlink debug audio",
                metadata: ["session_id": .string(sessionId), "turn_id": .string(turnId), "error": "\(error)"]
            )
        }
    }

    private static func debugAudioDirectory() throws -> URL {
        let fm = FileManager.default
        if let root = PackagePaths.packageRoot() {
            let debugDir = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent("debug-audio", isDirectory: true)
            try fm.createDirectory(at: debugDir, withIntermediateDirectories: true)
            return debugDir
        }

        let fallback = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("debug-audio", isDirectory: true)
        try fm.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    private func send<T: Encodable>(_ value: T) async throws {
        let data = try JSONEncoder().encode(value)
        let text = String(decoding: data, as: UTF8.self)
        logger.debug("ws send text", metadata: ["session_id": .string(sessionId), "json": .string(text)])
        try await outbound.writeText(text)
    }

    private func mirrorTTSStart() async {
        let data = try? JSONEncoder().encode(TTSStart(sessionId: sessionId))
        guard let data, let text = String(data: data, encoding: .utf8) else { return }
        await speakers.broadcastText(text)
    }

    private func mirrorTTSEnd() async {
        let data = try? JSONEncoder().encode(TTSEnd(sessionId: sessionId))
        guard let data, let text = String(data: data, encoding: .utf8) else { return }
        await speakers.broadcastText(text)
    }
}
