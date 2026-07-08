import Foundation
import Logging

/// Generates text embeddings via OpenAI's Embeddings API for `MemoryAgent`'s
/// pgvector-backed semantic search.
struct OpenAIEmbeddingService: Sendable {
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

    func embed(text: String) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenAIEmbeddingError.emptyInput
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/embeddings")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        let body: [String: Any] = ["model": model, "input": trimmed]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIEmbeddingError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            logger.error(
                "embedding http error",
                metadata: ["status": "\(http.statusCode)", "body": .string(bodyText)]
            )
            throw OpenAIEmbeddingError.httpError(http.statusCode, bodyText)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]],
              let first = items.first,
              let embedding = first["embedding"] as? [Double]
        else {
            throw OpenAIEmbeddingError.invalidResponse
        }
        return embedding.map(Float.init)
    }
}

enum OpenAIEmbeddingError: Error, CustomStringConvertible {
    case emptyInput
    case invalidResponse
    case httpError(Int, String)

    var description: String {
        switch self {
        case .emptyInput:
            "embedding input was empty"
        case .invalidResponse:
            "embedding API returned an unparseable response"
        case .httpError(let code, let body):
            "embedding API HTTP \(code): \(body)"
        }
    }
}
