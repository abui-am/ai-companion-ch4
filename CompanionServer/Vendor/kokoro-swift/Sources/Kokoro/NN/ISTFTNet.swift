import Foundation
import MLX
import MLXNN

protocol STFTLike {
    func transform(_ input: MLXArray) -> (magnitude: MLXArray, phase: MLXArray)
    func inverse(_ magnitude: MLXArray, _ phase: MLXArray) -> MLXArray
}

extension CustomSTFT: STFTLike {}
extension TorchSTFT: STFTLike {}

public final class AdaIN1d: Module {
    @ModuleInfo(key: "norm") var norm: InstanceNorm
    @ModuleInfo(key: "fc") var fc: Linear

    public init(styleDim: Int, features: Int) {
        _norm.wrappedValue = InstanceNorm(dimensions: features, affine: false)
        _fc.wrappedValue = Linear(styleDim, features * 2, bias: true)
    }

    public func callAsFunction(_ x: MLXArray, style: MLXArray) -> MLXArray {
        let h = fc(style)
        let parts = split(h, parts: 2, axis: -1)
        let gamma = parts[0].expandedDimensions(axis: 1)
        let beta = parts[1].expandedDimensions(axis: 1)
        return (1 + gamma) * norm(x) + beta
    }
}

public final class AdaINResBlock1: Module {
    let convs1: [TorchWeightNormConv1d]
    let convs2: [TorchWeightNormConv1d]
    let adain1: [AdaIN1d]
    let adain2: [AdaIN1d]
    public var alpha1: [MLXArray]
    public var alpha2: [MLXArray]

    public init(
        channels: Int,
        kernelSize: Int = 3,
        dilation: [Int] = [1, 3, 5],
        styleDim: Int = 64
    ) {
        self.convs1 = dilation.map { value in
            TorchWeightNormConv1d(
                inputChannels: channels,
                outputChannels: channels,
                kernelSize: kernelSize,
                padding: Int((kernelSize * value - value) / 2),
                dilation: value
            )
        }
        self.convs2 = (0 ..< dilation.count).map { _ in
            TorchWeightNormConv1d(
                inputChannels: channels,
                outputChannels: channels,
                kernelSize: kernelSize,
                padding: Int((kernelSize - 1) / 2)
            )
        }
        self.adain1 = (0 ..< dilation.count).map { _ in AdaIN1d(styleDim: styleDim, features: channels) }
        self.adain2 = (0 ..< dilation.count).map { _ in AdaIN1d(styleDim: styleDim, features: channels) }
        self.alpha1 = (0 ..< dilation.count).map { _ in MLXArray.ones([1, channels, 1]) }
        self.alpha2 = (0 ..< dilation.count).map { _ in MLXArray.ones([1, channels, 1]) }
    }

    public func callAsFunction(_ x: MLXArray, style: MLXArray) -> MLXArray {
        var output = x
        for index in convs1.indices {
            let a1 = alpha1[index].transposed(0, 2, 1)
            let a2 = alpha2[index].transposed(0, 2, 1)

            var xt = adain1[index](output, style: style)
            xt = xt + (sin(a1 * xt) * sin(a1 * xt)) / a1
            xt = convs1[index](xt)
            xt = adain2[index](xt, style: style)
            xt = xt + (sin(a2 * xt) * sin(a2 * xt)) / a2
            xt = convs2[index](xt)
            output = output + xt
        }
        return output
    }
}

public final class SineGen: Module {
    let samplingRate: Int
    let upsampleScale: Int
    let harmonicNum: Int
    let sineAmp: Float
    let noiseStd: Float
    let voicedThreshold: Float
    let flagForPulse: Bool

    public init(
        samplingRate: Int,
        upsampleScale: Int,
        harmonicNum: Int = 0,
        sineAmp: Float = 0.1,
        noiseStd: Float = 0.003,
        voicedThreshold: Float = 0,
        flagForPulse: Bool = false
    ) {
        self.samplingRate = samplingRate
        self.upsampleScale = upsampleScale
        self.harmonicNum = harmonicNum
        self.sineAmp = sineAmp
        self.noiseStd = noiseStd
        self.voicedThreshold = voicedThreshold
        self.flagForPulse = flagForPulse
    }

