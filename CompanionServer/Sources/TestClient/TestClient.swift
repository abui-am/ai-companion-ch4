import AVFoundation
import CompanionEnv
import Foundation
import Logging

// Matches CompanionServer's AudioParams.uplink (WireProtocol.swift).
let uplinkSampleRate = 16_000
let uplinkFrameMs = 60
let uplinkFrameBytes = uplinkSampleRate / 1000 * uplinkFrameMs * 2

@main
struct TestClient {
    static func main() async throws {
        var logger = Logger(label: "TestClient")
        LogConfig.apply(to: &logger)
        logger.info("starting", metadata: ["log_level": .string("\(LogConfig.level())")])

        let config: AppConfig
        do {
            config = try await AppConfig.load()
        } catch let error as AppConfigError {
            logger.critical("\(error.description)")
            exit(1)
        }

        let host = config.companionHost
        logger.info("config loaded", metadata: ["companion_host": .string(host)])

        logger.info("Mic-only mode — captures MacBook mic; TTS plays on ESP32 TestFirmware (/speaker).")

        guard await MicPermission.ensureGranted(logger: logger) else {
            exit(1)
        }

        guard await ensureServerReachable(host: host, logger: logger) else {
            exit(1)
        }

        while true {
            print("\nPress Enter to start talking (or type 'q' + Enter to quit)... ", terminator: "")
            guard let line = readLine(), line.lowercased() != "q" else { break }
            do {
                try await runInteractiveTurn(host: host, token: config.deviceToken, logger: logger)
            } catch let error as TestClientError {
                logger.error("\(error.description)")
            } catch let urlError as URLError where urlError.code == .cannotConnectToHost {
                logger.error(
                    "Cannot connect to CompanionServer at \(host). Is it running? Start CompanionServer first, then try again."
                )
            } catch {
                logger.error("turn failed", metadata: ["error": "\(error)"])
            }
        }
        logger.info("TestClient finished")
    }

    static func expect(_ socket: URLSessionWebSocketTask, type: String, logger: Logger) async throws {
        let message = try await socket.receive()
        if case .string(let text) = message {
            logger.info("recv text", metadata: ["json": .string(text)])
            guard text.contains("\"\(type)\"") else {
                throw TestClientError.unexpectedMessage(text)
            }
        }
    }

    static func send(_ socket: URLSessionWebSocketTask, json: [String: Any], logger: Logger) async throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        let text = String(decoding: data, as: UTF8.self)
        logger.debug("send text", metadata: ["json": .string(text)])
        try await socket.send(.string(text))
    }

    static func makeSocket(host: String, token: String, logger: Logger) -> URLSessionWebSocketTask {
        logger.info("connecting websocket", metadata: ["url": .string(host)])
        var request = URLRequest(url: URL(string: host)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        return socket
    }

    static func runInteractiveTurn(host: String, token: String, logger: Logger) async throws {
        logger.info("turn start", metadata: ["host": .string(host)])
        let socket = makeSocket(host: host, token: token, logger: logger)
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            logger.debug("websocket closed")
        }

        try await send(socket, json: ["type": "session.start", "audio": ["format": "opus", "sample_rate": uplinkSampleRate, "frame_ms": uplinkFrameMs]], logger: logger)
        try await expect(socket, type: "session.ready", logger: logger)

        try await send(socket, json: ["type": "audio.start"], logger: logger)

        let outbound = AudioFrameSender(socket: socket, logger: logger)
        let mic = try MicCapture(logger: logger)
        mic.onFrame = { frame in
            Task { await outbound.enqueue(frame) }
        }
        try mic.start()
        print("Recording... speak now, then press Enter to stop")
        _ = readLine()
        mic.stop()
        await outbound.flush()
        let framesSent = await outbound.framesSent
        let bytesSent = await outbound.bytesSent
        logger.info(
            "recording stopped",
            metadata: ["frames_sent": "\(framesSent)", "bytes_sent": "\(bytesSent)"]
        )
        guard framesSent > 0 else {
            throw TestClientError.noAudioCaptured
        }

        try await send(socket, json: ["type": "audio.stop"], logger: logger)

        try await drainTurn(socket, logger: logger)
        logger.info("turn complete — check ESP32 speaker for playback")
    }

    static func drainTurn(_ socket: URLSessionWebSocketTask, logger: Logger) async throws {
        var downlinkFrames = 0
        while true {
            let message = try await socket.receive()
            switch message {
            case .string(let text):
                logger.info("recv", metadata: ["json": .string(text)])
                if text.contains("\"tts.end\"") {
                    logger.info(
                        "tts mirrored to ESP speakers",
                        metadata: ["downlink_frames_on_ws": "\(downlinkFrames)"]
                    )
                    return
                }
                if text.contains("\"error\"") {
                    logger.warning("server error", metadata: ["json": .string(text)])
                    return
                }
            case .data:
                downlinkFrames += 1
            @unknown default:
                continue
            }
        }
    }

    static func ensureServerReachable(host: String, logger: Logger) async -> Bool {
        guard let pingURL = httpPingURL(from: host) else {
            logger.critical("Invalid COMPANION_HOST: \(host)")
            return false
        }

        do {
            var request = URLRequest(url: pingURL)
            request.timeoutInterval = 3
            logger.debug("ping request", metadata: ["url": .string(pingURL.absoluteString)])
            let (body, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                logger.critical(
                    "CompanionServer at \(pingURL.host ?? "?"):\(pingURL.port ?? 8080) did not respond OK. Start CompanionServer first."
                )
                return false
            }
            logger.info(
                "CompanionServer reachable",
                metadata: [
                    "host": .string(pingURL.host ?? "?"),
                    "port": "\(pingURL.port ?? 8080)",
                    "body": .string(String(decoding: body, as: UTF8.self)),
                ]
            )
            return true
        } catch {
            logger.critical(
                "Cannot reach CompanionServer at \(pingURL.host ?? "?"):\(pingURL.port ?? 8080). Start CompanionServer in Xcode or another terminal, then re-run TestClient."
            )
            return false
        }
    }

    static func httpPingURL(from wsURL: String) -> URL? {
        guard var components = URLComponents(string: wsURL) else { return nil }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = "/ping"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

enum TestClientError: Error, CustomStringConvertible {
    case unexpectedMessage(String)
    case noAudioCaptured

    var description: String {
        switch self {
        case .unexpectedMessage(let message):
            message
        case .noAudioCaptured:
            "No microphone audio captured. Check System Settings → Sound → Input and speak while recording."
        }
    }
}

actor AudioFrameSender {
    private let socket: URLSessionWebSocketTask
    private let logger: Logger
    private var inFlight = 0
    private(set) var framesSent = 0
    private(set) var bytesSent = 0

    init(socket: URLSessionWebSocketTask, logger: Logger) {
        self.socket = socket
        self.logger = logger
    }

    func enqueue(_ frame: Data) {
        inFlight += 1
        let frameNumber = framesSent + inFlight
        logger.debug("send binary queued", metadata: ["frame": "\(frameNumber)", "bytes": "\(frame.count)"])
        Task {
            defer { Task { await self.completeSend() } }
            do {
                try await socket.send(.data(frame))
                await self.recordSent(bytes: frame.count)
            } catch {
                self.logger.error("send binary failed", metadata: ["error": "\(error)"])
            }
        }
    }

    private func completeSend() {
        inFlight -= 1
    }

    private func recordSent(bytes: Int) {
        framesSent += 1
        bytesSent += bytes
        logger.debug("send binary done", metadata: ["frame": "\(framesSent)", "bytes": "\(bytes)"])
    }

    func flush() async {
        logger.debug("flushing outbound audio", metadata: ["in_flight": "\(inFlight)"])
        while inFlight > 0 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        logger.debug("flush complete", metadata: ["frames_sent": "\(framesSent)", "bytes_sent": "\(bytesSent)"])
    }
}

enum MicPermission {
    static func ensureGranted(logger: Logger) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            logger.info("Microphone access granted.")
            return true
        case .notDetermined:
            logger.info("Requesting microphone access — approve the macOS prompt to continue.")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if granted {
                logger.info("Microphone access granted.")
                return true
            }
            logger.critical(
                "Microphone access denied. Enable TestClient in System Settings → Privacy & Security → Microphone, then re-run."
            )
            return false
        case .denied, .restricted:
            logger.critical(
                "Microphone access denied. Enable TestClient in System Settings → Privacy & Security → Microphone, then re-run."
            )
            return false
        @unknown default:
            logger.critical("Unknown microphone authorization status.")
            return false
        }
    }
}

