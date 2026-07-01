import Foundation
import Logging

enum RealtimeAudioEvent: Sendable {
    case audio(Data)               // PCM16 @ 24 kHz chunk from response
    case inputTranscript(String)   // completed user-speech transcript
    case assistantTranscript(String) // incremental assistant text delta
    case done
    case error(String)
}

/// Manages a persistent WebSocket connection to the OpenAI Realtime API.
/// One instance is shared across turns of the same VoiceSession.
///
/// Turn flow:
///   1. `connect()` — called once on session start.
///   2. `appendAudioFrame(_:)` — called per uplink frame while capturing.
///      Frames are upsampled 16 kHz → 24 kHz before being sent.
///   3. `commitAndCreateResponse()` — called on audio.stop; returns an
///      AsyncStream that emits audio chunks then `.done`.
///   4. `cancelResponse()` — called on abort.
///   5. `close()` — called on session disconnect.
actor OpenAIRealtimeService {
    private static let sampleRate = 24_000

    private let apiKey: String
    private let model: String
    private let voice: String
    private let logger: Logger

    private var socket: URLSessionWebSocketTask?
    private var eventLoopTask: Task<Void, Never>?
    private var turnContinuation: AsyncStream<RealtimeAudioEvent>.Continuation?

    init(apiKey: String, model: String, voice: String, logger: Logger) {
        self.apiKey = apiKey
        self.model = model
        self.voice = voice
        self.logger = logger
    }

    // MARK: - Lifecycle

    func connect() async {
        if let existing = socket, existing.state == .running { return }
        socket?.cancel(with: .normalClosure, reason: nil)

        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(model)")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        logger.info("realtime connect", metadata: ["model": .string(model)])

        do {
            try await waitForEvent("session.created", on: task)
            logger.info("realtime session.created", metadata: ["model": .string(model)])

            try await sendJSON(sessionUpdatePayload())
            try await waitForEvent("session.updated", on: task)
            logger.info("realtime session configured", metadata: ["voice": .string(voice)])
        } catch {
            logger.error("realtime connect failed", metadata: ["error": .string("\(error)")])
            task.cancel(with: .abnormalClosure, reason: nil)
            socket = nil
            return
        }

        startEventLoop()
    }

    func close() async {
        eventLoopTask?.cancel()
        eventLoopTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        finishTurn(with: nil)
    }

    // MARK: - Turn control

    /// Appends one 60 ms uplink PCM frame (16 kHz, 16-bit mono).
    /// The frame is upsampled to 24 kHz before being base64-encoded and sent.
    func appendAudioFrame(_ data: Data) async {
        let resampled = upsample16kTo24k(data)
        try? await sendJSON([
            "type": "input_audio_buffer.append",
            "audio": resampled.base64EncodedString(),
        ])
    }

    /// Commits buffered audio and creates a response.
    /// Returns a stream that emits audio events and ends with `.done` or `.error`.
    func commitAndCreateResponse() async -> AsyncStream<RealtimeAudioEvent> {
        let (stream, continuation) = AsyncStream<RealtimeAudioEvent>.makeStream()
        guard let socket, socket.state == .running else {
            logger.error("commitAndCreateResponse: socket not connected (state=\(String(describing: socket?.state)))")
            continuation.yield(.error("realtime socket not connected"))
            continuation.finish()
            return stream
        }
        logger.info("commitAndCreateResponse: socket ok, sending commit+response.create")
        turnContinuation = continuation
        try? await sendJSON(["type": "input_audio_buffer.commit"])
        try? await sendJSON(["type": "response.create"])
        return stream
    }

    func cancelResponse() async {
        try? await sendJSON(["type": "response.cancel"])
        finishTurn(with: nil)
    }

    // MARK: - Event loop

    private func startEventLoop() {
        eventLoopTask?.cancel()
        guard let socket else { return }
        eventLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let msg = try await socket.receive()
                    if case .string(let text) = msg {
                        await self?.handleEvent(text)
                    }
                } catch {
                    guard !Task.isCancelled else { break }
                    self?.logger.error("realtime recv error", metadata: ["error": "\(error)"])
                    await self?.finishTurn(with: .error("WebSocket closed: \(error)"))
                    break
                }
            }
        }
    }

    private func handleEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        switch type {
        case "session.created", "session.updated":
            logger.debug("realtime [\(type)]")

        case "conversation.item.input_audio_transcription.completed":
            if let t = json["transcript"] as? String, !t.isEmpty {
                logger.info("realtime input transcript", metadata: ["text": .string(t)])
                turnContinuation?.yield(.inputTranscript(t))
            }

        case "response.audio.delta", "response.output_audio.delta":
            let b64 = (json["audio"] as? String) ?? (json["delta"] as? String)
            if let b64, let chunk = Data(base64Encoded: b64) {
                turnContinuation?.yield(.audio(chunk))
            }

        case "response.audio_transcript.delta", "response.output_audio_transcript.delta":
            if let delta = json["delta"] as? String, !delta.isEmpty {
                turnContinuation?.yield(.assistantTranscript(delta))
            }

        case "response.done":
            logger.info("realtime response.done")
            finishTurn(with: .done)

        case "error":
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? text
            logger.error("realtime api error", metadata: ["msg": .string(msg)])
            finishTurn(with: .error(msg))

        default:
            logger.debug("realtime [\(type)] (unhandled)")
        }
    }

    private func finishTurn(with event: RealtimeAudioEvent?) {
        if let event { turnContinuation?.yield(event) }
        turnContinuation?.finish()
        turnContinuation = nil
    }

    // MARK: - Helpers

    private func sessionUpdatePayload() -> [String: Any] {
        [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": CompanionPrompt.system,
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": Self.sampleRate],
                        "turn_detection": NSNull(),
                        "transcription": ["model": "whisper-1"],
                    ] as [String: Any],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": Self.sampleRate],
                        "voice": voice,
                    ],
                ],
            ] as [String: Any],
        ]
    }

    private func waitForEvent(_ wanted: String, on task: URLSessionWebSocketTask) async throws {
        while true {
            let raw = try await task.receive()
            guard case .string(let text) = raw,
                  let data = text.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String
            else { continue }

            if type == "error" {
                let msg = (json["error"] as? [String: Any])?["message"] as? String ?? text
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: msg])
            }
            if type == wanted { return }
            logger.debug("realtime [\(type)] (during connect)")
        }
    }

    private func sendJSON(_ json: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        try await socket?.send(.string(String(decoding: data, as: UTF8.self)))
    }

    /// Linear-interpolation upsample from 16 kHz to 24 kHz (ratio 3:2).
    /// For each 960-sample input frame (60 ms) produces 1440 output samples.
    private func upsample16kTo24k(_ data: Data) -> Data {
        let inCount = data.count / MemoryLayout<Int16>.size
        guard inCount > 0 else { return Data() }
        let outCount = inCount * 3 / 2
        var output = [Int16](repeating: 0, count: outCount)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for k in 0..<outCount {
                let srcPos = Double(k) * 2.0 / 3.0
                let lo = Int(srcPos)
                let hi = min(lo + 1, inCount - 1)
                let frac = srcPos - Double(lo)
                let val = Double(src[lo]) * (1.0 - frac) + Double(src[hi]) * frac
                output[k] = Int16(max(Double(Int16.min), min(Double(Int16.max), val.rounded())))
            }
        }
        return output.withUnsafeBytes { Data($0) }
    }
}
