# Testing CompanionFirmware (v2 stable)

Production firmware: ESP32 mic + speaker on one `/ws` session. **Stable** tap + client VAD — see [docs/STABLE_V1.md](../docs/STABLE_V1.md) (§ Client VAD).

For bench testing without ESP mic hardware, use **[TestFirmware](TestFirmware/TESTING.md)** (v1: Mac **TestClient** mic → server → ESP speaker on `/speaker`).

## 1. Arduino IDE setup

1. Boards Manager → install **esp32 by Espressif Systems**.
2. Library Manager → install:
  - **ArduinoJson** (Benoit Blanchon)
  - **WebSockets** (Markus Sattler / Links2004)
3. Tools → Board → **ESP32S3 Dev Module** (works for ESP32-S3 Mini/Super Mini boards too — there's no separate "Mini" board entry).
4. Tools → **Partition Scheme** → default (1.2 MB app) is fine now that the Edge Impulse wake-word model is gone; use **Huge APP** only if you need the extra flash headroom for other reasons.
5. Tools → USB CDC On Boot → **Enabled** on ESP32-S3 (so `Serial` shows up over USB without a separate UART adapter).
6. Tools → **PSRAM** → **QSPI PSRAM** (M5Stack CoreS3 / most S3 devkits; use OPI only if your module datasheet says octal PSRAM) — used for the uplink audio queue.

## 2. Configure

Edit `CompanionFirmware/config.h`:

- `WIFI_SSID` / `WIFI_PASSWORD` — your LAN.
- `COMPANION_SERVER_HOST` / `COMPANION_SERVER_PORT` — the Mac running `CompanionServer` (run `ipconfig getifaddr en0` on the Mac to find its LAN IP).
- `COMPANION_DEVICE_TOKEN` — must exactly match the `DEVICE_TOKEN` env var the server was started with.
- Mic/speaker/button GPIOs — match your actual wiring.



## 3. Wiring checklist


| Signal                   | Pin define                | GPIO | Notes                                                  |
| ------------------------ | ------------------------- | ---- | ------------------------------------------------------ |
| Mic BCLK / SCK           | `PIN_MIC_BCLK`            | 1    |                                                        |
| Mic WS / LRCLK           | `PIN_MIC_WS`              | 3    |                                                        |
| Mic DIN / SD (mic→ESP32) | `PIN_MIC_DIN`             | 2    |                                                        |
| Mic L/R select           | n/a (hardware pin on mic) |      | must match `MIC_CHANNEL_LEFT`                          |
| Speaker BCLK             | `PIN_SPK_BCLK`            | 6    |                                                        |
| Speaker WS/LRCLK         | `PIN_SPK_WS`              | 7    |                                                        |
| Speaker DOUT (ESP32→amp) | `PIN_SPK_DOUT`            | 4    |                                                        |
| Push-to-talk button      | `PIN_BUTTON`              | 5    | other leg to GND; GPIO4 is speaker DIN on this layout  |




## 4. Start the backend

```bash
cd CompanionServer
swift run CompanionServer
```

Requires `DEVICE_TOKEN` and `OPENAI_API_KEY` in `CompanionServer/.env` (see `.env.example`).

Confirm it's reachable from the same LAN the ESP32 will join:

```bash
curl http://<mac-lan-ip>:8080/health   # expect: ok
```



## 5. Flash and watch logs

1. Connect the ESP32-S3 over USB, select the right port under Tools → Port.
2. Sketch → Upload.
3. Tools → Serial Monitor, baud **115200**.

Expected boot sequence in the serial log:

```
connecting to <ssid>..... connected
I2S mic + speaker channels ready
ws connected
session ready: <uuid>
>>> READY — connecting mic / server OK; wait for LISTENING <<<
```

If it loops on `connecting to <ssid>` — check `WIFI_SSID`/`WIFI_PASSWORD`. If it logs `ws connected` but never `session ready`, the most likely cause is `COMPANION_DEVICE_TOKEN` not matching the server's `DEVICE_TOKEN` (server replies `.dontUpgrade`, the WS handshake fails, and the library will keep retrying `ws connected`/disconnect).

## 6. Functional test sequence

Run these in order, watching both the ESP32 serial monitor and the server's terminal output.

There's no wake word. Conversations are bookended by a single tap: **tap once to start**, then it's hands-free — talk, pause ~1s, the AI answers, talk again, pause, it answers again — until **you tap again to end it** (that second tap works at any point, including mid AI-reply). A no-speech safety timeout (4s of total silence with nothing ever said) also ends the conversation on its own. See `kEndOfSpeechSilenceMs` / `kNoSpeechTimeoutMs` / the adaptive-VAD constants in `ws_session.cpp`.

1. **Single turn** — tap once, speak a short sentence, then go quiet for ~1s.
  - Serial: `[BUTTON] pressed` → `[BUTTON] tap: IDLE → CAPTURING (mic ON)` + beep → `[VAD] energy=... peak=... crest=... zcr=... floor=... on=... off=...` lines while you talk → `[VAD] user paused after speaking — ending turn, sending to AI` → (server: pipeline runs) → `transcript: ...` → audio plays back through the speaker.
  - Server terminal: should show the latency.report log line for the turn.
2. **Seamless follow-up** — after the AI finishes replying, don't tap anything; just start talking again.
  - Expect serial: `[TTS] END — listening for reply` immediately followed by `[AUTO] AI finished speaking: IDLE → CAPTURING (mic ON)` and a beep, then the same pause-triggers-response flow as turn 1 — no button press needed.
3. **No-speech give-up** — tap once and just don't say anything for ~4s.
  - Expect serial: `[VAD] no speech at all — giving up, ending conversation`, `[SESSION] end conversation (no_speech_timeout) → IDLE`, an `abort` sent to the server, then `[TTS] END (no active playback) — back to idle` when the server's abort-cleanup `tts.end` arrives — and the device staying in `SESSION_IDLE`, **not** re-triggering another capture.
  - Watch the `[VAD] energy=... crest=... zcr=... on=... off=...` lines to tell whether the timeout fired because you were actually silent or the threshold needs tuning for your mic/room. In noise, `crest` and `zcr` should stay below the speech gate until you talk; if `voiced=1` while you're silent, raise `kVoiceOnsetMargin` or `kMinCrestX100` in `ws_session.cpp`.
4. **Tap to end mid-conversation** — start a turn (or wait for a seamless follow-up window) and tap once instead of speaking.
  - Expect: `[SESSION] end conversation (user_tap) → IDLE` — capture stops immediately, no turn gets sent.
5. **Barge-in** — start a turn, wait for TTS playback to start (`ws_session` state `SESSION_SPEAKING`), then tap.
  - Expect: audio stops immediately (speaker muted, playback queue drained), `[SESSION] end conversation (user_tap) → IDLE`, server log shows the pipeline/response cancelled, no further binary frames arrive.
6. **WiFi drop mid-turn** — start a turn, then power off the WiFi AP (or walk the device out of range) before `tts.end`.
  - Expect: serial logs `ws disconnected, resetting local session state`; once WiFi/AP returns, the library auto-reconnects and you get a **new** `session ready` with a different session ID (no resume, per the kill-on-disconnect policy in the project plan).
7. **Repeat turns back to back** — 3-4 consecutive tap-started conversations, each with a couple of seamless follow-up turns, with no errors or stuck state.



## 7. Known limitations to expect during testing

- Audio is raw 16-bit PCM, not real Opus, on both client and server (`pcm_codec.cpp` / `OpusCodec.swift` are placeholders) — fine for LAN testing, just means uplink/downlink use more bandwidth than the final design.
- `device_command` (LED) messages are logged but not acted on — no LED hardware wired up yet.
- WebSocket frame fragmentation isn't reassembled; not expected to matter at our frame sizes (1920–2880 bytes) but worth knowing if data looks truncated on a slow/lossy link.
- This firmware hasn't been compiled in CI/this environment (no `arduino-cli` available) — the first `Sketch → Upload` is also the first real compile. Note down any compiler errors here so they can be fixed in the source.