    public func callAsFunction(_ f0: MLXArray) -> (MLXArray, MLXArray, MLXArray) {
        precondition(!flagForPulse, "Pulse mode is not used by Kokoro inference.")
        precondition(f0.ndim == 3, "SineGen expects [B, T, 1] input.")

        let batch = f0.dim(0)
        let length = f0.dim(1)
        let dim = harmonicNum + 1
        let values = f0.asArray(Float.self)

        func offset(_ b: Int, _ t: Int, _ d: Int, _ channels: Int = dim) -> Int {
            ((b * length) + t) * channels + d
        }

        var harmonics = [Float](repeating: 0, count: batch * length * dim)
        var uv = [Float](repeating: 0, count: batch * length)

        for b in 0 ..< batch {
            for t in 0 ..< length {
                let base = values[(b * length) + t]
                let voiced: Float = base > voicedThreshold ? 1 : 0
                uv[(b * length) + t] = voiced
                for h in 0 ..< dim {
                    harmonics[offset(b, t, h)] = base * Float(h + 1)
                }
            }
        }

        var radValues = harmonics.map { value in
            let ratio = value / Float(samplingRate)
            return ratio - floor(ratio)
        }

        for b in 0 ..< batch {
            for h in 0 ..< dim {
                if h == 0 { continue }
                radValues[offset(b, 0, h)] += Float.random(in: 0 ..< 1)
            }
        }

        let frameLength = max(1, length / max(1, upsampleScale))
        var sineWaves = [Float](repeating: 0, count: batch * length * dim)
        for b in 0 ..< batch {
            for h in 0 ..< dim {
                var series = [Float](repeating: 0, count: length)
                for t in 0 ..< length {
                    series[t] = radValues[offset(b, t, h)]
                }
                let coarse = Self.interpolate1D(series, outputCount: frameLength)
                var phase = [Float](repeating: 0, count: frameLength)
                var running: Float = 0
                for index in coarse.indices {
                    running += coarse[index]
                    phase[index] = running * 2 * .pi
                }
                let upsampledPhase = Self.interpolate1D(
                    phase.map { $0 * Float(upsampleScale) },
                    outputCount: length
                )
                for t in 0 ..< length {
                    sineWaves[offset(b, t, h)] = sin(upsampledPhase[t]) * sineAmp
                }
            }
        }

        var noise = [Float](repeating: 0, count: batch * length * dim)
        var noiseAmp = [Float](repeating: 0, count: batch * length)
        for index in noiseAmp.indices {
            let voiced = uv[index]
            noiseAmp[index] = voiced * noiseStd + (1 - voiced) * (sineAmp / 3)
        }

        for b in 0 ..< batch {
            for t in 0 ..< length {
                let voiced = uv[(b * length) + t]
                let amplitude = noiseAmp[(b * length) + t]
                for h in 0 ..< dim {
                    let gaussian = Self.gaussian()
                    noise[offset(b, t, h)] = amplitude * gaussian
                    sineWaves[offset(b, t, h)] = sineWaves[offset(b, t, h)] * voiced + noise[offset(b, t, h)]
                }
            }
        }

        return (
            MLXArray(sineWaves, [batch, length, dim]),
            MLXArray(uv, [batch, length, 1]),
            MLXArray(noise, [batch, length, dim])
        )
    }

    private static func interpolate1D(_ values: [Float], outputCount: Int) -> [Float] {
        precondition(!values.isEmpty)
        guard outputCount != values.count else { return values }
        guard outputCount > 1 else { return [values[0]] }

        let inputCount = values.count
        let scale = Float(inputCount) / Float(outputCount)
        var output = [Float](repeating: 0, count: outputCount)

        for index in 0 ..< outputCount {
            let source = (Float(index) + 0.5) * scale - 0.5
            let left = max(0, Int(floor(source)))
            let right = min(inputCount - 1, left + 1)
            let weight = source - Float(left)
            output[index] = values[left] * (1 - weight) + values[right] * weight
        }
        return output
    }

