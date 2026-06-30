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
    private let speakers: SpeakerRegistry
    private let logger: Logger

    private var phase: SessionPhase = .connected
    private var opusBuffer: [Data] = []
    private let maxBufferedFrames = 500
    private var droppedFrames = 0
    private var pipelineTask: Task<Void, Never>?
    private var turnCounter = 0
    private var uplinkFrameCounter = 0

    init(outbound: SessionOutboundWriter, openAI: OpenAIService, speakers: SpeakerRegistry, logger: Logger) {
        self.outbound = outbound
        self.openAI = openAI
        self.speakers = speakers
        self.logger = logger
    }

    func start() async throws {
        phase = .connected
        logger.info("session started", metadata: ["session_id": .string(sessionId)])
        let ready = SessionReady(sessionId: sessionId, audio: .downlink)
        try await send(ready)
    }

    func handleAudioStart() {
        phase = .capturing
        opusBuffer.removeAll()
        droppedFrames = 0
        uplinkFrameCounter = 0
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
        if opusBuffer.count >= maxBufferedFrames {
            opusBuffer.removeFirst()
            droppedFrames += 1
            logger.warning(
                "opus buffer cap exceeded, dropping oldest frame",
                metadata: ["session_id": .string(sessionId), "dropped_total": "\(droppedFrames)"]
            )
        }
        opusBuffer.append(data)
        uplinkFrameCounter += 1
        logger.debug(
            "uplink frame buffered",
            metadata: [
                "session_id": .string(sessionId),
                "frame": "\(uplinkFrameCounter)",
                "bytes": "\(data.count)",
                "buffered": "\(opusBuffer.count)",
            ]
        )
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
        let frames = opusBuffer
        let dropped = droppedFrames
        opusBuffer.removeAll()
        let totalBytes = frames.reduce(0) { $0 + $1.count }
        logger.info(
            "audio.stop",
            metadata: [
                "session_id": .string(sessionId),
                "turn_id": .string(turnId),
                "frames": "\(frames.count)",
                "bytes": "\(totalBytes)",
                "dropped": "\(dropped)",
                "phase": .string("\(phase)"),
            ]
        )
        logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.audio_stop", "turn_id": .string(turnId)])

        pipelineTask = Task { [weak self] in
            await self?.runPipeline(turnId: turnId, frames: frames, droppedFrames: dropped)
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

    func handleAbort(reason: String) {
        logger.info(
            "abort",
            metadata: ["session_id": .string(sessionId), "reason": .string(reason), "phase": .string("\(phase)")]
        )
        pipelineTask?.cancel()
        pipelineTask = nil
        opusBuffer.removeAll()
        phase = .connected
        Task {
            try? await send(TTSEnd(sessionId: sessionId))
            await mirrorTTSEnd()
        }
    }

    func handleDisconnect() {
        pipelineTask?.cancel()
        pipelineTask = nil
        opusBuffer.removeAll()
        logger.info("session disconnected", metadata: ["session_id": .string(sessionId)])
    }

    private func runPipeline(turnId: String, frames: [Data], droppedFrames: Int) async {
        let t0 = Date()
        logger.info(
            "pipeline start",
            metadata: ["session_id": .string(sessionId), "turn_id": .string(turnId), "frames": "\(frames.count)"]
        )
        do {
            guard !frames.isEmpty else {
                logger.warning("pipeline abort — no audio frames", metadata: ["session_id": .string(sessionId)])
                try await send(ErrorMessage(code: "no_audio", message: "No audio frames received"))
                phase = .connected
                return
            }

            logger.debug("decoding uplink to WAV", metadata: ["session_id": .string(sessionId), "frames": "\(frames.count)"])
            let wav = try OpusCodec.decodeToWAV(frames, sampleRate: AudioParams.uplink.sampleRate)
            try Task.checkCancellation()
            logger.debug("WAV ready", metadata: ["session_id": .string(sessionId), "wav_bytes": "\(wav.count)"])

            logger.info("openai.transcribe start", metadata: ["session_id": .string(sessionId)])
            let transcript = try await openAI.transcribe(wav: wav)
            try Task.checkCancellation()
            let tAsrDone = Date()
            logger.info(
                "openai.transcribe done",
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

            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                logger.warning("empty transcript — skipping chat/tts", metadata: ["session_id": .string(sessionId)])
                try await send(ErrorMessage(code: "empty_transcript", message: "No speech detected in recording"))
                phase = .connected
                return
            }

            logger.info("openai.chat start", metadata: ["session_id": .string(sessionId)])
            let chatResult = try await openAI.chat(transcript: transcript)
            try Task.checkCancellation()
            let tLlmFirst = Date()
            logger.info(
                "openai.chat done",
                metadata: [
                    "session_id": .string(sessionId),
                    "reply_chars": "\(chatResult.reply.count)",
                    "reply": .string(chatResult.reply),
                    "has_command": "\(chatResult.command != nil)",
                    "ms": "\(ms(tAsrDone, tLlmFirst))",
                ]
            )
            logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.chat_ready", "turn_id": .string(turnId)])

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

            phase = .streamingTTS
            try await send(TTSStart(sessionId: sessionId))
            await mirrorTTSStart()
            logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.tts_start", "turn_id": .string(turnId)])

            logger.info(
                "openai.speech start",
                metadata: ["session_id": .string(sessionId), "input_chars": "\(chatResult.reply.count)"]
            )
            let pcm = try await openAI.speech(text: chatResult.reply)
            try Task.checkCancellation()
            let tTtsFirstByte = Date()
            logger.info(
                "openai.speech done",
                metadata: [
                    "session_id": .string(sessionId),
                    "pcm_bytes": "\(pcm.count)",
                    "ms": "\(ms(tLlmFirst, tTtsFirstByte))",
                ]
            )
            dumpDebugTTSAudio(pcm, turnId: turnId)

            let opusOut = try OpusCodec.encodeFromPCM(pcm, sampleRate: AudioParams.downlink.sampleRate)
            logger.debug(
                "downlink frames encoded",
                metadata: ["session_id": .string(sessionId), "frames": "\(opusOut.count)", "pcm_bytes": "\(pcm.count)"]
            )
            for (index, chunk) in opusOut.enumerated() {
                try Task.checkCancellation()
                if index == 0 {
                    logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.first_downlink_audio", "turn_id": .string(turnId)])
                }
                logger.debug(
                    "ws send binary",
                    metadata: ["session_id": .string(sessionId), "frame": "\(index + 1)", "bytes": "\(chunk.count)"]
                )
                try await outbound.writeBinary(chunk)
                await speakers.broadcastBinary(chunk)
            }
            let tWsSent = Date()

            guard phase == .streamingTTS else { return }
            try await send(TTSEnd(sessionId: sessionId))
            await mirrorTTSEnd()
            phase = .connected
            logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.tts_end", "turn_id": .string(turnId)])

            let report = LatencyReport(
                sessionId: sessionId,
                turnId: turnId,
                ms: LatencyMs(
                    audioStopToAsrDone: ms(t0, tAsrDone),
                    asrDoneToLlmFirstToken: ms(tAsrDone, tLlmFirst),
                    llmFirstTokenToTtsFirstByte: ms(tLlmFirst, tTtsFirstByte),
                    ttsFirstByteToWsSent: ms(tTtsFirstByte, tWsSent),
                    audioStopToFirstDownlink: ms(t0, tTtsFirstByte)
                ),
                droppedFrames: droppedFrames
            )
            try await send(report)
            logger.info(
                "pipeline complete",
                metadata: [
                    "session_id": .string(sessionId),
                    "turn_id": .string(turnId),
                    "total_ms": "\(ms(t0, tWsSent))",
                    "downlink_frames": "\(opusOut.count)",
                ]
            )
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

            guard !cleanedTranscript.isEmpty else {
                logger.warning("empty transcript — skipping chat/tts", metadata: ["session_id": .string(sessionId)])
                try await send(ErrorMessage(code: "empty_transcript", message: "No speech detected in recording"))
                phase = .connected
                return
            }

            logger.info("openai.chat start", metadata: ["session_id": .string(sessionId)])
            let chatResult = try await openAI.chat(transcript: cleanedTranscript)
            try Task.checkCancellation()
            let tLlmFirst = Date()
            logger.info(
                "openai.chat done",
                metadata: [
                    "session_id": .string(sessionId),
                    "reply_chars": "\(chatResult.reply.count)",
                    "reply": .string(chatResult.reply),
                    "has_command": "\(chatResult.command != nil)",
                    "ms": "\(ms(tAsrDone, tLlmFirst))",
                ]
            )
            logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.chat_ready", "turn_id": .string(turnId)])

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

            phase = .streamingTTS
            try await send(TTSStart(sessionId: sessionId))
            await mirrorTTSStart()
            logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.tts_start", "turn_id": .string(turnId)])

            logger.info(
                "openai.speech start",
                metadata: ["session_id": .string(sessionId), "input_chars": "\(chatResult.reply.count)"]
            )
            let pcm = try await openAI.speech(text: chatResult.reply)
            try Task.checkCancellation()
            let tTtsFirstByte = Date()
            logger.info(
                "openai.speech done",
                metadata: [
                    "session_id": .string(sessionId),
                    "pcm_bytes": "\(pcm.count)",
                    "ms": "\(ms(tLlmFirst, tTtsFirstByte))",
                ]
            )
            dumpDebugTTSAudio(pcm, turnId: turnId)

            let opusOut = try OpusCodec.encodeFromPCM(pcm, sampleRate: AudioParams.downlink.sampleRate)
            logger.debug(
                "downlink frames encoded",
                metadata: ["session_id": .string(sessionId), "frames": "\(opusOut.count)", "pcm_bytes": "\(pcm.count)"]
            )
            for (index, chunk) in opusOut.enumerated() {
                try Task.checkCancellation()
                if index == 0 {
                    logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.first_downlink_audio", "turn_id": .string(turnId)])
                }
                logger.debug(
                    "ws send binary",
                    metadata: ["session_id": .string(sessionId), "frame": "\(index + 1)", "bytes": "\(chunk.count)"]
                )
                try await outbound.writeBinary(chunk)
                await speakers.broadcastBinary(chunk)
            }
            let tWsSent = Date()

            guard phase == .streamingTTS else { return }
            try await send(TTSEnd(sessionId: sessionId))
            await mirrorTTSEnd()
            phase = .connected
            logger.info("e2e stage", metadata: ["session_id": .string(sessionId), "stage": "server.tts_end", "turn_id": .string(turnId)])

            let report = LatencyReport(
                sessionId: sessionId,
                turnId: turnId,
                ms: LatencyMs(
                    audioStopToAsrDone: ms(t0, tAsrDone),
                    asrDoneToLlmFirstToken: ms(tAsrDone, tLlmFirst),
                    llmFirstTokenToTtsFirstByte: ms(tLlmFirst, tTtsFirstByte),
                    ttsFirstByteToWsSent: ms(tTtsFirstByte, tWsSent),
                    audioStopToFirstDownlink: ms(t0, tTtsFirstByte)
                ),
                droppedFrames: 0
            )
            try await send(report)
            logger.info(
                "pipeline complete",
                metadata: [
                    "session_id": .string(sessionId),
                    "turn_id": .string(turnId),
                    "total_ms": "\(ms(t0, tWsSent))",
                    "downlink_frames": "\(opusOut.count)",
                ]
            )
        } catch is CancellationError {
            logger.info("pipeline cancelled", metadata: ["session_id": .string(sessionId)])
        } catch {
            logger.error("pipeline failed", metadata: ["session_id": .string(sessionId), "error": "\(error)"])
            try? await send(ErrorMessage(code: "pipeline_failed", message: "\(error)"))
            phase = .connected
        }
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
