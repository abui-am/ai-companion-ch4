import Accelerate
import CoreML
import Foundation

public final class SegmentedCoreMLModel {
    private enum FeatureName {
        static let inputIDs = "input_ids"
        static let attentionMask = "attention_mask"
        static let bertOutput = "bert_output"
        static let inputLengths = "input_lengths"
        static let style = "style"
        static let speed = "speed"
        static let predDur = "pred_dur"
        static let f0Pred = "f0_pred"
        static let nPred = "n_pred"
        static let tEn = "t_en"
        static let asr = "asr"
        static let f0Curve = "f0_curve"
        static let n = "n"
        static let acousticStyle = "acoustic_style"
        static let audio = "audio"
    }

    private static let samplesPerFrame = 600

    public let albertModel: MLModel
    public let prosodyModel: MLModel
    public let textEncoderModel: MLModel
    public let decoderModel: MLModel
    public let vocab: [String: Int]
    public let config: KokoroConfig
    public let maxPhonemeCount: Int

    private let compiledModelURLs: [URL]
    private let albertTokenCapacity: Int
    private let prosodyTokenCapacity: Int
    private let textTokenCapacity: Int
    private let bertHiddenSize: Int
    private let channelCount: Int
    private let frameCapacity: Int
    private let curveCapacity: Int
    private let audioCapacity: Int

    private let albertInputDataType: MLMultiArrayDataType
    private let attentionMaskDataType: MLMultiArrayDataType
    private let prosodyBertInputDataType: MLMultiArrayDataType
    private let prosodyInputLengthsDataType: MLMultiArrayDataType
    private let prosodyStyleInputDataType: MLMultiArrayDataType
    private let speedInputDataType: MLMultiArrayDataType
    private let textEncoderInputDataType: MLMultiArrayDataType
    private let textEncoderInputLengthsDataType: MLMultiArrayDataType
    private let decoderAsrInputDataType: MLMultiArrayDataType
    private let decoderCurveInputDataType: MLMultiArrayDataType
    private let decoderStyleInputDataType: MLMultiArrayDataType

