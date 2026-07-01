import Foundation
import MLX
import MLXFast
import MLXNN

func geluNew(_ x: MLXArray) -> MLXArray {
    let coeff = Float(sqrt(2.0 / .pi))
    return 0.5 * x * (1.0 + tanh(coeff * (x + 0.044715 * (x * x * x))))
}

func repeatStyle(_ style: MLXArray, length: Int) -> MLXArray {
    precondition(style.ndim == 2, "Style input must be [B, styleDim].")
    return broadcast(style.expandedDimensions(axis: 1), to: [style.dim(0), length, style.dim(1)])
}

func reverseAlongTime(_ x: MLXArray) -> MLXArray {
    let count = x.dim(1)
    let indices = MLXArray(Array((0 ..< count).reversed()))
    return take(x, indices, axis: 1)
}

func leakyRelu01(_ x: MLXArray) -> MLXArray {
    leakyRelu(x, negativeSlope: 0.1)
}

func reflectionPadLeft(_ x: MLXArray, count: Int) -> MLXArray {
    precondition(x.ndim == 3, "Expected [B, T, C] tensor for reflectionPadLeft.")
    guard count > 0 else { return x }
    precondition(x.dim(1) > count, "Reflection padding requires time dimension > padding count.")
    let indices = MLXArray(Array((1 ... count).reversed()))
    let reflected = take(x, indices, axis: 1)
    return concatenated([reflected, x], axis: 1)
}

public final class TorchConv1d: Module, UnaryLayer {
    @ParameterInfo(key: "weight") public var weight: MLXArray
    @ParameterInfo(key: "bias") public var bias: MLXArray?

    public let stride: Int
    public let padding: Int
    public let dilation: Int
    public let groups: Int

    public init(
        inputChannels: Int,
        outputChannels: Int,
        kernelSize: Int,
        stride: Int = 1,
        padding: Int = 0,
        dilation: Int = 1,
        groups: Int = 1,
        bias: Bool = true
    ) {
        self.stride = stride
        self.padding = padding
        self.dilation = dilation
        self.groups = groups
        self._weight.wrappedValue = MLXArray.zeros([outputChannels, inputChannels / groups, kernelSize])
        self._bias.wrappedValue = bias ? MLXArray.zeros([outputChannels]) : nil
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var y = conv1d(
            x,
            weight.transposed(0, 2, 1),
            stride: stride,
            padding: padding,
            dilation: dilation,
            groups: groups
        )
        if let bias {
            y = y + bias
        }
        return y
    }
}

public final class TorchWeightNormConv1d: Module, UnaryLayer {
    @ParameterInfo(key: "weight_g") public var weightG: MLXArray
    @ParameterInfo(key: "weight_v") public var weightV: MLXArray
    @ParameterInfo(key: "bias") public var bias: MLXArray?

    public let stride: Int
    public let padding: Int
    public let dilation: Int
    public let groups: Int

    public init(
        inputChannels: Int,
        outputChannels: Int,
        kernelSize: Int,
        stride: Int = 1,
        padding: Int = 0,
        dilation: Int = 1,
        groups: Int = 1,
        bias: Bool = true
    ) {
        self.stride = stride
        self.padding = padding
        self.dilation = dilation
        self.groups = groups
        self._weightG.wrappedValue = MLXArray.ones([outputChannels, 1, 1])
        self._weightV.wrappedValue = MLXArray.zeros([outputChannels, inputChannels / groups, kernelSize])
        self._bias.wrappedValue = bias ? MLXArray.zeros([outputChannels]) : nil
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        let denom = rsqrt(sum(weightV * weightV, axes: [1, 2], keepDims: true) + 1e-12)
        let normalized = weightG * weightV * denom
        var y = conv1d(
            x,
            normalized.transposed(0, 2, 1),
            stride: stride,
            padding: padding,
            dilation: dilation,
            groups: groups
        )
        if let bias {
            y = y + bias
        }
        return y
    }
}

public final class TorchConvTranspose1d: Module, UnaryLayer {
    @ParameterInfo(key: "weight") public var weight: MLXArray
    @ParameterInfo(key: "bias") public var bias: MLXArray?

