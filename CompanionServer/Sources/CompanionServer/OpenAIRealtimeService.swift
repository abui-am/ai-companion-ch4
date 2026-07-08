import CompanionDatabase
import Foundation
import Logging

enum RealtimeAudioEvent: Sendable {
    case audio(Data)               // PCM16 @ 24 kHz chunk from response
    case inputTranscript(String)   // completed user-speech transcript
    case assistantTranscript(String) // incremental assistant text delta
    case toolCallStarted(name: String, detail: String)
    case toolCallCompleted(name: String, detail: String, argumentsJSON: String, output: String)
    case done
    case error(String)
}

/// Manages a persistent WebSocket connection to the OpenAI Realtime API.
/// One instance is shared across turns of the same VoiceSession.
///
/// Turn flow:
///   1. `connect()` — called once on session start.
///   2. `appendAudioFrame(_:)` / `appendAudioFrames(_:)` — called while capturing.
///      Frames are upsampled 16 kHz → 24 kHz before being sent.
///   3. `commitAndCreateResponse()` — called on audio.stop; returns an
///      AsyncStream that emits audio chunks then `.done`.
///   4. `cancelResponse()` — called on abort.
///   5. `close()` — called on session disconnect.
actor OpenAIRealtimeService {
    private static let sampleRate = 24_000
    private static let maxToolRoundsPerTurn = 5

    private let apiKey: String
    private let model: String
    private let voice: String
    private let textOnlyOutput: Bool
    private var responseLanguage: String
    private var personality: ConfigPersonality
    private var timeZone: TimeZone
    private var memoryContext: String?
    private let subAgents: SubAgentRegistry
    private let logger: Logger

    private var socket: URLSessionWebSocketTask?
    private var eventLoopTask: Task<Void, Never>?
    private var turnContinuation: AsyncStream<RealtimeAudioEvent>.Continuation?
    private var toolCallTask: Task<Void, Never>?
    private var toolCallRoundsThisTurn = 0
    private var executedToolCallsThisTurn: Set<String> = []
    /// Set from `response.created` after each `response.create`; `response.done` is
    /// ignored unless it matches, so a stale done from a prior turn cannot close
    /// the current AsyncStream before audio deltas arrive.
    private var activeTurnResponseId: String?

    init(
        apiKey: String,
        model: String,
        voice: String,
        responseLanguage: String = "English",
        personality: ConfigPersonality = .calm,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        textOnlyOutput: Bool = false,
        subAgents: SubAgentRegistry = SubAgentRegistry(agents: []),
        logger: Logger
    ) {
        self.apiKey = apiKey
        self.model = model
        self.voice = voice
        self.responseLanguage = responseLanguage
        self.personality = personality
        self.timeZone = CompanionTimezone.resolve(identifier: timeZoneIdentifier)
        self.textOnlyOutput = textOnlyOutput
        self.subAgents = subAgents
        self.logger = logger
    }

    // MARK: - Lifecycle

    func connect() async {
        if let existing = socket, existing.state == .running { return }
        socket?.cancel(with: .normalClosure, reason: nil)

        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(model)")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        logger.info("realtime connect", metadata: ["model": .string(model)])

        do {
            try await waitForEvent("session.created", on: task)
            logger.info("realtime session.created", metadata: ["model": .string(model)])

            try await sendJSON(sessionUpdatePayload())
            try await waitForEvent("session.updated", on: task)
            logger.info("realtime session configured", metadata: ["voice": .string(voice)])
        } catch {
            logger.error("realtime connect failed", metadata: ["error": .string("\(error)")])
            task.cancel(with: .abnormalClosure, reason: nil)
            socket = nil
            return
        }

        startEventLoop()
    }

    func setResponseLanguage(_ language: String) async {
        responseLanguage = language
        guard let socket, socket.state == .running else { return }
        do {
            try await sendJSON(sessionUpdatePayload())
            logger.info("realtime response language updated", metadata: ["language": .string(language)])
        } catch {
            logger.error(
                "realtime response language update failed",
                metadata: ["language": .string(language), "error": .string("\(error)")]
            )
        }
    }

    func setPersonality(_ personality: ConfigPersonality) async {
        self.personality = personality
        guard let socket, socket.state == .running else { return }
        do {
            try await sendJSON(sessionUpdatePayload())
            logger.info("realtime personality updated", metadata: ["personality": .string(personality.rawValue)])
        } catch {
            logger.error(
                "realtime personality update failed",
                metadata: ["personality": .string(personality.rawValue), "error": .string("\(error)")]
            )
        }
    }

    func refreshTimeContext() async {
        guard let socket, socket.state == .running else { return }
        do {
            try await sendJSON(sessionUpdatePayload())
            logger.info(
                "realtime time context refreshed",
                metadata: ["timezone": .string(timeZone.identifier)]
            )
        } catch {
            logger.error(
                "realtime time context refresh failed",
                metadata: ["timezone": .string(timeZone.identifier), "error": .string("\(error)")]
            )
        }
    }

    /// Injects recent memories into the system prompt at session start — read-only, no
    /// embedding cost. Tool-driven writes/search are unaffected; see `MemoryAgent`.
    func refreshMemoryContext(memories: [MemoryRecord]) async {
        memoryContext = Self.formatMemoryContext(memories)
        guard let socket, socket.state == .running else {
            logger.debug(
                "realtime memory context staged — socket not ready yet",
                metadata: ["count": "\(memories.count)"]
            )
            return
        }
        do {
            try await sendJSON(sessionUpdatePayload())
            logger.info("realtime memory context refreshed", metadata: ["count": "\(memories.count)"])
        } catch {
            logger.error(
                "realtime memory context refresh failed",
                metadata: ["error": .string("\(error)")]
            )
        }
    }

    private static func formatMemoryContext(_ memories: [MemoryRecord]) -> String? {
        guard !memories.isEmpty else { return nil }
        return memories.map { "- \($0.content)" }.joined(separator: "\n")
    }

    func setTimeZone(_ identifier: String) async {
        timeZone = CompanionTimezone.resolve(identifier: identifier)
        guard let socket, socket.state == .running else { return }
        do {
            try await sendJSON(sessionUpdatePayload())
            logger.info("realtime timezone updated", metadata: ["timezone": .string(timeZone.identifier)])
        } catch {
            logger.error(
                "realtime timezone update failed",
                metadata: ["timezone": .string(timeZone.identifier), "error": .string("\(error)")]
            )
        }
    }

    func close() async {
        eventLoopTask?.cancel()
        eventLoopTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        finishTurn(with: nil)
    }

    // MARK: - Turn control

    /// Appends one 60 ms uplink PCM frame (16 kHz, 16-bit mono).
    func appendAudioFrame(_ data: Data) async {
        await appendAudioFrames([data])
    }

    /// Appends multiple consecutive uplink frames in one Realtime API message.
    func appendAudioFrames(_ frames: [Data]) async {
        guard !frames.isEmpty else { return }
        var combined = Data()
        combined.reserveCapacity(frames.count * frames[0].count * 3 / 2)
        for frame in frames {
            combined.append(upsample16kTo24k(frame))
        }
        try? await sendJSON([
            "type": "input_audio_buffer.append",
            "audio": combined.base64EncodedString(),
        ])
    }

    /// Commits buffered audio and creates a response.
    /// Returns a stream that emits audio events and ends with `.done` or `.error`.
    func commitAndCreateResponse() async -> AsyncStream<RealtimeAudioEvent> {
        let (stream, continuation) = AsyncStream<RealtimeAudioEvent>.makeStream()
        guard let socket, socket.state == .running else {
            logger.error("commitAndCreateResponse: socket not connected (state=\(String(describing: socket?.state)))")
            continuation.yield(.error("realtime socket not connected"))
            continuation.finish()
            return stream
        }
        logger.info("commitAndCreateResponse: socket ok, sending commit+response.create")
        activeTurnResponseId = nil
        turnContinuation = continuation
        toolCallRoundsThisTurn = 0
        executedToolCallsThisTurn = []
        try? await sendJSON(["type": "input_audio_buffer.commit"])
        try? await sendJSON(responseCreatePayload())
        return stream
    }

    func cancelResponse() async {
        toolCallTask?.cancel()
        toolCallTask = nil
        // Only OpenAI has anything to cancel once response.created has set
        // activeTurnResponseId — e.g. a device abort before audio.stop was
        // ever sent (no commitAndCreateResponse call yet) has no in-flight
        // response, and response.cancel would just log a spurious
        // "Cancellation failed: no active response found" API error.
        if activeTurnResponseId != nil {
            try? await sendJSON(["type": "response.cancel"])
        }
        finishTurn(with: nil)
    }

    // MARK: - Event loop

    private func startEventLoop() {
        eventLoopTask?.cancel()
        guard let socket else { return }
        eventLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let msg = try await socket.receive()
                    if case .string(let text) = msg {
                        await self?.handleEvent(text)
                    }
                } catch {
                    guard !Task.isCancelled else { break }
                    self?.logger.error("realtime recv error", metadata: ["error": "\(error)"])
                    await self?.finishTurn(with: .error("WebSocket closed: \(error)"))
                    break
                }
            }
        }
    }

    private func handleEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        switch type {
        case "session.created", "session.updated":
            logger.debug("realtime [\(type)]")

        case "conversation.item.input_audio_transcription.completed":
            if let t = json["transcript"] as? String, !t.isEmpty {
                logger.info("realtime input transcript", metadata: ["text": .string(t)])
                turnContinuation?.yield(.inputTranscript(t))
            }

        case "response.created":
            if let response = json["response"] as? [String: Any],
               let id = response["id"] as? String
            {
                activeTurnResponseId = id
                logger.debug("realtime response.created", metadata: ["response_id": .string(id)])
            } else {
                logger.debug("realtime [response.created]")
            }

        case "response.audio.delta", "response.output_audio.delta":
            guard !textOnlyOutput else { break }
            let b64 = (json["audio"] as? String) ?? (json["delta"] as? String)
            if let b64, let chunk = Data(base64Encoded: b64) {
                turnContinuation?.yield(.audio(chunk))
            }

        case "response.audio_transcript.delta", "response.output_audio_transcript.delta":
            if let delta = json["delta"] as? String, !delta.isEmpty {
                turnContinuation?.yield(.assistantTranscript(delta))
            }

        case "response.output_text.delta":
            if let delta = json["delta"] as? String, !delta.isEmpty {
                turnContinuation?.yield(.assistantTranscript(delta))
            }

        case "response.done":
            let doneId = (json["response"] as? [String: Any])?["id"] as? String
            guard let activeTurnResponseId else {
                logger.warning(
                    "ignoring response.done before response.created for this turn",
                    metadata: ["response_id": .string(doneId ?? "unknown")]
                )
                break
            }
            if let doneId, doneId != activeTurnResponseId {
                logger.warning(
                    "ignoring response.done with mismatched id",
                    metadata: [
                        "active_response_id": .string(activeTurnResponseId),
                        "done_response_id": .string(doneId),
                    ]
                )
                break
            }
            logger.info("realtime response.done", metadata: ["response_id": .string(activeTurnResponseId)])
            self.activeTurnResponseId = nil
            if let response = json["response"] as? [String: Any],
               let calls = Self.extractFunctionCalls(from: response),
               !calls.isEmpty,
               !subAgents.isEmpty
            {
                toolCallRoundsThisTurn += 1
                logger.info(
                    "realtime tool round",
                    metadata: [
                        "round": "\(toolCallRoundsThisTurn)",
                        "calls": "\(calls.count)",
                        "tools": .string(calls.map(\.name).joined(separator: ",")),
                    ]
                )
                if toolCallRoundsThisTurn > Self.maxToolRoundsPerTurn {
                    logger.warning(
                        "realtime tool round cap exceeded",
                        metadata: ["max_rounds": "\(Self.maxToolRoundsPerTurn)"]
                    )
                    finishTurn(with: .error("Too many tool calls this turn"))
                    return
                }
                toolCallTask?.cancel()
                toolCallTask = Task { [weak self] in
                    await self?.handleFunctionCalls(calls)
                }
            } else {
                finishTurn(with: .done)
            }

        case "error":
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? text
            logger.error("realtime api error", metadata: ["msg": .string(msg)])
            finishTurn(with: .error(msg))

        default:
            logger.debug("realtime [\(type)] (unhandled)")
        }
    }

    private func finishTurn(with event: RealtimeAudioEvent?) {
        if let event { turnContinuation?.yield(event) }
        turnContinuation?.finish()
        turnContinuation = nil
    }

    // MARK: - Helpers

    private func sessionUpdatePayload() -> [String: Any] {
        var audio: [String: Any] = [
            "input": [
                "format": ["type": "audio/pcm", "rate": Self.sampleRate],
                "turn_detection": NSNull(),
                "transcription": ["model": "whisper-1"],
            ] as [String: Any],
        ]
        if !textOnlyOutput {
            audio["output"] = [
                "format": ["type": "audio/pcm", "rate": Self.sampleRate],
                "voice": voice,
            ]
        }

        let session: [String: Any] = {
            var s: [String: Any] = [
                "type": "realtime",
                "instructions": CompanionPrompt.system(
                    responseLanguage: responseLanguage,
                    personality: personality,
                    timeZone: timeZone,
                    memoryContext: memoryContext
                ),
                "output_modalities": textOnlyOutput ? ["text"] : ["audio"],
                "audio": audio,
            ]
            if !subAgents.isEmpty {
                s["tools"] = subAgents.toolDefinitions
                s["tool_choice"] = "auto"
            }
            return s
        }()

        return [
            "type": "session.update",
            "session": session,
        ]
    }

    private struct PendingFunctionCall: Sendable {
        let name: String
        let callId: String
        let argumentsJSON: String
    }

    private static func extractFunctionCalls(from response: [String: Any]) -> [PendingFunctionCall]? {
        guard let output = response["output"] as? [[String: Any]] else { return nil }
        let calls = output.compactMap { item -> PendingFunctionCall? in
            guard item["type"] as? String == "function_call",
                  let name = item["name"] as? String,
                  let callId = item["call_id"] as? String,
                  let args = item["arguments"] as? String
            else { return nil }
            return PendingFunctionCall(name: name, callId: callId, argumentsJSON: args)
        }
        return calls.isEmpty ? nil : calls
    }

    private func handleFunctionCalls(_ calls: [PendingFunctionCall]) async {
        guard turnContinuation != nil else { return }

        for call in calls {
            guard !Task.isCancelled, turnContinuation != nil else { return }

            let detail = ConversationToolCallBuilder.label(name: call.name, argumentsJSON: call.argumentsJSON)

            let dedupeKey = Self.toolCallDedupeKey(name: call.name, argumentsJSON: call.argumentsJSON)
            if let dedupeKey, executedToolCallsThisTurn.contains(dedupeKey) {
                logger.info(
                    "skipping duplicate tool call",
                    metadata: ["name": .string(call.name), "key": .string(dedupeKey)]
                )
                let outputString = Self.encodeJSON(["summary": ConversationToolCallBuilder.duplicateSummary])
                try? await sendJSON([
                    "type": "conversation.item.create",
                    "item": [
                        "type": "function_call_output",
                        "call_id": call.callId,
                        "output": outputString,
                    ],
                ])
                turnContinuation?.yield(
                    .toolCallCompleted(name: call.name, detail: detail, argumentsJSON: call.argumentsJSON, output: outputString)
                )
                continue
            }
            if let dedupeKey {
                executedToolCallsThisTurn.insert(dedupeKey)
            }

            guard let agent = subAgents.agent(named: call.name) else {
                logger.warning("unknown function call", metadata: ["name": .string(call.name)])
                let outputString = Self.encodeJSON(["error": "tool not available"])
                try? await sendJSON([
                    "type": "conversation.item.create",
                    "item": [
                        "type": "function_call_output",
                        "call_id": call.callId,
                        "output": outputString,
                    ],
                ])
                turnContinuation?.yield(
                    .toolCallCompleted(name: call.name, detail: detail, argumentsJSON: call.argumentsJSON, output: outputString)
                )
                continue
            }

            turnContinuation?.yield(.toolCallStarted(name: call.name, detail: detail))
            logger.info("realtime tool call", metadata: ["name": .string(call.name), "detail": .string(detail)])

            let outputString = await agent.execute(argumentsJSON: call.argumentsJSON)

            guard !Task.isCancelled, turnContinuation != nil else { return }

            try? await sendJSON([
                "type": "conversation.item.create",
                "item": [
                    "type": "function_call_output",
                    "call_id": call.callId,
                    "output": outputString,
                ],
            ])
            turnContinuation?.yield(
                .toolCallCompleted(name: call.name, detail: detail, argumentsJSON: call.argumentsJSON, output: outputString)
            )
        }

        guard !Task.isCancelled, turnContinuation != nil else { return }
        activeTurnResponseId = nil
        try? await sendJSON(responseCreatePayload())
    }

    private static func toolCallDedupeKey(name: String, argumentsJSON: String) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if name == "web_search",
           let query = args["query"] as? String
        {
            let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { return nil }
            return "web_search:\(normalized)"
        }

        if name == "memory",
           let action = args["action"] as? String
        {
            switch action {
            case "remember":
                if let content = args["content"] as? String {
                    let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !normalized.isEmpty else { return nil }
                    return "memory:remember:\(normalized)"
                }
            case "search", "forget":
                if let query = args["query"] as? String {
                    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !normalized.isEmpty else { return nil }
                    return "memory:\(action):\(normalized)"
                }
            default:
                break
            }
        }

        return nil
    }

    private static func encodeJSON(_ payload: [String: String]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let string = String(data: data, encoding: .utf8)
        {
            return string
        }
        return payload["summary"] ?? payload["error"] ?? "{}"
    }

    private func responseCreatePayload() -> [String: Any] {
        if textOnlyOutput {
            return [
                "type": "response.create",
                "response": ["output_modalities": ["text"]],
            ]
        }
        return ["type": "response.create"]
    }

    private func waitForEvent(_ wanted: String, on task: URLSessionWebSocketTask) async throws {
        while true {
            let raw = try await task.receive()
            guard case .string(let text) = raw,
                  let data = text.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String
            else { continue }

            if type == "error" {
                let msg = (json["error"] as? [String: Any])?["message"] as? String ?? text
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: msg])
            }
            if type == wanted { return }
            logger.debug("realtime [\(type)] (during connect)")
        }
    }

    private func sendJSON(_ json: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        try await socket?.send(.string(String(decoding: data, as: UTF8.self)))
    }

    /// Linear-interpolation upsample from 16 kHz to 24 kHz (ratio 3:2).
    /// For each 960-sample input frame (60 ms) produces 1440 output samples.
    private func upsample16kTo24k(_ data: Data) -> Data {
        let inCount = data.count / MemoryLayout<Int16>.size
        guard inCount > 0 else { return Data() }
        let outCount = inCount * 3 / 2
        var output = [Int16](repeating: 0, count: outCount)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for k in 0..<outCount {
                let srcPos = Double(k) * 2.0 / 3.0
                let lo = Int(srcPos)
                let hi = min(lo + 1, inCount - 1)
                let frac = srcPos - Double(lo)
                let val = Double(src[lo]) * (1.0 - frac) + Double(src[hi]) * frac
                output[k] = Int16(max(Double(Int16.min), min(Double(Int16.max), val.rounded())))
            }
        }
        return output.withUnsafeBytes { Data($0) }
    }
}