    fileprivate static func gaussian() -> Float {
        let u1 = max(Float.leastNonzeroMagnitude, Float.random(in: 0 ..< 1))
        let u2 = Float.random(in: 0 ..< 1)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

public final class SourceModuleHnNSF: Module {
    let l_sin_gen: SineGen
    @ModuleInfo(key: "l_linear") var l_linear: Linear

    public let sineAmp: Float

    public init(
        samplingRate: Int,
        upsampleScale: Int,
        harmonicNum: Int = 0,
        sineAmp: Float = 0.1,
        addNoiseStd: Float = 0.003,
        voicedThreshold: Float = 0
    ) {
        self.sineAmp = sineAmp
        self.l_sin_gen = SineGen(
            samplingRate: samplingRate,
            upsampleScale: upsampleScale,
            harmonicNum: harmonicNum,
            sineAmp: sineAmp,
            noiseStd: addNoiseStd,
            voicedThreshold: voicedThreshold
        )
        _l_linear.wrappedValue = Linear(harmonicNum + 1, 1, bias: true)
    }

    public func callAsFunction(_ x: MLXArray) -> (MLXArray, MLXArray, MLXArray) {
        let (sineWaves, uv, _) = l_sin_gen(x)
        let sineMerge = tanh(l_linear(sineWaves))

        let count = uv.dim(0) * uv.dim(1)
        let noise = MLXArray(
            (0 ..< count).map { _ in SineGen.gaussian() * (sineAmp / 3) },
            [uv.dim(0), uv.dim(1), 1]
        )
        return (sineMerge, noise, uv)
    }
}

public final class Generator: Module {
    let numKernels: Int
    let numUpsamples: Int

    let m_source: SourceModuleHnNSF
    let f0_upsamp: Upsample
    let noise_convs: [TorchConv1d]
    let noise_res: [AdaINResBlock1]
    let ups: [TorchWeightNormConvTranspose1d]
    let resblocks: [AdaINResBlock1]
    @ModuleInfo(key: "conv_post") var conv_post: TorchWeightNormConv1d

    let post_n_fft: Int
    let stft: any STFTLike

    public init(
        styleDim: Int,
        resblockKernelSizes: [Int],
        upsampleRates: [Int],
        upsampleInitialChannel: Int,
        resblockDilationSizes: [[Int]],
        upsampleKernelSizes: [Int],
        genIstftNFFT: Int,
        genIstftHopSize: Int,
        disableComplex: Bool = false
    ) {
        self.numKernels = resblockKernelSizes.count
        self.numUpsamples = upsampleRates.count
        self.m_source = SourceModuleHnNSF(
            samplingRate: 24_000,
            upsampleScale: upsampleRates.reduce(1, *) * genIstftHopSize,
            harmonicNum: 8,
            voicedThreshold: 10
        )
        self.f0_upsamp = Upsample(
            scaleFactor: FloatOrArray(Float(upsampleRates.reduce(1, *) * genIstftHopSize)),
            mode: .nearest
        )

        var builtUps: [TorchWeightNormConvTranspose1d] = []
        for (index, (rate, kernel)) in zip(upsampleRates, upsampleKernelSizes).enumerated() {
            builtUps.append(
                TorchWeightNormConvTranspose1d(
                    inputChannels: upsampleInitialChannel / (1 << index),
                    outputChannels: upsampleInitialChannel / (1 << (index + 1)),
                    kernelSize: kernel,
                    stride: rate,
                    padding: (kernel - rate) / 2
                )
            )
        }
        self.ups = builtUps

        var builtResblocks: [AdaINResBlock1] = []
        var builtNoiseConvs: [TorchConv1d] = []
        var builtNoiseRes: [AdaINResBlock1] = []
        for i in 0 ..< upsampleRates.count {
            let channels = upsampleInitialChannel / (1 << (i + 1))
            for (kernel, dilations) in zip(resblockKernelSizes, resblockDilationSizes) {
                builtResblocks.append(
                    AdaINResBlock1(
                        channels: channels,
                        kernelSize: kernel,
                        dilation: dilations,
                        styleDim: styleDim
                    )
                )
            }

            if i + 1 < upsampleRates.count {
                let stride = upsampleRates[(i + 1)...].reduce(1, *)
                builtNoiseConvs.append(
                    TorchConv1d(
                        inputChannels: genIstftNFFT + 2,
                        outputChannels: channels,
                        kernelSize: stride * 2,
                        stride: stride,
                        padding: (stride + 1) / 2
                    )
                )
                builtNoiseRes.append(
                    AdaINResBlock1(channels: channels, kernelSize: 7, dilation: [1, 3, 5], styleDim: styleDim)
                )
            } else {
                builtNoiseConvs.append(
                    TorchConv1d(
                        inputChannels: genIstftNFFT + 2,
                        outputChannels: channels,
                        kernelSize: 1
                    )
                )
                builtNoiseRes.append(
                    AdaINResBlock1(channels: channels, kernelSize: 11, dilation: [1, 3, 5], styleDim: styleDim)
                )
            }
        }
        self.noise_convs = builtNoiseConvs
        self.noise_res = builtNoiseRes
        self.resblocks = builtResblocks
        self.post_n_fft = genIstftNFFT
        _conv_post.wrappedValue = TorchWeightNormConv1d(
            inputChannels: upsampleInitialChannel / (1 << upsampleRates.count),
            outputChannels: genIstftNFFT + 2,
            kernelSize: 7,
            padding: 3
        )

        if disableComplex {
            self.stft = CustomSTFT(
                filterLength: genIstftNFFT,
                hopLength: genIstftHopSize,
                winLength: genIstftNFFT
            )
        } else {
            self.stft = TorchSTFT(
                filterLength: genIstftNFFT,
                hopLength: genIstftHopSize,
                winLength: genIstftNFFT
            )
        }
    }

    public func callAsFunction(_ x: MLXArray, style: MLXArray, f0: MLXArray) -> MLXArray {
        let upsampledF0 = f0_upsamp(f0.expandedDimensions(axis: -1))
        let (harSource, _, _) = m_source(upsampledF0)
        let (harSpec, harPhase) = stft.transform(harSource.squeezed(axis: -1))
        let har = concatenated([harSpec, harPhase], axis: -1)

        var output = x
        for i in 0 ..< numUpsamples {
            output = leakyRelu01(output)
            let source = noise_res[i](noise_convs[i](har), style: style)
            output = ups[i](output)
            if i == numUpsamples - 1 {
                output = reflectionPadLeft(output, count: 1)
            }
            output = output + source

            var merged: MLXArray?
            for j in 0 ..< numKernels {
                let block = resblocks[i * numKernels + j](output, style: style)
                if merged == nil {
                    merged = block
                } else {
                    merged = merged! + block
                }
            }
            output = merged! / Float(numKernels)
        }

        output = leakyRelu(output)
        output = conv_post(output)
        let specBins = post_n_fft / 2 + 1
        let spec = exp(output[0..., 0..., 0..<specBins])
        let phase = sin(output[0..., 0..., specBins..<(specBins * 2)])
        return stft.inverse(spec, phase)
    }
}
