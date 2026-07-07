import Foundation

/// A JSON value with no fixed Swift type — used for tool call `input`/`output` payloads,
/// which are arbitrary JSON produced by sub-agents (`TaskAgent`, `CalendarAgent`, `WebSearchAgent`).
enum JSONValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Converts a `JSONSerialization` result (`String`, `NSNumber`, `[String: Any]`, `[Any]`, …)
    /// into `JSONValue`. Checks `Bool` before `NSNumber` since JSON booleans bridge to both.
    static func from(_ any: Any) -> JSONValue {
        switch any {
        case let value as String: .string(value)
        case let value as Bool: .bool(value)
        case let value as NSNumber: .number(value.doubleValue)
        case let value as [String: Any]: .object(value.mapValues { from($0) })
        case let value as [Any]: .array(value.map { from($0) })
        default: .null
        }
    }

    /// Parses a JSON-object string (as stored in Postgres for tool call `arguments`/`output`)
    /// into `[String: JSONValue]`. Falls back to `{"raw": "<original string>"}` when the
    /// string isn't valid JSON, so malformed sub-agent output never breaks the history API.
    static func parseObject(_ jsonString: String) -> [String: JSONValue] {
        guard let data = jsonString.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              case .object(let object) = JSONValue.from(any)
        else {
            return ["raw": .string(jsonString)]
        }
        return object
    }
}