    public let stride: Int
    public let padding: Int
    public let outputPadding: Int
    public let dilation: Int
    public let groups: Int

    public init(
        inputChannels: Int,
        outputChannels: Int,
        kernelSize: Int,
        stride: Int = 1,
        padding: Int = 0,
        outputPadding: Int = 0,
        dilation: Int = 1,
        groups: Int = 1,
        bias: Bool = true
    ) {
        self.stride = stride
        self.padding = padding
        self.outputPadding = outputPadding
        self.dilation = dilation
        self.groups = groups
        self._weight.wrappedValue = MLXArray.zeros([inputChannels, outputChannels / groups, kernelSize])
        self._bias.wrappedValue = bias ? MLXArray.zeros([outputChannels]) : nil
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var y = convTransposed1d(
            x,
            weight.transposed(1, 2, 0),
            stride: stride,
            padding: padding,
            dilation: dilation,
            outputPadding: outputPadding,
            groups: groups
        )
        if let bias {
            y = y + bias
        }
        return y
    }
}

public final class TorchWeightNormConvTranspose1d: Module, UnaryLayer {
    @ParameterInfo(key: "weight_g") public var weightG: MLXArray
    @ParameterInfo(key: "weight_v") public var weightV: MLXArray
    @ParameterInfo(key: "bias") public var bias: MLXArray?

    public let stride: Int
    public let padding: Int
    public let outputPadding: Int
    public let dilation: Int
    public let groups: Int

    public init(
        inputChannels: Int,
        outputChannels: Int,
        kernelSize: Int,
        stride: Int = 1,
        padding: Int = 0,
        outputPadding: Int = 0,
        dilation: Int = 1,
        groups: Int = 1,
        bias: Bool = true
    ) {
        self.stride = stride
        self.padding = padding
        self.outputPadding = outputPadding
        self.dilation = dilation
        self.groups = groups
        self._weightG.wrappedValue = MLXArray.ones([inputChannels, 1, 1])
        self._weightV.wrappedValue = MLXArray.zeros([inputChannels, outputChannels / groups, kernelSize])
        self._bias.wrappedValue = bias ? MLXArray.zeros([outputChannels]) : nil
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        let denom = rsqrt(sum(weightV * weightV, axes: [1, 2], keepDims: true) + 1e-12)
        let normalized = weightG * weightV * denom

        if groups == x.dim(-1), normalized.dim(1) == 1 {
            return depthwiseConvTransposed1d(x, weight: normalized, bias: bias)
        }

        var y = convTransposed1d(
            x,
            normalized.transposed(1, 2, 0),
            stride: stride,
            padding: padding,
            dilation: dilation,
            outputPadding: outputPadding,
            groups: groups
        )
        if let bias {
            y = y + bias
        }
        return y
    }

    private func depthwiseConvTransposed1d(
        _ x: MLXArray,
        weight: MLXArray,
        bias: MLXArray?
    ) -> MLXArray {
        let input = x.asArray(Float.self)
        let kernel = weight.asArray(Float.self)
        let biasValues = bias?.asArray(Float.self)

        let batch = x.dim(0)
        let inputLength = x.dim(1)
        let channels = x.dim(2)
        let kernelSize = weight.dim(2)
        let outputLength = (inputLength - 1) * stride - (2 * padding)
            + dilation * (kernelSize - 1) + outputPadding + 1

        func xIndex(_ b: Int, _ t: Int, _ c: Int) -> Int {
            ((b * inputLength) + t) * channels + c
        }

        func yIndex(_ b: Int, _ t: Int, _ c: Int) -> Int {
            ((b * outputLength) + t) * channels + c
        }

        func wIndex(_ c: Int, _ k: Int) -> Int {
            c * kernelSize + k
        }

        var output = [Float](repeating: 0, count: batch * outputLength * channels)

        for b in 0 ..< batch {
            for t in 0 ..< inputLength {
                for c in 0 ..< channels {
                    let value = input[xIndex(b, t, c)]
                    for k in 0 ..< kernelSize {
                        let outT = t * stride - padding + k * dilation
                        guard outT >= 0, outT < outputLength else { continue }
                        output[yIndex(b, outT, c)] += value * kernel[wIndex(c, k)]
                    }
                }
            }
        }

        if let biasValues {
            for b in 0 ..< batch {
                for t in 0 ..< outputLength {
                    for c in 0 ..< channels {
                        output[yIndex(b, t, c)] += biasValues[c]
                    }
                }
            }
        }

        return MLXArray(output, [batch, outputLength, channels])
    }
}

