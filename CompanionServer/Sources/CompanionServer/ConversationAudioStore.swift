import CompanionEnv
import Foundation
import Logging

/// Filesystem-backed storage for conversation-turn WAV audio, kept separate from the
/// always-on `debug-audio/` dumps. Only written when `personalizationData` is true — see
/// `VoiceSession.applyUserConfig`. Postgres stores the relative path only (`audio_path`);
/// the WAV bytes themselves live on disk under `rootDirectory`.
struct ConversationAudioStore: Sendable {
    private let rootDirectory: URL
    private let logger: Logger

    init(rootDirectory: URL, logger: Logger) {
        self.rootDirectory = rootDirectory
        self.logger = logger
    }

    /// Creates (if needed) and returns `CompanionServer/conversation-audio/`.
    static func defaultRootDirectory() throws -> URL {
        let fm = FileManager.default
        let base: URL = if let root = PackagePaths.packageRoot() {
            URL(fileURLWithPath: root, isDirectory: true)
        } else {
            URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        }
        let dir = base.appendingPathComponent("conversation-audio", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes the user's uplink speech (16 kHz PCM) as WAV. Returns the relative path to
    /// store in `conversation_messages.audio_path`, or `nil` when `pcm` is empty.
    func saveUplink(sessionId: String, turnId: String, pcm: Data) -> String? {
        save(
            pcm: pcm,
            sampleRate: AudioParams.uplink.sampleRate,
            sessionId: sessionId,
            filename: "\(turnId)-uplink.wav"
        )
    }

    /// Writes the assistant's downlink reply (24 kHz PCM) as WAV.
    func saveDownlink(sessionId: String, turnId: String, pcm: Data) -> String? {
        save(
            pcm: pcm,
            sampleRate: AudioParams.downlink.sampleRate,
            sessionId: sessionId,
            filename: "\(turnId)-downlink.wav"
        )
    }

    /// Resolves a relative `audio_path` (as stored in Postgres) to a readable file URL.
    func fileURL(forRelativePath relativePath: String) -> URL {
        rootDirectory.appendingPathComponent(relativePath)
    }

    private func save(pcm: Data, sampleRate: Int, sessionId: String, filename: String) -> String? {
        guard !pcm.isEmpty else { return nil }
        let relativePath = "\(sessionId)/\(filename)"
        do {
            let sessionDir = rootDirectory.appendingPathComponent(sessionId, isDirectory: true)
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            let fileURL = sessionDir.appendingPathComponent(filename)
            try WAVWriter.wrap(pcm: pcm, sampleRate: sampleRate).write(to: fileURL)
            return relativePath
        } catch {
            logger.warning(
                "failed to save conversation audio",
                metadata: ["path": .string(relativePath), "error": "\(error)"]
            )
            return nil
        }
    }
}
