import Foundation
import MLX
import MLXFast
import MLXNN

public final class LinearNorm: Module, UnaryLayer {
    @ModuleInfo(key: "linear_layer") var linearLayer: Linear

    public init(_ inputDimensions: Int, _ outputDimensions: Int, bias: Bool = true) {
        _linearLayer.wrappedValue = Linear(inputDimensions, outputDimensions, bias: bias)
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        linearLayer(x)
    }
}

public final class ChannelLayerNorm: Module, UnaryLayer {
    @ParameterInfo(key: "gamma") public var gamma: MLXArray
    @ParameterInfo(key: "beta") public var beta: MLXArray
    public let eps: Float

    public init(channels: Int, eps: Float = 1e-5) {
        self.eps = eps
        self._gamma.wrappedValue = MLXArray.ones([channels])
        self._beta.wrappedValue = MLXArray.zeros([channels])
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLXFast.layerNorm(x, weight: gamma, bias: beta, eps: eps)
    }
}

final class TextEncoderConvBlock: Module, UnaryLayer {
    @ModuleInfo(key: "conv") var conv: TorchWeightNormConv1d
    @ModuleInfo(key: "norm") var norm: ChannelLayerNorm

    init(channels: Int, kernelSize: Int) {
        let padding = (kernelSize - 1) / 2
        _conv.wrappedValue = TorchWeightNormConv1d(
            inputChannels: channels,
            outputChannels: channels,
            kernelSize: kernelSize,
            padding: padding
        )
        _norm.wrappedValue = ChannelLayerNorm(channels: channels)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        leakyRelu(norm(conv(x)), negativeSlope: 0.2)
    }
}

public final class TextEncoder: Module {
    @ModuleInfo(key: "embedding") var embedding: Embedding
    let cnn: [TextEncoderConvBlock]
    @ModuleInfo(key: "lstm") var lstm: TorchBiLSTM

    public init(channels: Int, kernelSize: Int, depth: Int, symbols: Int) {
        _embedding.wrappedValue = Embedding(embeddingCount: symbols, dimensions: channels)
        self.cnn = (0 ..< depth).map { _ in TextEncoderConvBlock(channels: channels, kernelSize: kernelSize) }
        _lstm.wrappedValue = TorchBiLSTM(inputSize: channels, hiddenSize: channels / 2)
    }

    public func callAsFunction(_ inputIDs: MLXArray) -> MLXArray {
        var x = embedding(inputIDs)
        for block in cnn {
            x = block(x)
        }
        return lstm(x)
    }
}

public final class AdaLayerNorm: Module {
    @ModuleInfo(key: "fc") var fc: Linear
    public let channels: Int
    public let eps: Float

    public init(styleDim: Int, channels: Int, eps: Float = 1e-5) {
        self.channels = channels
        self.eps = eps
        _fc.wrappedValue = Linear(styleDim, channels * 2, bias: true)
    }

    public func callAsFunction(_ x: MLXArray, style: MLXArray) -> MLXArray {
        let h = fc(style)
        let parts = split(h, parts: 2, axis: -1)
        let gamma = parts[0].expandedDimensions(axis: 1)
        let beta = parts[1].expandedDimensions(axis: 1)
        let normalized = MLXFast.layerNorm(x, weight: nil, bias: nil, eps: eps)
        return (1 + gamma) * normalized + beta
    }
}

public final class DurationEncoder: Module {
    public let lstms: [Module]
    public let styleDim: Int
    public let hiddenDim: Int

    public init(styleDim: Int, hiddenDim: Int, layers: Int) {
        self.styleDim = styleDim
        self.hiddenDim = hiddenDim

        var blocks: [Module] = []
        blocks.reserveCapacity(layers * 2)
        for _ in 0 ..< layers {
            blocks.append(TorchBiLSTM(inputSize: hiddenDim + styleDim, hiddenSize: hiddenDim / 2))
            blocks.append(AdaLayerNorm(styleDim: styleDim, channels: hiddenDim))
        }
        self.lstms = blocks
    }

    public func callAsFunction(_ x: MLXArray, style: MLXArray) -> MLXArray {
        var output = x
        let styleRepeated = repeatStyle(style, length: x.dim(1))
        output = concatenated([output, styleRepeated], axis: -1)

        for block in lstms {
            if let lstm = block as? TorchBiLSTM {
                output = lstm(output)
            } else if let norm = block as? AdaLayerNorm {
                output = norm(output, style: style)
                output = concatenated([output, styleRepeated], axis: -1)
            }
        }
        return output
    }
}

public final class ProsodyPredictor: Module {
    @ModuleInfo(key: "text_encoder") var textEncoder: DurationEncoder
    @ModuleInfo(key: "lstm") var lstm: TorchBiLSTM
    @ModuleInfo(key: "duration_proj") var durationProj: LinearNorm
    @ModuleInfo(key: "shared") var shared: TorchBiLSTM
    let F0: [AdainResBlk1d]
    let N: [AdainResBlk1d]
    @ModuleInfo(key: "F0_proj") var F0Proj: TorchConv1d
    @ModuleInfo(key: "N_proj") var NProj: TorchConv1d

    public init(styleDim: Int, hiddenDim: Int, layers: Int, maxDur: Int) {
        _textEncoder.wrappedValue = DurationEncoder(styleDim: styleDim, hiddenDim: hiddenDim, layers: layers)
        _lstm.wrappedValue = TorchBiLSTM(inputSize: hiddenDim + styleDim, hiddenSize: hiddenDim / 2)
        _durationProj.wrappedValue = LinearNorm(hiddenDim, maxDur)
        _shared.wrappedValue = TorchBiLSTM(inputSize: hiddenDim + styleDim, hiddenSize: hiddenDim / 2)

        self.F0 = [
            AdainResBlk1d(dimIn: hiddenDim, dimOut: hiddenDim, styleDim: styleDim),
            AdainResBlk1d(dimIn: hiddenDim, dimOut: hiddenDim / 2, styleDim: styleDim, upsample: true),
            AdainResBlk1d(dimIn: hiddenDim / 2, dimOut: hiddenDim / 2, styleDim: styleDim),
        ]
        self.N = [
            AdainResBlk1d(dimIn: hiddenDim, dimOut: hiddenDim, styleDim: styleDim),
            AdainResBlk1d(dimIn: hiddenDim, dimOut: hiddenDim / 2, styleDim: styleDim, upsample: true),
            AdainResBlk1d(dimIn: hiddenDim / 2, dimOut: hiddenDim / 2, styleDim: styleDim),
        ]
        _F0Proj.wrappedValue = TorchConv1d(
            inputChannels: hiddenDim / 2,
            outputChannels: 1,
            kernelSize: 1
        )
        _NProj.wrappedValue = TorchConv1d(
            inputChannels: hiddenDim / 2,
            outputChannels: 1,
            kernelSize: 1
        )
    }

    public func durationEncoding(_ texts: MLXArray, style: MLXArray) -> MLXArray {
        textEncoder(texts, style: style)
    }

    public func predictDurations(_ encoded: MLXArray) -> MLXArray {
        durationProj(lstm(encoded))
    }

    public func F0Ntrain(_ x: MLXArray, style: MLXArray) -> (MLXArray, MLXArray) {
        let sharedOutput = shared(x)

        var f0 = sharedOutput
        for block in F0 {
            f0 = block(f0, style: style)
        }
        f0 = F0Proj(f0).squeezed(axis: -1)

        var n = sharedOutput
        for block in N {
            n = block(n, style: style)
        }
        n = NProj(n).squeezed(axis: -1)

        return (f0, n)
    }
}