    public init(
        segmentedDir: URL,
        configURL: URL
    ) throws {
        let data = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(KokoroConfig.self, from: data)
        self.config = config
        self.vocab = config.vocab

        let aneConfiguration = MLModelConfiguration()
        aneConfiguration.computeUnits = .all

        let cpuConfiguration = MLModelConfiguration()
        cpuConfiguration.computeUnits = .cpuOnly

        let albertURL = segmentedDir.appendingPathComponent("albert.mlpackage", isDirectory: false)
        let prosodyURL = segmentedDir.appendingPathComponent("prosody.mlpackage", isDirectory: false)
        let textEncoderURL = segmentedDir.appendingPathComponent("text_encoder.mlpackage", isDirectory: false)
        let decoderURL = segmentedDir.appendingPathComponent("decoder.mlpackage", isDirectory: false)

        let (albertCompiledURL, albertModel) = try Self.loadModel(at: albertURL, configuration: aneConfiguration)
        let (prosodyCompiledURL, prosodyModel) = try Self.loadModel(at: prosodyURL, configuration: cpuConfiguration)
        let (textEncoderCompiledURL, textEncoderModel) = try Self.loadModel(at: textEncoderURL, configuration: cpuConfiguration)
        let (decoderCompiledURL, decoderModel) = try Self.loadModel(at: decoderURL, configuration: aneConfiguration)

        self.compiledModelURLs = [albertCompiledURL, prosodyCompiledURL, textEncoderCompiledURL, decoderCompiledURL]
        self.albertModel = albertModel
        self.prosodyModel = prosodyModel
        self.textEncoderModel = textEncoderModel
        self.decoderModel = decoderModel

        let albertInputShape = try Self.shape(for: FeatureName.inputIDs, in: albertModel.modelDescription.inputDescriptionsByName)
        let attentionMaskShape = try Self.shape(for: FeatureName.attentionMask, in: albertModel.modelDescription.inputDescriptionsByName)
        let albertOutputShape = try Self.shape(for: FeatureName.bertOutput, in: albertModel.modelDescription.outputDescriptionsByName)
        let prosodyInputShape = try Self.shape(for: FeatureName.bertOutput, in: prosodyModel.modelDescription.inputDescriptionsByName)
        let prosodyPredDurShape = try Self.shape(for: FeatureName.predDur, in: prosodyModel.modelDescription.outputDescriptionsByName)
        let prosodyF0Shape = try Self.shape(for: FeatureName.f0Pred, in: prosodyModel.modelDescription.outputDescriptionsByName)
        let prosodyNoiseShape = try Self.shape(for: FeatureName.nPred, in: prosodyModel.modelDescription.outputDescriptionsByName)
        let textEncoderInputShape = try Self.shape(for: FeatureName.inputIDs, in: textEncoderModel.modelDescription.inputDescriptionsByName)
        let textEncoderInputLengthsShape = try Self.shape(for: FeatureName.inputLengths, in: textEncoderModel.modelDescription.inputDescriptionsByName)
        let textEncoderOutputShape = try Self.shape(for: FeatureName.tEn, in: textEncoderModel.modelDescription.outputDescriptionsByName)
        let decoderAsrShape = try Self.shape(for: FeatureName.asr, in: decoderModel.modelDescription.inputDescriptionsByName)
        let decoderF0Shape = try Self.shape(for: FeatureName.f0Curve, in: decoderModel.modelDescription.inputDescriptionsByName)
        let decoderNoiseShape = try Self.shape(for: FeatureName.n, in: decoderModel.modelDescription.inputDescriptionsByName)
        let decoderAudioShape = try Self.shape(for: FeatureName.audio, in: decoderModel.modelDescription.outputDescriptionsByName)

        guard albertInputShape.count == 2,
              attentionMaskShape == albertInputShape,
              albertOutputShape.count == 3,
              albertOutputShape[0] == 1,
              albertOutputShape[1] == albertInputShape[1],
              prosodyInputShape.count == 3,
              prosodyInputShape[0] == 1,
              prosodyInputShape[2] == albertOutputShape[2],
              prosodyPredDurShape == [1, prosodyInputShape[1]],
              prosodyF0Shape.count == 2,
              prosodyNoiseShape == prosodyF0Shape,
              textEncoderInputShape.count == 2,
              textEncoderInputLengthsShape == [1],
              textEncoderOutputShape.count == 3,
              textEncoderOutputShape[0] == 1,
              textEncoderOutputShape[1] == config.hiddenDim,
              textEncoderOutputShape[2] == textEncoderInputShape[1],
              decoderAsrShape.count == 3,
              decoderAsrShape[0] == 1,
              decoderAsrShape[1] == config.hiddenDim,
              decoderF0Shape.count == 2,
              decoderNoiseShape == decoderF0Shape,
              decoderAudioShape.count == 3,
              decoderAudioShape[0] == 1,
              decoderAudioShape[1] == 1
        else {
            throw KokoroError.invalidSegmentedCoreMLContract("Segment model shapes do not match Kokoro's expected contracts.")
        }

        let effectiveTokenCapacity = min(albertInputShape[1], prosodyInputShape[1], textEncoderInputShape[1])
        guard effectiveTokenCapacity > 2 else {
            throw KokoroError.invalidSegmentedCoreMLContract("Segment token capacity \(effectiveTokenCapacity) is too small for BOS/EOS tokenization.")
        }

        let derivedFrameCapacity = decoderAsrShape[2]
        guard prosodyF0Shape[1] >= derivedFrameCapacity,
              decoderF0Shape[1] == prosodyF0Shape[1],
              decoderAudioShape[2] >= derivedFrameCapacity * Self.samplesPerFrame
        else {
            throw KokoroError.invalidSegmentedCoreMLContract("Prosody/decoder frame capacities are inconsistent.")
        }

        self.albertTokenCapacity = albertInputShape[1]
        self.prosodyTokenCapacity = prosodyInputShape[1]
        self.textTokenCapacity = textEncoderInputShape[1]
        self.bertHiddenSize = albertOutputShape[2]
        self.channelCount = textEncoderOutputShape[1]
        self.frameCapacity = derivedFrameCapacity
        self.curveCapacity = decoderF0Shape[1]
        self.audioCapacity = decoderAudioShape[2]
        self.maxPhonemeCount = effectiveTokenCapacity - 2

        self.albertInputDataType = try Self.dataType(for: FeatureName.inputIDs, in: albertModel.modelDescription.inputDescriptionsByName)
        self.attentionMaskDataType = try Self.dataType(for: FeatureName.attentionMask, in: albertModel.modelDescription.inputDescriptionsByName)
        self.prosodyBertInputDataType = try Self.dataType(for: FeatureName.bertOutput, in: prosodyModel.modelDescription.inputDescriptionsByName)
        self.prosodyInputLengthsDataType = try Self.dataType(for: FeatureName.inputLengths, in: prosodyModel.modelDescription.inputDescriptionsByName)
        self.prosodyStyleInputDataType = try Self.dataType(for: FeatureName.style, in: prosodyModel.modelDescription.inputDescriptionsByName)
        self.speedInputDataType = try Self.dataType(for: FeatureName.speed, in: prosodyModel.modelDescription.inputDescriptionsByName)
        self.textEncoderInputDataType = try Self.dataType(for: FeatureName.inputIDs, in: textEncoderModel.modelDescription.inputDescriptionsByName)
        self.textEncoderInputLengthsDataType = try Self.dataType(for: FeatureName.inputLengths, in: textEncoderModel.modelDescription.inputDescriptionsByName)
        self.decoderAsrInputDataType = try Self.dataType(for: FeatureName.asr, in: decoderModel.modelDescription.inputDescriptionsByName)
        self.decoderCurveInputDataType = try Self.dataType(for: FeatureName.f0Curve, in: decoderModel.modelDescription.inputDescriptionsByName)
        self.decoderStyleInputDataType = try Self.dataType(for: FeatureName.acousticStyle, in: decoderModel.modelDescription.inputDescriptionsByName)

        let prosodyStyleShape = try Self.shape(for: FeatureName.style, in: prosodyModel.modelDescription.inputDescriptionsByName)
        let decoderStyleShape = try Self.shape(for: FeatureName.acousticStyle, in: decoderModel.modelDescription.inputDescriptionsByName)
        guard prosodyStyleShape == [1, config.styleDim],
              decoderStyleShape == [1, config.styleDim]
        else {
            throw KokoroError.invalidSegmentedCoreMLContract("Segment style dimensions do not match Kokoro config style_dim=\(config.styleDim).")
        }
    }

