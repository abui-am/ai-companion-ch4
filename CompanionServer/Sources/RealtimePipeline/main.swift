import AVFoundation
import CompanionEnv
import Foundation

// New pipeline path: sound -> gpt-realtime-mini -> wav. Unlike the production
// VoiceSession pipeline (separate STT + LLM + TTS stages/providers), OpenAI's
// Realtime API does speech-in/speech-out in a single WebSocket session — no
// separate Cartesia/Kokoro TTS call needed, the model speaks its own reply.
//
// The exact Realtime API event names have shifted across API versions (some docs
// say `response.audio.delta` with an `audio` field, others say
// `response.output_audio.delta` with a `delta` field) — this handles both and logs
// every event type it doesn't recognize, so behavior can be confirmed/adjusted
// against whatever the live API actually sends back.
//
// Usage: RealtimePipeline <input-audio-file> [model] [voice]

enum RealtimePipelineError: Error, CustomStringConvertible {
    case audioFormatError
    case serverError(String)

    var description: String {
        switch self {
        case .audioFormatError: "Failed to decode/convert input audio."
        case .serverError(let message): "Realtime API error: \(message)"
        }
    }
}

let companionSystemPrompt = """
You are Botchill, a voice AI assistant.
Reply naturally and keep responses short enough for spoken playback.
Always respond in English, even if the user's transcript is in another language.
"""

// MARK: - Decode input audio file to 16-bit PCM mono at the given sample rate

func decodeToPCM16(_ url: URL, targetSampleRate: Double) throws -> Data {
    let file = try AVAudioFile(forReading: url)
    let sourceFormat = file.processingFormat
    guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: targetSampleRate, channels: 1, interleaved: true) else {
        throw RealtimePipelineError.audioFormatError
    }
    guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
        throw RealtimePipelineError.audioFormatError
    }
    guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw RealtimePipelineError.audioFormatError
    }
    try file.read(into: sourceBuffer)

    let outputCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * targetSampleRate / sourceFormat.sampleRate) + 1024
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
        throw RealtimePipelineError.audioFormatError
    }

    var suppliedInput = false
    var conversionError: NSError?
    let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
        if suppliedInput {
            outStatus.pointee = .noDataNow
            return nil
        }
        suppliedInput = true
        outStatus.pointee = .haveData
        return sourceBuffer
    }
    guard status != .error, conversionError == nil, let channelData = outputBuffer.int16ChannelData else {
        throw conversionError ?? RealtimePipelineError.audioFormatError
    }
    return Data(bytes: channelData[0], count: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size)
}

func wrapWAV(pcm: Data, sampleRate: Int) -> Data {
    var header = Data()
    let byteRate = sampleRate * 2
    let dataSize = UInt32(pcm.count)
    let chunkSize = 36 + dataSize
    func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    header.append(contentsOf: "RIFF".utf8)
    header.append(le32(chunkSize))
    header.append(contentsOf: "WAVE".utf8)
    header.append(contentsOf: "fmt ".utf8)
    header.append(le32(16))
    header.append(le16(1))
    header.append(le16(1))
    header.append(le32(UInt32(sampleRate)))
    header.append(le32(UInt32(byteRate)))
    header.append(le16(2))
    header.append(le16(16))
    header.append(contentsOf: "data".utf8)
    header.append(le32(dataSize))
    header.append(pcm)
    return header
}

// MARK: - Realtime pipeline

