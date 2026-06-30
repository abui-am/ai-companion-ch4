import Foundation
import HummingbirdWebSocket
import Logging
import NIOCore

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
    private let outbound: WebSocketOutboundWriter
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

    init(outbound: WebSocketOutboundWriter, openAI: OpenAIService, speakers: SpeakerRegistry, logger: Logger) {
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

        pipelineTask = Task { [weak self] in
            await self?.runPipeline(turnId: turnId, frames: frames, droppedFrames: dropped)
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

            let opusOut = try OpusCodec.encodeFromPCM(pcm, sampleRate: AudioParams.downlink.sampleRate)
            logger.debug(
                "downlink frames encoded",
                metadata: ["session_id": .string(sessionId), "frames": "\(opusOut.count)", "pcm_bytes": "\(pcm.count)"]
            )
            for (index, chunk) in opusOut.enumerated() {
                try Task.checkCancellation()
                logger.debug(
                    "ws send binary",
                    metadata: ["session_id": .string(sessionId), "frame": "\(index + 1)", "bytes": "\(chunk.count)"]
                )
                try await outbound.write(.binary(ByteBuffer(bytes: chunk)))
                await speakers.broadcastBinary(chunk)
            }
            let tWsSent = Date()

            guard phase == .streamingTTS else { return }
            try await send(TTSEnd(sessionId: sessionId))
            await mirrorTTSEnd()
            phase = .connected

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

    private func ms(_ a: Date, _ b: Date) -> Int {
        max(0, Int(b.timeIntervalSince(a) * 1000))
    }

    private func send<T: Encodable>(_ value: T) async throws {
        let data = try JSONEncoder().encode(value)
        let text = String(decoding: data, as: UTF8.self)
        logger.debug("ws send text", metadata: ["session_id": .string(sessionId), "json": .string(text)])
        try await outbound.write(.text(text))
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