    public func forward(
        phonemes: String,
        refS: MLMultiArray,
        speed: Float = 1.0
    ) throws -> KModel.Output {
        try Self.validate(speed: speed)

        let tokenIDs = try tokenize(phonemes)
        let actualTokenCount = tokenIDs.count

        let styleValues = try Self.floatValues(from: refS)
        let expectedStyleCount = config.styleDim * 2
        guard styleValues.count == expectedStyleCount else {
            throw KokoroError.expectedStyleVector(refS.shape.map(\.intValue))
        }

        let acousticStyleValues = Array(styleValues[..<config.styleDim])
        let prosodyStyleValues = Array(styleValues[config.styleDim..<expectedStyleCount])

        let albertInputIDs = try Self.makeMultiArray(shape: [1, albertTokenCapacity], dataType: albertInputDataType)
        try Self.write(
            values: tokenIDs.map(Int32.init),
            to: albertInputIDs,
            requiredCount: albertTokenCapacity,
            zeroFillRemaining: true
        )

        let attentionMask = try Self.makeMultiArray(shape: [1, albertTokenCapacity], dataType: attentionMaskDataType)
        let attentionMaskValues = Array(repeating: Int32(1), count: actualTokenCount)
        try Self.write(
            values: attentionMaskValues,
            to: attentionMask,
            requiredCount: albertTokenCapacity,
            zeroFillRemaining: true
        )

        let textEncoderInputIDs = try Self.makeMultiArray(shape: [1, textTokenCapacity], dataType: textEncoderInputDataType)
        try Self.write(
            values: tokenIDs.map(Int32.init),
            to: textEncoderInputIDs,
            requiredCount: textTokenCapacity,
            zeroFillRemaining: true
        )

        let prosodyInputLengths = try Self.makeMultiArray(shape: [1], dataType: prosodyInputLengthsDataType)
        try Self.write(values: [Int32(actualTokenCount)], to: prosodyInputLengths)

        let textEncoderInputLengths = try Self.makeMultiArray(shape: [1], dataType: textEncoderInputLengthsDataType)
        try Self.write(values: [Int32(actualTokenCount)], to: textEncoderInputLengths)

        let speedArray = try Self.makeMultiArray(shape: [1], dataType: speedInputDataType)
        try Self.write(values: [speed], to: speedArray)

        let prosodyStyle = try Self.makeMultiArray(shape: [1, config.styleDim], dataType: prosodyStyleInputDataType)
        try Self.write(values: prosodyStyleValues, to: prosodyStyle)

        let decoderStyle = try Self.makeMultiArray(shape: [1, config.styleDim], dataType: decoderStyleInputDataType)
        try Self.write(values: acousticStyleValues, to: decoderStyle)

        let albertPrediction = try Self.predict(
            with: albertModel,
            features: [
                FeatureName.inputIDs: albertInputIDs,
                FeatureName.attentionMask: attentionMask,
            ]
        )
        guard let bertOutput = albertPrediction.featureValue(for: FeatureName.bertOutput)?.multiArrayValue else {
            throw KokoroError.missingCoreMLFeature(FeatureName.bertOutput)
        }

        let bertOutputPrefix = Array(
            try Self.floatValues(from: bertOutput)
                .prefix(actualTokenCount * bertHiddenSize)
        )
        let prosodyBertInput = try Self.makeMultiArray(shape: [1, prosodyTokenCapacity, bertHiddenSize], dataType: prosodyBertInputDataType)
        try Self.write(
            values: bertOutputPrefix,
            to: prosodyBertInput,
            requiredCount: prosodyTokenCapacity * bertHiddenSize,
            zeroFillRemaining: true
        )

        let prosodyPrediction = try Self.predict(
            with: prosodyModel,
            features: [
                FeatureName.bertOutput: prosodyBertInput,
                FeatureName.inputLengths: prosodyInputLengths,
                FeatureName.style: prosodyStyle,
                FeatureName.speed: speedArray,
            ]
        )
        guard let predDurArray = prosodyPrediction.featureValue(for: FeatureName.predDur)?.multiArrayValue,
              let f0Array = prosodyPrediction.featureValue(for: FeatureName.f0Pred)?.multiArrayValue,
              let noiseArray = prosodyPrediction.featureValue(for: FeatureName.nPred)?.multiArrayValue
        else {
            throw KokoroError.invalidSegmentedCoreMLContract("Prosody segment did not return pred_dur, f0_pred, and n_pred.")
        }

        let textEncoderPrediction = try Self.predict(
            with: textEncoderModel,
            features: [
                FeatureName.inputIDs: textEncoderInputIDs,
                FeatureName.inputLengths: textEncoderInputLengths,
            ]
        )
        guard let textEncodedArray = textEncoderPrediction.featureValue(for: FeatureName.tEn)?.multiArrayValue else {
            throw KokoroError.missingCoreMLFeature(FeatureName.tEn)
        }

        let predDur = Array(
            try Self.intValues(from: predDurArray)
                .prefix(actualTokenCount)
        ).map { max(0, $0) }
        let (alignmentMatrix, clippedPredDur, totalFrames) = Self.buildAlignment(
            durations: predDur,
            tokenCapacity: textTokenCapacity,
            frameCapacity: frameCapacity
        )

        let textEncoded = try Self.floatValues(from: textEncodedArray)
        let asrValues = Self.matmul(
            lhs: textEncoded,
            rhs: alignmentMatrix,
            rowCount: channelCount,
            sharedCount: textTokenCapacity,
            columnCount: frameCapacity
        )

        let asrArray = try Self.makeMultiArray(shape: [1, channelCount, frameCapacity], dataType: decoderAsrInputDataType)
        try Self.write(values: asrValues, to: asrArray)

        let decoderF0 = try Self.copyMultiArray(f0Array, to: decoderCurveInputDataType, expectedCount: curveCapacity)
        let decoderNoise = try Self.copyMultiArray(noiseArray, to: decoderCurveInputDataType, expectedCount: curveCapacity)

        let decoderPrediction = try Self.predict(
            with: decoderModel,
            features: [
                FeatureName.asr: asrArray,
                FeatureName.f0Curve: decoderF0,
                FeatureName.n: decoderNoise,
                FeatureName.acousticStyle: decoderStyle,
            ]
        )
        guard let audioArray = decoderPrediction.featureValue(for: FeatureName.audio)?.multiArrayValue else {
            throw KokoroError.missingCoreMLFeature(FeatureName.audio)
        }

        let audio = try Self.floatValues(from: audioArray)
        let expectedSamples = min(audioCapacity, totalFrames * Self.samplesPerFrame)
        return KModel.Output(
            audio: Array(audio.prefix(expectedSamples)),
            predDur: clippedPredDur
        )
    }

