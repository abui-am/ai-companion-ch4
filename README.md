# AI Companion (Botchill)

An ESP32-S3 desk robot that talks to a Mac-hosted Swift server over WebSocket. The server bridges to the **OpenAI Realtime API** for speech-in / speech-out in a single round-trip per turn.

```
ESP32-S3 (CompanionFirmware)
  ├─ INMP441 mic  → 16 kHz PCM uplink
  ├─ MAX98357A speaker ← TTS downlink
  ├─ SH1106 OLED face ← animated eyes + emotion marks
  ├─ DRV8833 wheels ← desk motion (stroll, turn, stop)
  ├─ Touch button → start / end conversation
  └─ WebSocket → ws://<host>:8080/ws

CompanionServer (Swift / Hummingbird 2)
  ├─ WSS server on :8080
  ├─ Postgres (tasks, calendar, memories, conversations)
  └─ OpenAI Realtime API (gpt-realtime-mini) + tool sub-agents
```

**Interaction:** tap once to start, speak and pause ~1 s for the device to detect end-of-speech, listen to the reply, then keep talking hands-free. Tap again anytime to end (including mid-reply barge-in). Long press (~800 ms) also ends the session. No on-device wake word.

For the full stack spec, see [docs/STABLE_V1.md](docs/STABLE_V1.md).

---

## Botchill capabilities

Botchill is a warm, voice-first desk companion. During a conversation it can call **tools** (sub-agents) mid-turn; the server emits `tool.start` / `tool.done` WebSocket events so companion apps can show live activity (e.g. "Checking your calendar…").

### Voice tools (Realtime function calling)

| Tool | What it does | Backed by |
|------|--------------|-----------|
| `tasks` | List, add, update, complete, and delete to-do items | Postgres + [Task API](docs/TASK_API.md) |
| `calendar` | List, add, update, and delete scheduled events | Postgres + [Calendar API](docs/CALENDAR_API.md) |
| `memory` | Remember, search, forget, and list durable facts about the user | pgvector embeddings + [Memory API](docs/MEMORY_API.md) |
| `web_search` | Look up current news, weather, sports, prices, and live facts | OpenAI Responses API (on when `WEB_SEARCH_ENABLED=true`) |
| `move` | Drive desk wheels: `stroll`, `forward`, `backward`, `turn_left`, `turn_right`, `stop` | ESP32 motor driver (`motor_drive.cpp`) |
| `emotion` | Set OLED face: `neutral`, `happy`, `excited`, `angry`, `sad`, `surprised`, `confused`, `sleepy`, `love` | ESP32 face display (`face_display.cpp`) — see [Emotion API](docs/EMOTION_API.md) |

Times for tasks and calendar are interpreted in the user's timezone (`COMPANION_TIMEZONE`, default `Asia/Jakarta`).

### Personality and personas

- **Personality** (`calm`, `energetic`, `professional`) — changes tone and how expressive the face is. Set via [Config API](docs/CONFIG_API.md) (`PATCH /api/v1/config` or `PUT /api/v1/config/personality`); applies live on the next turn when a voice session is connected.
- **Personas** — full character voices (Rocky, Minion, Grumpy, Pirate, Wizard, Jokowi) loaded from `CompanionServer/personas/*.md`. Switch live via [Persona API](docs/PERSONA_API.md); the next reply is in character without reconnecting.

### Conversation modes

Botchill adapts reply length and tone automatically:

- **Casual** (default) — short, friendly banter (1–2 sentences).
- **Serious** — no length cap when the user needs real help or depth.
- **Web search** — full spoken answers with specific facts after a lookup.

Recent memories are injected into the system prompt at session start (when `privacy.personalizationData` is on). Transcripts, audio, and tool calls are persisted for the [Conversation API](docs/CONVERSATION_API.md).

### Physical hardware features

| Feature | Hardware | Notes |
|---------|----------|-------|
| Voice I/O | INMP441 + MAX98357A | 16 kHz uplink, 24 kHz downlink; client-side VAD |
| Face | 1.3" SH1106 OLED @ 0x3C | FluxGarage RoboEyes + comic emotion marks |
| Motion | DRV8833 dual H-bridge | Gentle desk-area wheel motion only |
| Input | TTP223 touch on GPIO 3 | Short tap = start/end turn; long press = end session |

---

## Requirements

| Component | Requirement |
|-----------|-------------|
| Server | macOS 15+, Swift 6, Xcode command-line tools |
| Database | Docker (Postgres 17 + pgvector via `docker compose`) |
| Device | ESP32-S3 Dev Module with **QSPI PSRAM** |
| Hardware | INMP441 mic, MAX98357A amp, SH1106 OLED, DRV8833 + 2× gear motors, touch button (TTP223) |
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

