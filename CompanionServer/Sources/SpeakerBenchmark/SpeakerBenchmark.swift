@preconcurrency import AVFoundation
import CompanionEnv
import Foundation
import Logging

// Sends a prerecorded benchmark clip to CompanionServer `/ws` so TestFirmware
// on `/speaker` can exercise the full downlink path without a live Mac mic.
//
// Default input: CompanionServer/benchmark_input.m4a (same file as RealtimePipeline).
//
// Usage:
//   swift run SpeakerBenchmark
//   swift run SpeakerBenchmark /path/to/audio.m4a

@main
enum SpeakerBenchmark {
    private static let uplinkSampleRate = 16_000
    private static let uplinkFrameMs = 60
    private static let uplinkFrameBytes = uplinkSampleRate / 1000 * uplinkFrameMs * 2

    enum Error: Swift.Error, CustomStringConvertible {
        case audioFormatError
        case missingInput(String)
        case unexpectedMessage(String)

        var description: String {
            switch self {
            case .audioFormatError:
                "Failed to decode/convert input audio to 16 kHz mono PCM."
            case .missingInput(let path):
                "Input file not found: \(path)"
            case .unexpectedMessage(let text):
                "Unexpected server message: \(text)"
            }
        }
    }

    static func main() async throws {
        var logger = Logger(label: "SpeakerBenchmark")
        LogConfig.apply(to: &logger)

        let defaultInput = PackagePaths.resolveRelativeToPackageRoot("benchmark_input.m4a")
        let inputPath = CommandLine.arguments.count >= 2 ? CommandLine.arguments[1] : defaultInput
        let inputURL = URL(fileURLWithPath: inputPath)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw Error.missingInput(inputURL.path)
        }

        let config = try await AppConfig.load()
        logger.info(
            "starting benchmark turn",
            metadata: [
                "input": .string(inputURL.path),
                "companion_host": .string(config.companionHost),
            ]
        )
        print("Input: \(inputURL.lastPathComponent)")
        print("Uplink → \(config.companionHost)  |  Downlink → TestFirmware (/speaker)")

        guard await ensureServerReachable(host: config.companionHost, logger: logger) else {
            exit(1)
        }

        let pcm = try decodeToPCM16(inputURL, targetSampleRate: Double(uplinkSampleRate))
        let durationMs = pcm.count / 2 * 1000 / uplinkSampleRate
        logger.info("decoded input", metadata: ["bytes": "\(pcm.count)", "duration_ms": "\(durationMs)"])

        let socket = makeSocket(host: config.companionHost, token: config.deviceToken, logger: logger)
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        try await send(
            socket,
            json: [
                "type": "session.start",
                "audio": ["format": "opus", "sample_rate": uplinkSampleRate, "frame_ms": uplinkFrameMs],
            ],
            logger: logger
        )
        try await expect(socket, type: "session.ready", logger: logger)

        try await send(socket, json: ["type": "audio.start"], logger: logger)

