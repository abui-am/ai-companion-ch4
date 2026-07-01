import Foundation
import MLX
import MLXNN

public final class KModel: Module {
    public struct Output: Sendable {
        public let audio: [Float]
        public let predDur: [Int]
    }

    public let config: KokoroConfig
    public let vocab: [String: Int]
    public let contextLength: Int

    @ModuleInfo(key: "bert") var bert: CustomAlbert
    @ModuleInfo(key: "bert_encoder") var bertEncoder: Linear
    @ModuleInfo(key: "predictor") var predictor: ProsodyPredictor
    @ModuleInfo(key: "text_encoder") var textEncoder: TextEncoder
    @ModuleInfo(key: "decoder") var decoder: Decoder

    public init(
        configURL: URL,
        weightsURL: URL? = nil,
        disableComplex: Bool = false
    ) throws {
        let data = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(KokoroConfig.self, from: data)
        self.config = config
        self.vocab = config.vocab
        self.contextLength = config.plbert.maxPositionEmbeddings

        _bert.wrappedValue = CustomAlbert(config: config.plbert, vocabSize: config.nToken)
        _bertEncoder.wrappedValue = Linear(config.plbert.hiddenSize, config.hiddenDim, bias: true)
        _predictor.wrappedValue = ProsodyPredictor(
            styleDim: config.styleDim,
            hiddenDim: config.hiddenDim,
            layers: config.nLayer,
            maxDur: config.maxDur
        )
        _textEncoder.wrappedValue = TextEncoder(
            channels: config.hiddenDim,
            kernelSize: config.textEncoderKernelSize,
            depth: config.nLayer,
            symbols: config.nToken
        )
        _decoder.wrappedValue = Decoder(
            dimIn: config.hiddenDim,
            styleDim: config.styleDim,
            dimOut: config.nMels,
            resblockKernelSizes: config.istftnet.resblockKernelSizes,
            upsampleRates: config.istftnet.upsampleRates,
            upsampleInitialChannel: config.istftnet.upsampleInitialChannel,
            resblockDilationSizes: config.istftnet.resblockDilationSizes,
            upsampleKernelSizes: config.istftnet.upsampleKernelSizes,
            genIstftNFFT: config.istftnet.genIstftNFFT,
            genIstftHopSize: config.istftnet.genIstftHopSize,
            disableComplex: disableComplex
        )
        super.init()

        if let weightsURL {
            try loadWeights(from: weightsURL)
        }
    }

    public func loadWeights(from url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw KokoroError.missingWeights(url)
        }
        let (weights, _) = try loadArraysAndMetadata(url: url)
        let parameters = ModuleParameters.unflattened(weights)
        try update(parameters: parameters, verify: [.all])
        eval(self)
    }

    public func tokenize(_ phonemes: String) throws -> [Int] {
        let ids = phonemes.compactMap { vocab[String($0)] }
        if ids.count + 2 > contextLength {
            throw KokoroError.invalidPhonemeLength(ids.count)
        }
        return [0] + ids + [0]
    }

    public func forwardWithTokenIDs(
        _ inputIDs: MLXArray,
        refS: MLXArray,
        speed: Float = 1.0
    ) throws -> Output {
        try Self.validate(speed: speed)
        precondition(inputIDs.ndim == 2, "Expected [B, T] token ids.")
        let batch = inputIDs.dim(0)
        guard batch == 1 else {
            throw KokoroError.unsupportedBatch(batch)
        }

        let style = normalizeStyle(refS)
        let attentionMask = MLXArray.ones([1, inputIDs.dim(1)], dtype: .float32)

        let bertDur = bert(inputIDs, attentionMask: attentionMask)
        let dEn = bertEncoder(bertDur)

        let acousticStyle = style[0..., 0..<config.styleDim]
        let prosodyStyle = style[0..., config.styleDim..<(config.styleDim * 2)]

        let durationEncoded = predictor.durationEncoding(dEn, style: prosodyStyle)
        let durationLogits = predictor.predictDurations(durationEncoded)
        let duration = sum(sigmoid(durationLogits), axis: -1) / speed
        let predDur = clip(duration.round(), min: 1).asType(.int32)
        let predDurValues = predDur.asArray(Int32.self).map(Int.init)

        let alignment = buildAlignment(durations: predDurValues)
        let prosodyAligned = matmul(durationEncoded.transposed(0, 2, 1), alignment).transposed(0, 2, 1)
        let (f0Pred, nPred) = predictor.F0Ntrain(prosodyAligned, style: prosodyStyle)

        let textEncoded = textEncoder(inputIDs)
        let asr = matmul(textEncoded.transposed(0, 2, 1), alignment).transposed(0, 2, 1)

        let audio = decoder(asr, F0Curve: f0Pred, N: nPred, style: acousticStyle)
        eval(audio)
        return Output(audio: audio.asArray(Float.self), predDur: predDurValues)
    }

    public func callAsFunction(
        phonemes: String,
        refS: MLXArray,
        speed: Float = 1.0
    ) throws -> [Float] {
        try forward(phonemes: phonemes, refS: refS, speed: speed).audio
    }

    public func forward(
        phonemes: String,
        refS: MLXArray,
        speed: Float = 1.0
    ) throws -> Output {
        let ids = try tokenize(phonemes)
        let inputIDs = MLXArray(ids, [1, ids.count]).asType(.int32)
        return try forwardWithTokenIDs(inputIDs, refS: refS, speed: speed)
    }

    private static func validate(speed: Float) throws {
        guard speed.isFinite, speed > 0 else {
            throw KokoroError.invalidSpeed(speed)
        }
    }

    private func normalizeStyle(_ refS: MLXArray) -> MLXArray {
        let style = if refS.ndim == 1 {
            refS.expandedDimensions(axis: 0)
        } else {
            refS
        }
        precondition(style.ndim == 2 && style.dim(1) == config.styleDim * 2)
        return style
    }

    private func buildAlignment(durations: [Int]) -> MLXArray {
        let tokenCount = durations.count
        let totalFrames = durations.reduce(0, +)
        var values = [Float](repeating: 0, count: tokenCount * totalFrames)
        var frame = 0
        for (tokenIndex, duration) in durations.enumerated() {
            for _ in 0 ..< duration {
                values[(tokenIndex * totalFrames) + frame] = 1
                frame += 1
            }
        }
        return MLXArray(values, [1, tokenCount, totalFrames])
    }
}
