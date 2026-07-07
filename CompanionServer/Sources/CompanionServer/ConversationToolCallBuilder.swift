import Foundation

/// Structured tool call surfaced to clients — same shape whether it arrives live over the
/// WebSocket (`tool.done`, see `WireProtocol`) or from persisted history
/// (`GET /conversations/{id}/history`, see `ConversationRoutes`).
struct StructuredToolCall: Sendable, Codable, Equatable {
    let id: String
    let tool: String
    let action: String?
    let label: String
    let status: String
    let input: [String: JSONValue]
    let output: [String: JSONValue]
    let summary: String?
    let createdAt: Date
}

/// Single source of truth for structured tool-call objects, shared by the live WebSocket
/// event and the persisted history API so both agree on label formatting and status
/// derivation. See `OpenAIRealtimeService.handleFunctionCalls` (producer) and
/// `VoiceSession` (WebSocket + persistence).
enum ConversationToolCallBuilder {
    /// Matches the dedupe-skip output in `OpenAIRealtimeService` — kept as one constant so
    /// the "duplicate" status derivation below can never drift from the text it detects.
    static let duplicateSummary = "Already looked that up this turn."

    static func makeId() -> String {
        let suffix = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
            .prefix(12)
        return "ctool_\(suffix)"
    }

    /// Human-readable label for the tool-call UI, e.g. `"list"`, `"create: Buy milk"`, or a
    /// web search query. Used both for the live `tool.start` event and the persisted `label`.
    static func label(name: String, argumentsJSON: String) -> String {
        guard let args = SubAgentJSON.parseArguments(argumentsJSON) else { return argumentsJSON }

        if name == "web_search", let query = args["query"] as? String {
            return query
        }

        if name == "tasks" || name == "calendar" {
            let action = args["action"] as? String ?? name
            if let title = args["title"] as? String, !title.isEmpty {
                return "\(action): \(title)"
            }
            if let id = args["id"] as? String, !id.isEmpty {
                return "\(action): \(id)"
            }
            return action
        }

        return argumentsJSON
    }

    /// Builds a `StructuredToolCall` from the raw JSON strings captured during a turn —
    /// parses `input`/`output`, derives `status`, and extracts `action`/`summary`.
    static func build(
        id: String,
        name: String,
        detail: String,
        argumentsJSON: String,
        outputJSON: String,
        createdAt: Date
    ) -> StructuredToolCall {
        let input = JSONValue.parseObject(argumentsJSON)
        let output = JSONValue.parseObject(outputJSON)

        let summary: String? = if case .string(let value)? = output["summary"] { value } else { nil }
        let action: String? = if case .string(let value)? = input["action"] { value } else { nil }

        let status: String =
            if output["error"] != nil {
                "error"
            } else if summary == duplicateSummary {
                "duplicate"
            } else {
                "success"
            }

        return StructuredToolCall(
            id: id,
            tool: name,
            action: action,
            label: detail,
            status: status,
            input: input,
            output: output,
            summary: summary,
            createdAt: createdAt
        )
    }
}
