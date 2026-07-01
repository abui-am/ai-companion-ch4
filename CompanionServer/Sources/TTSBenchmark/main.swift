import AVFoundation
import CompanionEnv
import Foundation
import Kokoro

// Benchmarks Cartesia (cloud, streaming WS) against Kokoro (local, on-device MLX)
// TTS on identical text, derived once by transcribing the given input audio file
// via Cartesia's cloud STT (not Apple's local Speech framework — SFSpeechRecognizer
// requires an interactive TCC permission prompt that a headless/agent shell can't
// satisfy and hard-crashes the process instead of just denying).
//
// Both engines synthesize the same text as a single non-streaming chunk for a fair
// apples-to-apples comparison, run twice each (cold + warm) since both have a
// one-time setup cost (WS handshake / Metal model load + JIT) that a long-running
// server would pay once and amortize across many turns.
//
// Usage: TTSBenchmark <input-audio-file> [override-text]

struct BenchmarkResult {
    let label: String
    let setupMs: Int
    let synthesisMs: Int
    let audioDurationMs: Int
    let pcm: Data
    let sampleRate: Int

    var realtimeFactor: Double {
        guard synthesisMs > 0 else { return 0 }
        return Double(audioDurationMs) / Double(synthesisMs)
    }
}

enum BenchmarkError: Error, CustomStringConvertible {
    case audioFormatError
    case cartesiaError(String)

    var description: String {
        switch self {
        case .audioFormatError: "Failed to decode/convert input audio."
        case .cartesiaError(let message): "Cartesia error: \(message)"
        }
    }
}

// MARK: - Decode input audio file to 16kHz mono PCM s16le (matches Cartesia STT's expected format)

func decodeToPCM16(_ url: URL, targetSampleRate: Double = 16_000) throws -> Data {
    let file = try AVAudioFile(forReading: url)
    let sourceFormat = file.processingFormat
    guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: targetSampleRate, channels: 1, interleaved: true) else {
        throw BenchmarkError.audioFormatError
    }
    guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
        throw BenchmarkError.audioFormatError
    }
    guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw BenchmarkError.audioFormatError
    }
    try file.read(into: sourceBuffer)

    let outputCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * targetSampleRate / sourceFormat.sampleRate) + 1024
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
        throw BenchmarkError.audioFormatError
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
        throw conversionError ?? BenchmarkError.audioFormatError
    }
    return Data(bytes: channelData[0], count: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size)
}

// MARK: - Cartesia STT (one-shot file transcription, same protocol as CartesiaSTTService)

func transcribeViaCartesia(pcm: Data, apiKey: String, sampleRate: Int) async throws -> String {
    var components = URLComponents(string: "wss://api.cartesia.ai/stt/websocket")!
    components.queryItems = [
        URLQueryItem(name: "model", value: "ink-whisper"),
        URLQueryItem(name: "encoding", value: "pcm_s16le"),
        URLQueryItem(name: "sample_rate", value: "\(sampleRate)"),
        URLQueryItem(name: "cartesia_version", value: "2026-03-01"),
        URLQueryItem(name: "language", value: "en"),
    ]
    var request = URLRequest(url: components.url!)
    request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
    let task = URLSession.shared.webSocketTask(with: request)
    task.resume()
    defer { task.cancel(with: .normalClosure, reason: nil) }

    let chunkBytes = sampleRate / 1000 * 100 * 2 // 100ms chunks, 16-bit mono
    var offset = 0
    while offset < pcm.count {
        let end = min(offset + chunkBytes, pcm.count)
        try await task.send(.data(pcm.subdata(in: offset..<end)))
        offset = end
    }
    try await task.send(.string("finalize"))

    var transcriptChunks: [String] = []
    while true {
        let message = try await task.receive()
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { continue }

        switch type {
        case "transcript":
            if (json["is_final"] as? Bool) == true, let chunk = json["text"] as? String, !chunk.isEmpty {
                transcriptChunks.append(chunk)
            }
        case "flush_done", "done":
            return transcriptChunks.joined(separator: " ")
        case "error":
            throw BenchmarkError.cartesiaError("\(json)")
        default:
            break
        }
    }
}

