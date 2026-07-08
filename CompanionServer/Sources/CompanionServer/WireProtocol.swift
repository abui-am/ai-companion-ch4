import Foundation

/// Wire protocol v1 — see `docs/STABLE_V1.md` and `CompanionStack.protocolVersion`.
enum MessageType: String, Codable {
    case sessionStart = "session.start"
    case sessionReady = "session.ready"
    case speakerReady = "speaker.ready"
    case audioStart = "audio.start"
    case audioStop = "audio.stop"
    case transcriptInput = "transcript.input"
    case abort
    case transcriptFinal = "transcript.final"
    case deviceCommand = "device_command"
    case ttsStart = "tts.start"
    case ttsEnd = "tts.end"
    case toolStart = "tool.start"
    case toolDone = "tool.done"
    case error
    case latencyReport = "latency.report"
}

struct AudioParams: Codable {
    let format: String
    let sampleRate: Int
    let frameMs: Int

    enum CodingKeys: String, CodingKey {
        case format
        case sampleRate = "sample_rate"
        case frameMs = "frame_ms"
    }

    static let uplink = AudioParams(format: "opus", sampleRate: 16_000, frameMs: 60)
    static let downlink = AudioParams(format: "pcm", sampleRate: 24_000, frameMs: 60)
}

// MARK: - Inbound

struct InboundEnvelope: Codable {
    let type: MessageType
}

struct SessionStart: Codable {
    let type: MessageType
    let audio: AudioParams
    let mode: String?
    let language: String?

    enum CodingKeys: String, CodingKey {
        case type
        case audio
        case mode
        case language
    }
}

struct AbortMessage: Codable {
    let type: MessageType
    let sessionId: String
    let reason: String

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case reason
    }
}

struct TranscriptInput: Codable {
    let type: MessageType
    let text: String
}

// MARK: - Outbound

struct SessionReady: Codable {
    var type: MessageType = .sessionReady
    let sessionId: String
    let audio: AudioParams

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case audio
    }
}

struct SpeakerReady: Codable {
    var type: MessageType = .speakerReady
}

struct TranscriptFinal: Codable {
    var type: MessageType = .transcriptFinal
    let sessionId: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case text
    }
}

struct LEDParams: Codable, Sendable {
    let r: Int?
    let g: Int?
    let b: Int?
    let pattern: String?
    let durationMs: Int?

    enum CodingKeys: String, CodingKey {
        case r
        case g
        case b
        case pattern
        case durationMs = "duration_ms"
    }

    init(r: Int? = nil, g: Int? = nil, b: Int? = nil, pattern: String? = nil, durationMs: Int? = nil) {
        self.r = r
        self.g = g
        self.b = b
        self.pattern = pattern
        self.durationMs = durationMs
    }
}

struct DeviceCommand: Codable, Sendable {
    var type: MessageType = .deviceCommand
    let action: String
    let params: LEDParams
}

struct TTSStart: Codable {
    var type: MessageType = .ttsStart
    let sessionId: String

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
    }
}

struct TTSEnd: Codable {
    var type: MessageType = .ttsEnd
    let sessionId: String

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
    }
}

/// Sent when a sub-agent lookup begins, so a companion app can show "Checking your
/// calendar…" while the model waits on `tasks`/`calendar`/`web_search`. See `ToolDone`
/// for the completed result, and `ConversationToolCallBuilder.label` for `label` text.
struct ToolStart: Codable {
    var type: MessageType = .toolStart
    let sessionId: String
    let turnId: String
    let tool: String
    let label: String

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case turnId = "turn_id"
        case tool
        case label
    }
}

/// Sent when a sub-agent lookup completes. `call` is the same structured object returned by
/// `GET /conversations/{id}/history`, so clients can share one rendering path for both.
struct ToolDone: Codable {
    var type: MessageType = .toolDone
    let sessionId: String
    let turnId: String
    let call: StructuredToolCall

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case turnId = "turn_id"
        case call
    }
}

struct ErrorMessage: Codable {
    var type: MessageType = .error
    let code: String
    let message: String?
}

struct LatencyMs: Codable {
    let audioStopToAsrDone: Int
    let asrDoneToLlmFirstToken: Int
    let llmFirstTokenToTtsFirstByte: Int
    let ttsFirstByteToWsSent: Int
    let audioStopToFirstDownlink: Int
    let audioStopToFirstTtsAudioChunk: Int

    enum CodingKeys: String, CodingKey {
        case audioStopToAsrDone = "audio_stop_to_asr_done"
        case asrDoneToLlmFirstToken = "asr_done_to_llm_first_token"
        case llmFirstTokenToTtsFirstByte = "llm_first_token_to_tts_first_byte"
        case ttsFirstByteToWsSent = "tts_first_byte_to_ws_sent"
        case audioStopToFirstDownlink = "audio_stop_to_first_downlink"
        case audioStopToFirstTtsAudioChunk = "audio_stop_to_first_tts_audio_chunk"
    }
}

struct LatencyReport: Codable {
    var type: MessageType = .latencyReport
    let sessionId: String
    let turnId: String
    let ms: LatencyMs
    let droppedFrames: Int

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case turnId = "turn_id"
        case ms
        case droppedFrames = "dropped_frames"
    }
}
