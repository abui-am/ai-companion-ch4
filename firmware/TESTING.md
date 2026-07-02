# Testing CompanionFirmware (v2)

Production firmware: ESP32 mic + speaker on one `/ws` session. Stack spec: **[docs/STABLE_V1.md](../docs/STABLE_V1.md)**.

For bench testing without ESP mic hardware, use **[TestFirmware](TestFirmware/TESTING.md)** (v1: Mac **TestClient** mic → server → ESP speaker on `/speaker`).

## 1. Arduino IDE setup

1. Boards Manager → install **esp32 by Espressif Systems**.
2. Library Manager → install:
  - **ArduinoJson** (Benoit Blanchon)
  - **WebSockets** (Markus Sattler / Links2004)
3. Tools → Board → select an ESP32S3baud board (e.g. "ESP32S3 Dev Module").
4. Tools → USB CDC On Boot → **Enabled** (so `Serial` shows up over USB without a separate UART adapter).



## 2. Configure

Edit `CompanionFirmware/config.h`:

- `WIFI_SSID` / `WIFI_PASSWORD` — your LAN.
- `COMPANION_SERVER_HOST` / `COMPANION_SERVER_PORT` — the Mac running `CompanionServer` (run `ipconfig getifaddr en0` on the Mac to find its LAN IP).
- `COMPANION_DEVICE_TOKEN` — must exactly match the `DEVICE_TOKEN` env var the server was started with.
- Mic/speaker/button GPIOs — match your actual wiring.



## 3. Wiring checklist


| Signal                   | Pin define                | Notes                                                  |
| ------------------------ | ------------------------- | ------------------------------------------------------ |
| Mic BCLK                 | `PIN_MIC_BCLK`            |                                                        |
| Mic WS/LRCLK             | `PIN_MIC_WS`              |                                                        |
| Mic DIN (mic→ESP32)      | `PIN_MIC_DIN`             |                                                        |
| Mic L/R select           | n/a (hardware pin on mic) | must match `MIC_CHANNEL_LEFT`                          |
| Speaker BCLK             | `PIN_SPK_BCLK`            |                                                        |
| Speaker WS/LRCLK         | `PIN_SPK_WS`              |                                                        |
| Speaker DOUT (ESP32→amp) | `PIN_SPK_DOUT`            |                                                        |
| Push-to-talk button      | `PIN_BUTTON`              | other leg to GND, internal pull-up enabled in firmware |




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
ready, hold button to talk
```

If it loops on `connecting to <ssid>` — check `WIFI_SSID`/`WIFI_PASSWORD`. If it logs `ws connected` but never `session ready`, the most likely cause is `COMPANION_DEVICE_TOKEN` not matching the server's `DEVICE_TOKEN` (server replies `.dontUpgrade`, the WS handshake fails, and the library will keep retrying `ws connected`/disconnect).

## 6. Functional test sequence

Run these in order, watching both the ESP32 serial monitor and the server's terminal output.

1. **Single turn** — hold the button, speak a short sentence, release.
  - Serial: `button pressed` → (server: pipeline runs) → `transcript: ...` → `session ready` is *not* re-sent (only on (re)connect) → audio should play back through the speaker → button task otherwise idle.
  - Server terminal: should show the latency.report log line for the turn.
2. **Push-to-talk timing** — confirm capture only sends frames between press and release (check the server doesn't log `audio_too_short` if you spoke for >1s; if it does, audio isn't reaching the mic — check wiring/`MIC_CHANNEL_LEFT`).
3. **Barge-in / abort** — start a turn, wait for TTS playback to start (`ws_session` state `SESSION_SPEAKING`), then press the button again mid-playback.
  - Expect: audio stops immediately, serial shows the abort being sent, server log shows the pipeline cancelled, no further binary frames arrive.
4. **WiFi drop mid-turn** — start a turn, then power off the WiFi AP (or walk the device out of range) before `tts.end`.
  - Expect: serial logs `ws disconnected, resetting local session state`; once WiFi/AP returns, the library auto-reconnects and you get a **new** `session ready` with a different session ID (no resume, per the kill-on-disconnect policy in the project plan).
5. **Repeat turns back to back** — 3-4 consecutive press/release cycles with no errors or stuck state (device should always return to "ready, hold button to talk" behavior, i.e. next press always starts a fresh capture).



## 7. Known limitations to expect during testing

- Audio is raw 16-bit PCM, not real Opus, on both client and server (`pcm_codec.cpp` / `OpusCodec.swift` are placeholders) — fine for LAN testing, just means uplink/downlink use more bandwidth than the final design.
- `device_command` (LED) messages are logged but not acted on — no LED hardware wired up yet.
- WebSocket frame fragmentation isn't reassembled; not expected to matter at our frame sizes (1920–2880 bytes) but worth knowing if data looks truncated on a slow/lossy link.
- This firmware hasn't been compiled in CI/this environment (no `arduino-cli` available) — the first `Sketch → Upload` is also the first real compile. Note down any compiler errors here so they can be fixed in the source.

