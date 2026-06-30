import Foundation
import Logging

struct ChatToolResult {
    let reply: String
    let command: DeviceCommand?
}

protocol OpenAIService: Sendable {
    func transcribe(wav: Data) async throws -> String
    func chat(transcript: String) async throws -> ChatToolResult
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

    func transcribe(wav: Data) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        logger.debug("HTTP POST /v1/audio/transcriptions", metadata: ["wav_bytes": "\(wav.count)", "model": "whisper-1"])
        var request = authorizedRequest(url: url)
        request.httpMethod = "POST"
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField("model", "whisper-1")
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        logger.debug("HTTP response /v1/audio/transcriptions", metadata: ["status": "\(status)", "bytes": "\(data.count)"])
        try Self.checkStatus(response, data, logger: logger)
        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return decoded.text
    }

    func chat(transcript: String) async throws -> ChatToolResult {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        logger.debug(
            "HTTP POST /v1/chat/completions",
            metadata: ["model": "gpt-4o-mini", "transcript_chars": "\(transcript.count)"]
        )
        var request = authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ChatRequest(
            model: "gpt-4o-mini",
            messages: [.init(role: "user", content: transcript)],
            tools: [.setLEDTool]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        logger.debug("HTTP response /v1/chat/completions", metadata: ["status": "\(status)", "bytes": "\(data.count)"])
        try Self.checkStatus(response, data, logger: logger)
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let choice = decoded.choices.first else {
            logger.warning("chat completion returned no choices")
            return ChatToolResult(reply: "", command: nil)
        }

        var command: DeviceCommand?
        if let toolCall = choice.message.toolCalls?.first,
           let argsData = toolCall.function.arguments.data(using: .utf8),
           let params = try? JSONDecoder().decode(LEDParams.self, from: argsData) {
            command = DeviceCommand(action: "set_led", params: params)
            logger.debug(
                "chat tool call",
                metadata: ["name": .string(toolCall.function.name), "arguments": .string(toolCall.function.arguments)]
            )
        }

        return ChatToolResult(reply: choice.message.content ?? "", command: command)
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

private struct TranscriptionResponse: Decodable {
    let text: String
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessageIn]
    let tools: [ChatTool]

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

private struct ChatResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
        let toolCalls: [ToolCall]?

        enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCall: Decodable {
        let function: FunctionCall
    }

    struct FunctionCall: Decodable {
        let name: String
        let arguments: String
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
