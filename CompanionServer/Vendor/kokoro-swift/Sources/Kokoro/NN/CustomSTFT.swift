import Foundation
import MLX
import MLXNN

public final class CustomSTFT: Module {
    public enum PaddingMode {
        case replicate
        case constant

        var mlxMode: PadMode {
            switch self {
            case .replicate: .edge
            case .constant: .constant
            }
        }
    }

    public let filterLength: Int
    public let hopLength: Int
    public let winLength: Int
    public let nFFT: Int
    public let center: Bool
    public let padMode: PaddingMode
    public let freqBins: Int

    let windowValues: [Float]
    let weightForwardRealValues: [Float]
    let weightForwardImagValues: [Float]
    let weightBackwardRealValues: [Float]
    let weightBackwardImagValues: [Float]

    public init(
        filterLength: Int = 800,
        hopLength: Int = 200,
        winLength: Int = 800,
        center: Bool = true,
        padMode: PaddingMode = .replicate
    ) {
        self.filterLength = filterLength
        self.hopLength = hopLength
        self.winLength = winLength
        self.nFFT = filterLength
        self.center = center
        self.padMode = padMode
        self.freqBins = filterLength / 2 + 1

        let windowValues = Self.makeHannWindow(winLength: winLength, nFFT: filterLength)
        self.windowValues = windowValues

        let (forwardReal, forwardImag, backwardReal, backwardImag) = Self.makeKernels(
            window: windowValues,
            nFFT: filterLength,
            freqBins: self.freqBins
        )

        self.weightForwardRealValues = forwardReal
        self.weightForwardImagValues = forwardImag
        self.weightBackwardRealValues = backwardReal
        self.weightBackwardImagValues = backwardImag
    }

    public func transform(_ waveform: MLXArray) -> (magnitude: MLXArray, phase: MLXArray) {
        precondition(waveform.ndim == 2, "CustomSTFT expects waveform [B, T].")

        var x = waveform.expandedDimensions(axis: -1)
        if center {
            let pad = nFFT / 2
            x = padded(x, widths: [0, [pad, pad], 0], mode: padMode.mlxMode)
        }

        let real = conv1d(x, weightForwardReal, stride: hopLength)
        let imag = conv1d(x, weightForwardImag, stride: hopLength)
        let magnitude = sqrt(real * real + imag * imag + 1e-14)
        let phase = atan2(imag, real)
        return (magnitude, phase)
    }

    public func inverse(_ magnitude: MLXArray, _ phase: MLXArray, length: Int? = nil) -> MLXArray {
        precondition(magnitude.ndim == 3 && phase.ndim == 3, "Expected [B, Frames, Freq] inputs.")

        let real = magnitude * cos(phase)
        let imag = magnitude * sin(phase)
        var waveform = convTransposed1d(real, weightBackwardReal, stride: hopLength)
            - convTransposed1d(imag, weightBackwardImag, stride: hopLength)

        if center {
            let pad = nFFT / 2
            let end = max(pad, waveform.dim(1) - pad)
            waveform = waveform[0..., pad..<end, 0...]
        }
        if let length {
            waveform = waveform[0..., 0..<min(length, waveform.dim(1)), 0...]
        }
        return waveform.squeezed(axis: -1)
    }

    public func inverse(_ magnitude: MLXArray, _ phase: MLXArray) -> MLXArray {
        inverse(magnitude, phase, length: nil)
    }

    public func callAsFunction(_ waveform: MLXArray) -> MLXArray {
        let (magnitude, phase) = transform(waveform)
        return inverse(magnitude, phase, length: waveform.dim(1))
    }

    private static func makeHannWindow(winLength: Int, nFFT: Int) -> [Float] {
        var values = (0 ..< winLength).map { index -> Float in
            let value = 0.5 - 0.5 * cos(2.0 * .pi * Double(index) / Double(winLength))
            return Float(value)
        }
        if winLength < nFFT {
            values.append(contentsOf: repeatElement(0.0, count: nFFT - winLength))
        } else if winLength > nFFT {
            values = Array(values.prefix(nFFT))
        }
        return values
    }

    private static func makeKernels(
        window: [Float],
        nFFT: Int,
        freqBins: Int
    ) -> ([Float], [Float], [Float], [Float]) {
        var forwardReal: [Float] = []
        var forwardImag: [Float] = []
        var backwardReal: [Float] = Array(repeating: 0.0, count: nFFT * freqBins)
        var backwardImag: [Float] = Array(repeating: 0.0, count: nFFT * freqBins)
        forwardReal.reserveCapacity(freqBins * nFFT)
        forwardImag.reserveCapacity(freqBins * nFFT)

        let invScale = 1.0 / Double(nFFT)

        for k in 0 ..< freqBins {
            for n in 0 ..< nFFT {
                let angle = 2.0 * Double.pi * Double(k * n) / Double(nFFT)
                let win = Double(window[n])
                forwardReal.append(Float(cos(angle) * win))
                forwardImag.append(Float(-sin(angle) * win))

                let backwardIndex = n * freqBins + k
                backwardReal[backwardIndex] = Float(cos(angle) * win * invScale)
                backwardImag[backwardIndex] = Float(sin(angle) * win * invScale)
            }
        }

        return (forwardReal, forwardImag, backwardReal, backwardImag)
    }

    private var weightForwardReal: MLXArray {
        MLXArray(weightForwardRealValues, [freqBins, filterLength, 1])
    }

    private var weightForwardImag: MLXArray {
        MLXArray(weightForwardImagValues, [freqBins, filterLength, 1])
    }

    private var weightBackwardReal: MLXArray {
        MLXArray(weightBackwardRealValues, [1, filterLength, freqBins])
    }

    private var weightBackwardImag: MLXArray {
        MLXArray(weightBackwardImagValues, [1, filterLength, freqBins])
    }
}

public final class TorchSTFT: Module {
    let impl: CustomSTFT

    public init(filterLength: Int = 800, hopLength: Int = 200, winLength: Int = 800) {
        self.impl = CustomSTFT(
            filterLength: filterLength,
            hopLength: hopLength,
            winLength: winLength,
            center: true,
            padMode: .replicate
        )
    }

    public func transform(_ inputData: MLXArray) -> (magnitude: MLXArray, phase: MLXArray) {
        impl.transform(inputData)
    }

    public func inverse(_ magnitude: MLXArray, _ phase: MLXArray) -> MLXArray {
        impl.inverse(magnitude, phase)
    }

    public func callAsFunction(_ inputData: MLXArray) -> MLXArray {
        impl(inputData)
    }
}
