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
    private let tts: TTSStreamingService
    private let stt: CartesiaSTTServiceProtocol
    private let speakers: SpeakerRegistry
    private let realtime: OpenAIRealtimeService?
    private let downlinkPacer: DownlinkPacer
    private let logger: Logger

    private var phase: SessionPhase = .connected
    private var pipelineTask: Task<Void, Never>?
    private var activeContextId: String?
    private var turnCounter = 0
    private var uplinkFrameCounter = 0
    private var uplinkPCMDump = Data()
    private var downlinkPCMDump = Data()
    private var downlinkTurnId: String?
    private var conversationHistory: [ChatMessage] = []
    private let maxHistoryMessages = 20

    init(
        outbound: SessionOutboundWriter,
        openAI: OpenAIService,
        tts: TTSStreamingService,
        stt: CartesiaSTTServiceProtocol,
        speakers: SpeakerRegistry,
        realtime: OpenAIRealtimeService? = nil,
        logger: Logger
    ) {
        self.outbound = outbound
        self.openAI = openAI
        self.tts = tts
        self.stt = stt
        self.speakers = speakers
        self.realtime = realtime
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
        if let realtime {
            Task { await realtime.connect() }
        } else {
            Task { await stt.connect() }
        }
        let ready = SessionReady(sessionId: sessionId, audio: .downlink)
        try await send(ready)
    }

    func handleAudioStart() {
        phase = .capturing
        uplinkFrameCounter = 0
        uplinkPCMDump.removeAll(keepingCapacity: true)
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
        uplinkPCMDump.append(data)
        logger.debug(
            "uplink frame",
            metadata: ["session_id": .string(sessionId), "frame": "\(uplinkFrameCounter)", "bytes": "\(data.count)"]
        )
        if let realtime {
            await realtime.appendAudioFrame(data)
        } else {
            await stt.sendAudio(data)
        }
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
        dumpDebugUplinkAudio(uplinkPCMDump, turnId: turnId)

        if realtime != nil {
            pipelineTask = Task { [weak self] in
                await self?.runRealtimeTurn(turnId: turnId)
            }
        } else {
            pipelineTask = Task { [weak self] in
                await self?.runPipeline(turnId: turnId, frameCount: frameCount)
            }
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
        if let realtime {
            await realtime.cancelResponse()
        } else {
            if let contextId = activeContextId {
                await tts.cancelTurn(contextId: contextId)
                activeContextId = nil
            }
            // Closing/reconnecting the STT socket unblocks any pending finalize() wait immediately.
            await stt.close()
            Task { await stt.connect() }
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
        if let realtime {
            Task { await realtime.close() }
        } else {
            if let contextId = activeContextId {
                Task { await tts.cancelTurn(contextId: contextId) }
                activeContextId = nil
            }
            Task { await stt.close() }
        }
        Task { await downlinkPacer.cancel() }
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

    /// Single-roundtrip realtime pipeline: committed audio → OpenAI Realtime API
    /// → streamed PCM audio back to the client. Bypasses STT, LLM, and TTS stages.
    private func runRealtimeTurn(turnId: String) async {
        guard let realtime else { return }
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
            var firstDownlinkAt: Date?

            for await event in events {
                try Task.checkCancellation()
                switch event {
                case .audio(let pcm):
                    if firstDownlinkAt == nil {
                        firstDownlinkAt = Date()
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
            await beginDownlinkCapture(turnId: turnId)
            try await send(TTSStart(sessionId: sessionId))
            await mirrorTTSStart()
            logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.tts_start", "turn_id": .string(turnId)])

            let contextId = "\(sessionId)-\(turnId)"
            activeContextId = contextId
            let audioEvents = await tts.beginTurn(contextId: contextId)

            var tLlmFirstToken: Date?
            var tTtsFirstByte: Date?
            var tWsFirstSent: Date?
            var downlinkFrameCount = 0

            let downlinkTask = Task { [weak self, sessionId] () -> DownlinkResult in
                var firstByte: Date?
                var firstWsSent: Date?
                var frameCount = 0
                for await event in audioEvents {
                    switch event {
                    case .audio(let pcm):
                        if firstByte == nil {
                            firstByte = Date()
                            self?.logger.info(
                                "e2e stage",
                                metadata: ["session_id": .string(sessionId), "stage": "server.first_tts_audio_chunk", "turn_id": .string(turnId)]
                            )
                        }
                        let chunks = await self?.sendDownlinkPCM(pcm) ?? 0
                        if chunks > 0, firstWsSent == nil {
                            firstWsSent = Date()
                            self?.logger.info(
                                "e2e stage",
                                metadata: ["session_id": .string(sessionId), "stage": "server.first_downlink_audio", "turn_id": .string(turnId)]
                            )
                        }
                        frameCount += chunks
                    case .done:
                        break
                    case .error(let message):
                        self?.logger.error("tts stream error", metadata: ["session_id": .string(sessionId), "error": .string(message)])
                    }
                }
                return DownlinkResult(frameCount: frameCount, firstByte: firstByte, firstWsSent: firstWsSent)
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
                    await tts.sendTranscriptChunk(text, contextId: contextId, isFinal: false)
                case .done(let result):
                    chatResult = result
                }
            }
            await tts.sendTranscriptChunk("", contextId: contextId, isFinal: true)
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

            guard phase == .streamingTTS else { return }
            await downlinkPacer.endTurn()
            dumpDownlinkCaptureIfNeeded()
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
            await downlinkPacer.cancel()
            dumpDownlinkCaptureIfNeeded()
            logger.info("pipeline cancelled", metadata: ["session_id": .string(sessionId)])
        } catch {
            activeContextId = nil
            await downlinkPacer.cancel()
            dumpDownlinkCaptureIfNeeded()
            logger.error("pipeline failed", metadata: ["session_id": .string(sessionId), "error": "\(error)"])
            try? await send(ErrorMessage(code: "pipeline_failed", message: "\(error)"))
            phase = .connected
        }
    }

    private struct DownlinkResult {
        let frameCount: Int
        let firstByte: Date?
        let firstWsSent: Date?
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

    private func ms(_ a: Date, _ b: Date) -> Int {
        max(0, Int(b.timeIntervalSince(a) * 1000))
    }

    private func dumpDebugUplinkAudio(_ pcm: Data, turnId: String) {
        guard !pcm.isEmpty else { return }
        do {
            let directory = try Self.debugAudioDirectory()
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let filename = "\(timestamp)-\(sessionId)-\(turnId)-uplink.wav"
            let fileURL = directory.appendingPathComponent(filename)
            try Self.wrapWAV(pcm: pcm, sampleRate: AudioParams.uplink.sampleRate).write(to: fileURL)
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
