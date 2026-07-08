# AI Companion — Project Summary

**Last updated:** 2026-07-06  
**Status:** **Stable** — tap-to-talk + hands-free adaptive VAD (see [STABLE_V1.md](STABLE_V1.md))  
**Scope:** ESP32-S3 voice companion firmware + Swift CompanionServer backend

This document summarizes the current stack, what was accomplished during the wake-word debug session, and where the project stands today. For the full wake-word investigation log, see [WAKE_WORD_DEBUG_REPORT.md](WAKE_WORD_DEBUG_REPORT.md). For the stable v1 stack spec, see [STABLE_V1.md](STABLE_V1.md).

---

## What we built

An ESP32-S3 voice companion that talks to a Mac-hosted **CompanionServer** over **WebSocket** (no MQTT). The server bridges to **OpenAI Realtime API** for speech-in / speech-out in a single round-trip per turn.

```
ESP32-S3 (CompanionFirmware)
  ├─ INMP441 mic  → 16 kHz PCM uplink
  ├─ MAX98357A speaker ← TTS downlink
  ├─ Touch button → start / end conversation
  └─ WebSocketsClient (Links2004) → wss://CompanionServer/ws

CompanionServer (Swift)
  ├─ Hummingbird 2 + HummingbirdWebSocket (WSS server)
  └─ URLSessionWebSocketTask → OpenAI Realtime API
```

### Interaction model (current)

There is **no on-device wake word**. Conversations work like this:

1. **Tap once** to start — mic opens, device beeps.
2. **Speak**, then pause ~1 s — silence-based VAD ends your turn and sends audio to the AI.
3. **AI replies** through the speaker; mic reopens automatically when TTS finishes.
4. **Keep talking** — follow-up turns are hands-free, no extra tap needed.
5. **Tap again** at any time to end the conversation (including mid AI-reply / barge-in).

Safety: if you tap but never speak, a **4 s no-speech timeout** ends the session.

### Session states

| State | Meaning |
|-------|---------|
| `SESSION_IDLE` | Waiting for tap |
| `SESSION_CAPTURING` | Mic on, VAD watching for end-of-speech |
| `SESSION_PROCESSING` | Turn sent, waiting for AI response |
| `SESSION_SPEAKING` | Playing TTS downlink |

---

## Tech stack

| Layer | Technology |
|-------|------------|
| ESP32 firmware | Arduino (ESP32-S3 Dev Module), FreeRTOS tasks |
| Device ↔ server | Links2004 **WebSocketsClient** (`WebSocketsClient.h`) |
| Server | **Hummingbird 2** + **HummingbirdWebSocket** |
| Server ↔ OpenAI | Apple **URLSessionWebSocketTask** |
| Audio codec (v1) | Raw 16-bit PCM (Opus placeholders exist, not active) |
| Auth | Shared compile-time `DEVICE_TOKEN` bearer header |
| Pipeline | OpenAI Realtime only (`gpt-realtime-mini`, voice `verse`) |

**Not used:** MQTT, on-device Edge Impulse wake word (removed).

---

## Wake-word debug session (2026-07-04)

**Goal:** On-device wake phrase **"hey botchill"** via Edge Impulse (`adjiemuliadi-project-1_inferencing` v1.0.3) without breaking the voice uplink path (already good for server STT).

**Result:** Firmware stabilized; wake word **not product-ready**.

| Metric | Value |
|--------|-------|
| Inference time | ~3.4 s per classify (ESP-NN off) |
| Typical scores | `noise` 0.7–0.95, `hey_botchill` 0.01–0.17 |
| Threshold tried | 0.30 (Studio default 0.60) |
| Slice period | 250 ms (4000 samples) |

### Crashes fixed