/// Captures the Mac's default input device and converts it to 16kHz mono
/// 16-bit PCM frames matching CompanionServer's uplink format, chunked to
/// the protocol's 60ms frame size. Temporary stand-in for the ESP32's I2S
/// mic until that hardware is wired up — same wire format either way, so
/// nothing downstream needs to change when the real mic arrives.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private let logger: Logger
    private var converter: AVAudioConverter?
    private var frameBuffer = Data()
    private var protocolFramesEmitted = 0
    private var conversionErrors = 0
    var onFrame: ((Data) -> Void)?

    init(logger: Logger) throws {
        self.logger = logger
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(uplinkSampleRate), channels: 1, interleaved: true) else {
            throw TestClientError.unexpectedMessage("failed to construct target audio format")
        }
        targetFormat = format
    }

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        logger.info(
            "mic capture starting",
            metadata: [
                "input_sample_rate": "\(inputFormat.sampleRate)",
                "input_channels": "\(inputFormat.channelCount)",
                "target_sample_rate": "\(targetFormat.sampleRate)",
                "frame_bytes": "\(uplinkFrameBytes)",
            ]
        )
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw TestClientError.unexpectedMessage("failed to construct audio converter")
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        logger.info("mic capture started")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        frameBuffer.removeAll()
        logger.info(
            "mic capture stopped",
            metadata: [
                "protocol_frames": "\(protocolFramesEmitted)",
                "conversion_errors": "\(conversionErrors)",
            ]
        )
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrames = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 32
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrames) else { return }

        var suppliedInput = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, let channelData = outBuffer.int16ChannelData else {
            conversionErrors += 1
            if conversionErrors <= 3 {
                logger.warning(
                    "audio conversion failed",
                    metadata: [
                        "status": "\(status.rawValue)",
                        "error": "\(error?.localizedDescription ?? "none")",
                    ]
                )
            }
            return
        }

        let frameLength = Int(outBuffer.frameLength)
        guard frameLength > 0 else { return }

        let data = Data(bytes: channelData[0], count: frameLength * MemoryLayout<Int16>.size)
        frameBuffer.append(data)

        while frameBuffer.count >= uplinkFrameBytes {
            let chunk = frameBuffer.prefix(uplinkFrameBytes)
            frameBuffer.removeFirst(uplinkFrameBytes)
            protocolFramesEmitted += 1
            logger.debug(
                "mic frame ready",
                metadata: ["frame": "\(protocolFramesEmitted)", "bytes": "\(chunk.count)"]
            )
            onFrame?(Data(chunk))
        }
    }
}
