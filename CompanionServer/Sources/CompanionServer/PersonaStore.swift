import CompanionEnv
import Foundation
import Logging

/// Character personas as plain-markdown instruction files: `personas/<name>.md`
/// at the package root. Dropping a new file in adds a character — no code
/// change, no rebuild (files are read on use). The active choice persists to
/// `personas/.active` so it survives restarts, and is pushed live into every
/// attached Realtime session on change (takes effect next turn).
actor PersonaStore {
    /// Guardrail for uploads via the API — a persona prompt has no business
    /// being bigger than this (it is injected into every realtime session).
    static let maxContentBytes = 64 * 1024

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
        self.init(directory: base.appendingPathComponent("personas", isDirectory: true), logger: logger)
    }

    init(directory: URL, logger: Logger) {
        self.directory = directory
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

    /// Creates or overwrites `personas/<name>.md`. If the edited persona is
    /// currently active, the new text is pushed into live sessions immediately.
    func save(name: String, content: String) async throws {
        guard isValidName(name) else {
            throw PersonaError.invalidName(name)
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PersonaError.emptyContent
        }
        guard content.utf8.count <= Self.maxContentBytes else {
            throw PersonaError.contentTooLarge(limit: Self.maxContentBytes)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(name).md")
        try content.write(to: file, atomically: true, encoding: .utf8)
        logger.info("persona saved", metadata: ["persona": .string(name)])

        if activeName() == name {
            for (sessionId, realtime) in attached {
                await realtime.setPersona(named: name, instruction: content)
                logger.debug(
                    "updated persona pushed to live session",
                    metadata: ["session_id": .string(sessionId), "persona": .string(name)]
                )
            }
        }
    }

    /// Removes `personas/<name>.md`; deleting the active persona clears it.
    func delete(name: String) async throws {
        guard isValidName(name), instruction(for: name) != nil else {
            throw PersonaError.unknownPersona(name)
        }
        if activeName() == name {
            try await setActive(nil)
        }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).md"))
        logger.info("persona deleted", metadata: ["persona": .string(name)])
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
    case invalidName(String)
    case emptyContent
    case contentTooLarge(limit: Int)

    var description: String {
        switch self {
        case .unknownPersona(let name):
            "Unknown persona \"\(name)\" — add personas/\(name).md or pick from GET /api/v1/personas"
        case .invalidName(let name):
            "Invalid persona name \"\(name)\" — use letters, numbers, - and _ only"
        case .emptyContent:
            "Persona content must not be empty"
        case .contentTooLarge(let limit):
            "Persona content too large — max \(limit) bytes"
        }
    }
}
