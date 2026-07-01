import CoreML
import Foundation
import MLX

public struct CoreMLVoiceAdapter {
    public static func styleVector(
        from voiceLoader: VoiceLoader,
        voice: String,
        phonemeCount: Int
    ) throws -> MLMultiArray {
        let style = try voiceLoader.styleVector(for: voice, phonemeCount: phonemeCount)
        let shape = style.shape
        guard shape.count == 2, shape[0] == 1 else {
            throw KokoroError.expectedStyleVector(shape)
        }

        let values = style.asArray(Float.self)
        let array = try MLMultiArray(
            shape: [NSNumber(value: 1), NSNumber(value: shape[1])],
            dataType: .float32
        )
        let pointer = UnsafeMutableRawPointer(array.dataPointer).bindMemory(to: Float.self, capacity: values.count)
        for (index, value) in values.enumerated() {
            pointer[index] = value
        }
        return array
    }
}
