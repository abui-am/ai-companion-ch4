import Foundation
import Logging

/// Runs web lookups via OpenAI Responses API (`tools: [{ type: "web_search" }]`).
/// Sub-agent backend for the Realtime orchestrator's `web_search` function tool.
struct WebSearchAgent: SubAgent, Sendable {
    let name = "web_search"

    var toolDefinition: [String: Any] {
        [
            "type": "function",
            "name": name,
            "description": """
            Search the live web for current information: news, weather, sports, prices, events, \
            releases, or any fact that may have changed since your training data. Use when the \
            user asks about recent or time-sensitive topics.

            Before calling this tool, speak one short preamble in the same turn (friend tone, \
            reference what they asked). Then call the tool immediately. Vary the wording. \
            Do not imply whether the lookup will succeed.

            Preamble sample phrases:
            - "Okay, about {topic} — let me check."
            - "Right, I'll look up {topic} real quick."
            - "One sec, I'll see what's out there on {topic}."
            - "Let me pull up {topic} for you."
            """,
            "parameters": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Concise search query for what to look up on the web.",
                    ] as [String: Any],
                ],
                "required": ["query"],
            ] as [String: Any],
        ]
    }

    private let apiKey: String
    private let model: String
    private let logger: Logger
    private let session: URLSession

    init(apiKey: String, model: String, logger: Logger, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.logger = logger
        self.session = session
    }

    func execute(argumentsJSON: String) async -> String {
        let query: String
        if let data = argumentsJSON.data(using: .utf8),
           let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let q = args["query"] as? String
        {
            query = q
        } else {
            logger.error("web_search missing query", metadata: ["args": .string(argumentsJSON)])
            return Self.encodeOutput(["error": "missing query parameter"])
        }

        let result: String
        do {
            result = try await search(query: query)
        } catch {
            logger.error("web_search failed", metadata: ["error": "\(error)"])
            result = "Web search failed: \(error)"
        }

        return Self.encodeOutput(["summary": result])
    }

    func search(query: String) async throws -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WebSearchError.emptyQuery
        }

        logger.info("web search start", metadata: ["query": .string(trimmed), "model": .string(model)])

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45

        let body: [String: Any] = [
            "model": model,
            "input": trimmed,
            "instructions": """
            You are a research assistant for a voice companion. Search the web and return a \
            concise factual summary (2–4 sentences) suitable to be spoken aloud. Include \
            specific numbers, dates, or names when relevant. No bullet lists.
            """,
            "tools": [
                [
                    "type": "web_search",
                    "search_context_size": "low",
                ] as [String: Any],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebSearchError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            logger.error(
                "web search http error",
                metadata: ["status": "\(http.statusCode)", "body": .string(bodyText)]
            )
            throw WebSearchError.httpError(http.statusCode, bodyText)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebSearchError.invalidResponse
        }

        if let text = Self.extractOutputText(from: json), !text.isEmpty {
            logger.info("web search done", metadata: ["chars": "\(text.count)"])
            return text
        }

        throw WebSearchError.noResults
    }

    private static func encodeOutput(_ payload: [String: String]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let string = String(data: data, encoding: .utf8)
        {
            return string
        }
        return payload["summary"] ?? payload["error"] ?? "{}"
    }

    private static func extractOutputText(from json: [String: Any]) -> String? {
        if let topLevel = json["output_text"] as? String, !topLevel.isEmpty {
            return topLevel
        }
        guard let output = json["output"] as? [[String: Any]] else { return nil }
        for item in output {
            guard item["type"] as? String == "message" else { continue }
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content {
                guard part["type"] as? String == "output_text",
                      let text = part["text"] as? String,
                      !text.isEmpty
                else { continue }
                return text
            }
        }
        return nil
    }
}

enum WebSearchError: Error, CustomStringConvertible {
    case emptyQuery
    case invalidResponse
    case noResults
    case httpError(Int, String)

    var description: String {
        switch self {
        case .emptyQuery:
            "web search query was empty"
        case .invalidResponse:
            "web search returned an unparseable response"
        case .noResults:
            "web search returned no text"
        case .httpError(let code, let body):
            "web search HTTP \(code): \(body)"
        }
    }
}
