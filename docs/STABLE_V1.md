# Stable v1 — AI Companion Stack

This document is the canonical reference for **stack v1**: the current working configuration used for showcase and hardware testing. When someone says “run v1” or “stable stack,” they mean the settings and behaviors described here.

**Code anchors:** `CompanionStack.protocolVersion` / `CompanionStack.pipelineProfile` (Swift), `COMPANION_PROTOCOL_VERSION` (firmware).

---

## What “v1” means 
|      Layer     |     v1 identifier      |        Summary       |
|----------------|------------------------|----------------------|
| **Pipeline profile** | `v1` | OpenAI Realtime API — single WebSocket round-trip for speech-in / speech-out |
| **Wire protocol** | `v1` | JSON events on text frames; raw 16-bit PCM on binary frames (no per-frame header) |
| **Firmware (split test)** | TestFirmware **v1** | Mac mic on `/ws` → server → ESP speaker on `/speaker` |
| **Firmware (integrated)** | CompanionFirmware **v2** | ESP mic + speaker on one `/ws` session |

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
- Server VAD: disabled (`turn_detection: null`) — client sends `audio.stop` (push-to-talk)
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

**Outbound:** `session.ready`, `transcript.final`, `device_command`, `tts.start`, `tts.end`, `error`, `speaker.ready` (`/speaker` only)

`transcript.input` is rejected with `error` (`unsupported_event`) — use audio uplink.

Full schemas: `WireProtocol.swift`, `firmware/*/protocol.h`, `.cursor/skills/hummingbird/reference.md`.

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

### CompanionFirmware v2 (integrated path)

```
ESP32 (/ws) ──mic + speaker──► CompanionServer ──► OpenAI Realtime
```

- Push-to-talk on GPIO4 (touch)
- INMP441 mic + MAX98357A speaker
- Guide: `firmware/TESTING.md`

### Shared hardware (both sketches)

| Signal   |   GPIO   |
|----------|----------|
| Mic BCLK | 14       |
| Mic WS   | 12       |
| Mic DIN  | 35       |
| Speaker BCLK | 33   |
| Speaker WS | 25     |
| Speaker DOUT | 32   |
| Button / touch | 4  |

---

## Quick start (v1 stable)

**Terminal 1 — server**

```bash
cd CompanionServer
cp .env.example .env   # fill DEVICE_TOKEN, OPENAI_API_KEY
swift run CompanionServer
```

**Terminal 2 — integrated device (CompanionFirmware v2)**

Flash `firmware/CompanionFirmware`, set `config.h` host + token, hold button to talk.

**Or — split test (TestFirmware v1 + TestClient)**

```bash
# Terminal 2
swift run TestClient
```

---

## Known v1 limitations (documented, not bugs)

- Binary audio is **PCM**, not Opus — firmware `pcm_codec` chunks frames only; no libopus yet
- `device_command` (LED) is validated server-side (`CmdRouter`) but not wired on ESP yet
- Prerecorded benchmark tools (`SpeakerBenchmark`, `TTSBenchmark`) removed — see [ARCHIVED_LEGACY_PIPELINE.md](ARCHIVED_LEGACY_PIPELINE.md) to restore

---

## Versioning going forward

- **v1 (this doc):** Realtime pipeline + PCM wire protocol + current session policies
- **v2 (future):** Real Opus on the wire, optional header, or protocol negotiation in `session.ready`
- Changing the wire format or pipeline requires a new profile doc (`STABLE_V2.md`) and new `CompanionStack` constants
- Re-adding Cartesia/Kokoro: follow [ARCHIVED_LEGACY_PIPELINE.md](ARCHIVED_LEGACY_PIPELINE.md)