func runRealtimePipeline(inputURL: URL, model: String, voice: String, apiKey: String) async throws {
    let sampleRate = 24_000
    print("Decoding \(inputURL.path) to PCM16 @ \(sampleRate)Hz ...")
    let pcm = try decodeToPCM16(inputURL, targetSampleRate: Double(sampleRate))
    print("Decoded \(pcm.count) bytes (\(Double(pcm.count) / 2 / Double(sampleRate)) s of audio)")

    var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(model)")!)
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    let socket = URLSession.shared.webSocketTask(with: request)
    socket.resume()
    defer { socket.cancel(with: .normalClosure, reason: nil) }

    func send(_ json: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    let connectStart = Date()
    try await send([
        "type": "session.update",
        "session": [
            "type": "realtime",
            "instructions": companionSystemPrompt,
            "audio": [
                "input": [
                    "format": ["type": "audio/pcm", "rate": sampleRate],
                    "turn_detection": NSNull(),
                ],
                "output": [
                    "format": ["type": "audio/pcm", "rate": sampleRate],
                    "voice": voice,
                ],
            ],
        ],
    ])

    // Stream the whole input as uplink chunks (mirrors how a live mic would feed it).
    let chunkBytes = sampleRate / 1000 * 100 * 2 // 100ms chunks, 16-bit mono
    var offset = 0
    while offset < pcm.count {
        let end = min(offset + chunkBytes, pcm.count)
        let chunk = pcm.subdata(in: offset..<end)
        try await send(["type": "input_audio_buffer.append", "audio": chunk.base64EncodedString()])
        offset = end
    }
    try await send(["type": "input_audio_buffer.commit"])
    try await send(["type": "response.create"])
    print("Sent session config + \(pcm.count) bytes of audio + commit + response.create")

    var firstAudioMs: Int?
    var responsePCM = Data()
    var transcript = ""
    var userTranscript = ""

    while true {
        let message = try await socket.receive()
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { continue }

        switch type {
        case "session.created", "session.updated":
            print("[\(type)]")

        case "conversation.item.input_audio_transcription.completed":
            if let text = json["transcript"] as? String {
                userTranscript = text
                print("[input transcript] \(text)")
            }

        case "response.audio.delta", "response.output_audio.delta":
            let base64 = (json["audio"] as? String) ?? (json["delta"] as? String)
            guard let base64, let chunk = Data(base64Encoded: base64) else { break }
            if firstAudioMs == nil {
                firstAudioMs = Int(Date().timeIntervalSince(connectStart) * 1000)
                print("[+\(firstAudioMs!)ms] first audio delta")
            }
            responsePCM.append(chunk)

        case "response.audio_transcript.delta", "response.output_audio_transcript.delta":
            if let delta = json["delta"] as? String {
                transcript += delta
            }

        case "response.done":
            let totalMs = Int(Date().timeIntervalSince(connectStart) * 1000)
            print("[response.done] total=\(totalMs)ms")
            let durationMs = Int(Double(responsePCM.count) / 2.0 / Double(sampleRate) * 1000)
            print("\n=== Result ===")
            print("Model: \(model), voice: \(voice)")
            if !userTranscript.isEmpty { print("Input transcript: \(userTranscript)") }
            print("Reply transcript: \(transcript)")
            print("Time to first audio: \(firstAudioMs.map { "\($0)ms" } ?? "n/a")")
            print("Total response time: \(totalMs)ms")
            print("Output audio duration: \(durationMs)ms")

            let outURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("realtime-output.wav")
            try wrapWAV(pcm: responsePCM, sampleRate: sampleRate).write(to: outURL)
            print("Saved \(outURL.path)")
            return

        case "error":
            throw RealtimePipelineError.serverError("\(json["error"] ?? json)")

        default:
            print("[\(type)] (unhandled)")
        }
    }
}

// MARK: - main

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("Usage: RealtimePipeline <input-audio-file> [model] [voice]\n".data(using: .utf8)!)
    exit(1)
}
let inputURL = URL(fileURLWithPath: arguments[1])
let model = arguments.count >= 3 ? arguments[2] : "gpt-realtime-mini"
let voice = arguments.count >= 4 ? arguments[3] : "marin"

let config: AppConfig
do {
    config = try await AppConfig.load()
} catch let error as AppConfigError {
    print("Config error: \(error.description)")
    exit(1)
}

try await runRealtimePipeline(inputURL: inputURL, model: model, voice: voice, apiKey: config.openAIAPIKey)