        var framesSent = 0
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + uplinkFrameBytes, pcm.count)
            let frame = pcm.subdata(in: offset..<end)
            try await socket.send(.data(frame))
            framesSent += 1
            offset = end
            if offset < pcm.count {
                try await Task.sleep(nanoseconds: UInt64(uplinkFrameMs) * 1_000_000)
            }
        }

        let captureFinishedAt = Date()
        try await send(socket, json: ["type": "audio.stop"], logger: logger)
        logger.info("uplink complete", metadata: ["frames_sent": "\(framesSent)"])
        print("Sent \(framesSent) uplink frames (\(durationMs) ms audio). Waiting for TestFirmware playback...")

        try await drainUntilTTSEnd(socket, logger: logger, captureFinishedAt: captureFinishedAt)
        print("Benchmark turn complete.")
        if let root = PackagePaths.packageRoot() {
            print("Server WAV dumps → \(root)/debug-audio/")
            print("  *-uplink.wav   mic/audio sent to server")
            print("  *-downlink.wav AI TTS response")
        }
    }

    // MARK: - WebSocket helpers

    private static func makeSocket(host: String, token: String, logger: Logger) -> URLSessionWebSocketTask {
        logger.info("connecting websocket", metadata: ["url": .string(host)])
        var request = URLRequest(url: URL(string: host)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        return socket
    }

    private static func send(_ socket: URLSessionWebSocketTask, json: [String: Any], logger: Logger) async throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        let text = String(decoding: data, as: UTF8.self)
        logger.debug("send text", metadata: ["json": .string(text)])
        try await socket.send(.string(text))
    }

    private static func expect(_ socket: URLSessionWebSocketTask, type: String, logger: Logger) async throws {
        let message = try await socket.receive()
        guard case .string(let text) = message else {
            throw Error.unexpectedMessage("\(message)")
        }
        logger.info("recv text", metadata: ["json": .string(text)])
        guard text.contains("\"\(type)\"") else {
            throw Error.unexpectedMessage(text)
        }
    }

    private static func drainUntilTTSEnd(
        _ socket: URLSessionWebSocketTask,
        logger: Logger,
        captureFinishedAt: Date
    ) async throws {
        var downlinkFrames = 0
        var firstDownlinkAt: Date?

        while true {
            let message = try await socket.receive()
            switch message {
            case .string(let text):
                logger.info("recv", metadata: ["json": .string(text)])
                if text.contains("\"transcript.final\"") {
                    if let transcript = extractJSONStringField(named: "text", from: text) {
                        print("Transcript: \(transcript)")
                    }
                }
                if text.contains("\"tts.start\"") {
                    print("[speaking] tts.start — check TestFirmware serial for downlink frames")
                }
                if text.contains("\"error\"") {
                    print("Server error: \(text)")
                    return
                }
                if text.contains("\"tts.end\"") {
                    let stopToSpeechMs = firstDownlinkAt.map {
                        max(0, Int($0.timeIntervalSince(captureFinishedAt) * 1000))
                    }
                    logger.info(
                        "benchmark complete",
                        metadata: [
                            "downlink_frames_on_ws": "\(downlinkFrames)",
                            "stop_to_first_downlink_ms": "\(stopToSpeechMs ?? -1)",
                        ]
                    )
                    print("Downlink frames on /ws: \(downlinkFrames) (TestFirmware on /speaker mirrors these)")
                    return
                }
            case .data(let data):
                downlinkFrames += 1
                if firstDownlinkAt == nil {
                    firstDownlinkAt = Date()
                    let ms = max(0, Int(firstDownlinkAt!.timeIntervalSince(captureFinishedAt) * 1000))
                    print("First downlink frame after audio.stop: \(ms) ms")
                }
                _ = data
            @unknown default:
                continue
            }
        }
    }

    private static func extractJSONStringField(named key: String, from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key] as? String
        else { return nil }
        return value
    }

    private static func ensureServerReachable(host: String, logger: Logger) async -> Bool {
        guard var components = URLComponents(string: host) else {
            logger.critical("Invalid companion host: \(host)")
            return false
        }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = "/ping"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return false }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                logger.critical("CompanionServer not reachable at \(url.host ?? "?")")
                return false
            }
            return true
        } catch {
            let pingURL = url.absoluteString
            logger.critical(
                "Cannot reach CompanionServer at \(pingURL) — is it running? Start it first: cd CompanionServer && swift run CompanionServer"
            )
            print("Cannot reach CompanionServer at \(pingURL)")
            print("Start the server in another terminal: cd CompanionServer && swift run CompanionServer")
            return false
        }
    }

    // MARK: - Audio decode

    private static func decodeToPCM16(_ url: URL, targetSampleRate: Double) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw Error.audioFormatError
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw Error.audioFormatError
        }
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw Error.audioFormatError
        }
        try file.read(into: sourceBuffer)

        let outputCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * targetSampleRate / sourceFormat.sampleRate) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            throw Error.audioFormatError
        }

        final class ConversionState: @unchecked Sendable {
            var suppliedInput = false
            let sourceBuffer: AVAudioPCMBuffer
            init(sourceBuffer: AVAudioPCMBuffer) {
                self.sourceBuffer = sourceBuffer
            }
        }

        let state = ConversionState(sourceBuffer: sourceBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if state.suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            state.suppliedInput = true
            outStatus.pointee = .haveData
            return state.sourceBuffer
        }
        guard status != .error, conversionError == nil, let channelData = outputBuffer.int16ChannelData else {
            throw conversionError ?? Error.audioFormatError
        }
        return Data(bytes: channelData[0], count: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size)
    }
}