    private func tokenize(_ phonemes: String) throws -> [Int] {
        let ids = phonemes.compactMap { vocab[String($0)] }
        if ids.count > maxPhonemeCount {
            throw KokoroError.invalidCoreMLPhonemeLength(ids.count, limit: maxPhonemeCount)
        }
        return [0] + ids + [0]
    }

    private static func validate(speed: Float) throws {
        guard speed.isFinite, speed > 0 else {
            throw KokoroError.invalidSpeed(speed)
        }
    }

    private static func loadModel(
        at url: URL,
        configuration: MLModelConfiguration
    ) throws -> (URL, MLModel) {
        let compiledURL = try compiledModelURL(for: url)
        let model = try MLModel(contentsOf: compiledURL, configuration: configuration)
        return (compiledURL, model)
    }

    private static func compiledModelURL(for modelURL: URL) throws -> URL {
        if modelURL.pathExtension == "mlmodelc" {
            return modelURL
        }
        return try MLModel.compileModel(at: modelURL)
    }

    private static func predict(
        with model: MLModel,
        features: [String: MLMultiArray]
    ) throws -> MLFeatureProvider {
        let provider = try MLDictionaryFeatureProvider(
            dictionary: features.mapValues { MLFeatureValue(multiArray: $0) }
        )
        return try model.prediction(from: provider)
    }

