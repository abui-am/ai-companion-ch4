import Foundation
import Kokoro

private enum CLIError: LocalizedError {
    case help(String)
    case usage(String)
    case missingFile(URL)
    case invalidFloat(String)

    var errorDescription: String? {
        switch self {
        case .help(let message), .usage(let message):
            return message
        case .missingFile(let url):
            return "Required file not found at \(url.path)."
        case .invalidFloat(let value):
            return "Could not parse floating-point value '\(value)'."
        }
    }
}

private enum CLIBackend: String {
    case mlx
    case coremlANESegmented = "coreml-ane-segmented"

    var defaultSegmentedDirectoryPath: String? {
        switch self {
        case .coremlANESegmented:
            return "CoreML_ANE/segmented"
        case .mlx:
            return nil
        }
    }
}

private let usage = """
Usage:
  KokoroCLI --text "Hello world" --voice af_heart --output hello.wav
  KokoroCLI --text "Hello world" --voice af_heart --output hello.wav --auto-download
  KokoroCLI download-voice af_heart af_bella am_adam
  KokoroCLI download-voice --all
  KokoroCLI list-voices

Options:
  --backend <mode>             mlx | coreml-ane-segmented (default: mlx)
  --coreml-segmented-dir <path> Segmented CoreML directory (default: CoreML_ANE/segmented)
  --speed <float>              Speech speed modifier (default: 1.0)
  --lang-code <code>           Misaki language code (default: en-us)
  --weights-dir <dir>          Model directory with config.json, voices/ (default: ./MLX_GPU)
  --auto-download              Auto-download missing voices from HuggingFace
  --cache-dir <dir>            Cache directory for downloads (default: ~/Library/Caches/Kokoro)
  --help                       Show this help
"""

// MARK: - Download commands

