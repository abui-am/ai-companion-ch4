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

private struct ChatMessage: Sendable {
    let role: String
    let content: String
}

actor VoiceSession {
    private let sessionId = UUID().uuidString
    private let outbound: SessionOutboundWriter
    private let realtime: OpenAIRealtimeService
    private let tts: (any TTSStreamingService)?
    private let speakers: SpeakerRegistry
    private let downlinkPacer: DownlinkPacer
    private let logger: Logger

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
    private var dumpOnlyMode = false
    private var conversationHistory: [ChatMessage] = []
    private let maxHistoryMessages = 20

    init(
        outbound: SessionOutboundWriter,
        realtime: OpenAIRealtimeService,
        tts: (any TTSStreamingService)? = nil,
        speakers: SpeakerRegistry,
        logger: Logger
    ) {
        self.outbound = outbound
        self.realtime = realtime
        self.tts = tts
        self.speakers = speakers
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
        if let language = start.language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
            logger.info(
                "session response language override",
                metadata: ["session_id": .string(sessionId), "language": .string(language)]
            )
            await realtime.setResponseLanguage(language)
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
                case .done:
                    logger.info("realtime text stream done", metadata: ["session_id": .string(sessionId)])
                case .error(let msg):
                    logger.error("realtime event error", metadata: ["session_id": .string(sessionId), "msg": .string(msg)])
                }
            }

            await tts.sendTranscriptChunk("", contextId: contextId, isFinal: true)
            downlinkFrames = await downlinkTask.value
            activeContextId = nil

            if !inputText.isEmpty {
                conversationHistory.append(ChatMessage(role: "user", content: inputText))
            }
            if !assistantText.isEmpty {
                conversationHistory.append(ChatMessage(role: "assistant", content: assistantText))
                if conversationHistory.count > maxHistoryMessages {
                    conversationHistory.removeFirst(conversationHistory.count - maxHistoryMessages)
                }
            }

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
                case .done:
                    logger.info("realtime stream done", metadata: ["session_id": .string(sessionId)])
                case .error(let msg):
                    logger.error("realtime event error", metadata: ["session_id": .string(sessionId), "msg": .string(msg)])
                }
            }
            logger.info("realtime event loop finished", metadata: ["session_id": .string(sessionId), "downlink_frames": "\(downlinkFrames)"])

            if !inputText.isEmpty {
                conversationHistory.append(ChatMessage(role: "user", content: inputText))
            }
            if !assistantText.isEmpty {
                conversationHistory.append(ChatMessage(role: "assistant", content: assistantText))
                if conversationHistory.count > maxHistoryMessages {
                    conversationHistory.removeFirst(conversationHistory.count - maxHistoryMessages)
                }
            }

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
        await downlinkPacer.beginTurn()
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

    private func dumpDebugUplinkAudio(_ pcm: Data, turnId: String) {
        guard !pcm.isEmpty else { return }
        do {
            let directory = try Self.debugAudioDirectory()
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let filename = "\(timestamp)-\(sessionId)-\(turnId)-uplink.wav"
            let fileURL = directory.appendingPathComponent(filename)
            try Self.wrapWAV(pcm: pcm, sampleRate: AudioParams.uplink.sampleRate).write(to: fileURL)
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
            try Self.wrapWAV(pcm: pcm, sampleRate: AudioParams.downlink.sampleRate).write(to: fileURL)
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

    private static func wrapWAV(pcm: Data, sampleRate: Int) -> Data {
        var header = Data()
        let byteRate = sampleRate * 2
        let blockAlign: UInt16 = 2
        let dataSize = UInt32(pcm.count)
        let chunkSize = 36 + dataSize

        header.append(contentsOf: "RIFF".utf8)
        header.append(littleEndian: chunkSize)
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(littleEndian: UInt32(16))
        header.append(littleEndian: UInt16(1))
        header.append(littleEndian: UInt16(1))
        header.append(littleEndian: UInt32(sampleRate))
        header.append(littleEndian: UInt32(byteRate))
        header.append(littleEndian: blockAlign)
        header.append(littleEndian: UInt16(16))
        header.append(contentsOf: "data".utf8)
        header.append(littleEndian: dataSize)
        header.append(pcm)
        return header
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

private extension Data {
    mutating func append(littleEndian value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func append(littleEndian value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
