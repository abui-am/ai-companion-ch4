import Foundation

public enum ConvertedWeightsLayout {
    public static let modelFileName = "kokoro-v1_0.safetensors"
    public static let voicesDirectoryName = "voices"
    public static let converterScriptPath = "Scripts/convert_weights.py"

    public static func defaultModelURL(relativeTo directory: URL) -> URL {
        directory.appendingPathComponent(modelFileName, isDirectory: false)
    }

    public static func defaultVoicesDirectory(relativeTo directory: URL) -> URL {
        directory.appendingPathComponent(voicesDirectoryName, isDirectory: true)
    }
}

public struct ConvertedWeightsManifest: Sendable {
    public let modelURL: URL
    public let voicesDirectoryURL: URL

    public init(directory: URL) {
        self.modelURL = ConvertedWeightsLayout.defaultModelURL(relativeTo: directory)
        self.voicesDirectoryURL = ConvertedWeightsLayout.defaultVoicesDirectory(relativeTo: directory)
    }
}
