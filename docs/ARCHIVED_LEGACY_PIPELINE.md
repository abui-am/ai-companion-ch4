# Archived: Legacy Pipeline, Cartesia (Sonic), and Kokoro

Removed from `CompanionServer` when the stack was trimmed to **stable v1** (OpenAI Realtime only). Use this document to rebuild the multi-stage pipeline or individual providers.

**Restore source from git** before this prune:

```bash
git show HEAD:CompanionServer/Sources/CompanionServer/CartesiaService.swift
# …etc — or checkout an older commit
```

---

## Architecture (legacy)

```
Client uplink PCM
    → CartesiaSTTService (Ink-Whisper WS)     # or skip via transcript.input
    → OpenAIRESTService.chat (gpt-5-nano SSE)  # + set_led tool
    → TTSStreamingService                      # Cartesia Sonic OR Kokoro MLX
    → DownlinkPacer → WS binary PCM
```

Controlled by `OPENAI_USE_REALTIME=false`. When `true`, `VoiceSession` used `runRealtimeTurn` instead and ignored TTS/STT.

`VoiceSession.runChatAndSpeak` overlapped LLM token streaming with TTS: each chat token was forwarded to `tts.sendTranscriptChunk` while a parallel task consumed `TTSStreamEvent.audio` into `DownlinkPacer`.

---

## Environment variables (legacy)

| Variable | Default | Purpose |
|----------|---------|---------|
| `OPENAI_USE_REALTIME` | `false` | Toggle Realtime vs legacy |
| `TTS_PROVIDER` | `cartesia` | `cartesia` or `kokoro` |
| `CARTESIA_API_KEY` | required | STT + Sonic TTS |
| `CARTESIA_VOICE_ID` | `156fb8d2-…` | Sonic voice UUID |
| `CARTESIA_MODEL_ID` | `sonic-2` | Sonic model |
| `KOKORO_WEIGHTS_DIR` | `.kokoro-models/MLX_GPU` | Local MLX weights |
| `KOKORO_VOICE` | `af_heart` | Kokoro voice name |

`AppConfig.load()` required `CARTESIA_API_KEY` even when Realtime was enabled.

---

## Cartesia Sonic TTS (`CartesiaService.swift`)

**Endpoint:** `wss://api.cartesia.ai/tts/websocket?api_key=…&cartesia_version=2024-06-10`

**Protocol:** `TTSStreamingService`

```swift
protocol TTSStreamingService: Sendable {
    func beginTurn(contextId: String) async -> AsyncStream<TTSStreamEvent>
    func sendTranscriptChunk(_ text: String, contextId: String, isFinal: Bool) async
    func cancelTurn(contextId: String) async
}

enum TTSStreamEvent { case audio(Data); case done; case error(String) }
```

**Outbound request (per chunk):**

```json
{
  "model_id": "sonic-2",
  "transcript": "partial or final text",
  "voice": { "mode": "id", "id": "<CARTESIA_VOICE_ID>" },
  "output_format": {
    "container": "raw",
    "encoding": "pcm_s16le",
    "sample_rate": 24000
  },
  "context_id": "<sessionId>-<turnId>",
  "continue": true
}
```

Set `"continue": false` on final empty chunk to flush.

**Inbound responses:**

| `type` | Fields | Action |
|--------|--------|--------|
| `chunk` | `context_id`, `data` (base64 PCM) | yield `.audio` |
| `done` | `context_id` | yield `.done`, finish stream |
| `error` | `context_id`, `error` | yield `.error` |

**Cancel:** `{"context_id":"…","cancel":true}`

One persistent WS per `CartesiaService` actor; multiplex turns via `context_id`.

---

## Cartesia Ink-Whisper STT (`CartesiaSTTService.swift`)

**Endpoint:** `wss://api.cartesia.ai/stt/websocket?model=ink-whisper&encoding=pcm_s16le&sample_rate=16000&cartesia_version=2026-03-01&language=en`

**Header:** `X-API-Key: <CARTESIA_API_KEY>`

**Flow:**

1. `connect()` — open WS at session start
2. `sendAudio(Data)` — send raw binary PCM frames as captured
3. `finalize()` — send text `"finalize"`, wait for `flush_done`/`done`, return joined `transcript` chunks where `is_final=true`
4. `close()` — send `"close"`, cancel socket

**Inbound:**

```json
{ "type": "transcript", "is_final": true, "text": "…" }
{ "type": "flush_done" }
```

One WS per `VoiceSession` (not shared across sessions).

---

## OpenAI REST (`OpenAIService.swift`)

### Chat (streaming SSE)

