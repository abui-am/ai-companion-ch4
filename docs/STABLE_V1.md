# Stable v1 — AI Companion Stack

This document is the canonical reference for **stack v1**: the current working configuration used for showcase and hardware testing. When someone says “run v1” or “stable stack,” they mean the settings and behaviors described here.

**Stable as of 2026-07-06:** tap-to-talk + hands-free adaptive VAD (no on-device wake word). See [§ Client VAD (stable)](#client-vad-stable).

**Code anchors:** `CompanionStack.protocolVersion` / `CompanionStack.pipelineProfile` (Swift), `COMPANION_PROTOCOL_VERSION` (firmware), VAD constants in `ws_session.cpp`.

---

## What “v1” means 
|      Layer     |     v1 identifier      |        Summary       |
|----------------|------------------------|----------------------|
| **Pipeline profile** | `v1` | OpenAI Realtime API — single WebSocket round-trip for speech-in / speech-out |
| **Wire protocol** | `v1` | JSON events on text frames; raw 16-bit PCM on binary frames (no per-frame header) |
| **Firmware (split test)** | TestFirmware **v1** | Mac mic on `/ws` → server → ESP speaker on `/speaker` |
| **Firmware (integrated)** | CompanionFirmware **v2** | ESP mic + speaker on one `/ws` session; **tap + client VAD** (stable) |

The server runs **only** the OpenAI Realtime pipeline. Legacy multi-stage paths (Cartesia Sonic/Kokoro TTS, Cartesia STT, REST chat) were removed — rebuild guide: [ARCHIVED_LEGACY_PIPELINE.md](ARCHIVED_LEGACY_PIPELINE.md).

---

## Pipeline v1

Each turn:

1. Uplink PCM frames are upsampled 16 kHz → 24 kHz and appended to the OpenAI Realtime input buffer.
2. On `audio.stop`, the server commits audio and calls `response.create`.
3. Downlink PCM chunks from Realtime are paced at 60 ms/frame and sent as WS binary.

### v1 defaults (`.env`)

| Variable | Stable value | Notes |
|----------|--------------|-------|
| `OPENAI_REALTIME_MODEL` | `gpt-realtime-mini` | GA Realtime model (no `OpenAI-Beta` header) |
| `OPENAI_REALTIME_VOICE` | `verse` | Output voice |
| `DEVICE_TOKEN` | *(shared secret)* | Bearer token for WSS upgrade |
| `OPENAI_API_KEY` | *(required)* | Realtime API |

Copy `CompanionServer/.env.example` and fill secrets before running.

### OpenAI Realtime (GA shape)

- Endpoint: `wss://api.openai.com/v1/realtime?model=<OPENAI_REALTIME_MODEL>`
- Auth: `Authorization: Bearer <OPENAI_API_KEY>` only (no beta header)
- Session: `type: "realtime"`, `audio.input` / `audio.output` at **24 kHz PCM**
- Server VAD: disabled (`turn_detection: null`) — **client adaptive VAD** sends `audio.stop` at end-of-speech (not hold-to-talk)
- Input transcription: `whisper-1` (emits `transcript.final` to client)
- System prompt: `CompanionPrompt.system` (“Botchill”)

Implementation: `OpenAIRealtimeService.swift`, turn orchestration: `VoiceSession.runRealtimeTurn`.

---

## Wire protocol v1

### Transport

| Item | Value |
|------|-------|
| URL | `ws://<host>:8080/ws` (primary), `ws://<host>:8080/speaker` (TTS mirror) |
| Auth | `Authorization: Bearer <DEVICE_TOKEN>` on upgrade |
| Text frames | UTF-8 JSON control events |
| Binary frames | Raw audio payload — **no length prefix, no codec header** |

### Audio parameters

Declared in `session.start` / `session.ready` as `audio.format` (legacy label `"opus"` for forward compatibility). **Actual payload is raw PCM** until libopus is integrated.

| Direction | Sample rate | Frame duration | Frame size | Encoding |
|-----------|-------------|----------------|------------|----------|
| Uplink | 16 kHz | 60 ms | 1 920 bytes | PCM16 mono LE |
| Downlink | 24 kHz | 60 ms | 2 880 bytes | PCM16 mono LE |

Constants: `AudioParams` (Swift), `COMPANION_*` in `firmware/*/protocol.h`.

### JSON events

**Inbound:** `session.start`, `audio.start`, `audio.stop`, `abort`

**Outbound:** `session.ready`, `transcript.final`, `device_command`, `tts.start`, `tts.end`, `tool.start`, `tool.done`, `error`, `speaker.ready` (`/speaker` only)

`transcript.input` is rejected with `error` (`unsupported_event`) — use audio uplink.

Full schemas: `WireProtocol.swift`, `firmware/*/protocol.h`, `.cursor/skills/hummingbird/reference.md`.

#### Tool call events

Sent when the model invokes a sub-agent (`tasks`, `calendar`, `web_search`) mid-turn. Firmware ignores unknown JSON types, so these are safe to add without a firmware update; companion apps can use them to show live tool activity (e.g. "Checking your calendar…").

- `tool.start` — `{ session_id, turn_id, tool, label }`, sent when the lookup begins.
- `tool.done` — `{ session_id, turn_id, call }`, sent when it completes. `call` is the same structured object (`id`, `tool`, `action`, `label`, `status`, `input`, `output`, `summary`, `createdAt`) returned by `GET /api/v1/conversations/{id}/history` — see [CONVERSATION_API.md](CONVERSATION_API.md).

Persisted alongside transcripts when `privacy.personalizationData` is on. Implementation: `OpenAIRealtimeService.handleFunctionCalls` (executes the tool call), `VoiceSession` (emits the WebSocket events and persists), `ConversationToolCallBuilder` (shared label/status logic).

### Session lifecycle (v1 policy)

- **Disconnect:** cancel pipeline, close Realtime socket, discard unsent downlink — no resume
- **Reconnect:** new `session.start` → new `session_id`
- **Abort:** cancel Realtime response, stop downlink pacer, send `tts.end`
- **Backpressure:** `DownlinkPacer` leaky-bucket at real-time rate; speaker clients get initial burst of 12 frames

---

## Server

- **Runtime:** macOS 15+, Swift 6, Hummingbird 2
- **Start:** `cd CompanionServer && swift run CompanionServer`
- **Health:** `GET /health` → `ok`, `GET /ping` → `pong`
- **Routes:** `/ws` (voice session), `/speaker` (TTS fan-out for TestFirmware v1)
- **Debug audio:** WAV dumps under `CompanionServer/debug-audio/` when package root is found

On boot the server logs `stack_version=protocol=v1 pipeline=v1`.

---

## Firmware topologies

### TestFirmware v1 (split path)

```
TestClient (/ws) ──mic──► CompanionServer ──► OpenAI Realtime
                              │
                              └── TTS binary ──► ESP (/speaker) ──► I2S speaker
```

- Mic: Mac `TestClient`
- Speaker: ESP32-S3 + MAX98357A
- Guide: `firmware/TestFirmware/TESTING.md`

### CompanionFirmware v2 (integrated path) — **stable**

```
ESP32 (/ws) ──mic + speaker──► CompanionServer ──► OpenAI Realtime
```

**Interaction (stable):**

1. **Tap once** → mic on, beep, start capturing.
2. **Speak**, pause **~1 s** → client VAD ends turn, sends `audio.stop`.
3. **AI replies** → mic reopens automatically when TTS finishes (hands-free follow-up).
4. **Tap again** anytime → end conversation (including barge-in during TTS).

Safety: **4 s** no-speech timeout if you tap but never talk.

Implementation: `ws_session.cpp` (session state machine + VAD), `audio_io.cpp` (VAD metrics). Guide: `firmware/TESTING.md`.

#### CompanionFirmware GPIO (`config.h`)

| Signal | GPIO |
|--------|------|
| Mic BCLK | 12 |
| Mic WS | 4 |
| Mic DIN | 13 |
| Speaker BCLK | 6 |
| Speaker WS | 7 |
| Speaker DOUT | 5 |
| Touch button | 11 |

`MIC_DATA_SHIFT=14`, PSRAM required for uplink queue.

### TestFirmware v1 hardware (split path only)

| Signal | GPIO |
|--------|------|
| Mic BCLK | 14 |
| Mic WS | 12 |
| Mic DIN | 35 |
| Speaker BCLK | 33 |
| Speaker WS | 25 |
| Speaker DOUT | 32 |
| Button / touch | 4 |

---

## Client VAD (stable)

On-device end-of-speech detection for CompanionFirmware v2. Uplink audio sent to the server is **unchanged**; VAD runs on a filtered analysis path only.

### Algorithm (summary)

1. **High-pass ~300 Hz** on VAD path — reduces HVAC rumble.
2. **Adaptive noise floor** — learns room background; capped at 550.
3. **Hysteresis** — harder bar to *start* speech, lower bar to *continue*.
4. **Speech shape** — crest factor + zero-crossing rate reject steady fan hum.
5. **End-of-turn** — 1 s silence after latched speech → `audio.stop`.

### Stable constants (`ws_session.cpp`)

| Constant | Value | Meaning |
|----------|-------|---------|
| `kEndOfSpeechSilenceMs` | 1000 | Pause after speech → send turn |
| `kNoSpeechTimeoutMs` | 4000 | Tap but never spoke → give up |
| `kVoiceOnsetMargin` | 450 | Energy above floor to *start* speech |
| `kVoiceOffsetMargin` | 150 | Energy above floor to *continue* speech |
| `kVoiceOnsetMinFrames` | 3 | ~180 ms sustained onset (~60 ms frames) |
| `kNoiseFloorMax` | 550 | Cap floor inflation in loud rooms |
| `kMinCrestX100` | 220 | Onset: peak/mean ≥ 2.2× |
| `kMinOffsetCrestX100` | 140 | Continue: peak/mean ≥ 1.4× |
| `kMinZcrX1000` | 55 | Onset: ~5.5% zero-crossings |

Serial tuning aid: `[VAD] energy=... peak=... crest=... zcr=... floor=... on=... off=... voiced=...`

### Session states

| State | Meaning |
|-------|---------|
| `SESSION_IDLE` | Waiting for tap |
| `SESSION_CAPTURING` | Mic on, VAD watching |
| `SESSION_PROCESSING` | Turn sent, waiting for AI |
| `SESSION_SPEAKING` | TTS playback |

---

## Quick start (v1 stable)

**Terminal 1 — server**

```bash
cd CompanionServer
cp .env.example .env   # fill DEVICE_TOKEN, OPENAI_API_KEY
swift run CompanionServer
```

**Terminal 2 — integrated device (CompanionFirmware v2)**

Flash `firmware/CompanionFirmware`, set `config.h` host + token, **tap once** to start a conversation.

**Or — split test (TestFirmware v1 + TestClient)**

```bash
# Terminal 2
swift run TestClient
```

---

## Known v1 limitations (documented, not bugs)

- Binary audio is **PCM**, not Opus — firmware `pcm_codec` chunks frames only; no libopus yet
- `device_command` (LED) is validated server-side (`CmdRouter`) but not wired on ESP yet
- Client VAD may need constant tuning in very noisy rooms — see [§ Client VAD (stable)](#client-vad-stable)
- On-device wake word removed (Edge Impulse too slow); tap + VAD is the stable interaction model
- Prerecorded benchmark tools (`SpeakerBenchmark`, `TTSBenchmark`) removed — see [ARCHIVED_LEGACY_PIPELINE.md](ARCHIVED_LEGACY_PIPELINE.md) to restore

---

## Versioning going forward

- **v1 (this doc):** Realtime pipeline + PCM wire protocol + current session policies
- **v2 (future):** Real Opus on the wire, optional header, or protocol negotiation in `session.ready`
- Changing the wire format or pipeline requires a new profile doc (`STABLE_V2.md`) and new `CompanionStack` constants
- Re-adding Cartesia/Kokoro: follow [ARCHIVED_LEGACY_PIPELINE.md](ARCHIVED_LEGACY_PIPELINE.md)