    private static func buildAlignment(
        durations: [Int],
        tokenCapacity: Int,
        frameCapacity: Int
    ) -> ([Float], [Int], Int) {
        var matrix = [Float](repeating: 0, count: tokenCapacity * frameCapacity)
        var clippedDurations = durations.map { max(0, $0) }
        var frameIndex = 0

        for tokenIndex in 0..<min(tokenCapacity, clippedDurations.count) {
            let duration = min(clippedDurations[tokenIndex], frameCapacity - frameIndex)
            clippedDurations[tokenIndex] = duration
            guard duration > 0 else {
                continue
            }
            let rowStart = tokenIndex * frameCapacity + frameIndex
            for offset in 0..<duration {
                matrix[rowStart + offset] = 1
            }
            frameIndex += duration
            if frameIndex == frameCapacity {
                break
            }
        }

        if clippedDurations.count > tokenCapacity {
            for index in tokenCapacity..<clippedDurations.count {
                clippedDurations[index] = 0
            }
        }

        return (matrix, clippedDurations, frameIndex)
    }

    private static func matmul(
        lhs: [Float],
        rhs: [Float],
        rowCount: Int,
        sharedCount: Int,
        columnCount: Int
    ) -> [Float] {
        precondition(lhs.count == rowCount * sharedCount)
        precondition(rhs.count == sharedCount * columnCount)

        var result = [Float](repeating: 0, count: rowCount * columnCount)
        lhs.withUnsafeBufferPointer { lhsBuffer in
            rhs.withUnsafeBufferPointer { rhsBuffer in
                result.withUnsafeMutableBufferPointer { resultBuffer in
                    cblas_sgemm(
                        CblasRowMajor,
                        CblasNoTrans,
                        CblasNoTrans,
                        Int32(rowCount),
                        Int32(columnCount),
                        Int32(sharedCount),
                        1.0,
                        lhsBuffer.baseAddress,
                        Int32(sharedCount),
                        rhsBuffer.baseAddress,
                        Int32(columnCount),
                        0.0,
                        resultBuffer.baseAddress,
                        Int32(columnCount)
                    )
                }
            }
        }
        return result
    }

