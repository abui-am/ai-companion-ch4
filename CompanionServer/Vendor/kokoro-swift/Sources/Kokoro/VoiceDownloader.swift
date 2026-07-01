import Foundation

/// Downloads voice packs and model assets on demand from HuggingFace.
public final class VoiceDownloader: Sendable {
    public static let defaultRepoID = "mweinbach/Kokoro-82M-Swift"
    public static let defaultBaseURL = "https://huggingface.co/mweinbach/Kokoro-82M-Swift/resolve/main"

    /// All available voice names.
    public static let availableVoices: [String] = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore",
        "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
        "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam",
        "am_michael", "am_onyx", "am_puck", "am_santa",
        "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
        "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
        "ef_dora", "em_alex", "em_santa", "ff_siwis",
        "hf_alpha", "hf_beta", "hm_omega", "hm_psi",
        "if_sara", "im_nicola",
        "jf_alpha", "jf_gongitsune", "jf_nezumi", "jf_tebukuro", "jm_kumo",
        "pf_dora", "pm_alex", "pm_santa",
        "zf_xiaobei", "zf_xiaoni", "zf_xiaoxiao", "zf_xiaoyi",
        "zm_yunjian", "zm_yunxi", "zm_yunxia", "zm_yunyang",
    ]

    private let baseURL: String
    private let cacheDirectory: URL
    private let session: URLSession

    /// Initialize a downloader.
    /// - Parameters:
    ///   - baseURL: HuggingFace resolve URL (defaults to mweinbach/Kokoro-82M-Swift)
    ///   - cacheDirectory: Local directory to cache downloaded files.
    ///     Defaults to `~/Library/Caches/Kokoro`.
    public init(
        baseURL: String = VoiceDownloader.defaultBaseURL,
        cacheDirectory: URL? = nil
    ) {
        self.baseURL = baseURL
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory()
        self.session = URLSession(configuration: .default)
    }

    // MARK: - Voice downloads

    /// Download a single voice pack if not already cached.
    /// Returns the local file URL.
    public func downloadVoice(_ name: String) async throws -> URL {
        let relativePath = "MLX_GPU/voices/\(name).npy"
        return try await downloadFile(relativePath: relativePath, subdirectory: "voices")
    }

    /// Download multiple voices, returning their local URLs.
    public func downloadVoices(_ names: [String]) async throws -> [URL] {
        try await withThrowingTaskGroup(of: URL.self) { group in
            for name in names {
                group.addTask { try await self.downloadVoice(name) }
            }
            var urls: [URL] = []
            for try await url in group {
                urls.append(url)
            }
            return urls
        }
    }

    /// Download all 54 voices.
    public func downloadAllVoices() async throws -> [URL] {
        try await downloadVoices(Self.availableVoices)
    }

    // MARK: - Config download

    /// Download config.json if not cached.
    public func downloadConfig() async throws -> URL {
        try await downloadFile(relativePath: "MLX_GPU/config.json", subdirectory: nil)
    }

    // MARK: - MLX model weights

    /// Download the MLX safetensors model weights (~310MB).
    public func downloadMLXWeights() async throws -> URL {
        try await downloadFile(relativePath: "MLX_GPU/kokoro-v1_0.safetensors", subdirectory: nil)
    }

    // MARK: - Convenience: get ready-to-use voices directory

    /// Returns a local directory URL containing the requested voice .npy files.
    /// Downloads any that are missing.
    public func voicesDirectory(for voices: [String]? = nil) async throws -> URL {
        let voiceNames = voices ?? Self.availableVoices
        _ = try await downloadVoices(voiceNames)
        return cacheDirectory.appendingPathComponent("voices", isDirectory: true)
    }

    // MARK: - Internal

    private func downloadFile(relativePath: String, subdirectory: String?) throws -> URL {
        // Synchronous wrapper for callers that don't need async
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<URL, Error>?
        Task {
            do {
                let url = try await self.downloadFileAsync(relativePath: relativePath, subdirectory: subdirectory)
                result = .success(url)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch result! {
        case .success(let url): return url
        case .failure(let error): throw error
        }
    }

    private func downloadFile(relativePath: String, subdirectory: String?) async throws -> URL {
        try await downloadFileAsync(relativePath: relativePath, subdirectory: subdirectory)
    }

    private func downloadFileAsync(relativePath: String, subdirectory: String?) async throws -> URL {
        let fileName = URL(fileURLWithPath: relativePath).lastPathComponent
        let localDir: URL
        if let subdirectory {
            localDir = cacheDirectory.appendingPathComponent(subdirectory, isDirectory: true)
        } else {
            localDir = cacheDirectory
        }
        let localURL = localDir.appendingPathComponent(fileName, isDirectory: false)

        // Already cached
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }

        // Create directory
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)

        // Download
        let remoteURLString = "\(baseURL)/\(relativePath)"
        guard let remoteURL = URL(string: remoteURLString) else {
            throw DownloadError.invalidURL(remoteURLString)
        }

        let (tempURL, response) = try await session.download(from: remoteURL)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw DownloadError.httpError(statusCode, remoteURLString)
        }

        // Move to cache
        if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: localURL)

        return localURL
    }

    // MARK: - Cache directory

    public static func defaultCacheDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("Kokoro", isDirectory: true)
    }

    /// Remove all cached files.
    public func clearCache() throws {
        if FileManager.default.fileExists(atPath: cacheDirectory.path) {
            try FileManager.default.removeItem(at: cacheDirectory)
        }
    }

    // MARK: - Errors

    public enum DownloadError: Error, LocalizedError {
        case invalidURL(String)
        case httpError(Int, String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL(let url):
                return "Invalid download URL: \(url)"
            case .httpError(let code, let url):
                return "HTTP \(code) downloading \(url)"
            }
        }
    }
}
