import Foundation
import Logging

protocol CartesiaSTTServiceProtocol: Sendable {
    /// Opens the WebSocket connection ahead of capture so the handshake doesn't
    /// land on the critical path of the first turn. Safe to call multiple times.
    func connect() async
    /// Streams a raw PCM uplink frame to Cartesia as it's captured.
    func sendAudio(_ data: Data) async
    /// Flushes buffered audio and returns the transcript accumulated since the
    /// last call to `finalize()`. The connection stays open for the next turn.
    func finalize() async -> String
    /// Ends the session. Call on disconnect/abort.
    func close() async
}

/// Streams uplink audio to Cartesia's Ink-Whisper STT over a persistent WebSocket
/// so transcription starts while the user is still talking instead of waiting for
/// a single blocking REST call after `audio.stop`. One instance is owned per
/// `VoiceSession` (the connection carries one caller's audio, unlike the TTS
/// service which multiplexes many turns over a shared socket via context_id).
actor CartesiaSTTService: CartesiaSTTServiceProtocol {
    private let apiKey: String
    private let modelId: String
    private let sampleRate: Int
    private let language: String
    private let logger: Logger
    private let session: URLSession

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var transcriptChunks: [String] = []
    private var flushContinuation: CheckedContinuation<Void, Never>?

    init(
        apiKey: String,
        modelId: String = "ink-whisper",
        sampleRate: Int,
        language: String = "en",
        logger: Logger,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.modelId = modelId
        self.sampleRate = sampleRate
        self.language = language
        self.logger = logger
        self.session = session
    }

    func connect() async {
        await connectIfNeeded()
    }

    func sendAudio(_ data: Data) async {
        await connectIfNeeded()
        try? await socket?.send(.data(data))
    }

    func finalize() async -> String {
        guard let socket else { return takeAccumulatedText() }
        do {
            try await socket.send(.string("finalize"))
        } catch {
            logger.warning("cartesia stt finalize send failed", metadata: ["error": "\(error)"])
            return takeAccumulatedText()
        }
        await waitForFlush()
        return takeAccumulatedText()
    }

    func close() async {
        try? await socket?.send(.string("close"))
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        receiveTask?.cancel()
        receiveTask = nil
        resumeFlushIfPending()
    }

    private func connectIfNeeded() async {
        guard socket == nil else { return }
        var components = URLComponents(string: "wss://api.cartesia.ai/stt/websocket")!
        components.queryItems = [
            URLQueryItem(name: "model", value: modelId),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "sample_rate", value: "\(sampleRate)"),
            URLQueryItem(name: "cartesia_version", value: "2026-03-01"),
            URLQueryItem(name: "language", value: language),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        let task = session.webSocketTask(with: request)
        task.resume()
        socket = task
        logger.info("cartesia stt ws connected")

        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        while let socket {
            do {
                let message = try await socket.receive()
                if case .string(let text) = message {
                    handle(text)
                }
            } catch {
                logger.warning("cartesia stt ws receive failed", metadata: ["error": "\(error)"])
                self.socket = nil
                self.receiveTask = nil
                resumeFlushIfPending()
                return
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let response = try? JSONDecoder().decode(CartesiaSTTResponse.self, from: data)
        else {
            logger.warning("cartesia stt unparseable message", metadata: ["text": .string(text)])
            return
        }

        switch response.type {
        case "transcript":
            if response.isFinal == true, let chunk = response.text, !chunk.isEmpty {
                transcriptChunks.append(chunk)
            }
        case "flush_done", "done":
            resumeFlushIfPending()
        case "error":
            logger.error("cartesia stt error", metadata: ["text": .string(text)])
            resumeFlushIfPending()
        default:
            break
        }
    }

    private func waitForFlush() async {
        await withCheckedContinuation { continuation in
            flushContinuation = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                await self?.resumeFlushIfPending()
            }
        }
    }

    private func resumeFlushIfPending() {
        flushContinuation?.resume()
        flushContinuation = nil
    }

    private func takeAccumulatedText() -> String {
        let text = transcriptChunks.joined(separator: " ")
        transcriptChunks.removeAll()
        return text
    }
}

private struct CartesiaSTTResponse: Decodable {
    let type: String
    let isFinal: Bool?
    let text: String?

    enum CodingKeys: String, CodingKey {
        case type
        case isFinal = "is_final"
        case text
    }
}
