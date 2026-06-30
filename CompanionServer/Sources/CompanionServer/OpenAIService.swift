import Foundation
import Logging

struct ChatToolResult: Sendable {
    let reply: String
    let command: DeviceCommand?
}

enum ChatStreamEvent: Sendable {
    case token(String)
    case done(ChatToolResult)
}

/// A single turn in a session's conversation history, fed back to the LLM so it
/// has context from earlier turns in the same connection.
struct ChatMessage: Sendable {
    let role: String
    let content: String
}

protocol OpenAIService: Sendable {
    func chat(transcript: String, history: [ChatMessage]) -> AsyncThrowingStream<ChatStreamEvent, Error>
    func speech(text: String) async throws -> Data
}

enum OpenAIError: Error {
    case missingAPIKey
    case badResponse(Int, String)
}

/// Calls OpenAI's REST API directly over URLSession.
struct OpenAIRESTService: OpenAIService {
    let apiKey: String
    let session: URLSession
    let logger: Logger

    init(apiKey: String, logger: Logger, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.logger = logger
        self.session = session
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    func chat(transcript: String, history: [ChatMessage]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = URL(string: "https://api.openai.com/v1/chat/completions")!
                    logger.debug(
                        "HTTP POST /v1/chat/completions (stream)",
                        metadata: ["model": "gpt-5-nano", "transcript_chars": "\(transcript.count)", "history_messages": "\(history.count)"]
                    )
                    var request = authorizedRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let body = ChatRequest(
                        model: "gpt-5-nano",
                        messages: [.init(role: "system", content: CompanionPrompt.system)]
                            + history.map { .init(role: $0.role, content: $0.content) }
                            + [.init(role: "user", content: CompanionPrompt.userMessage(for: transcript))],
                        tools: [.setLEDTool],
                        stream: true
                    )
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    guard (200...299).contains(status) else {
                        var errorData = Data()
                        for try await byte in bytes { errorData.append(byte) }
                        logger.error(
                            "OpenAI HTTP error",
                            metadata: ["status": "\(status)", "body": .string(String(data: errorData, encoding: .utf8) ?? "")]
                        )
                        throw OpenAIError.badResponse(status, String(data: errorData, encoding: .utf8) ?? "")
                    }

                    var contentBuffer = ""
                    var toolCalls: [Int: (name: String, arguments: String)] = [:]

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8) else { continue }
                        let chunk = try JSONDecoder().decode(ChatStreamChunk.self, from: data)
                        guard let choice = chunk.choices.first else { continue }

                        if let content = choice.delta.content, !content.isEmpty {
                            contentBuffer += content
                            continuation.yield(.token(content))
                        }
                        if let calls = choice.delta.toolCalls {
                            for call in calls {
                                var entry = toolCalls[call.index] ?? (name: "", arguments: "")
                                if let name = call.function?.name { entry.name = name }
                                if let args = call.function?.arguments { entry.arguments += args }
                                toolCalls[call.index] = entry
                            }
                        }
                    }

                    var command: DeviceCommand?
                    if let setLED = toolCalls.values.first(where: { $0.name == "set_led" }),
                       let argsData = setLED.arguments.data(using: .utf8),
                       let params = try? JSONDecoder().decode(LEDParams.self, from: argsData) {
                        command = DeviceCommand(action: "set_led", params: params)
                        logger.debug(
                            "chat tool call",
                            metadata: ["name": "set_led", "arguments": .string(setLED.arguments)]
                        )
                    }

                    logger.debug(
                        "HTTP response /v1/chat/completions (stream) complete",
                        metadata: ["reply_chars": "\(contentBuffer.count)"]
                    )
                    continuation.yield(.done(ChatToolResult(reply: contentBuffer, command: command)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func speech(text: String) async throws -> Data {
        let url = URL(string: "https://api.openai.com/v1/audio/speech")!
        logger.debug(
            "HTTP POST /v1/audio/speech",
            metadata: ["model": "tts-1", "voice": "alloy", "response_format": "pcm", "input_chars": "\(text.count)"]
        )
        var request = authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            SpeechRequest(model: "tts-1", input: text, voice: "alloy", responseFormat: "pcm")
        )

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        logger.debug("HTTP response /v1/audio/speech", metadata: ["status": "\(status)", "bytes": "\(data.count)"])
        try Self.checkStatus(response, data, logger: logger)
        return data
    }

    private static func checkStatus(_ response: URLResponse, _ data: Data, logger: Logger) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("OpenAI HTTP error", metadata: ["status": "\(status)", "body": .string(body)])
            throw OpenAIError.badResponse(status, body)
        }
    }
}

// MARK: - REST payload types

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessageIn]
    let tools: [ChatTool]
    let stream: Bool

    struct ChatMessageIn: Encodable {
        let role: String
        let content: String
    }
}

private struct ChatTool: Encodable {
    let type = "function"
    let function: Function

    struct Function: Encodable {
        let name: String
        let description: String
        let parameters: Parameters
    }

    struct Parameters: Encodable {
        let type = "object"
        let properties: [String: Property]
        let required: [String]
    }

    struct Property: Encodable {
        let type: String
    }

    static let setLEDTool = ChatTool(
        function: .init(
            name: "set_led",
            description: "Set the companion device's LED color",
            parameters: .init(
                properties: ["r": .init(type: "integer"), "g": .init(type: "integer"), "b": .init(type: "integer")],
                required: ["r", "g", "b"]
            )
        )
    )
}

private struct ChatStreamChunk: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let delta: Delta
    }

    struct Delta: Decodable {
        let content: String?
        let toolCalls: [ToolCallDelta]?

        enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCallDelta: Decodable {
        let index: Int
        let function: FunctionDelta?
    }

    struct FunctionDelta: Decodable {
        let name: String?
        let arguments: String?
    }
}

struct SpeechRequest: Encodable {
    let model: String
    let input: String
    let voice: String
    let responseFormat: String

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case voice
        case responseFormat = "response_format"
    }
}
