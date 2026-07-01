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
    private let speakers: SpeakerRegistry
    private let downlinkPacer: DownlinkPacer
    private let logger: Logger

    private var phase: SessionPhase = .connected
    private var pipelineTask: Task<Void, Never>?
    private var turnCounter = 0
    private var uplinkFrameCounter = 0
    private var uplinkPCMDump = Data()
    private var downlinkPCMDump = Data()
    private var downlinkTurnId: String?
    private var dumpOnlyMode = false
    private var conversationHistory: [ChatMessage] = []
    private let maxHistoryMessages = 20

    init(
        outbound: SessionOutboundWriter,
        realtime: OpenAIRealtimeService,
        speakers: SpeakerRegistry,
        logger: Logger
    ) {
        self.outbound = outbound
        self.realtime = realtime
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

    func handleSessionStart(_ start: SessionStart) {
        dumpOnlyMode = start.mode == "dump_only"
        if dumpOnlyMode {
            logger.info(
                "dump-only session — uplink WAV dump only, no pipeline",
                metadata: ["session_id": .string(sessionId)]
            )
            print("[session] dump-only mode — AI pipeline disabled")
        }
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
        if dumpOnlyMode {
            return
        }
        await realtime.appendAudioFrame(data)
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

        if dumpOnlyMode {
            phase = .connected
            uplinkFrameCounter = 0
            uplinkPCMDump.removeAll(keepingCapacity: true)
            logger.info(
                "dump-only turn complete",
                metadata: ["session_id": .string(sessionId), "turn_id": .string(turnId)]
            )
            return
        }

        phase = .processing
        pipelineTask = Task { [weak self] in
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
        await realtime.cancelResponse()
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
        Task { await realtime.close() }
        Task { await downlinkPacer.cancel() }
        logger.info("session disconnected", metadata: ["session_id": .string(sessionId)])
    }

    private func runRealtimeTurn(turnId: String) async {
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
