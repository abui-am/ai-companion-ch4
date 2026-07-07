# AI Companion (Botchill)

An ESP32-S3 voice companion that talks to a Mac-hosted Swift server over WebSocket. The server bridges to the **OpenAI Realtime API** for speech-in / speech-out in a single round-trip per turn.

```
ESP32-S3 (CompanionFirmware)
  ├─ INMP441 mic  → 16 kHz PCM uplink
  ├─ MAX98357A speaker ← TTS downlink
  ├─ Touch button → start / end conversation
  └─ WebSocket → ws://<host>:8080/ws

CompanionServer (Swift / Hummingbird 2)
  ├─ WSS server on :8080
  └─ OpenAI Realtime API (gpt-realtime-mini)
```

**Interaction:** tap once to start, speak and pause ~1 s for the device to detect end-of-speech, listen to the reply, then keep talking hands-free. Tap again anytime to end (including mid-reply barge-in). No on-device wake word.

For the full stack spec, see [docs/STABLE_V1.md](docs/STABLE_V1.md).

---

## Requirements

| Component | Requirement |
|-----------|-------------|
| Server | macOS 15+, Swift 6, Xcode command-line tools |
| Device | ESP32-S3 Dev Module with **QSPI PSRAM** |
| Hardware | INMP441 mic, MAX98357A amp, touch button (TTP223) |
| Network | ESP32 and Mac on the same LAN |
| API | OpenAI API key with Realtime access |

---

## Quick start

### 1. Start the server

```bash
cd CompanionServer
cp .env.example .env
```

Edit `.env` and set at minimum:

```env
DEVICE_TOKEN=your-shared-secret
OPENAI_API_KEY=sk-...
```

Start Postgres (creates the `companion` database; tables are created on first server boot):

```bash
docker compose up -d
```

```bash
swift run CompanionServer
```

Verify:

```bash
curl http://localhost:8080/health   # → ok
```

**Database:** There is no SQLite file in the repo. Data lives in Postgres via Docker (`companion-postgres` container, database name `companion`). Tables (`tasks`, `calendar_events`, etc.) are created automatically when the server starts and runs migrations. To inspect:

```bash
docker exec -it companion-postgres psql -U postgres -d companion -c '\dt'
```

Connection string (default): `postgres://postgres:postgres@localhost:5432/companion`

The server logs `stack_version=protocol=v1 pipeline=v1` on boot.

### 2. Flash the firmware

1. Open `firmware/CompanionFirmware/CompanionFirmware.ino` in Arduino IDE.
2. Install board support (**esp32 by Espressif**) and libraries:
   - **ArduinoJson** (Benoit Blanchon)
   - **WebSockets** (Links2004)
3. Board settings:
   - **ESP32S3 Dev Module**
   - **USB CDC On Boot** → Enabled
   - **PSRAM** → QSPI PSRAM
4. Edit `firmware/CompanionFirmware/config.h`:
   - `WIFI_SSID` / `WIFI_PASSWORD`
   - `COMPANION_SERVER_HOST` — your Mac's LAN IP (`ipconfig getifaddr en0`)
   - `COMPANION_DEVICE_TOKEN` — must match `DEVICE_TOKEN` in `.env`
5. Upload and open Serial Monitor at **115200** baud.

Expected boot: WiFi connected → `ws connected` → `session ready: <uuid>` → `>>> READY`.

### 3. Talk to it

1. **Tap once** — mic opens, short beep.
2. **Speak**, then pause ~1 s — VAD ends your turn and sends audio to the AI.
3. **Listen** to the reply through the speaker.
4. **Keep talking** — follow-up turns are hands-free after TTS finishes.
5. **Tap again** to end the conversation.

If you tap but never speak, a **4 s no-speech timeout** ends the session.

---

## Hardware wiring (CompanionFirmware)

| Signal | GPIO | Notes |
|--------|------|-------|
| Mic BCLK | 12 | INMP441 SCK |
| Mic WS | 4 | INMP441 LRCLK |
| Mic DIN | 13 | INMP441 SD |
| Speaker BCLK | 6 | MAX98357A |
| Speaker WS | 7 | MAX98357A LRC |
| Speaker DOUT | 5 | MAX98357A DIN |
| Touch button | 11 | TTP223; other leg to GND |

