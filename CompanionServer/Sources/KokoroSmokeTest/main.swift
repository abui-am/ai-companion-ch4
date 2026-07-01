import Foundation
import Kokoro

// Standalone smoke test for the kokoro-swift local TTS pipeline: load the MLX
// model + a voice pack, synthesize a fixed sentence, write a WAV, and print
// timing so it can be compared against Cartesia's latency.report numbers.
//
// Usage: KokoroSmokeTest <weights-dir> [voice] [text]
//   weights-dir must contain config.json, kokoro-v1_0.safetensors, and a
//   voices/ subdirectory (matching the MLX_GPU/ layout from the Kokoro-82M-Swift
//   HuggingFace repo).

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("Usage: KokoroSmokeTest <weights-dir> [voice] [text]\n".data(using: .utf8)!)
    exit(1)
}

let weightsDir = URL(fileURLWithPath: arguments[1], isDirectory: true)
let voice = arguments.count >= 3 ? arguments[2] : "af_heart"
let text = arguments.count >= 4 ? arguments[3] : "Hello! This is a smoke test of the Kokoro text to speech pipeline running locally on Apple Silicon."

let configURL = weightsDir.appendingPathComponent("config.json")
let weightsURL = weightsDir.appendingPathComponent("kokoro-v1_0.safetensors")
let voicesDir = weightsDir.appendingPathComponent("voices", isDirectory: true)
let outputURL = URL(fileURLWithPath: "kokoro-smoke-test.wav")

print("Loading model from \(weightsDir.path) ...")
let loadStart = Date()
let model = try KModel(configURL: configURL, weightsURL: weightsURL)
let voices = VoiceLoader(baseDirectory: voicesDir, enableDownload: true)
let pipeline = KPipeline(model: model, voices: voices)
let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)
print("Model loaded in \(loadMs) ms")

print("Synthesizing (\(text.count) chars, voice=\(voice)) ...")
let synthStart = Date()
let result = try pipeline.synthesize(text: text, voice: voice)
let synthMs = Int(Date().timeIntervalSince(synthStart) * 1000)

try AudioWriter.writeWAV(samples: result.audio, to: outputURL, sampleRate: result.sampleRate)

let audioDurationMs = Int(Double(result.audio.count) / Double(result.sampleRate) * 1000)
print("""
Synthesis done in \(synthMs) ms
  phonemes: \(result.phonemes)
  audio samples: \(result.audio.count) @ \(result.sampleRate) Hz (\(audioDurationMs) ms of audio)
  realtime factor: \(String(format: "%.2f", Double(audioDurationMs) / Double(max(synthMs, 1))))x
  output: \(outputURL.path)
""")
