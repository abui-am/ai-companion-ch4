# TestFirmware (speaker-only)

ESP32 sketch that connects to CompanionServer **`/speaker`** and plays TTS audio. Mic input comes from **TestClient** on your Mac (`/ws`).

## Architecture

```
TestClient (/ws)  ──mic──► CompanionServer ──► OpenAI
                               │
                               ├── transcript → TestClient (logs)
                               └── TTS binary ──► ESP TestFirmware (/speaker) ──► I2S speaker
```

## Arduino IDE setup

Same as [CompanionFirmware](../TESTING.md): ESP32 board package, **ArduinoJson**, **WebSockets** (Links2004), USB CDC On Boot enabled.

Open `firmware/TestFirmware/TestFirmware.ino` as the sketch.

## Configure

Edit [`config.h`](config.h):

| Define | Purpose |
|--------|---------|
| `WIFI_SSID` / `WIFI_PASSWORD` | LAN credentials |
| `COMPANION_SERVER_HOST` | Mac IP (`ipconfig getifaddr en0`) |
| `COMPANION_DEVICE_TOKEN` | Must match `DEVICE_TOKEN` in `CompanionServer/.env` |
| `HAS_SPEAKER` | `1` = play on I2S amp, `0` = log downlink only |

Path is fixed to `/speaker` — do not change unless the server route changes.

## Start CompanionServer

```bash
cd CompanionServer
swift run CompanionServer
```

```bash
curl http://<mac-ip>:8080/ping   # → pong
```

## Flash ESP and run TestClient

1. Upload **TestFirmware** to ESP32-S3.
2. Serial Monitor @ **115200** — expect `speaker ready`.
3. In another terminal:

```bash
cd CompanionServer
swift run TestClient
```

4. Press Enter to talk, speak, press Enter to stop.
5. Watch TestClient logs for `transcript.final`; ESP plays TTS on the speaker.

## Expected ESP boot

```
=== TestFirmware ===
wifi: connecting to ... connected (192.168.x.x)
ws connected to /speaker
ws recv text: {"type":"speaker.ready"}
speaker ready — waiting for TTS from TestClient
TestFirmware ready (speaker-only)
```

## Expected one turn

1. TestClient sends uplink audio on `/ws`
2. Server logs transcribe + chat + speech
3. ESP: `tts.start` → downlink binary frames → `tts.end`
4. Speaker plays (if `HAS_SPEAKER=1` and amp wired)

## Note on audio format

Server requests OpenAI TTS as raw PCM and chunks it into binary frames. ESP `pcm_codec` treats those frames as 16-bit PCM for I2S speaker playback. TestClient logs transcript text regardless; use that to verify the pipeline.
