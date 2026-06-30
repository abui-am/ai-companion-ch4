@preconcurrency import AVFoundation
import CompanionEnv
import Foundation
import Logging
import Speech

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

        guard await Permission.ensureGranted(logger: logger) else {
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
        logger.info("e2e stage", metadata: ["stage": "client.session_ready"])

        let captureStartedAt = Date()
        let mic = try MicCapture(logger: logger)
        try mic.start()
        logger.info("e2e stage", metadata: ["stage": "client.capture_started"])
        print("Recording... speak now, then press Enter to stop")
        _ = readLine()
        let pcm = mic.stop()
        let captureFinishedAt = Date()
        let bytesSent = pcm.count
        let framesSent = bytesSent / uplinkFrameBytes
        logger.info(
            "recording stopped",
            metadata: ["frames_sent": "\(framesSent)", "bytes_sent": "\(bytesSent)"]
        )
        guard framesSent > 0 else {
            throw TestClientError.noAudioCaptured
        }
        logger.info("e2e stage", metadata: ["stage": "client.capture_finished", "pcm_bytes": "\(pcm.count)"])

        let transcriptResult: Result<String, Error>
        do {
            transcriptResult = .success(try await AppleSpeechTranscriber(logger: logger).transcribe(pcm: pcm))
        } catch {
            transcriptResult = .failure(error)
        }
        let payload = await makeSubmissionPayload(pcm: pcm, transcriptResult: transcriptResult, logger: logger)
        try await submit(payload: payload, socket: socket, logger: logger)
        logger.info("e2e stage", metadata: ["stage": "client.payload_submitted"])

        try await drainTurn(
            socket,
            logger: logger,
            captureStartedAt: captureStartedAt,
            captureFinishedAt: captureFinishedAt
        )
        logger.info("turn complete — check ESP32 speaker for playback")
    }

    static func makeSubmissionPayload(
        pcm: Data,
        transcriptResult: Result<String, Error>
    ) -> SubmissionPayload {
        switch transcriptResult {
        case .success(let transcript):
            return .transcript(transcript)
        case .failure:
            return .audioFrames(chunkPCMForUplink(pcm))
        }
    }

    static func makeSubmissionPayload(
        pcm: Data,
        transcriptResult: Result<String, Error>,
        logger: Logger
    ) async -> SubmissionPayload {
        switch transcriptResult {
        case .success(let transcript):
            logger.info("local transcript ready", metadata: ["text": .string(transcript)])
            logger.info("e2e stage", metadata: ["stage": "client.local_transcript_ready", "mode": "transcript"])
            return .transcript(transcript)
        case .failure(let error):
            logger.warning("apple speech failed, falling back to raw audio uplink", metadata: ["error": "\(error)"])
            logger.info("e2e stage", metadata: ["stage": "client.local_transcript_failed", "mode": "audio_fallback"])
            return .audioFrames(chunkPCMForUplink(pcm))
        }
    }

    static func submit(payload: SubmissionPayload, socket: URLSessionWebSocketTask, logger: Logger) async throws {
        switch payload {
        case .transcript(let transcript):
            logger.info("e2e stage", metadata: ["stage": "client.submit_transcript", "chars": "\(transcript.count)"])
            try await send(socket, json: ["type": "transcript.input", "text": transcript], logger: logger)
        case .audioFrames(let frames):
            logger.info("e2e stage", metadata: ["stage": "client.submit_audio_fallback", "frames": "\(frames.count)"])
            try await send(socket, json: ["type": "audio.start"], logger: logger)
            for frame in frames {
                logger.debug("send binary fallback", metadata: ["bytes": "\(frame.count)"])
                try await socket.send(.data(frame))
            }
            try await send(socket, json: ["type": "audio.stop"], logger: logger)
        }
    }

    static func chunkPCMForUplink(_ pcm: Data) -> [Data] {
        guard !pcm.isEmpty else { return [] }
        var frames: [Data] = []
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + uplinkFrameBytes, pcm.count)
            frames.append(pcm.subdata(in: offset..<end))
            offset = end
        }
        return frames
    }

    static func makeTalkToSpeechMetrics(
        captureStartedAt: Date,
        captureFinishedAt: Date,
        firstDownlinkAt: Date
    ) -> TalkToSpeechMetrics {
        TalkToSpeechMetrics(
            talkDurationMs: max(0, Int(captureFinishedAt.timeIntervalSince(captureStartedAt) * 1000)),
            stopToSpeechMs: max(0, Int(firstDownlinkAt.timeIntervalSince(captureFinishedAt) * 1000)),
            talkToSpeechMs: max(0, Int(firstDownlinkAt.timeIntervalSince(captureStartedAt) * 1000))
        )
    }

    static func drainTurn(
        _ socket: URLSessionWebSocketTask,
        logger: Logger,
        captureStartedAt: Date,
        captureFinishedAt: Date
    ) async throws {
        var downlinkFrames = 0
        while true {
            let message = try await socket.receive()
            switch message {
            case .string(let text):
                logger.info("recv", metadata: ["json": .string(text)])
                if text.contains("\"tts.end\"") {
                    logger.info("e2e stage", metadata: ["stage": "client.tts_end", "downlink_frames": "\(downlinkFrames)"])
                    logger.info(
                        "tts mirrored to ESP speakers",
                        metadata: ["downlink_frames_on_ws": "\(downlinkFrames)"]
                    )
                    return
                }
                if text.contains("\"tts.start\"") {
                    logger.info("e2e stage", metadata: ["stage": "client.tts_start"])
                }
                if text.contains("\"transcript.final\"") {
                    logger.info("e2e stage", metadata: ["stage": "client.transcript_final"])
                }
                if text.contains("\"error\"") {
                    logger.warning("server error", metadata: ["json": .string(text)])
                    return
                }
            case .data:
                downlinkFrames += 1
                if downlinkFrames == 1 {
                    let now = Date()
                    let metrics = makeTalkToSpeechMetrics(
                        captureStartedAt: captureStartedAt,
                        captureFinishedAt: captureFinishedAt,
                        firstDownlinkAt: now
                    )
                    logger.info("e2e stage", metadata: ["stage": "client.first_downlink_audio"])
                    logger.info(
                        "talk-to-speech",
                        metadata: [
                            "talk_duration_ms": "\(metrics.talkDurationMs)",
                            "stop_to_speech_ms": "\(metrics.stopToSpeechMs)",
                            "talk_to_speech_ms": "\(metrics.talkToSpeechMs)",
                        ]
                    )
                }
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

enum SubmissionPayload: Equatable {
    case transcript(String)
    case audioFrames([Data])
}

struct TalkToSpeechMetrics: Equatable {
    let talkDurationMs: Int
    let stopToSpeechMs: Int
    let talkToSpeechMs: Int
}

enum TestClientError: Error, CustomStringConvertible {
    case unexpectedMessage(String)
    case noAudioCaptured
    case speechRecognitionUnavailable
    case speechRecognitionFailed(String)

    var description: String {
        switch self {
        case .unexpectedMessage(let message):
            message
        case .noAudioCaptured:
            "No microphone audio captured. Check System Settings → Sound → Input and speak while recording."
        case .speechRecognitionUnavailable:
            "Apple Speech recognition is unavailable for the selected locale on this Mac."
        case .speechRecognitionFailed(let message):
            "Apple Speech recognition failed: \(message)"
        }
    }
}

enum Permission {
    static func ensureGranted(logger: Logger) async -> Bool {
        let micGranted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            logger.info("Microphone access granted.")
            micGranted = true
        case .notDetermined:
            logger.info("Requesting microphone access — approve the macOS prompt to continue.")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if granted {
                logger.info("Microphone access granted.")
                micGranted = true
                break
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

        guard micGranted else { return false }

        switch await requestSpeechAuthorization() {
        case .authorized:
            logger.info("Speech recognition access granted.")
            return true
        case .denied, .restricted:
            logger.critical(
                "Speech recognition denied. Enable TestClient in System Settings → Privacy & Security → Speech Recognition, then re-run."
            )
            return false
        case .notDetermined:
            logger.critical("Speech recognition authorization not determined after request.")
            return false
        @unknown default:
            logger.critical("Unknown speech recognition authorization status.")
            return false
        }
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
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
    private var capturedPCM = Data()
    private var protocolFramesEmitted = 0
    private var conversionErrors = 0

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

    func stop() -> Data {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        let pcm = capturedPCM
        capturedPCM.removeAll()
        frameBuffer.removeAll()
        logger.info(
            "mic capture stopped",
            metadata: [
                "protocol_frames": "\(protocolFramesEmitted)",
                "conversion_errors": "\(conversionErrors)",
            ]
        )
        return pcm
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
        capturedPCM.append(data)
        frameBuffer.append(data)

        while frameBuffer.count >= uplinkFrameBytes {
            let chunk = frameBuffer.prefix(uplinkFrameBytes)
            frameBuffer.removeFirst(uplinkFrameBytes)
            protocolFramesEmitted += 1
            logger.debug(
                "mic frame ready",
                metadata: ["frame": "\(protocolFramesEmitted)", "bytes": "\(chunk.count)"]
            )
        }
    }
}

final class AppleSpeechTranscriber {
    private let recognizer: SFSpeechRecognizer?
    private let logger: Logger

    init(locale: Locale = Locale(identifier: "en-US"), logger: Logger) {
        self.recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        self.logger = logger
    }

    func transcribe(pcm: Data) async throws -> String {
        guard let recognizer, recognizer.isAvailable else {
            throw TestClientError.speechRecognitionUnavailable
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("testclient-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try makeWAV(pcm: pcm, sampleRate: uplinkSampleRate).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        logger.info("apple speech start", metadata: ["wav_bytes": "\(pcm.count)"])
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if #available(macOS 13, *) {
            request.requiresOnDeviceRecognition = false
        }

        let text: String = try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    continuation.resume(throwing: TestClientError.speechRecognitionFailed(error.localizedDescription))
                    return
                }
                guard let result, result.isFinal else { return }
                continuation.resume(returning: result.bestTranscription.formattedString)
            }
        }
        return text
    }

    private func makeWAV(pcm: Data, sampleRate: Int) -> Data {
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