func wrapWAV(pcm: Data, sampleRate: Int) -> Data {
    var header = Data()
    let byteRate = sampleRate * 2
    let dataSize = UInt32(pcm.count)
    let chunkSize = 36 + dataSize
    func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
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

// MARK: - Cartesia TTS (single persistent WS connection, two single-shot synthesis calls)

actor CartesiaBenchmarkClient {
    private let apiKey: String
    private let voiceId: String
    private let modelId: String
    private let sampleRate: Int
    private var socket: URLSessionWebSocketTask?

    init(apiKey: String, voiceId: String, modelId: String, sampleRate: Int) {
        self.apiKey = apiKey
        self.voiceId = voiceId
        self.modelId = modelId
        self.sampleRate = sampleRate
    }

    func connect() async -> Int {
        let start = Date()
        var components = URLComponents(string: "wss://api.cartesia.ai/tts/websocket")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "cartesia_version", value: "2024-06-10"),
        ]
        let task = URLSession.shared.webSocketTask(with: components.url!)
        task.resume()
        socket = task
        return Int(Date().timeIntervalSince(start) * 1000)
    }

    func synthesize(text: String) async throws -> (synthesisMs: Int, pcm: Data) {
        guard let socket else { fatalError("connect() must be called first") }
        let contextId = UUID().uuidString
        let payload: [String: Any] = [
            "model_id": modelId,
            "transcript": text,
            "voice": ["mode": "id", "id": voiceId],
            "output_format": ["container": "raw", "encoding": "pcm_s16le", "sample_rate": sampleRate],
            "context_id": contextId,
            "continue": false,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let start = Date()
        try await socket.send(.string(String(decoding: body, as: UTF8.self)))

        var pcm = Data()
        while true {
            let message = try await socket.receive()
            guard case .string(let text) = message,
                  let responseData = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let type = json["type"] as? String
            else { continue }

            switch type {
            case "chunk":
                if let base64 = json["data"] as? String, let chunk = Data(base64Encoded: base64) {
                    pcm.append(chunk)
                }
            case "done":
                return (Int(Date().timeIntervalSince(start) * 1000), pcm)
            case "error":
                throw BenchmarkError.cartesiaError("\(json["error"] ?? json)")
            default:
                break
            }
        }
    }

    func close() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }
}

func benchmarkCartesia(text: String, config: AppConfig) async throws -> (cold: BenchmarkResult, warm: BenchmarkResult) {
    let client = CartesiaBenchmarkClient(
        apiKey: config.cartesiaAPIKey,
        voiceId: config.cartesiaVoiceId,
        modelId: config.cartesiaModelId,
        sampleRate: 24_000
    )
    let setupMs = await client.connect()

    let (coldMs, coldPCM) = try await client.synthesize(text: text)
    let (warmMs, warmPCM) = try await client.synthesize(text: text)
    await client.close()

    let durationMs = { (pcm: Data) in Int(Double(pcm.count) / 2.0 / 24_000.0 * 1000) }
    return (
        cold: BenchmarkResult(label: "Cartesia (cold)", setupMs: setupMs, synthesisMs: coldMs, audioDurationMs: durationMs(coldPCM), pcm: coldPCM, sampleRate: 24_000),
        warm: BenchmarkResult(label: "Cartesia (warm)", setupMs: 0, synthesisMs: warmMs, audioDurationMs: durationMs(warmPCM), pcm: warmPCM, sampleRate: 24_000)
    )
}

// MARK: - Kokoro (local model load once, two single-shot synthesis calls)

