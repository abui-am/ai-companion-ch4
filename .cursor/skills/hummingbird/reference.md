# Hummingbird CompanionServer Reference

Stable v1 wire protocol and pipeline: [docs/STABLE_V1.md](../../../docs/STABLE_V1.md)

## Codable wire events

```swift
enum MessageType: String, Codable {
    case sessionStart = "session.start"
    case sessionReady = "session.ready"
    case audioStart = "audio.start"
    case audioStop = "audio.stop"
    case abort
    case transcriptFinal = "transcript.final"
    case deviceCommand = "device_command"
    case ttsStart = "tts.start"
    case ttsEnd = "tts.end"
    case error
}

struct SessionStart: Codable {
    let type: String = MessageType.sessionStart.rawValue
    let audio: AudioParams
}

struct AudioParams: Codable {
    let format: String      // "opus"
    let sampleRate: Int     // 16000 uplink
    let frameMs: Int        // 60
}

struct SessionReady: Codable {
    let type: String = MessageType.sessionReady.rawValue
    let sessionId: String
    let audio: AudioParams  // sampleRate 24000 downlink
}

struct DeviceCommand: Codable {
    let type: String = MessageType.deviceCommand.rawValue
    let action: String      // "set_led"
    let params: LEDParams
}

struct LEDParams: Codable {
    let r: Int
    let g: Int
    let b: Int
}
```

Use `CodingKeys` if snake_case on wire (`session_id`, `sample_rate`).

## Session flow

```
1. Client → session.start
2. Server → session.ready (assign sessionId)
3. Client → audio.start
4. Client → binary Opus frames (loop)
5. Client → audio.stop
6. Server → transcript.final
7. Server → device_command (optional, LLM tool)
8. Server → tts.start
9. Server → binary Opus TTS frames
10. Server → tts.end
```

## Pipeline actor sketch

```swift
actor VoicePipeline {
    func processTurn(opusFrames: [Data], session: SessionContext) async throws -> TurnResult {
        let wav = try OpusCodec.decodeToWAV(opusFrames, sampleRate: 16_000)
        let transcript = try await openAI.transcribe(wav)
        let (reply, command) = try await openAI.chat(transcript, tools: [.setLED])
        let mp3 = try await openAI.tts(reply)
        let opusOut = try OpusCodec.encodeFromMP3(mp3, sampleRate: 24_000)
        return TurnResult(transcript: transcript, command: command, opus: opusOut)
    }
}
```

## WebSocket router with typed context

When you need per-request state on upgrade:

```swift
struct CompanionWSContext: WebSocketRequestContext {
    var coreContext: CoreRequestContextStorage
    var sessionID: String?
}

let wsRouter = Router(context: CompanionWSContext.self)
wsRouter.ws("/ws") { request, context in
    guard validateAuth(request) else { return .dontUpgrade }
    return .upgrade([:])
} onUpgrade: { inbound, outbound, context in
    // context available here
}
```

## OpenAI integration notes

| Stage | API | Swift package |
|-------|-----|---------------|
| ASR | `audio/transcriptions` | MacPaw/OpenAI |
| LLM | `chat/completions` + tools | MacPaw/OpenAI |
| TTS | `audio/speech` | MacPaw/OpenAI |

Use `AsyncStream` to pipe TTS bytes into Opus encoder without buffering full MP3.

## ESP32 client expectations

- Connect: `ws://<mac-lan-ip>:8080/ws`
- Header: `Authorization: Bearer <token>`
- Binary frames: raw PCM16 mono LE (wire protocol v1) — 16 kHz uplink, 24 kHz downlink, 60 ms frames, no header
- Push-to-talk: send `audio.stop` on button release

## Hummingbird vs other Swift networking

| Need | Use |
|------|-----|
| WSS server | HummingbirdWebSocket |
| WSS client (TestClient) | URLSessionWebSocketTask |
| LAN device discovery | Network `NWBrowser` (optional, not server) |
| Apple P2P config | MultipeerConnectivity (future iOS, not ESP32) |

## Session disconnect policy

```
WSS close → cancel pipelineTask → cancel URLSessionTasks → delete VoiceSession actor
No TTS buffer replay. Reconnect = new session.start + new session_id.
```

## Abort handling

```
Client abort → pipelineTask.cancel() → cancel OpenAI streams → stop outbound binary
Optional tts.end. Do not send transcript.final for aborted turn.
```

## device_command validation

Whitelist actions (`set_led` only for showcase). Validate `r,g,b` in 0...255 before forwarding. On failure: `error` event, do not send to client.

## latency.report event

```json
{
  "type": "latency.report",
  "session_id": "abc",
  "turn_id": "turn-47",
  "ms": {
    "audio_stop_to_first_downlink": 1102
  },
  "dropped_frames": 0
}
```
