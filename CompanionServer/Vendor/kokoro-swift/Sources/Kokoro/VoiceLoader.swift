import Foundation
import MLX

public final class VoiceLoader {
    private let baseDirectory: URL
    private var cache: [String: MLXArray] = [:]
    private let downloader: VoiceDownloader?

    /// Initialize with a local directory of voice .npy files.
    public init(baseDirectory: URL, enableDownload: Bool = false) {
        self.baseDirectory = baseDirectory
        self.downloader = enableDownload ? VoiceDownloader(cacheDirectory: baseDirectory.deletingLastPathComponent()) : nil
    }

    public func loadVoice(named voice: String) throws -> MLXArray {
        if let cached = cache[voice] {
            return cached
        }

        var url = baseDirectory.appendingPathComponent("\(voice).npy", isDirectory: false)
        if !FileManager.default.fileExists(atPath: url.path) {
            // Try downloading if enabled
            if let downloader {
                let semaphore = DispatchSemaphore(value: 0)
                var downloadResult: Result<URL, Error>?
                Task {
                    do {
                        let downloaded = try await downloader.downloadVoice(voice)
                        downloadResult = .success(downloaded)
                    } catch {
                        downloadResult = .failure(error)
                    }
                    semaphore.signal()
                }
                semaphore.wait()
                switch downloadResult! {
                case .success(let downloaded):
                    url = downloaded
                case .failure:
                    throw KokoroError.missingVoice(voice)
                }
            } else {
                throw KokoroError.missingVoice(voice)
            }
        }

        let raw = try loadArray(url: url)
        let voicePack: MLXArray
        switch raw.ndim {
        case 2:
            voicePack = raw
        case 3 where raw.dim(1) == 1:
            voicePack = raw.squeezed(axis: 1)
        default:
            throw KokoroError.expected2DVoicePack(voice, raw.shape)
        }

        cache[voice] = voicePack
        return voicePack
    }

    public func loadVoiceBlend(named voices: String, delimiter: Character = ",") throws -> MLXArray {
        let names = voices.split(separator: delimiter).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        precondition(!names.isEmpty, "Voice name must not be empty.")
        if names.count == 1, let first = names.first {
            return try loadVoice(named: first)
        }

        let packs = try names.map(loadVoice(named:))
        let stackedPacks = stacked(packs, axis: 0)
        return mean(stackedPacks, axis: 0)
    }

    public func styleVector(for voice: String, phonemeCount: Int) throws -> MLXArray {
        let pack = try loadVoiceBlend(named: voice)
        let index = max(0, min(phonemeCount - 1, pack.dim(0) - 1))
        let style = pack[index]
        if style.ndim == 1 {
            return style.expandedDimensions(axis: 0)
        }
        if style.ndim == 2 {
            return style
        }
        throw KokoroError.expectedStyleVector(style.shape)
    }
}
