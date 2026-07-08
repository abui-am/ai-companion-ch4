import CompanionDatabase
import Foundation
import Logging

/// Sub-agent backend for the Realtime orchestrator's `memory` function tool. Stores durable
/// user facts as OpenAI embeddings in Postgres (`MemoryRepository`) for later semantic recall.
/// Writes and on-demand recall are tool-driven only — the most recent facts are also injected
/// into the system prompt at session start for free, see `VoiceSession.refreshMemoryContext`.
/// Gated by `ConfigRecord.personalizationData`, the same privacy flag as conversation history.
struct MemoryAgent: SubAgent, Sendable {
    let name = "memory"

    private static let defaultSearchLimit = 5
    private static let defaultListLimit = 20
    private static let maxContentLength = 500
    private static let duplicateMaxDistance = 0.08
    private static let searchMaxDistance = 0.35

    private let memories: MemoryRepository
    private let embeddings: OpenAIEmbeddingService
    private let config: ConfigRepository
    private let logger: Logger

    init(memories: MemoryRepository, embeddings: OpenAIEmbeddingService, config: ConfigRepository, logger: Logger) {
        self.memories = memories
        self.embeddings = embeddings
        self.config = config
        self.logger = logger
    }

    var toolDefinition: [String: Any] {
        [
            "type": "function",
            "name": name,
            "description": """
            Store and recall durable personal facts about the user across conversations — name, \
            preferences, relationships, routines. The most recent facts are already listed in your \
            instructions; use this tool for anything not already known or from long ago.

            Actions:
            - remember: content required — save one short fact (one sentence)
            - search: query required, optional limit (default 5) — semantic search over saved facts
            - forget: query or id — remove a fact by meaning or by exact ID
            - list: optional limit (default 20) — most recent facts, no search
            """,
            "parameters": [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": ["remember", "search", "forget", "list"],
                        "description": "What to do with memory.",
                    ] as [String: Any],
                    "content": [
                        "type": "string",
                        "description": "Fact to save for action=remember. Keep to one short sentence.",
                    ] as [String: Any],
                    "query": [
                        "type": "string",
                        "description": "Natural-language query for action=search or action=forget.",
                    ] as [String: Any],
                    "id": [
                        "type": "string",
                        "description": "Memory ID (mem_...) for action=forget, if known.",
                    ] as [String: Any],
                    "limit": [
                        "type": "integer",
                        "description": "Max results for action=search or action=list.",
                    ] as [String: Any],
                ],
                "required": ["action"],
            ] as [String: Any],
        ]
    }

    func execute(argumentsJSON: String) async -> String {
        guard let args = SubAgentJSON.parseArguments(argumentsJSON) else {
            logger.error("memory invalid arguments", metadata: ["args": .string(argumentsJSON)])
            return SubAgentJSON.encodeError("invalid arguments JSON")
        }
        guard let action = args["action"] as? String else {
            return SubAgentJSON.encodeError("missing action")
        }

        guard await isPersonalizationEnabled() else {
            return SubAgentJSON.encodeError(
                "Memory is off. Enable personalization in Settings to save or recall memories."
            )
        }

        do {
            switch action {
            case "remember":
                return try await remember(args: args)
            case "search":
                return try await search(args: args)
            case "forget":
                return try await forget(args: args)
            case "list":
                return try await list(args: args)
            default:
                return SubAgentJSON.encodeError("unknown action: \(action)")
            }
        } catch let error as MemoryRepositoryError {
            logger.warning("memory repository error", metadata: ["error": .string(error.description)])
            return SubAgentJSON.encodeError(error.description)
        } catch let error as OpenAIEmbeddingError {
            logger.error("memory embedding failed", metadata: ["error": .string(error.description)])
            return SubAgentJSON.encodeError("memory lookup failed — try again")
        } catch {
            logger.error("memory failed", metadata: ["error": .string("\(error)")])
            return SubAgentJSON.encodeError("\(error)")
        }
    }

    private func isPersonalizationEnabled() async -> Bool {
        do {
            return try await config.get().personalizationData
        } catch {
            logger.warning(
                "memory failed to load config — defaulting to disabled",
                metadata: ["error": "\(error)"]
            )
            return false
        }
    }

    private func remember(args: [String: Any]) async throws -> String {
        guard let content = (args["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty
        else {
            return SubAgentJSON.encodeError("remember requires content")
        }
        guard content.count <= Self.maxContentLength else {
            return SubAgentJSON.encodeError("content must be \(Self.maxContentLength) characters or fewer")
        }

        let embedding = try await embeddings.embed(text: content)
        if let duplicate = try await memories.findDuplicate(embedding: embedding, maxDistance: Self.duplicateMaxDistance) {
            let updated = try await memories.update(id: duplicate.id, content: content, embedding: embedding)
            return SubAgentJSON.encode([
                "summary": "Updated existing memory.",
                "id": updated.id,
                "content": updated.content,
                "updated": true,
            ])
        }

        let record = try await memories.insert(content: content, embedding: embedding)
        return SubAgentJSON.encode([
            "summary": "Saved memory.",
            "id": record.id,
            "content": record.content,
            "updated": false,
        ])
    }

    private func search(args: [String: Any]) async throws -> String {
        guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return SubAgentJSON.encodeError("search requires query")
        }
        let limit = (args["limit"] as? Int) ?? Self.defaultSearchLimit
        let embedding = try await embeddings.embed(text: query)
        let records = try await memories.search(embedding: embedding, limit: limit, maxDistance: Self.searchMaxDistance)
        guard !records.isEmpty else {
            return SubAgentJSON.encode(["summary": "No relevant memories found.", "memories": []])
        }
        return SubAgentJSON.encode([
            "summary": "Found \(records.count) memory(s).",
            "memories": records.map(memoryJSON),
        ])
    }

    private func forget(args: [String: Any]) async throws -> String {
        if let id = (args["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            try await memories.delete(id: id)
            return SubAgentJSON.encode(["summary": "Forgot memory.", "deleted": true, "id": id])
        }
        guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return SubAgentJSON.encodeError("forget requires query or id")
        }
        let embedding = try await embeddings.embed(text: query)
        guard let match = try await memories.deleteBestMatch(embedding: embedding, maxDistance: Self.searchMaxDistance) else {
            return SubAgentJSON.encode(["summary": "No matching memory found.", "deleted": false])
        }
        return SubAgentJSON.encode(["summary": "Forgot memory.", "deleted": true, "id": match.id])
    }

    private func list(args: [String: Any]) async throws -> String {
        let limit = (args["limit"] as? Int) ?? Self.defaultListLimit
        let records = try await memories.list(limit: limit)
        return SubAgentJSON.encode([
            "summary": "Found \(records.count) memory(s).",
            "memories": records.map(memoryJSON),
        ])
    }

    private func memoryJSON(_ record: MemoryRecord) -> [String: Any] {
        ["id": record.id, "content": record.content]
    }
}
