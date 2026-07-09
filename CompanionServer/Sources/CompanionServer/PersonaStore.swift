import CompanionEnv
import Foundation
import Logging

/// Character personas as plain-markdown instruction files: `personas/<name>.md`
/// at the package root. Dropping a new file in adds a character — no code
/// change, no rebuild (files are read on use). The active choice persists to
/// `personas/.active` so it survives restarts, and is pushed live into every
/// attached Realtime session on change (takes effect next turn).
actor PersonaStore {
    private let directory: URL
    private let logger: Logger
    /// Live sessions to push persona changes into, keyed by session id.
    private var attached: [String: OpenAIRealtimeService] = [:]

    init(logger: Logger) {
        let fm = FileManager.default
        let base: URL = if let root = PackagePaths.packageRoot() {
            URL(fileURLWithPath: root, isDirectory: true)
        } else {
            URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        }
        directory = base.appendingPathComponent("personas", isDirectory: true)
        self.logger = logger
    }

    func available() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return entries.filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }.sorted()
    }

    func activeName() -> String? {
        guard let raw = try? String(contentsOf: activeFile, encoding: .utf8) else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    func activeInstruction() -> String? {
        activeName().flatMap { instruction(for: $0) }
    }

    func instruction(for name: String) -> String? {
        guard isValidName(name) else { return nil }
        let file = directory.appendingPathComponent("\(name).md")
        return try? String(contentsOf: file, encoding: .utf8)
    }

    /// `nil` clears the persona (back to the plain personality tone).
    func setActive(_ name: String?) async throws {
        var instruction: String? = nil
        if let name {
            guard let loaded = self.instruction(for: name) else {
                throw PersonaError.unknownPersona(name)
            }
            instruction = loaded
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try name.write(to: activeFile, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: activeFile)
        }
        logger.info("persona set", metadata: ["persona": .string(name ?? "none")])
        for (sessionId, realtime) in attached {
            await realtime.setPersona(named: name, instruction: instruction)
            logger.debug(
                "persona pushed to live session",
                metadata: ["session_id": .string(sessionId), "persona": .string(name ?? "none")]
            )
        }
    }

    func attach(sessionId: String, realtime: OpenAIRealtimeService) {
        attached[sessionId] = realtime
    }

    func detach(sessionId: String) {
        attached.removeValue(forKey: sessionId)
    }

    private var activeFile: URL { directory.appendingPathComponent(".active") }

    /// Filename-safe names only — also blocks path traversal.
    private func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}

enum PersonaError: Error, CustomStringConvertible {
    case unknownPersona(String)

    var description: String {
        switch self {
        case .unknownPersona(let name):
            "Unknown persona \"\(name)\" — add personas/\(name).md or pick from GET /api/v1/personas"
        }
    }
}