    private static func shape(
        for name: String,
        in descriptions: [String: MLFeatureDescription]
    ) throws -> [Int] {
        guard let constraint = descriptions[name]?.multiArrayConstraint else {
            throw KokoroError.missingCoreMLFeature(name)
        }
        return constraint.shape.map(\.intValue)
    }

    private static func dataType(
        for name: String,
        in descriptions: [String: MLFeatureDescription]
    ) throws -> MLMultiArrayDataType {
        guard let constraint = descriptions[name]?.multiArrayConstraint else {
            throw KokoroError.missingCoreMLFeature(name)
        }
        return constraint.dataType
    }

    private static func makeMultiArray(shape: [Int], dataType: MLMultiArrayDataType) throws -> MLMultiArray {
        try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: dataType)
    }

    private static func copyMultiArray(
        _ source: MLMultiArray,
        to dataType: MLMultiArrayDataType,
        expectedCount: Int
    ) throws -> MLMultiArray {
        let destination = try makeMultiArray(shape: [1, expectedCount], dataType: dataType)
        try write(values: try floatValues(from: source), to: destination, requiredCount: expectedCount)
        return destination
    }

    private static func intValues(from array: MLMultiArray) throws -> [Int] {
        switch array.dataType {
        case .int32:
            return withUnsafeBufferPointer(array, as: Int32.self) { buffer in
                buffer.map(Int.init)
            }
        case .float16:
            return withUnsafeBufferPointer(array, as: Float16.self) { buffer in
                buffer.map { Int(Float($0).rounded()) }
            }
        case .float32:
            return withUnsafeBufferPointer(array, as: Float.self) { buffer in
                buffer.map { Int($0.rounded()) }
            }
        case .double:
            return withUnsafeBufferPointer(array, as: Double.self) { buffer in
                buffer.map { Int($0.rounded()) }
            }
        @unknown default:
            throw KokoroError.unsupportedCoreMLDataType(array.dataType)
        }
    }

    private static func floatValues(from array: MLMultiArray) throws -> [Float] {
        switch array.dataType {
        case .float16:
            return withUnsafeBufferPointer(array, as: Float16.self) { buffer in
                buffer.map(Float.init)
            }
        case .float32:
            return withUnsafeBufferPointer(array, as: Float.self) { buffer in
                Array(buffer)
            }
        case .double:
            return withUnsafeBufferPointer(array, as: Double.self) { buffer in
                buffer.map(Float.init)
            }
        case .int32:
            return withUnsafeBufferPointer(array, as: Int32.self) { buffer in
                buffer.map(Float.init)
            }
        @unknown default:
            throw KokoroError.unsupportedCoreMLDataType(array.dataType)
        }
    }

    private static func write(
        values: [Int32],
        to array: MLMultiArray,
        requiredCount: Int? = nil,
        zeroFillRemaining: Bool = false
    ) throws {
        let expectedCount = requiredCount ?? values.count
        switch array.dataType {
        case .int32:
            try writeBuffer(values: values, to: array, as: Int32.self, requiredCount: expectedCount, zeroFillRemaining: zeroFillRemaining) { $0 }
        case .float16:
            try writeBuffer(values: values, to: array, as: Float16.self, requiredCount: expectedCount, zeroFillRemaining: zeroFillRemaining) { Float16($0) }
        case .float32:
            try writeBuffer(values: values, to: array, as: Float.self, requiredCount: expectedCount, zeroFillRemaining: zeroFillRemaining) { Float($0) }
        case .double:
            try writeBuffer(values: values, to: array, as: Double.self, requiredCount: expectedCount, zeroFillRemaining: zeroFillRemaining) { Double($0) }
        @unknown default:
            throw KokoroError.unsupportedCoreMLDataType(array.dataType)
        }
    }

    private static func write(
        values: [Float],
        to array: MLMultiArray,
        requiredCount: Int? = nil,
        zeroFillRemaining: Bool = false
    ) throws {
        let expectedCount = requiredCount ?? values.count
        switch array.dataType {
        case .float16:
            try writeBuffer(values: values, to: array, as: Float16.self, requiredCount: expectedCount, zeroFillRemaining: zeroFillRemaining) { Float16($0) }
        case .float32:
            try writeBuffer(values: values, to: array, as: Float.self, requiredCount: expectedCount, zeroFillRemaining: zeroFillRemaining) { $0 }
        case .double:
            try writeBuffer(values: values, to: array, as: Double.self, requiredCount: expectedCount, zeroFillRemaining: zeroFillRemaining) { Double($0) }
        case .int32:
            try writeBuffer(values: values, to: array, as: Int32.self, requiredCount: expectedCount, zeroFillRemaining: zeroFillRemaining) { Int32($0.rounded()) }
        @unknown default:
            throw KokoroError.unsupportedCoreMLDataType(array.dataType)
        }
    }

    private static func writeBuffer<Input, Output: ExpressibleByIntegerLiteral>(
        values: [Input],
        to array: MLMultiArray,
        as outputType: Output.Type,
        requiredCount: Int,
        zeroFillRemaining: Bool,
        transform: (Input) -> Output
    ) throws {
        let totalCount = array.shape.map(\.intValue).reduce(1, *)
        guard totalCount >= requiredCount,
              values.count <= requiredCount,
              zeroFillRemaining || totalCount == requiredCount
        else {
            throw KokoroError.invalidCoreMLArrayShape(array.shape.map(\.intValue))
        }

        let buffer = UnsafeMutableRawPointer(array.dataPointer)
            .bindMemory(to: outputType, capacity: totalCount)
        if zeroFillRemaining {
            for index in 0..<totalCount {
                buffer[index] = 0
            }
        }
        for (index, value) in values.enumerated() {
            buffer[index] = transform(value)
        }
    }

    private static func withUnsafeBufferPointer<Element, Result>(
        _ array: MLMultiArray,
        as elementType: Element.Type,
        _ body: (UnsafeBufferPointer<Element>) throws -> Result
    ) rethrows -> Result {
        let count = array.shape.map(\.intValue).reduce(1, *)
        let pointer = UnsafeMutableRawPointer(array.dataPointer)
            .bindMemory(to: elementType, capacity: count)
        return try body(UnsafeBufferPointer(start: pointer, count: count))
    }
}