- `POST https://api.openai.com/v1/chat/completions`
- Model: `gpt-5-nano`
- System: `CompanionPrompt.system`
- Tools: `set_led` → `DeviceCommand` via `CmdRouter.validate`
- Stream: parse `data: ` lines, accumulate `delta.content` and `tool_calls`

### Speech (non-streaming)

- `POST https://api.openai.com/v1/audio/speech`
- Body: `{ "model": "tts-1", "input": "…", "voice": "alloy", "response_format": "pcm" }`
- Used by benchmarks; production legacy path used Cartesia/Kokoro instead

---

## Kokoro local TTS (`KokoroTTSService.swift`)

**Dependency:** `Vendor/kokoro-swift` (SwiftPM path package), product `Kokoro`.

**Weights layout** (`KOKORO_WEIGHTS_DIR`):

```
config.json
kokoro-v1_0.safetensors
voices/
  af_heart.pt   # etc.
```

Download from [mweinbach/Kokoro-82M-Swift](https://huggingface.co/mweinbach/Kokoro-82M-Swift) on HuggingFace.

**Load:**

```swift
let model = try KModel(configURL: configURL, weightsURL: weightsURL)
let voices = VoiceLoader(baseDirectory: voicesDir, enableDownload: true)
let pipeline = KPipeline(model: model, voices: voices)
let result = try pipeline.synthesize(text: text, voice: voice) // blocking
```

**PCM extraction:** strip 44-byte WAV header from `AudioWriter.wavData(samples:sampleRate:)`.

**Streaming strategy:** sentence-buffer — accumulate LLM tokens until `.!?` terminator, synthesize each sentence, emit `.audio`. Final remainder on `isFinal`.

**Build note:** MLX Metal shaders require `xcodebuild`, not plain `swift run`.

---

## VoiceSession integration (removed paths)

| Method | Trigger | Pipeline |
|--------|---------|----------|
| `runPipeline` | `audio.stop` (no Realtime) | STT finalize → chat+speak |
| `runPipelineFromTranscript` | `transcript.input` JSON | skip STT → chat+speak |
| `runChatAndSpeak` | shared | parallel LLM stream + TTS stream |
| `runRealtimeTurn` | `audio.stop` (Realtime) | **kept in v1** |

`latency.report` was emitted at end of `runChatAndSpeak` with stage timings (`audio_stop_to_asr_done`, etc.). Realtime path did not emit `latency.report`.

---

## OpusCodec (`OpusCodec.swift`)

Placeholder — chunked raw PCM into 60 ms frames. No libopus. Label `"opus"` in wire JSON was forward-compatible naming only.

---

## Standalone tools (removed targets)

### `TTSBenchmark`

Compared Cartesia vs Kokoro on same text: decode m4a → Cartesia STT → OpenAI chat → cold/warm TTS runs each. Wrote `benchmark-cartesia.wav` and `benchmark-kokoro.wav`.

```bash
swift run TTSBenchmark benchmark_input.m4a
```

### `RealtimePipeline`

CLI proof-of-concept for OpenAI Realtime GA (file → WAV). Predated `OpenAIRealtimeService` integration.

```bash
swift run RealtimePipeline benchmark_input.m4a gpt-realtime-mini verse
```

### `SpeakerBenchmark`

Prerecorded uplink to `/ws` while TestFirmware listens on `/speaker` — E2E downlink without live mic.

```bash
swift run SpeakerBenchmark [audio.m4a]
```

### `KokoroSmokeTest`

```bash
swift run KokoroSmokeTest .kokoro-models/MLX_GPU af_heart "Hello"
```

---

## Package.swift (legacy)

```swift
dependencies: [
    .package(path: "Vendor/kokoro-swift"),
],
// CompanionServer target also linked Kokoro
products: [
    .executable(name: "TTSBenchmark", …),
    .executable(name: "RealtimePipeline", …),
    .executable(name: "SpeakerBenchmark", …),
],
targets: [
    .executableTarget(name: "KokoroSmokeTest", dependencies: ["Kokoro"]),
]
```

---

## Rebuild checklist

1. Restore Swift files listed above from git history
2. Re-add `Vendor/kokoro-swift` (submodule or `git clone` into `CompanionServer/Vendor/`)
3. Restore `Package.swift` targets and Kokoro dependency
4. Re-add env vars to `AppConfig` and `.env.example`
5. Restore `VoiceSession` legacy branches and `CompanionServerApp` TTS/STT wiring
6. Re-enable `OPENAI_USE_REALTIME` toggle if you want both paths
7. Run `swift build` (Kokoro: use `xcodebuild` for Metal)

---

## Why removed

Stable v1 uses a single OpenAI Realtime WebSocket per session. Cartesia and Kokoro added ~2k lines, a vendored TTS model tree, and API keys that v1 never called at runtime.
