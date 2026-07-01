import Foundation
import Misaki
import Testing
@testable import Kokoro

private func resolvedConvertedDirectory() -> URL? {
    let fileManager = FileManager.default
    let currentDirectoryURL = URL(
        fileURLWithPath: fileManager.currentDirectoryPath,
        isDirectory: true
    )

    let candidates: [URL] = [
        ProcessInfo.processInfo.environment["KOKORO_SMOKE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) },
        currentDirectoryURL.appendingPathComponent("MLX_GPU", isDirectory: true),
        currentDirectoryURL.appendingPathComponent("../../MLX_GPU", isDirectory: true).standardizedFileURL,
        URL(fileURLWithPath: "/tmp/kokoro-converted", isDirectory: true),
    ]
    .compactMap { $0 }

    return candidates.first { fileManager.fileExists(atPath: $0.path) }
}

private func resolvedSegmentedDirectory() -> URL? {
    let fileManager = FileManager.default
    let currentDirectoryURL = URL(
        fileURLWithPath: fileManager.currentDirectoryPath,
        isDirectory: true
    )

    let candidates: [URL] = [
        ProcessInfo.processInfo.environment["KOKORO_SEGMENTED_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) },
        currentDirectoryURL.appendingPathComponent("CoreML_ANE/segmented", isDirectory: true),
        currentDirectoryURL.appendingPathComponent("../../CoreML_ANE/segmented", isDirectory: true).standardizedFileURL,
    ]
    .compactMap { $0 }

    return candidates.first { fileManager.fileExists(atPath: $0.path) }
}

@Test func integratesMisakiG2PWithKokoroInference() throws {
    let text = "Hello world from Swift."
    let g2p = try G2P(unk: "")
    let phonemes = g2p(text).phonemes.trimmingCharacters(in: .whitespacesAndNewlines)

    #expect(!phonemes.isEmpty)

    guard let convertedDirectoryURL = resolvedConvertedDirectory() else {
        return
    }
    let configURL = convertedDirectoryURL.appendingPathComponent("config.json", isDirectory: false)
    guard FileManager.default.fileExists(atPath: configURL.path) else {
        return
    }

    let configData = try Data(contentsOf: configURL)
    let config = try JSONDecoder().decode(KokoroConfig.self, from: configData)

    for phoneme in phonemes where !phoneme.isWhitespace {
        #expect(config.tokenID(for: phoneme) != nil)
    }

    let manifest = ConvertedWeightsManifest(directory: convertedDirectoryURL)
    let voiceURL = manifest.voicesDirectoryURL.appendingPathComponent("af_heart.npy", isDirectory: false)
    guard FileManager.default.fileExists(atPath: manifest.modelURL.path),
          FileManager.default.fileExists(atPath: voiceURL.path)
    else {
        return
    }

    let model = try KModel(configURL: configURL, weightsURL: manifest.modelURL)
    let voices = VoiceLoader(baseDirectory: manifest.voicesDirectoryURL)
    let pipeline = KPipeline(model: model, voices: voices, g2p: g2p)
    let result = try pipeline.synthesize(text: text, voice: "af_heart")

    #expect(result.graphemes == text)
    #expect(result.phonemes == phonemes)
    #expect(result.audio.count > 0)
    #expect(result.sampleRate == 24_000)
}

@Test func segmentedCoreMLBackendSynthesizesShortText() throws {
    let text = "Hello world."
    let g2p = try G2P(unk: "")

    guard let convertedDirectoryURL = resolvedConvertedDirectory(),
          let segmentedDirectoryURL = resolvedSegmentedDirectory()
    else {
        return
    }

    let configURL = convertedDirectoryURL.appendingPathComponent("config.json", isDirectory: false)
    let manifest = ConvertedWeightsManifest(directory: convertedDirectoryURL)
    let voiceURL = manifest.voicesDirectoryURL.appendingPathComponent("af_heart.npy", isDirectory: false)
    guard FileManager.default.fileExists(atPath: configURL.path),
          FileManager.default.fileExists(atPath: manifest.voicesDirectoryURL.path),
          FileManager.default.fileExists(atPath: voiceURL.path)
    else {
        return
    }

    let model = try SegmentedCoreMLModel(
        segmentedDir: segmentedDirectoryURL,
        configURL: configURL
    )
    let voices = VoiceLoader(baseDirectory: manifest.voicesDirectoryURL)
    let pipeline = KPipeline(coreMLSegmentedModel: model, voices: voices, g2p: g2p)
    let result = try pipeline.synthesize(text: text, voice: "af_heart")

    #expect(result.graphemes == text)
    #expect(!result.phonemes.isEmpty)
    #expect(!result.audio.isEmpty)
    #expect(result.sampleRate == 24_000)
}
