# TestFirmware (speaker-only)

ESP32 sketch that connects to CompanionServer **`/speaker`** and plays TTS audio. Mic input comes from **TestClient** on your Mac (`/ws`).

## Architecture

```
TestClient (/ws)  ──mic──► CompanionServer ──► OpenAI
                               │
                               ├── transcript → TestClient (logs)
                               └── TTS binary ──► ESP TestFirmware (/speaker) ──► I2S speaker
```

## Speaker hardware test (do this first)

Isolates **I2S + amp wiring** from WiFi / server / AI. No Mac, no CompanionServer needed.

1. In [`config.h`](config.h) confirm:
   - `HAS_SPEAKER 1`
   - `SPEAKER_SELF_TEST_ON_BOOT 1` (default in TestFirmware)
   - `PIN_SPK_BCLK`, `PIN_SPK_WS`, `PIN_SPK_DOUT` match your MAX98357A wiring
2. Flash **TestFirmware**, open Serial Monitor @ **115200**.
3. **Right after boot** (before WiFi finishes) you should **hear a 1-second 440 Hz beep**.

| What you hear | What it means |
|---------------|---------------|
| Clear beep + serial `[SPEAKER TEST] OK` | Speaker path works — safe to test server pipeline |
| Silence + serial `[SPEAKER TEST] OK` | I2S writes succeed but amp/speaker/wiring wrong — check 3V3/GND, DIN/BCLK/LRC, amp SD pin |
| `[SPEAKER TEST] FAIL` | I2S driver error — check GPIO pins, double-init, or board config |
| `[SPEAKER TEST] skipped` | `HAS_SPEAKER=0` in config |

To repeat the beep without reflashing: power-cycle the board (test runs every boot).

Set `SPEAKER_SELF_TEST_ON_BOOT 0` when you're done debugging hardware.

## Mic loopback test (mic + speaker, no server)

Hear yourself on the speaker to verify **INMP441 mic wiring** and I2S paths together. No WiFi, no CompanionServer.

1. In [`config.h`](config.h) set:
   - `MIC_LOOPBACK_TEST_MODE 1`
   - Confirm mic pins: `PIN_MIC_BCLK 14`, `PIN_MIC_WS 12`, `PIN_MIC_DIN 35`
   - Speaker pins same as above (33 / 25 / 32)
2. Flash **TestFirmware**, Serial Monitor @ **921600**.
1. **Tap** → beep
2. **Mic listening** — bicara (max 10 detik; progress di serial)
3. **Tap lagi** → mic stop
4. **Playback** rekaman di speaker

TTP223 mode **momentary**: tap singkat, lepas, ngomong, tap lagi.

**Serial Monitor must be set to `921600` baud** when `MIC_LOOPBACK_LOG_EVERY_FRAME=1`.

### Diagnostic log fields (every frame)

| Field | Meaning |
|-------|---------|
| `f` | Frame number |
| `samp` | Samples in frame (expect 960 @ 60 ms / 16 kHz) |
| `got` / `exp_bytes` | Bytes read (expect 1920) |
| `int_ms` | Time since last frame (expect ~60) |
| `jit_ms` | `int_ms - 60` — jitter |
| `read_us` / `write_us` | I2S driver latency |
| `rms` / `peak` | Level (noise floor vs speech) |
| `dc` | DC offset (expect near 0) |
| `clip` | Samples near full scale |
| `zc` | Zero crossings (hiss = high at low rms) |

Every 30 frames, `[LOOPBACK SUMMARY]` prints min/max/avg/std for interval and noise.

**Noise test:** stay silent 5 s — note `rms_avg` in summary (noise floor).  
**Jitter test:** speak steadily — `interval_ms std` should stay &lt; 3 ms.

Expected serial:

```
=== TestFirmware ===
mode: mic loopback (no WiFi — hear yourself on speaker)
audio: I2S mic ready
audio: I2S speaker ready
[MIC LOOPBACK] running — speak into the mic
```

| Symptom | Check |
|---------|--------|
| Silence | Mic L/R pin to GND, 3V3/GND, BCLK/WS/DIN GPIOs |
| Loud hiss only | `MIC_DATA_SHIFT` in `audio_io.cpp` (try 10–14) |
| Feedback squeal | Lower amp volume; mic too close to speaker |

When done, set `MIC_LOOPBACK_TEST_MODE 0` to return to `/speaker` TTS testing.

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

## Automated benchmark (no mic)

Uses `benchmark_input.m4a` — the same clip as `RealtimePipeline` / `TTSBenchmark`.

**Terminal 1** — server:

```bash
cd CompanionServer
swift run CompanionServer
```

**Terminal 2** — flash TestFirmware, confirm `speaker ready` on serial.

**Terminal 3** — send prerecorded uplink:

```bash
cd CompanionServer
swift run SpeakerBenchmark
# or: swift run SpeakerBenchmark /path/to/other.m4a
```

Expected:
- Mac prints transcript + downlink frame count
- ESP serial: `tts.start` → `prefill complete` → `downlink frame N` → `tts complete`
- Speaker plays AI response (if `HAS_SPEAKER=1`)

`SpeakerBenchmark` connects to `/ws` (uplink only). TestFirmware on `/speaker` receives the mirrored TTS audio.

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
