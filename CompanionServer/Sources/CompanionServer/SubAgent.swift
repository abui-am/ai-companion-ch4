import Foundation

enum SubAgentJSONError: Error, CustomStringConvertible {
    case parseError(String)

    var description: String {
        switch self {
        case .parseError(let message):
            message
        }
    }
}

enum SubAgentJSON {
    static func parseArguments(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return args
    }

    static func parseDate(_ string: String, defaultTimeZone: TimeZone = .gmt) -> Date? {
        CompanionTimezone.parseCompanionDate(string, in: defaultTimeZone)
    }

    static func formatDate(_ date: Date, in timeZone: TimeZone) -> String {
        CompanionTimezone.formatDate(date, in: timeZone)
    }

    static func formatDateUTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func encode(_ payload: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let string = String(data: data, encoding: .utf8)
        {
            return string
        }
        if let summary = payload["summary"] as? String { return summary }
        if let error = payload["error"] as? String { return error }
        return "{}"
    }

    static func parseZonedDate(
        _ string: String,
        defaultTimeZone: TimeZone,
        field: String
    ) -> Result<Date, SubAgentJSONError> {
        guard let date = CompanionTimezone.parseCompanionDate(string, in: defaultTimeZone) else {
            return .failure(.parseError("invalid \(field)"))
        }
        return .success(date)
    }

    static func encodeError(_ message: String) -> String {
        encode(["error": message])
    }
}

/// A cheap text-only worker invoked by the Realtime orchestrator via function tools.
protocol SubAgent: Sendable {
    var name: String { get }
    var toolDefinition: [String: Any] { get }
    func execute(argumentsJSON: String) async -> String
}

/// Registry of sub-agents exposed as Realtime function tools.
struct SubAgentRegistry: Sendable {
    private let agentsByName: [String: any SubAgent]

    init(agents: [any SubAgent]) {
        agentsByName = Dictionary(uniqueKeysWithValues: agents.map { ($0.name, $0) })
    }

    var toolDefinitions: [[String: Any]] {
        agentsByName.values.map(\.toolDefinition)
    }

    var isEmpty: Bool {
        agentsByName.isEmpty
    }

    func agent(named name: String) -> (any SubAgent)? {
        agentsByName[name]
    }
}