public final class TorchBiLSTM: Module {
    @ParameterInfo(key: "weight_ih_l0") public var weightIHL0: MLXArray
    @ParameterInfo(key: "weight_hh_l0") public var weightHHL0: MLXArray
    @ParameterInfo(key: "bias_ih_l0") public var biasIHL0: MLXArray
    @ParameterInfo(key: "bias_hh_l0") public var biasHHL0: MLXArray
    @ParameterInfo(key: "weight_ih_l0_reverse") public var weightIHL0Reverse: MLXArray
    @ParameterInfo(key: "weight_hh_l0_reverse") public var weightHHL0Reverse: MLXArray
    @ParameterInfo(key: "bias_ih_l0_reverse") public var biasIHL0Reverse: MLXArray
    @ParameterInfo(key: "bias_hh_l0_reverse") public var biasHHL0Reverse: MLXArray

    public let inputSize: Int
    public let hiddenSize: Int

    public init(inputSize: Int, hiddenSize: Int) {
        self.inputSize = inputSize
        self.hiddenSize = hiddenSize
        self._weightIHL0.wrappedValue = MLXArray.zeros([4 * hiddenSize, inputSize])
        self._weightHHL0.wrappedValue = MLXArray.zeros([4 * hiddenSize, hiddenSize])
        self._biasIHL0.wrappedValue = MLXArray.zeros([4 * hiddenSize])
        self._biasHHL0.wrappedValue = MLXArray.zeros([4 * hiddenSize])
        self._weightIHL0Reverse.wrappedValue = MLXArray.zeros([4 * hiddenSize, inputSize])
        self._weightHHL0Reverse.wrappedValue = MLXArray.zeros([4 * hiddenSize, hiddenSize])
        self._biasIHL0Reverse.wrappedValue = MLXArray.zeros([4 * hiddenSize])
        self._biasHHL0Reverse.wrappedValue = MLXArray.zeros([4 * hiddenSize])
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        let forward = runDirection(
            x,
            weightIH: weightIHL0,
            weightHH: weightHHL0,
            biasIH: biasIHL0,
            biasHH: biasHHL0
        )
        let reversedInput = reverseAlongTime(x)
        let backwardReversed = runDirection(
            reversedInput,
            weightIH: weightIHL0Reverse,
            weightHH: weightHHL0Reverse,
            biasIH: biasIHL0Reverse,
            biasHH: biasHHL0Reverse
        )
        let backward = reverseAlongTime(backwardReversed)
        return concatenated([forward, backward], axis: -1)
    }

    private func runDirection(
        _ x: MLXArray,
        weightIH: MLXArray,
        weightHH: MLXArray,
        biasIH: MLXArray,
        biasHH: MLXArray
    ) -> MLXArray {
        precondition(x.ndim == 3, "TorchBiLSTM expects [B, T, C] input.")
        let batch = x.dim(0)
        let steps = x.dim(1)
        var hidden = MLXArray.zeros([batch, hiddenSize], dtype: x.dtype)
        var cell = MLXArray.zeros([batch, hiddenSize], dtype: x.dtype)
        var outputs: [MLXArray] = []
        outputs.reserveCapacity(steps)

        for step in 0 ..< steps {
            let xt = x[0..., step, 0...]
            let gates = matmul(xt, weightIH.T) + matmul(hidden, weightHH.T) + biasIH + biasHH
            let parts = split(gates, parts: 4, axis: -1)
            let inputGate = sigmoid(parts[0])
            let forgetGate = sigmoid(parts[1])
            let candidate = tanh(parts[2])
            let outputGate = sigmoid(parts[3])

            cell = forgetGate * cell + inputGate * candidate
            hidden = outputGate * tanh(cell)
            outputs.append(hidden)
        }

        return stacked(outputs, axis: 1)
    }
}