func benchmarkKokoro(text: String, config: AppConfig) throws -> (cold: BenchmarkResult, warm: BenchmarkResult) {
    let weightsDir = URL(fileURLWithPath: config.kokoroWeightsDir, isDirectory: true)
    let configURL = weightsDir.appendingPathComponent("config.json")
    let weightsURL = weightsDir.appendingPathComponent("kokoro-v1_0.safetensors")
    let voicesDir = weightsDir.appendingPathComponent("voices", isDirectory: true)

    let loadStart = Date()
    let model = try KModel(configURL: configURL, weightsURL: weightsURL)
    let voices = VoiceLoader(baseDirectory: voicesDir, enableDownload: true)
    let pipeline = KPipeline(model: model, voices: voices)
    let setupMs = Int(Date().timeIntervalSince(loadStart) * 1000)

    func synth() throws -> (ms: Int, pcm: Data, sampleRate: Int) {
        let start = Date()
        let result = try pipeline.synthesize(text: text, voice: config.kokoroVoice)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let pcm = Data(AudioWriter.wavData(samples: result.audio, sampleRate: result.sampleRate).dropFirst(44))
        return (ms, pcm, result.sampleRate)
    }

    // First call after model load also pays Metal's one-time JIT kernel compile cost.
    let cold = try synth()
    let warm = try synth()

    let durationMs = { (pcm: Data, sr: Int) in Int(Double(pcm.count) / 2.0 / Double(sr) * 1000) }
    return (
        cold: BenchmarkResult(label: "Kokoro (cold, incl. model load + Metal JIT)", setupMs: setupMs, synthesisMs: cold.ms, audioDurationMs: durationMs(cold.pcm, cold.sampleRate), pcm: cold.pcm, sampleRate: cold.sampleRate),
        warm: BenchmarkResult(label: "Kokoro (warm)", setupMs: 0, synthesisMs: warm.ms, audioDurationMs: durationMs(warm.pcm, warm.sampleRate), pcm: warm.pcm, sampleRate: warm.sampleRate)
    )
}

// MARK: - OpenAI chat (streaming, mirrors OpenAIRESTService.chat — duplicated here
// since CompanionServer's internals aren't exposed as a library target)

let companionSystemPrompt = """
You are Botchill, a voice AI assistant.
Reply naturally and keep responses short enough for spoken playback.
Always respond in English, even if the user's transcript is in another language.
If the user asks to change the LED color, call the `set_led` tool with RGB integer values between 0 and 255.
If no tool is needed, answer normally.
"""

func streamChatCompletion(
    transcript: String,
    apiKey: String,
    model: String = "gpt-5-nano",
    logTokenArrivals: Bool = false
) async throws -> (firstTokenMs: Int, totalMs: Int, tokenCount: Int, reply: String) {
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "model": model,
        "messages": [
            ["role": "system", "content": companionSystemPrompt],
            ["role": "user", "content": transcript],
        ],
        "stream": true,
    ])

    let start = Date()
    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard (200...299).contains(status) else {
        var errorBody = Data()
        for try await byte in bytes { errorBody.append(byte) }
        throw BenchmarkError.cartesiaError("OpenAI HTTP \(status): \(String(data: errorBody, encoding: .utf8) ?? "")")
    }

    var firstTokenMs: Int?
    var tokenCount = 0
    var reply = ""
    for try await line in bytes.lines {
        guard line.hasPrefix("data: ") else { continue }
        let payload = String(line.dropFirst(6))
        if payload == "[DONE]" { break }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String,
              !content.isEmpty
        else { continue }
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        if firstTokenMs == nil {
            firstTokenMs = elapsedMs
        }
        tokenCount += 1
        if logTokenArrivals, tokenCount <= 10 {
            print("  [+\(elapsedMs)ms] token #\(tokenCount): \(content.debugDescription)")
        }
        reply += content
    }
    let totalMs = Int(Date().timeIntervalSince(start) * 1000)
    return (firstTokenMs ?? totalMs, totalMs, tokenCount, reply)
}

// MARK: - main

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("Usage: TTSBenchmark <input-audio-file>\n".data(using: .utf8)!)
    exit(1)
}
let inputURL = URL(fileURLWithPath: arguments[1])

let config: AppConfig
do {
    config = try await AppConfig.load()
} catch let error as AppConfigError {
    print("Config error: \(error.description)")
    exit(1)
}