private func runDownloadVoice(arguments: [String]) throws {
    let downloader = VoiceDownloader()

    if arguments.contains("--all") {
        print("Downloading all \(VoiceDownloader.availableVoices.count) voices...")
        let semaphore = DispatchSemaphore(value: 0)
        var downloadError: Error?
        Task {
            do {
                let urls = try await downloader.downloadAllVoices()
                print("Downloaded \(urls.count) voices to \(VoiceDownloader.defaultCacheDirectory().path)/voices/")
            } catch {
                downloadError = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = downloadError { throw error }
        return
    }

    let voiceNames = arguments.filter { !$0.hasPrefix("-") }
    guard !voiceNames.isEmpty else {
        throw CLIError.usage("Specify voice names or --all.\n\n\(usage)")
    }

    for name in voiceNames {
        print("Downloading \(name)...")
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<URL, Error>?
        Task {
            do {
                let url = try await downloader.downloadVoice(name)
                result = .success(url)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch result! {
        case .success(let url):
            print("  -> \(url.path)")
        case .failure(let error):
            throw error
        }
    }
}

private func runListVoices() {
    print("Available voices (\(VoiceDownloader.availableVoices.count)):\n")
    let grouped = Dictionary(grouping: VoiceDownloader.availableVoices) {
        String($0.prefix(2))
    }
    let prefixLabels: [String: String] = [
        "af": "American Female", "am": "American Male",
        "bf": "British Female",  "bm": "British Male",
        "ef": "Spanish Female",  "em": "Spanish Male",
        "ff": "French Female",
        "hf": "Hindi Female",    "hm": "Hindi Male",
        "if": "Italian Female",  "im": "Italian Male",
        "jf": "Japanese Female", "jm": "Japanese Male",
        "pf": "Portuguese Female", "pm": "Portuguese Male",
        "zf": "Chinese Female",  "zm": "Chinese Male",
    ]
    for prefix in grouped.keys.sorted() {
        let label = prefixLabels[prefix] ?? prefix
        let voices = grouped[prefix]!.sorted()
        print("  \(label): \(voices.joined(separator: ", "))")
    }
}

// MARK: - Synthesis

private struct SynthesisOptions {
    let text: String
    let voice: String
    let outputURL: URL
    let weightsDirectoryURL: URL
    let speed: Float
    let langCode: String
    let backend: CLIBackend
    let coreMLSegmentedDirectoryURL: URL?
    let autoDownload: Bool
    let cacheDir: URL?
}

private func parseSynthesisOptions(arguments: [String]) throws -> SynthesisOptions {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

    var text: String?
    var voice: String?
    var outputURL: URL?
    var weightsDirectoryURL = cwd.appendingPathComponent("MLX_GPU", isDirectory: true)
    var speed: Float = 1.0
    var langCode = "en-us"
    var backend: CLIBackend = .mlx
    var coreMLSegmentedDirectoryURL: URL?
    var autoDownload = false
    var cacheDir: URL?

    func nextValue(for flag: String, at index: inout Int) throws -> String {
        index += 1
        guard index < arguments.count else {
            throw CLIError.usage("Missing value for \(flag).\n\n\(usage)")
        }
        return arguments[index]
    }

    func resolvePath(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: path, relativeTo: cwd).standardizedFileURL
    }

    var i = 0
    while i < arguments.count {
        switch arguments[i] {
        case "--text":       text = try nextValue(for: "--text", at: &i)
        case "--voice":      voice = try nextValue(for: "--voice", at: &i)
        case "--output":     outputURL = resolvePath(try nextValue(for: "--output", at: &i))
        case "--weights-dir": weightsDirectoryURL = resolvePath(try nextValue(for: "--weights-dir", at: &i))
        case "--speed":
            let v = try nextValue(for: "--speed", at: &i)
            guard let f = Float(v) else { throw CLIError.invalidFloat(v) }
            speed = f
        case "--lang-code":  langCode = try nextValue(for: "--lang-code", at: &i)
        case "--backend":
            let v = try nextValue(for: "--backend", at: &i)
            guard let b = CLIBackend(rawValue: v) else {
                throw CLIError.usage("Unsupported backend '\(v)'.\n\n\(usage)")
            }
            backend = b
        case "--coreml-segmented-dir":
            coreMLSegmentedDirectoryURL = resolvePath(try nextValue(for: "--coreml-segmented-dir", at: &i))
        case "--auto-download": autoDownload = true
        case "--cache-dir":  cacheDir = resolvePath(try nextValue(for: "--cache-dir", at: &i))
        case "--help", "-h": throw CLIError.help(usage)
        default:
            throw CLIError.usage("Unknown argument '\(arguments[i])'.\n\n\(usage)")
        }
        i += 1
    }

    guard let text, !text.isEmpty else {
        throw CLIError.usage("Missing required --text.\n\n\(usage)")
    }
    guard let voice, !voice.isEmpty else {
        throw CLIError.usage("Missing required --voice.\n\n\(usage)")
    }
    guard let outputURL else {
        throw CLIError.usage("Missing required --output.\n\n\(usage)")
    }

    if coreMLSegmentedDirectoryURL == nil, let p = backend.defaultSegmentedDirectoryPath {
        coreMLSegmentedDirectoryURL = resolvePath(p)
    }

    return SynthesisOptions(
        text: text, voice: voice, outputURL: outputURL,
        weightsDirectoryURL: weightsDirectoryURL,
        speed: speed, langCode: langCode, backend: backend,
        coreMLSegmentedDirectoryURL: coreMLSegmentedDirectoryURL,
        autoDownload: autoDownload, cacheDir: cacheDir
    )
}

private func runSynthesis() throws {
    let opts = try parseSynthesisOptions(arguments: Array(CommandLine.arguments.dropFirst()))
    let manifest = ConvertedWeightsManifest(directory: opts.weightsDirectoryURL)
    let configURL = opts.weightsDirectoryURL.appendingPathComponent("config.json", isDirectory: false)

    guard FileManager.default.fileExists(atPath: configURL.path) else {
        throw CLIError.missingFile(configURL)
    }

    // If auto-download is on and voices directory doesn't exist, use cache dir
    let voicesDir: URL
    if opts.autoDownload {
        let cacheBase = opts.cacheDir ?? VoiceDownloader.defaultCacheDirectory()
        voicesDir = cacheBase.appendingPathComponent("voices", isDirectory: true)
        try FileManager.default.createDirectory(at: voicesDir, withIntermediateDirectories: true)
    } else {
        voicesDir = manifest.voicesDirectoryURL
        guard FileManager.default.fileExists(atPath: voicesDir.path) else {
            throw CLIError.missingFile(voicesDir)
        }
    }

    try FileManager.default.createDirectory(
        at: opts.outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let voices = VoiceLoader(baseDirectory: voicesDir, enableDownload: opts.autoDownload)
    let pipeline: KPipeline

    switch opts.backend {
    case .mlx:
        guard FileManager.default.fileExists(atPath: manifest.modelURL.path) else {
            throw CLIError.missingFile(manifest.modelURL)
        }
        let model = try KModel(configURL: configURL, weightsURL: manifest.modelURL)
        pipeline = KPipeline(model: model, voices: voices, langCode: opts.langCode)
    case .coremlANESegmented:
        guard let segDir = opts.coreMLSegmentedDirectoryURL else {
            throw CLIError.usage("Missing --coreml-segmented-dir.\n\n\(usage)")
        }
        guard FileManager.default.fileExists(atPath: segDir.path) else {
            throw CLIError.missingFile(segDir)
        }
        let model = try SegmentedCoreMLModel(segmentedDir: segDir, configURL: configURL)
        pipeline = KPipeline(coreMLSegmentedModel: model, voices: voices, langCode: opts.langCode)
    }

    let result = try pipeline.synthesize(text: opts.text, voice: opts.voice, speed: opts.speed)
    let outputURL = try AudioWriter.writeWAV(samples: result.audio, to: opts.outputURL, sampleRate: result.sampleRate)

    print("Wrote \(outputURL.path)")
    print("Backend: \(opts.backend.rawValue)")
    print("Phonemes: \(result.phonemes)")
    print("Samples: \(result.audio.count) @ \(result.sampleRate) Hz")
}

// MARK: - Entry point

do {
    let args = Array(CommandLine.arguments.dropFirst())

    if args.isEmpty || args.first == "--help" || args.first == "-h" {
        print(usage)
        exit(args.isEmpty ? EXIT_FAILURE : EXIT_SUCCESS)
    }

    switch args.first {
    case "download-voice":
        try runDownloadVoice(arguments: Array(args.dropFirst()))
    case "list-voices":
        runListVoices()
    default:
        try runSynthesis()
    }
} catch let error as CLIError {
    switch error {
    case .help(let message):
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
        exit(EXIT_SUCCESS)
    default:
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(EXIT_FAILURE)
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(EXIT_FAILURE)
}
