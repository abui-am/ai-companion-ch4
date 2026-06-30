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

actor VoiceSession {
    private let sessionId = UUID().uuidString
    private let outbound: SessionOutboundWriter
    private let openAI: OpenAIService
    private let cartesia: CartesiaTTSService
    private let stt: CartesiaSTTServiceProtocol
    private let speakers: SpeakerRegistry
    private let logger: Logger

    private var phase: SessionPhase = .connected
    private var pipelineTask: Task<Void, Never>?
    private var activeContextId: String?
    private var turnCounter = 0
    private var uplinkFrameCounter = 0
    private var conversationHistory: [ChatMessage] = []
    private let maxHistoryMessages = 20

    init(
        outbound: SessionOutboundWriter,
        openAI: OpenAIService,
        cartesia: CartesiaTTSService,
        stt: CartesiaSTTServiceProtocol,
        speakers: SpeakerRegistry,
        logger: Logger
    ) {
        self.outbound = outbound
        self.openAI = openAI
        self.cartesia = cartesia
        self.stt = stt
        self.speakers = speakers
        self.logger = logger
    }

    func start() async throws {
        phase = .connected
        logger.info("session started", metadata: ["session_id": .string(sessionId)])
        Task { await stt.connect() }
        let ready = SessionReady(sessionId: sessionId, audio: .downlink)
        try await send(ready)
    }

    func handleAudioStart() {
        phase = .capturing
        uplinkFrameCounter = 0
        logger.info("audio.start", metadata: ["session_id": .string(sessionId), "phase": .string("\(phase)")])
    }

    func handleOpusFrame(_ data: Data) async {
        guard phase == .capturing else {
            logger.debug(
                "ignored uplink frame — not capturing",
                metadata: ["session_id": .string(sessionId), "phase": .string("\(phase)"), "bytes": "\(data.count)"]
            )
            return
        }
        uplinkFrameCounter += 1
        logger.debug(
            "uplink frame forwarded to stt",
            metadata: ["session_id": .string(sessionId), "frame": "\(uplinkFrameCounter)", "bytes": "\(data.count)"]
        )
        await stt.sendAudio(data)
    }

    func handleAudioStop() {
        guard phase == .capturing else {
            logger.warning(
                "audio.stop ignored — not capturing",
                metadata: ["session_id": .string(sessionId), "phase": .string("\(phase)")]
            )
            return
        }
        phase = .processing
        turnCounter += 1
        let turnId = "turn-\(turnCounter)"
        let frameCount = uplinkFrameCounter
        logger.info(
            "audio.stop",
            metadata: [
                "session_id": .string(sessionId),
                "turn_id": .string(turnId),
                "frames": "\(frameCount)",
                "phase": .string("\(phase)"),
            ]
        )
        logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.audio_stop", "turn_id": .string(turnId)])

        pipelineTask = Task { [weak self] in
            await self?.runPipeline(turnId: turnId, frameCount: frameCount)
        }
    }

    func handleTranscriptInput(_ text: String) {
        phase = .processing
        turnCounter += 1
        let turnId = "turn-\(turnCounter)"
        logger.info(
            "transcript.input",
            metadata: ["session_id": .string(sessionId), "turn_id": .string(turnId), "chars": "\(text.count)"]
        )
        logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.transcript_input", "turn_id": .string(turnId)])

        pipelineTask = Task { [weak self] in
            await self?.runPipelineFromTranscript(turnId: turnId, transcript: text)
        }
    }

    func handleAbort(reason: String) async {
        logger.info(
            "abort",
            metadata: ["session_id": .string(sessionId), "reason": .string(reason), "phase": .string("\(phase)")]
        )
        pipelineTask?.cancel()
        pipelineTask = nil
        if let contextId = activeContextId {
            await cartesia.cancelTurn(contextId: contextId)
            activeContextId = nil
        }
        // Closing/reconnecting the STT socket unblocks any pending finalize() wait immediately
        // instead of leaving the cancelled pipeline task suspended until its watchdog timeout.
        await stt.close()
        Task { await stt.connect() }
        phase = .connected
        Task {
            try? await send(TTSEnd(sessionId: sessionId))
            await mirrorTTSEnd()
        }
    }

    func handleDisconnect() {
        pipelineTask?.cancel()
        pipelineTask = nil
        if let contextId = activeContextId {
            Task { await cartesia.cancelTurn(contextId: contextId) }
            activeContextId = nil
        }
        Task { await stt.close() }
        logger.info("session disconnected", metadata: ["session_id": .string(sessionId)])
    }

    private func runPipeline(turnId: String, frameCount: Int) async {
        let t0 = Date()
        logger.info(
            "pipeline start",
            metadata: ["session_id": .string(sessionId), "turn_id": .string(turnId), "frames": "\(frameCount)"]
        )
        do {
            guard frameCount > 0 else {
                logger.warning("pipeline abort — no audio frames", metadata: ["session_id": .string(sessionId)])
                try await send(ErrorMessage(code: "no_audio", message: "No audio frames received"))
                phase = .connected
                return
            }

            logger.info("cartesia.stt finalize start", metadata: ["session_id": .string(sessionId)])
            let transcript = await stt.finalize()
            try Task.checkCancellation()
            let tAsrDone = Date()
            logger.info(
                "cartesia.stt finalize done",
                metadata: [
                    "session_id": .string(sessionId),
                    "chars": "\(transcript.count)",
                    "text": .string(transcript),
                    "ms": "\(ms(t0, tAsrDone))",
                ]
            )
            logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.transcript_ready", "turn_id": .string(turnId)])

            guard phase == .processing else { return }
            try await send(TranscriptFinal(sessionId: sessionId, text: transcript))

            await runChatAndSpeak(turnId: turnId, transcript: transcript, t0: t0, tAsrDone: tAsrDone, droppedFrames: 0)
        } catch is CancellationError {
            logger.info("pipeline cancelled", metadata: ["session_id": .string(sessionId)])
        } catch {
            logger.error("pipeline failed", metadata: ["session_id": .string(sessionId), "error": "\(error)"])
            try? await send(ErrorMessage(code: "pipeline_failed", message: "\(error)"))
            phase = .connected
        }
    }

    private func runPipelineFromTranscript(turnId: String, transcript: String) async {
        let t0 = Date()
        logger.info(
            "pipeline start",
            metadata: ["session_id": .string(sessionId), "turn_id": .string(turnId), "transcript_chars": "\(transcript.count)"]
        )

        do {
            let cleanedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let tAsrDone = Date()

            guard phase == .processing else { return }
            try await send(TranscriptFinal(sessionId: sessionId, text: cleanedTranscript))

            await runChatAndSpeak(turnId: turnId, transcript: cleanedTranscript, t0: t0, tAsrDone: tAsrDone, droppedFrames: 0)
        } catch is CancellationError {
            logger.info("pipeline cancelled", metadata: ["session_id": .string(sessionId)])
        } catch {
            logger.error("pipeline failed", metadata: ["session_id": .string(sessionId), "error": "\(error)"])
            try? await send(ErrorMessage(code: "pipeline_failed", message: "\(error)"))
            phase = .connected
        }
    }

    /// Streams the LLM reply token-by-token to Cartesia as it arrives and forwards
    /// Cartesia's streamed PCM audio to the downlink incrementally, so chat
    /// generation and TTS synthesis overlap instead of running sequentially.
    private func runChatAndSpeak(turnId: String, transcript: String, t0: Date, tAsrDone: Date, droppedFrames: Int) async {
        do {
            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                logger.warning("empty transcript — skipping chat/tts", metadata: ["session_id": .string(sessionId)])
                try await send(ErrorMessage(code: "empty_transcript", message: "No speech detected in recording"))
                phase = .connected
                return
            }

            phase = .streamingTTS
            try await send(TTSStart(sessionId: sessionId))
            await mirrorTTSStart()
            logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.tts_start", "turn_id": .string(turnId)])

            let contextId = "\(sessionId)-\(turnId)"
            activeContextId = contextId
            let audioEvents = await cartesia.beginTurn(contextId: contextId)

            var tLlmFirstToken: Date?
            var tTtsFirstByte: Date?
            var tWsFirstSent: Date?
            var downlinkFrameCount = 0
            var fullPCM = Data()

            let downlinkTask = Task { [outbound, speakers, logger, sessionId] () -> DownlinkResult in
                var firstByte: Date?
                var firstWsSent: Date?
                var frameCount = 0
                var pcmAccumulator = Data()
                for await event in audioEvents {
                    switch event {
                    case .audio(let pcm):
                        if firstByte == nil {
                            firstByte = Date()
                            logger.info(
                                "e2e stage",
                                metadata: ["session_id": .string(sessionId), "stage": "server.first_tts_audio_chunk", "turn_id": .string(turnId)]
                            )
                        }
                        pcmAccumulator.append(pcm)
                        let opusOut = (try? OpusCodec.encodeFromPCM(pcm, sampleRate: AudioParams.downlink.sampleRate)) ?? []
                        for chunk in opusOut {
                            if firstWsSent == nil {
                                firstWsSent = Date()
                                logger.info(
                                    "e2e stage",
                                    metadata: ["session_id": .string(sessionId), "stage": "server.first_downlink_audio", "turn_id": .string(turnId)]
                                )
                            }
                            frameCount += 1
                            try? await outbound.writeBinary(chunk)
                            await speakers.broadcastBinary(chunk)
                        }
                    case .done:
                        break
                    case .error(let message):
                        logger.error("cartesia stream error", metadata: ["session_id": .string(sessionId), "error": .string(message)])
                    }
                }
                return DownlinkResult(frameCount: frameCount, firstByte: firstByte, firstWsSent: firstWsSent, pcm: pcmAccumulator)
            }

            var chatResult = ChatToolResult(reply: "", command: nil)
            for try await event in openAI.chat(transcript: transcript, history: conversationHistory) {
                try Task.checkCancellation()
                switch event {
                case .token(let text):
                    if tLlmFirstToken == nil {
                        tLlmFirstToken = Date()
                        logger.info(
                            "e2e stage",
                            metadata: ["session_id": .string(sessionId), "stage": "server.llm_first_token", "turn_id": .string(turnId)]
                        )
                    }
                    await cartesia.sendTranscriptChunk(text, contextId: contextId, isFinal: false)
                case .done(let result):
                    chatResult = result
                }
            }
            await cartesia.sendTranscriptChunk("", contextId: contextId, isFinal: true)
            try Task.checkCancellation()
            let tLlmDone = Date()
            logger.info(
                "openai.chat done (streamed)",
                metadata: [
                    "session_id": .string(sessionId),
                    "reply_chars": "\(chatResult.reply.count)",
                    "reply": .string(chatResult.reply),
                    "has_command": "\(chatResult.command != nil)",
                    "ms": "\(ms(tAsrDone, tLlmDone))",
                ]
            )
            logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.chat_ready", "turn_id": .string(turnId)])

            conversationHistory.append(ChatMessage(role: "user", content: transcript))
            conversationHistory.append(ChatMessage(role: "assistant", content: chatResult.reply))
            if conversationHistory.count > maxHistoryMessages {
                conversationHistory.removeFirst(conversationHistory.count - maxHistoryMessages)
            }

            if let rawCommand = chatResult.command {
                do {
                    let validated = try CmdRouter.validate(rawCommand)
                    logger.info(
                        "device_command validated",
                        metadata: [
                            "session_id": .string(sessionId),
                            "action": .string(validated.action),
                            "r": "\(validated.params.r)",
                            "g": "\(validated.params.g)",
                            "b": "\(validated.params.b)",
                        ]
                    )
                    try await send(validated)
                } catch {
                    logger.error(
                        "invalid device_command rejected",
                        metadata: ["session_id": .string(sessionId), "error": "\(error)"]
                    )
                    try await send(ErrorMessage(code: "invalid_device_command", message: nil))
                }
            }

            let downlinkResult = await downlinkTask.value
            activeContextId = nil
            tTtsFirstByte = downlinkResult.firstByte
            tWsFirstSent = downlinkResult.firstWsSent
            downlinkFrameCount = downlinkResult.frameCount
            fullPCM = downlinkResult.pcm
            dumpDebugTTSAudio(fullPCM, turnId: turnId)

            guard phase == .streamingTTS else { return }
            try await send(TTSEnd(sessionId: sessionId))
            await mirrorTTSEnd()
            phase = .connected
            logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.tts_end", "turn_id": .string(turnId)])

            let tEnd = Date()
            let report = LatencyReport(
                sessionId: sessionId,
                turnId: turnId,
                ms: LatencyMs(
                    audioStopToAsrDone: ms(t0, tAsrDone),
                    asrDoneToLlmFirstToken: tLlmFirstToken.map { ms(tAsrDone, $0) } ?? 0,
                    llmFirstTokenToTtsFirstByte: (tLlmFirstToken != nil && tTtsFirstByte != nil) ? ms(tLlmFirstToken!, tTtsFirstByte!) : 0,
                    ttsFirstByteToWsSent: (tTtsFirstByte != nil && tWsFirstSent != nil) ? ms(tTtsFirstByte!, tWsFirstSent!) : 0,
                    audioStopToFirstDownlink: tWsFirstSent.map { ms(t0, $0) } ?? ms(t0, tEnd),
                    audioStopToFirstTtsAudioChunk: tTtsFirstByte.map { ms(t0, $0) } ?? 0
                ),
                droppedFrames: droppedFrames
            )
            try await send(report)
            logger.info(
                "pipeline complete",
                metadata: [
                    "session_id": .string(sessionId),
                    "turn_id": .string(turnId),
                    "total_ms": "\(ms(t0, tEnd))",
                    "downlink_frames": "\(downlinkFrameCount)",
                ]
            )
        } catch is CancellationError {
            activeContextId = nil
            logger.info("pipeline cancelled", metadata: ["session_id": .string(sessionId)])
        } catch {
            activeContextId = nil
            logger.error("pipeline failed", metadata: ["session_id": .string(sessionId), "error": "\(error)"])
            try? await send(ErrorMessage(code: "pipeline_failed", message: "\(error)"))
            phase = .connected
        }
    }

    private struct DownlinkResult {
        let frameCount: Int
        let firstByte: Date?
        let firstWsSent: Date?
        let pcm: Data
    }

    private func ms(_ a: Date, _ b: Date) -> Int {
        max(0, Int(b.timeIntervalSince(a) * 1000))
    }

    private func dumpDebugTTSAudio(_ pcm: Data, turnId: String) {
        do {
            let directory = try Self.debugAudioDirectory()
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let filename = "\(timestamp)-\(sessionId)-\(turnId).wav"
            let fileURL = directory.appendingPathComponent(filename)
            try Self.wrapWAV(pcm: pcm, sampleRate: AudioParams.downlink.sampleRate).write(to: fileURL)
            logger.info(
                "tts debug audio saved",
                metadata: [
                    "session_id": .string(sessionId),
                    "turn_id": .string(turnId),
                    "path": .string(fileURL.path),
                    "bytes": "\(pcm.count)",
                ]
            )
        } catch {
            logger.warning(
                "failed to save tts debug audio",
                metadata: ["session_id": .string(sessionId), "turn_id": .string(turnId), "error": "\(error)"]
            )
        }
    }

    private static func debugAudioDirectory() throws -> URL {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let packageFile = dir.appendingPathComponent("Package.swift")
            if fm.fileExists(atPath: packageFile.path) {
                let debugDir = dir.appendingPathComponent("debug-audio", isDirectory: true)
                try fm.createDirectory(at: debugDir, withIntermediateDirectories: true)
                return debugDir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
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