Mic L/R pin tied to GND → left channel. Sample rate: **16 kHz mono** uplink, **24 kHz** downlink.

Pin map and VAD constants: [docs/STABLE_V1.md](docs/STABLE_V1.md).

---

## Project layout

```
ai-companion-ch5/
├── CompanionServer/          # Swift backend (Hummingbird 2 + WebSocket)
│   ├── Sources/
│   │   ├── CompanionServer/  # WSS server, OpenAI Realtime, voice sessions
│   │   ├── CompanionEnv/     # .env loading, logging
│   │   └── TestClient/       # Mac mic dev harness (no ESP hardware)
│   └── .env.example
├── firmware/
│   ├── CompanionFirmware/    # Production ESP32 firmware (mic + speaker)
│   └── TestFirmware/         # Split test: Mac mic → server → ESP speaker
└── docs/
    ├── STABLE_V1.md          # Canonical v1 stack reference
    ├── PROJECT_SUMMARY.md    # Architecture overview + history
    └── WAKE_WORD_DEBUG_REPORT.md
```

---

## Development without ESP hardware

**TestClient** captures audio from your Mac microphone and sends it to the server on `/ws`:

```bash
cd CompanionServer
swift run TestClient
```

**TestFirmware** (split path) receives TTS on `/speaker` and plays it through the ESP speaker while TestClient handles the mic. See [firmware/TestFirmware/TESTING.md](firmware/TestFirmware/TESTING.md).

Run server tests:

```bash
cd CompanionServer
swift test
```

---

## Configuration

| Variable | Default | Purpose |
|----------|---------|---------|
| `OPENAI_REALTIME_MODEL` | `gpt-realtime-mini` | Realtime model |
| `OPENAI_REALTIME_VOICE` | `verse` | Output voice |
| `COMPANION_RESPONSE_LANGUAGE` | `English` | Reply language (`auto` = match user) |
| `COMPANION_TIMEZONE` | server local TZ | IANA timezone for task/calendar times (e.g. `Asia/Jakarta`) |
| `WEB_SEARCH_ENABLED` | `true` | Enable web search tool for current facts |
| `DATABASE_URL` | `postgres://postgres:postgres@localhost:5432/companion` | Postgres connection (requires `docker compose up -d`) |

Full list: `CompanionServer/.env.example`.

---

## Testing

Functional test checklist (single turn, follow-up, no-speech timeout, barge-in, WiFi drop): [firmware/TESTING.md](firmware/TESTING.md).

---

## Known limitations (v1)

- Audio on the wire is **raw PCM**, not Opus — fine for LAN, higher bandwidth than a production codec.
- No on-device wake word (Edge Impulse was too slow on ESP32-S3); tap + VAD is the stable model.
- `device_command` (LED) messages are validated server-side but not wired on the ESP yet.
- WebSocket sessions do not resume after disconnect — reconnect gets a new session ID.

---

## Documentation

| Doc | Contents |
|-----|----------|
| [docs/STABLE_V1.md](docs/STABLE_V1.md) | Wire protocol, pipeline, VAD constants, quick start |
| [docs/TASK_API.md](docs/TASK_API.md) | Task list REST API for frontend (`TaskView`) |
| [docs/CALENDAR_API.md](docs/CALENDAR_API.md) | Calendar REST API for frontend (`CalendarView`) |
| [docs/CONFIG_API.md](docs/CONFIG_API.md) | Settings REST API for frontend (`SettingsView`) |
| [docs/CONVERSATION_API.md](docs/CONVERSATION_API.md) | Read-only conversation history + audio playback API |
| [docs/PROJECT_SUMMARY.md](docs/PROJECT_SUMMARY.md) | Full architecture and wake-word debug history |
| [firmware/TESTING.md](firmware/TESTING.md) | CompanionFirmware test sequence |
| [docs/ARCHIVED_LEGACY_PIPELINE.md](docs/ARCHIVED_LEGACY_PIPELINE.md) | Removed Cartesia/Kokoro multi-stage pipeline |
