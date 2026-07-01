import Foundation
import MLX
import MLXNN

public final class AdainResBlk1d: Module {
    @ModuleInfo(key: "conv1") var conv1: TorchWeightNormConv1d
    @ModuleInfo(key: "conv2") var conv2: TorchWeightNormConv1d
    @ModuleInfo(key: "norm1") var norm1: AdaIN1d
    @ModuleInfo(key: "norm2") var norm2: AdaIN1d
    @ModuleInfo(key: "conv1x1") var conv1x1: TorchWeightNormConv1d?
    @ModuleInfo(key: "pool") var pool: TorchWeightNormConvTranspose1d?

    let upsampleLayer: Upsample?
    public let upsampleType: String
    let learnedShortcut: Bool

    public init(
        dimIn: Int,
        dimOut: Int,
        styleDim: Int = 64,
        upsample: Bool = false
    ) {
        self.upsampleType = upsample ? "upsample" : "none"
        self.learnedShortcut = dimIn != dimOut
        self.upsampleLayer = upsample ? Upsample(scaleFactor: FloatOrArray(2.0), mode: .nearest) : nil

        _conv1.wrappedValue = TorchWeightNormConv1d(
            inputChannels: dimIn,
            outputChannels: dimOut,
            kernelSize: 3,
            padding: 1
        )
        _conv2.wrappedValue = TorchWeightNormConv1d(
            inputChannels: dimOut,
            outputChannels: dimOut,
            kernelSize: 3,
            padding: 1
        )
        _norm1.wrappedValue = AdaIN1d(styleDim: styleDim, features: dimIn)
        _norm2.wrappedValue = AdaIN1d(styleDim: styleDim, features: dimOut)

        if learnedShortcut {
            _conv1x1.wrappedValue = TorchWeightNormConv1d(
                inputChannels: dimIn,
                outputChannels: dimOut,
                kernelSize: 1,
                bias: false
            )
        }
        if upsample {
            _pool.wrappedValue = TorchWeightNormConvTranspose1d(
                inputChannels: dimIn,
                outputChannels: dimIn,
                kernelSize: 3,
                stride: 2,
                padding: 1,
                outputPadding: 1,
                groups: dimIn
            )
        }
    }

    public func callAsFunction(_ x: MLXArray, style: MLXArray) -> MLXArray {
        let residual = residual(x, style: style)
        let shortcut = shortcut(x)
        return (residual + shortcut) * (1 / sqrt(Float(2)))
    }

    private func shortcut(_ x: MLXArray) -> MLXArray {
        var output = x
        if let upsampleLayer {
            output = upsampleLayer(output)
        }
        if let conv1x1 {
            output = conv1x1(output)
        }
        return output
    }

    private func residual(_ x: MLXArray, style: MLXArray) -> MLXArray {
        var output = leakyRelu(norm1(x, style: style), negativeSlope: 0.2)
        if let pool {
            output = pool(output)
        }
        output = conv1(output)
        output = leakyRelu(norm2(output, style: style), negativeSlope: 0.2)
        output = conv2(output)
        return output
    }
}

final class SingleConvSequential: Module, UnaryLayer {
    @ModuleInfo(key: "conv") var conv: TorchWeightNormConv1d

    init(inputChannels: Int, outputChannels: Int, kernelSize: Int = 1) {
        _conv.wrappedValue = TorchWeightNormConv1d(
            inputChannels: inputChannels,
            outputChannels: outputChannels,
            kernelSize: kernelSize
        )
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        conv(x)
    }
}

public final class Decoder: Module {
    @ModuleInfo(key: "encode") var encode: AdainResBlk1d
    let decode: [AdainResBlk1d]
    @ModuleInfo(key: "F0_conv") var F0Conv: TorchWeightNormConv1d
    @ModuleInfo(key: "N_conv") var NConv: TorchWeightNormConv1d
    @ModuleInfo(key: "asr_res") var asrRes: SingleConvSequential
    @ModuleInfo(key: "generator") var generator: Generator

    public init(
        dimIn: Int,
        styleDim: Int,
        dimOut: Int,
        resblockKernelSizes: [Int],
        upsampleRates: [Int],
        upsampleInitialChannel: Int,
        resblockDilationSizes: [[Int]],
        upsampleKernelSizes: [Int],
        genIstftNFFT: Int,
        genIstftHopSize: Int,
        disableComplex: Bool = false
    ) {
        _encode.wrappedValue = AdainResBlk1d(dimIn: dimIn + 2, dimOut: 1024, styleDim: styleDim)
        self.decode = [
            AdainResBlk1d(dimIn: 1024 + 2 + 64, dimOut: 1024, styleDim: styleDim),
            AdainResBlk1d(dimIn: 1024 + 2 + 64, dimOut: 1024, styleDim: styleDim),
            AdainResBlk1d(dimIn: 1024 + 2 + 64, dimOut: 1024, styleDim: styleDim),
            AdainResBlk1d(dimIn: 1024 + 2 + 64, dimOut: 512, styleDim: styleDim, upsample: true),
        ]
        _F0Conv.wrappedValue = TorchWeightNormConv1d(
            inputChannels: 1,
            outputChannels: 1,
            kernelSize: 3,
            stride: 2,
            padding: 1
        )
        _NConv.wrappedValue = TorchWeightNormConv1d(
            inputChannels: 1,
            outputChannels: 1,
            kernelSize: 3,
            stride: 2,
            padding: 1
        )
        _asrRes.wrappedValue = SingleConvSequential(inputChannels: dimIn, outputChannels: 64)
        _generator.wrappedValue = Generator(
            styleDim: styleDim,
            resblockKernelSizes: resblockKernelSizes,
            upsampleRates: upsampleRates,
            upsampleInitialChannel: upsampleInitialChannel,
            resblockDilationSizes: resblockDilationSizes,
            upsampleKernelSizes: upsampleKernelSizes,
            genIstftNFFT: genIstftNFFT,
            genIstftHopSize: genIstftHopSize,
            disableComplex: disableComplex
        )
    }

    public func callAsFunction(
        _ asr: MLXArray,
        F0Curve: MLXArray,
        N: MLXArray,
        style: MLXArray
    ) -> MLXArray {
        let f0 = F0Conv(F0Curve.expandedDimensions(axis: -1))
        let noise = NConv(N.expandedDimensions(axis: -1))

        var x = concatenated([asr, f0, noise], axis: -1)
        x = encode(x, style: style)
        let asrResidual = asrRes(asr)

        var includeResidual = true
        for block in decode {
            if includeResidual {
                x = concatenated([x, asrResidual, f0, noise], axis: -1)
            }
            x = block(x, style: style)
            if block.upsampleType != "none" {
                includeResidual = false
            }
        }

        return generator(x, style: style, f0: F0Curve)
    }
}
