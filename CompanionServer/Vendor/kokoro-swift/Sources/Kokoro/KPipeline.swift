import Foundation
import Misaki

public enum InferenceBackend {
    case mlx(KModel)
    case coremlSegmented(SegmentedCoreMLModel)

    fileprivate var maxPhonemeCount: Int {
        switch self {
        case .mlx(let model):
            return max(1, model.contextLength - 2)
        case .coremlSegmented(let model):
            return model.maxPhonemeCount
        }
    }
}

public final class KPipeline {
    public struct Result: Sendable {
        public let graphemes: String
        public let phonemes: String
        public let audio: [Float]
        public let sampleRate: Int
    }

    public let backend: InferenceBackend
    public let voices: VoiceLoader
    public let sampleRate: Int
    public let langCode: String
    public private(set) var g2p: G2P?

    public var mlxModel: KModel? {
        guard case let .mlx(model) = backend else {
            return nil
        }
        return model
    }

    public var model: KModel {
        guard let model = mlxModel else {
            fatalError("KPipeline.model is only available when using the MLX backend.")
        }
        return model
    }

    public var segmentedCoreMLModel: SegmentedCoreMLModel? {
        guard case let .coremlSegmented(model) = backend else {
            return nil
        }
        return model
    }

    public convenience init(
        model: KModel,
        voices: VoiceLoader,
        sampleRate: Int = 24_000,
        langCode: String = "en-us",
        g2p: G2P? = nil
    ) {
        self.init(
            backend: .mlx(model),
            voices: voices,
            sampleRate: sampleRate,
            langCode: langCode,
            g2p: g2p
        )
    }

    public convenience init(
        coreMLSegmentedModel: SegmentedCoreMLModel,
        voices: VoiceLoader,
        sampleRate: Int = 24_000,
        langCode: String = "en-us",
        g2p: G2P? = nil
    ) {
        self.init(
            backend: .coremlSegmented(coreMLSegmentedModel),
            voices: voices,
            sampleRate: sampleRate,
            langCode: langCode,
            g2p: g2p
        )
    }

    public init(
        backend: InferenceBackend,
        voices: VoiceLoader,
        sampleRate: Int = 24_000,
        langCode: String = "en-us",
        g2p: G2P? = nil
    ) {
        self.backend = backend
        self.voices = voices
        self.sampleRate = sampleRate
        self.langCode = langCode
        self.g2p = g2p
    }

    public func synthesize(
        phonemes: String,
        voice: String,
        speed: Float = 1.0
    ) throws -> Result {
        try synthesizeResolved(graphemes: phonemes, phonemes: phonemes, voice: voice, speed: speed)
    }

    public func synthesize(
        text: String,
        voice: String,
        speed: Float = 1.0
    ) throws -> Result {
        let phonemes = try resolveG2P()(text).phonemes
        return try synthesizeResolved(graphemes: text, phonemes: phonemes, voice: voice, speed: speed)
    }

    @discardableResult
    public func synthesizeToWAV(
        phonemes: String,
        voice: String,
        speed: Float = 1.0,
        outputURL: URL
    ) throws -> URL {
        let result = try synthesize(phonemes: phonemes, voice: voice, speed: speed)
        return try AudioWriter.writeWAV(samples: result.audio, to: outputURL, sampleRate: sampleRate)
    }

    @discardableResult
    public func synthesizeToWAV(
        text: String,
        voice: String,
        speed: Float = 1.0,
        outputURL: URL
    ) throws -> URL {
        let result = try synthesize(text: text, voice: voice, speed: speed)
        return try AudioWriter.writeWAV(samples: result.audio, to: outputURL, sampleRate: sampleRate)
    }

    public static func chunkPhonemes(_ phonemes: String, limit: Int = 510) -> [String] {
        let trimmed = phonemes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else {
            return trimmed.isEmpty ? [] : [trimmed]
        }

        let breakCharacters = Set([" ", ".", ",", ";", ":", "!", "?", "—", "…"])
        let characters = Array(trimmed)
        var chunks: [String] = []
        var start = 0

        while start < characters.count {
            let endLimit = min(start + limit, characters.count)
            if endLimit == characters.count {
                chunks.append(String(characters[start..<endLimit]).trimmingCharacters(in: .whitespaces))
                break
            }

            var splitIndex = endLimit
            var cursor = endLimit - 1
            while cursor > start + (limit / 2) {
                if breakCharacters.contains(String(characters[cursor])) {
                    splitIndex = cursor + 1
                    break
                }
                cursor -= 1
            }

            chunks.append(String(characters[start..<splitIndex]).trimmingCharacters(in: .whitespaces))
            start = splitIndex
            while start < characters.count, characters[start].isWhitespaceLike {
                start += 1
            }
        }

        return chunks.filter { !$0.isEmpty }
    }

    private func synthesizeResolved(
        graphemes: String,
        phonemes: String,
        voice: String,
        speed: Float
    ) throws -> Result {
        guard speed.isFinite, speed > 0 else {
            throw KokoroError.invalidSpeed(speed)
        }

        let normalizedPhonemes = phonemes.trimmingCharacters(in: .whitespacesAndNewlines)
        let chunks = Self.chunkPhonemes(normalizedPhonemes, limit: backend.maxPhonemeCount)
        var audio: [Float] = []

        for chunk in chunks where !chunk.isEmpty {
            let output: KModel.Output
            switch backend {
            case .mlx(let model):
                let style = try voices.styleVector(for: voice, phonemeCount: chunk.count)
                output = try model.forward(phonemes: chunk, refS: style, speed: speed)
            case .coremlSegmented(let model):
                let style = try CoreMLVoiceAdapter.styleVector(from: voices, voice: voice, phonemeCount: chunk.count)
                output = try model.forward(phonemes: chunk, refS: style, speed: speed)
            }
            audio.append(contentsOf: output.audio)
        }

        return Result(
            graphemes: graphemes,
            phonemes: normalizedPhonemes,
            audio: audio,
            sampleRate: sampleRate
        )
    }

    private func resolveG2P() throws -> G2P {
        if let g2p {
            return g2p
        }

        let normalized = Self.normalizedLangCode(langCode)
        switch normalized {
        case "en-us":
            let g2p = try G2P(british: false, unk: "")
            self.g2p = g2p
            return g2p
        case "en-gb":
            let g2p = try G2P(british: true, unk: "")
            self.g2p = g2p
            return g2p
        default:
            throw KokoroError.unsupportedLanguageCode(langCode)
        }
    }

    private static func normalizedLangCode(_ rawValue: String) -> String {
        switch rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        {
        case "a", "en", "en-us":
            return "en-us"
        case "b", "en-gb", "en-uk":
            return "en-gb"
        default:
            return rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
        }
    }
}

private extension Character {
    var isWhitespaceLike: Bool {
        unicodeScalars.allSatisfy(\.properties.isWhitespace)
    }
}
