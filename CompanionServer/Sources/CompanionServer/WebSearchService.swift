import Foundation
import Logging

/// Runs web lookups via OpenAI Responses API (`tools: [{ type: "web_search" }]`).
/// Used as the backend for the Realtime `web_search` function tool.
struct WebSearchService: Sendable {
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