| Problem | Fix |
|---------|-----|
| ESP-NN overflow buffer → `StoreProhibited` | `EI_CLASSIFIER_TFLITE_ENABLE_ESP_NN=0` in `build_opt.h` |
| `EI_IMPULSE_ALLOC_FAILED` / out of memory | PSRAM-backed `ei_malloc`/`ei_calloc`/`ei_free` in `wake_word.cpp` |
| Uplink queue freed while send task blocked | Queue kept allocated; drain only (`ws_session.cpp`) |
| I2S startup garbage poisoning MFCC window | `audioIoPrimeMic()` + classifier re-init after prime |
| Buffer overrun (NN slower than slice period) | Async classify task with snapshot buffer + drop-if-busy |

### Approaches tried

| Approach | Outcome |
|----------|---------|
| Separate wake gain/shift | Worse scores; uplink path left unchanged (`MIC_DATA_SHIFT=14`) |
| Sync Edge Impulse example | Buffer overruns (~3.4 s NN vs 250 ms slices) |
| `EI_CLASSIFIER_SLICES_PER_MODEL_WINDOW=2` | Still overrun |
| Re-enable ESP-NN | Same crash every time — must stay off |
| Async inference (v1) | Crash from buffer races |
| Async inference (v2, snapshot + drop-if-busy) | Stable but ~1 classify every 3.5 s |

**Root cause:** Edge Impulse continuous audio assumes real-time inference. This model on ESP32-S3 without ESP-NN cannot keep up.

---

## What changed after the debug session

The wake-word path was **removed** in favor of tap + VAD turn-taking:

| Change | Detail |
|--------|--------|
| `wake_word.cpp` / `wake_word.h` | **Deleted** — no Edge Impulse on device |
| `ws_session.cpp` | Refactored: capture task, uplink queue, VAD, session state machine |
| `ws_session.h` | Documents tap-to-talk + hands-free turns (no wake word) |
| `audio_io.cpp` | Mic priming, I2S improvements |
| `config.h` | Pin layout, `MIC_DATA_SHIFT=14`, touch button on GPIO 11 |
| `TESTING.md` | Updated test sequence for tap/VAD model; default partition OK (no Huge APP for EI) |
| `OpenAIRealtimeService.swift` | Minor server-side sync fixes |

---

## Hardware (CompanionFirmware)

| Item | Value |
|------|--------|
| Board | ESP32-S3 Dev Module |
| PSRAM | QSPI PSRAM (uplink audio queue) |
| Mic | INMP441 — BCLK 12, WS 4, DIN 13 |
| Speaker | MAX98357A — BCLK 6, WS 7, DOUT 5 |
| Touch | GPIO 3 (TTP223 etc.) |
| Sample rate | 16 kHz mono |

---

## Testing

See [firmware/TESTING.md](../firmware/TESTING.md) for the full checklist. Key scenarios:

1. Single turn (tap → speak → pause → AI reply)
2. Seamless follow-up (no tap between turns)
3. No-speech give-up (4 s timeout)
4. Tap to end mid-conversation
5. Barge-in during TTS
6. WiFi drop / reconnect (new session ID, no resume)
7. Repeat turns back-to-back

Bench tools:

| Tool | Purpose |
|------|---------|
| `firmware/TestFirmware` | Mac mic → server → ESP speaker (split test) |
| `TestClient` (Swift) | Dev harness without ESP hardware |
| `hey_bochil_te3st.wav` | Test clip for Edge Impulse Live Classification |

---

## Known limitations

- Raw PCM on wire (not Opus) — fine for LAN, higher bandwidth than final design
- `device_command` (LED) messages logged but not acted on
- WebSocket frame fragmentation not reassembled (not expected at current frame sizes)
- On-device wake word deferred until a faster model or alternative engine is available

---

## If we revisit wake word

Priority recommendations from the debug report:

1. **Retrain in Edge Impulse** with INMP441 recordings from the actual device and room
2. **Use a smaller/faster model** targeting <300 ms inference on ESP32-S3
3. **Alternative engines** — Porcupine, custom tiny model, etc.
4. **Server-side wake detection** on the uplink stream (higher latency, no on-device NN)
5. **Do not re-enable ESP-NN** until the exported model supports ESP32-S3 optimized kernels without arena overflow

Until then, **tap-to-talk + hands-free VAD** is the **stable** product interaction model (documented in [STABLE_V1.md](STABLE_V1.md)).