**Database:** Data lives in Postgres via Docker (`companion-postgres` container, database name `companion`). Tables (`tasks`, `calendar_events`, `memories`, etc.) are created automatically when the server starts and runs migrations. To inspect:

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
   - **Adafruit SH110X** (or **Adafruit SSD1306** if your 1.3" panel is an SSD1306 clone — see `OLED_USE_SSD1306` in `config.h`)
   - **FluxGarage RoboEyes**
3. Board settings:
   - **ESP32S3 Dev Module**
   - **USB CDC On Boot** → Enabled
   - **PSRAM** → QSPI PSRAM
4. Edit `firmware/CompanionFirmware/config.h`:
   - `WIFI_SSID` / `WIFI_PASSWORD`
   - `COMPANION_SERVER_HOST` — your Mac's LAN IP (`ipconfig getifaddr en0`)
   - `COMPANION_DEVICE_TOKEN` — must match `DEVICE_TOKEN` in `.env`
5. Upload and open Serial Monitor at **115200** baud.

Expected boot: panel self-test → WiFi connected → `ws connected` → `session ready: <uuid>` → `>>> READY`.

### 3. Talk to it

1. **Tap once** — mic opens, short beep.
2. **Speak**, then pause ~1 s — VAD ends your turn and sends audio to the AI.
3. **Listen** to the reply through the speaker; watch the OLED face react.
4. **Keep talking** — follow-up turns are hands-free after TTS finishes.
5. **Tap again** (or **long press**) to end the conversation.

If you tap but never speak, a **4 s no-speech timeout** ends the session.

Try: *"What's on my calendar tomorrow?"*, *"Remember my dog is named Max"*, *"Stroll around the desk"*, *"What's the weather in Jakarta?"*, or *"Switch to Rocky"* (via Persona API from a terminal).

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
| OLED SDA | 8 | SH1106 I2C |
| OLED SCL | 9 | SH1106 I2C |
| Motor AIN1 / AIN2 | 1 / 2 | DRV8833 left wheel |
| Motor BIN1 / BIN2 | 11 / 10 | DRV8833 right wheel |
| Touch button | 3 | TTP223; other leg to GND |

Mic L/R pin tied to GND → left channel. Sample rate: **16 kHz mono** uplink, **24 kHz** downlink.

Pin map, VAD constants, and motor tuning: [docs/STABLE_V1.md](docs/STABLE_V1.md).

---

## Project layout

```
ai-companion-ch5/
├── CompanionServer/          # Swift backend (Hummingbird 2 + WebSocket)
│   ├── Sources/
│   │   ├── CompanionServer/  # WSS server, OpenAI Realtime, sub-agents, REST APIs
│   │   ├── CompanionDatabase/# Postgres repositories (tasks, calendar, memory, …)
│   │   ├── CompanionEnv/     # .env loading, logging
│   │   └── TestClient/       # Mac mic dev harness (no ESP hardware)
│   ├── personas/             # Character voice markdown files
│   ├── docker-compose.yaml   # Postgres for local dev
│   └── .env.example
├── firmware/
│   ├── CompanionFirmware/    # Production ESP32 firmware (mic + speaker + face + motors)
│   └── TestFirmware/         # Split test: Mac mic → server → ESP speaker
└── docs/
    ├── STABLE_V1.md          # Canonical v1 stack reference
    ├── PROJECT_SUMMARY.md    # Architecture overview + history
    └── *_API.md              # REST API docs for frontend integration
```

---

## Tooling

### Server executables

| Command | Purpose |
|---------|---------|
| `swift run CompanionServer` | Main WSS + REST server |
| `swift run TestClient` | Mac microphone → `/ws` (no ESP hardware) |
| `swift test` | Unit and API integration tests |
| `docker compose up -d` | Start Postgres (`CompanionServer/docker-compose.yaml`) |

All Swift commands run from `CompanionServer/`.

### Firmware targets

| Target | Path | Purpose |
|--------|------|---------|
| **CompanionFirmware** | `firmware/CompanionFirmware/` | Full integrated device: mic, speaker, face, motors |
| **TestFirmware** | `firmware/TestFirmware/` | Split path: Mac mic via TestClient, ESP plays TTS on `/speaker` |

Guides: [firmware/TESTING.md](firmware/TESTING.md), [firmware/TestFirmware/TESTING.md](firmware/TestFirmware/TESTING.md).

### REST APIs (frontend / curl)

All endpoints use `Authorization: Bearer <DEVICE_TOKEN>`.

| API | Base path | Doc |
|-----|-----------|-----|
| Config (settings) | `/api/v1/config` | [CONFIG_API.md](docs/CONFIG_API.md) |
| Personas | `/api/v1/personas` | [PERSONA_API.md](docs/PERSONA_API.md) |
| Profile | `/api/v1/profile` | [PROFILE_API.md](docs/PROFILE_API.md) |
| Tasks | `/api/v1/tasks` | [TASK_API.md](docs/TASK_API.md) |
| Calendar | `/api/v1/calendar/events` | [CALENDAR_API.md](docs/CALENDAR_API.md) |
| Memories | `/api/v1/memories` | [MEMORY_API.md](docs/MEMORY_API.md) |
| Conversations | `/api/v1/conversations` | [CONVERSATION_API.md](docs/CONVERSATION_API.md) |

Health checks: `GET /health` → `ok`, `GET /ping` → `pong`.

### Debug and diagnostics

- **Serial monitor** (115200 baud) — VAD metrics (`[VAD] energy=…`), session states, motor/face commands.
- **Debug audio** — WAV dumps under `CompanionServer/debug-audio/` when the package root is found.
- **Postgres shell** — `docker exec -it companion-postgres psql -U postgres -d companion`.
- **Resilience** — self-healing for idle Realtime socket loss, stuck PROCESSING turns, and mic I2S wedge; see [docs/STABLE_V1.md](docs/STABLE_V1.md#resilience-added-2026-07-09).

### Cursor agent skills (`.cursor/skills/`)

| Skill | Use when |
|-------|----------|
| [esp32](.cursor/skills/esp32/SKILL.md) | Firmware, I2S, PSRAM, Arduino/ESP32-S3 |
| [hummingbird](.cursor/skills/hummingbird/SKILL.md) | Swift WebSocket/HTTP server, wire protocol |
| [postgres-best-practices](.cursor/skills/postgres-best-practices/SKILL.md) | Schema, indexing, pgvector memory |

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
| `WEB_SEARCH_ENABLED` | `true` | Enable `web_search` tool for current facts |
| `OPENAI_EMBEDDING_MODEL` | `text-embedding-3-small` | Embeddings for memory recall |
| `DATABASE_URL` | `postgres://postgres:postgres@localhost:5432/companion` | Postgres connection (requires `docker compose up -d`) |

Full list: `CompanionServer/.env.example`.

---

## Testing

Functional test checklist (single turn, follow-up, no-speech timeout, barge-in, WiFi drop, move/emotion commands): [firmware/TESTING.md](firmware/TESTING.md).

---

## Known limitations (v1)

- Audio on the wire is **raw PCM**, not Opus — fine for LAN, higher bandwidth than a production codec.
- No on-device wake word (Edge Impulse was too slow on ESP32-S3); tap + VAD is the stable model. See [docs/WAKE_WORD_DEBUG_REPORT.md](docs/WAKE_WORD_DEBUG_REPORT.md).
- WebSocket sessions do not resume after disconnect — reconnect gets a new session ID.
- Device pairing in Config API is mock-only (`Bocil-Desk-01` / `paired`); no real unpair flow yet.

---

## Documentation

| Doc | Contents |
|-----|----------|
| [docs/STABLE_V1.md](docs/STABLE_V1.md) | Wire protocol, pipeline, VAD constants, resilience, quick start |
| [docs/TASK_API.md](docs/TASK_API.md) | Task list REST API for frontend (`TaskView`) |
| [docs/CALENDAR_API.md](docs/CALENDAR_API.md) | Calendar REST API for frontend (`CalendarView`) |
| [docs/CONFIG_API.md](docs/CONFIG_API.md) | Settings REST API for frontend (`SettingsView`) |
| [docs/PERSONA_API.md](docs/PERSONA_API.md) | Character persona picker API |
| [docs/PROFILE_API.md](docs/PROFILE_API.md) | User profile + focus time API |
| [docs/MEMORY_API.md](docs/MEMORY_API.md) | Long-term memory browse/delete API |
| [docs/CONVERSATION_API.md](docs/CONVERSATION_API.md) | Read-only conversation history + audio playback API |
| [docs/PROJECT_SUMMARY.md](docs/PROJECT_SUMMARY.md) | Full architecture and wake-word debug history |
| [docs/OMNIBOT_REFERENCE.md](docs/OMNIBOT_REFERENCE.md) | Related OmniBot/Pixel robot backend reference |
| [firmware/TESTING.md](firmware/TESTING.md) | CompanionFirmware test sequence |
| [docs/ARCHIVED_LEGACY_PIPELINE.md](docs/ARCHIVED_LEGACY_PIPELINE.md) | Removed Cartesia/Kokoro multi-stage pipeline |
