import Foundation
import Logging

enum TTSStreamEvent: Sendable {
    case audio(Data)
    case done
    case error(String)
}

protocol TTSStreamingService: Sendable {
    func beginTurn(contextId: String) async -> AsyncStream<TTSStreamEvent>
    func sendTranscriptChunk(_ text: String, contextId: String, isFinal: Bool) async
    func cancelTurn(contextId: String) async
}

/// Maintains a persistent WebSocket connection to Cartesia's streaming TTS endpoint
/// so turns don't pay the ~200ms WS handshake cost on every request. Text chunks for
/// a turn are sent as they become available (tagged with a shared `context_id`) and
/// raw PCM audio is streamed back incrementally rather than buffered.
actor CartesiaService: TTSStreamingService {
    private let apiKey: String
    private let voiceId: String
    private let modelId: String
    private let sampleRate: Int
    private let logger: Logger
    private let session: URLSession

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var continuations: [String: AsyncStream<TTSStreamEvent>.Continuation] = [:]

    init(
        apiKey: String,
        voiceId: String,
        modelId: String,
        sampleRate: Int = 24_000,
        logger: Logger,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.voiceId = voiceId
        self.modelId = modelId
        self.sampleRate = sampleRate
        self.logger = logger
        self.session = session
    }

    /// Registers a turn and returns a stream of audio events for it. Call this
    /// before sending any transcript chunks for `contextId`.
    func beginTurn(contextId: String) -> AsyncStream<TTSStreamEvent> {
        AsyncStream { continuation in
            continuations[contextId] = continuation
        }
    }

    func sendTranscriptChunk(_ text: String, contextId: String, isFinal: Bool) async {
        guard !text.isEmpty || isFinal else { return }
        do {
            try await connectIfNeeded()
            let message = CartesiaRequest(
                modelId: modelId,
                transcript: text,
                voice: .init(mode: "id", id: voiceId),
                outputFormat: .init(container: "raw", encoding: "pcm_s16le", sampleRate: sampleRate),
                contextId: contextId,
                continueFlag: !isFinal
            )
            let data = try JSONEncoder().encode(message)
            let json = String(decoding: data, as: UTF8.self)
            try await socket?.send(.string(json))
        } catch {
            logger.error(
                "cartesia send failed",
                metadata: ["context_id": .string(contextId), "error": "\(error)"]
            )
            finishTurn(contextId: contextId, event: .error("\(error)"))
        }
    }

    func cancelTurn(contextId: String) {
        finishTurn(contextId: contextId, event: nil)
        Task {
            let cancel = CartesiaCancel(contextId: contextId)
            guard let data = try? JSONEncoder().encode(cancel) else { return }
            try? await socket?.send(.string(String(decoding: data, as: UTF8.self)))
        }
    }

    private func connectIfNeeded() async throws {
        guard socket == nil else { return }
        var components = URLComponents(string: "wss://api.cartesia.ai/tts/websocket")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "cartesia_version", value: "2024-06-10"),
        ]
        let task = session.webSocketTask(with: components.url!)
        task.resume()
        socket = task
        logger.info("cartesia ws connected")

        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        while let socket {
            do {
                let message = try await socket.receive()
                switch message {
                case .string(let text):
                    handle(text)
                case .data:
                    break
                @unknown default:
                    break
                }
            } catch {
                logger.warning("cartesia ws receive failed — will reconnect on next send", metadata: ["error": "\(error)"])
                self.socket = nil
                self.receiveTask = nil
                for (contextId, _) in continuations {
                    finishTurn(contextId: contextId, event: .error("\(error)"))
                }
                return
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        guard let response = try? JSONDecoder().decode(CartesiaResponse.self, from: data) else {
            logger.warning("cartesia unparseable message", metadata: ["text": .string(text)])
            return
        }

        switch response.type {
        case "chunk":
            guard let base64 = response.data, let pcm = Data(base64Encoded: base64) else { return }
            continuations[response.contextId]?.yield(.audio(pcm))
        case "done":
            finishTurn(contextId: response.contextId, event: .done)
        case "error":
            finishTurn(contextId: response.contextId, event: .error(response.error ?? "unknown cartesia error"))
        default:
            break
        }
    }

    private func finishTurn(contextId: String, event: TTSStreamEvent?) {
        guard let continuation = continuations[contextId] else { return }
        if let event {
            continuation.yield(event)
        }
        continuation.finish()
        continuations.removeValue(forKey: contextId)
    }
}

// MARK: - Wire payload types

private struct CartesiaRequest: Encodable {
    let modelId: String
    let transcript: String
    let voice: Voice
    let outputFormat: OutputFormat
    let contextId: String
    let continueFlag: Bool

    struct Voice: Encodable {
        let mode: String
        let id: String
    }

    struct OutputFormat: Encodable {
        let container: String
        let encoding: String
        let sampleRate: Int

        enum CodingKeys: String, CodingKey {
            case container
            case encoding
            case sampleRate = "sample_rate"
        }
    }

    enum CodingKeys: String, CodingKey {
        case modelId = "model_id"
        case transcript
        case voice
        case outputFormat = "output_format"
        case contextId = "context_id"
        case continueFlag = "continue"
    }
}

private struct CartesiaCancel: Encodable {
    let contextId: String
    let cancel = true

    enum CodingKeys: String, CodingKey {
        case contextId = "context_id"
        case cancel
    }
}

private struct CartesiaResponse: Decodable {
    let type: String
    let contextId: String
    let data: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case type
        case contextId = "context_id"
        case data
        case error
    }
}