// Stage 1+2: decode + STT (Cartesia) — shared by both TTS variants below.
print("Decoding \(inputURL.path) ...")
let pcm = try decodeToPCM16(inputURL)
print("Transcribing via Cartesia STT (\(pcm.count) bytes PCM @ 16kHz) ...")
let sttStart = Date()
let transcript = try await transcribeViaCartesia(pcm: pcm, apiKey: config.cartesiaAPIKey, sampleRate: 16_000)
let sttMs = Int(Date().timeIntervalSince(sttStart) * 1000)
print("Transcript (\(transcript.count) chars): \(transcript)")

// Stage 3: LLM. Compare gpt-5-nano (production model) against gpt-4o-mini to check
// whether the near-zero first-token-to-total gap we keep seeing is a property of
// this specific model (e.g. an internal reasoning phase before any visible tokens)
// rather than a streaming bug — log the first 10 token arrival times for each.
print("\nCalling OpenAI chat (gpt-5-nano) ...")
let (nanoFirstTokenMs, nanoTotalMs, nanoTokenCount, _) = try await streamChatCompletion(
    transcript: transcript, apiKey: config.openAIAPIKey, model: "gpt-5-nano", logTokenArrivals: true
)
print("  gpt-5-nano: first_token=\(nanoFirstTokenMs)ms total=\(nanoTotalMs)ms tokens=\(nanoTokenCount)")

print("\nCalling OpenAI chat (gpt-4o-mini) ...")
let (miniFirstTokenMs, miniTotalMs, miniTokenCount, reply) = try await streamChatCompletion(
    transcript: transcript, apiKey: config.openAIAPIKey, model: "gpt-4o-mini", logTokenArrivals: true
)
print("  gpt-4o-mini: first_token=\(miniFirstTokenMs)ms total=\(miniTotalMs)ms tokens=\(miniTokenCount)")
print("\nUsing gpt-4o-mini's reply for the TTS stage below (\(reply.count) chars): \(reply)")

let llmFirstTokenMs = miniFirstTokenMs
let llmTotalMs = miniTotalMs

// Stage 4: TTS — this is the actual comparison. "Warm" numbers approximate a
// long-running server where the connection/model is already up from a prior turn.
print("\n--- TTS: Cartesia ---")
let (cartesiaCold, cartesiaWarm) = try await benchmarkCartesia(text: reply, config: config)

print("\n--- TTS: Kokoro ---")
let (kokoroCold, kokoroWarm) = try benchmarkKokoro(text: reply, config: config)

func printStageRow(_ stage: String, _ cartesiaMs: Int, _ kokoroMs: Int) {
    print(String(format: "%-28@ %14d ms %14d ms", stage, cartesiaMs, kokoroMs))
}

print("\n=== Full flow: audio -> STT -> OpenAI -> TTS ===")
print(String(format: "%-28@ %17@ %17@", "stage", "cartesia-flow", "kokoro-flow"))
printStageRow("STT (Cartesia, shared)", sttMs, sttMs)
printStageRow("LLM time-to-first-token", llmFirstTokenMs, llmFirstTokenMs)
printStageRow("LLM total (full reply)", llmTotalMs, llmTotalMs)
printStageRow("TTS synthesis (cold)", cartesiaCold.synthesisMs, kokoroCold.synthesisMs)
printStageRow("TTS synthesis (warm)", cartesiaWarm.synthesisMs, kokoroWarm.synthesisMs)
print("---")
printStageRow("TOTAL (STT+LLM+TTS, cold)", sttMs + llmTotalMs + cartesiaCold.synthesisMs, sttMs + llmTotalMs + kokoroCold.synthesisMs)
printStageRow("TOTAL (STT+LLM+TTS, warm)", sttMs + llmTotalMs + cartesiaWarm.synthesisMs, sttMs + llmTotalMs + kokoroWarm.synthesisMs)

let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
try wrapWAV(pcm: cartesiaWarm.pcm, sampleRate: cartesiaWarm.sampleRate).write(to: outDir.appendingPathComponent("benchmark-cartesia.wav"))
try wrapWAV(pcm: kokoroWarm.pcm, sampleRate: kokoroWarm.sampleRate).write(to: outDir.appendingPathComponent("benchmark-kokoro.wav"))
print("\nSaved benchmark-cartesia.wav and benchmark-kokoro.wav (warm TTS runs) for listening comparison.")
