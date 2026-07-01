import CoreML
import Foundation

public struct KokoroConfig: Codable, Sendable {
    public struct PLBERT: Codable, Sendable {
        public let hiddenSize: Int
        public let numAttentionHeads: Int
        public let intermediateSize: Int
        public let maxPositionEmbeddings: Int
        public let numHiddenLayers: Int
        public let dropout: Float

        public let embeddingSize: Int
        public let typeVocabSize: Int
        public let layerNormEps: Float
        public let hiddenAct: String
        public let numHiddenGroups: Int
        public let innerGroupNum: Int

        enum CodingKeys: String, CodingKey {
            case hiddenSize = "hidden_size"
            case numAttentionHeads = "num_attention_heads"
            case intermediateSize = "intermediate_size"
            case maxPositionEmbeddings = "max_position_embeddings"
            case numHiddenLayers = "num_hidden_layers"
            case dropout
            case embeddingSize = "embedding_size"
            case typeVocabSize = "type_vocab_size"
            case layerNormEps = "layer_norm_eps"
            case hiddenAct = "hidden_act"
            case numHiddenGroups = "num_hidden_groups"
            case innerGroupNum = "inner_group_num"
        }

        public init(from decoder: Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hiddenSize = try container.decode(Int.self, forKey: .hiddenSize)
            numAttentionHeads = try container.decode(Int.self, forKey: .numAttentionHeads)
            intermediateSize = try container.decode(Int.self, forKey: .intermediateSize)
            maxPositionEmbeddings = try container.decode(Int.self, forKey: .maxPositionEmbeddings)
            numHiddenLayers = try container.decode(Int.self, forKey: .numHiddenLayers)
            dropout = try container.decodeIfPresent(Float.self, forKey: .dropout) ?? 0.1
            embeddingSize = try container.decodeIfPresent(Int.self, forKey: .embeddingSize) ?? 128
            typeVocabSize = try container.decodeIfPresent(Int.self, forKey: .typeVocabSize) ?? 2
            layerNormEps = try container.decodeIfPresent(Float.self, forKey: .layerNormEps) ?? 1e-12
            hiddenAct = try container.decodeIfPresent(String.self, forKey: .hiddenAct) ?? "gelu_new"
            numHiddenGroups = try container.decodeIfPresent(Int.self, forKey: .numHiddenGroups) ?? 1
            innerGroupNum = try container.decodeIfPresent(Int.self, forKey: .innerGroupNum) ?? 1
        }
    }

    public struct ISTFTNet: Codable, Sendable {
        public let upsampleKernelSizes: [Int]
        public let upsampleRates: [Int]
        public let genIstftHopSize: Int
        public let genIstftNFFT: Int
        public let resblockDilationSizes: [[Int]]
        public let resblockKernelSizes: [Int]
        public let upsampleInitialChannel: Int

        enum CodingKeys: String, CodingKey {
            case upsampleKernelSizes = "upsample_kernel_sizes"
            case upsampleRates = "upsample_rates"
            case genIstftHopSize = "gen_istft_hop_size"
            case genIstftNFFT = "gen_istft_n_fft"
            case resblockDilationSizes = "resblock_dilation_sizes"
            case resblockKernelSizes = "resblock_kernel_sizes"
            case upsampleInitialChannel = "upsample_initial_channel"
        }
    }

    public let istftnet: ISTFTNet
    public let dimIn: Int
    public let dropout: Float
    public let hiddenDim: Int
    public let maxConvDim: Int
    public let maxDur: Int
    public let multispeaker: Bool
    public let nLayer: Int
    public let nMels: Int
    public let nToken: Int
    public let styleDim: Int
    public let textEncoderKernelSize: Int
    public let plbert: PLBERT
    public let vocab: [String: Int]

    enum CodingKeys: String, CodingKey {
        case istftnet
        case dimIn = "dim_in"
        case dropout
        case hiddenDim = "hidden_dim"
        case maxConvDim = "max_conv_dim"
        case maxDur = "max_dur"
        case multispeaker
        case nLayer = "n_layer"
        case nMels = "n_mels"
        case nToken = "n_token"
        case styleDim = "style_dim"
        case textEncoderKernelSize = "text_encoder_kernel_size"
        case plbert
        case vocab
    }

    public func tokenID(for phoneme: Character) -> Int? {
        vocab[String(phoneme)]
    }
}

public enum KokoroError: Error, LocalizedError {
    case invalidPhonemeLength(Int)
    case missingVoice(String)
    case missingWeights(URL)
    case expected2DVoicePack(String, [Int])
    case expectedStyleVector([Int])
    case unsupportedBatch(Int)
    case unsupportedLanguageCode(String)
    case invalidSpeed(Float)
    case invalidCoreMLPhonemeLength(Int, limit: Int)
    case missingCoreMLFeature(String)
    case invalidCoreMLArrayShape([Int])
    case unsupportedCoreMLDataType(MLMultiArrayDataType)
    case invalidSegmentedCoreMLContract(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPhonemeLength(let count):
            return "Phoneme sequence length \(count) exceeds Kokoro's 510-token context."
        case .missingVoice(let name):
            return "Could not find converted voice pack '\(name)'."
        case .missingWeights(let url):
            return "Could not find converted weights at \(url.path)."
        case .expected2DVoicePack(let name, let shape):
            return "Voice '\(name)' must be a rank-2 array after conversion, got shape \(shape)."
        case .expectedStyleVector(let shape):
            return "Expected style vector with trailing dimension 256, got shape \(shape)."
        case .unsupportedBatch(let batch):
            return "This initial Kokoro Swift port currently supports batch size 1, got \(batch)."
        case .unsupportedLanguageCode(let langCode):
            return "Kokoro Swift text synthesis currently supports English Misaki G2P only, got '\(langCode)'."
        case .invalidSpeed(let speed):
            return "Speech speed must be a finite value greater than 0, got \(speed)."
        case .invalidCoreMLPhonemeLength(let count, let limit):
            return "Phoneme sequence length \(count) exceeds this CoreML model's \(limit)-phoneme limit."
        case .missingCoreMLFeature(let name):
            return "Missing expected CoreML feature '\(name)'."
        case .invalidCoreMLArrayShape(let shape):
            return "Unexpected CoreML multi-array shape \(shape)."
        case .unsupportedCoreMLDataType(let dataType):
            return "Unsupported CoreML multi-array data type \(dataType.rawValue)."
        case .invalidSegmentedCoreMLContract(let message):
            return message
        }
    }
}
