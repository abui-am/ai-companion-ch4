# Mic Stall & Long-Session Stability — Debug Report (2026-07-09)

One overnight debugging session, three real bugs, all sharing the same user-visible
symptom: **the robot works for a while, then stops responding until something is
restarted.** This report records the diagnosis chain so the next "it keeps
thinking" issue starts from evidence, not guesses.

## Symptoms observed (in the order they appeared)

1. OLED black at boot ("is the display broken?")
2. `[WS] DISCONNECTED (was in state 0) — resetting` every ~17 s
3. Conversations worked, then every turn hung on the thinking face after a few
   minutes of idle ("always thinking now")
4. After ~50 s of continuous conversation: turn-start beep disappears, robot
   stops hearing anything, only a reboot recovers it

## Root causes (four distinct problems)

### 1. OLED "broken" — it was never drawn to

The eyes render exclusively from `faceDisplayLoop()` in `loop()`, which doesn't
run until `setup()` finishes — and `setup()` blocks in `connectWiFi()`. With
WiFi unable to connect (iPhone hotspot on 5 GHz; ESP32-S3 is 2.4 GHz-only), the
screen stayed black with perfectly working hardware.

**Fix:** white-flash panel self-test right after display init + eyes animate
during the WiFi wait. Plus `OLED_USE_SSD1306` config switch after chasing the
SH1106-vs-SSD1306 clone question (this panel is a real SH1106; the SSD1306
driver produced 2-px-shifted garbage, which is the diagnostic tell).

Also required: **Personal Hotspot → Maximize Compatibility** (forces 2.4 GHz),
and `COMPANION_SERVER_HOST` updated to the Mac's hotspot IP (changes per
session — hotspot DHCP; long-term answer is BLE provisioning).

### 2. "Always thinking" after idle — dead upstream Realtime socket

OpenAI reaps idle Realtime sockets. `OpenAIRealtimeService` connected once and
never reconnected; after the reap, every `commitAndCreateResponse` logged
`socket not connected` and yielded `.error` — which `VoiceSession` only
*logged*. Because `phase` never reached `.streamingTTS`, the
`guard phase == .streamingTTS else { return }` exit skipped `tts.end`/error
send entirely: **the device was never told the turn died** and waited in
PROCESSING forever. Server restart "fixed" it by reconnecting everything —
classic works-again-for-a-while pattern.

**Fixes:**
- `ensureConnected()` reconnects the Realtime socket lazily before appends and
  commits (`OpenAIRealtimeService.swift`)
- turns that end without TTS send `error code=turn_failed` and reset `phase`
  (`VoiceSession.swift`, both the realtime and realtime+cartesia paths)

### 3. Beep disappears after long conversations — mic I2S wedge

The turn-start beep is played by `captureTask` on CAPTURING entry. That task
assembles mic frames in `audioIoReadUplinkFrame()`, whose read loop had **no
deadline** — it spun until a full frame arrived. Every turn stop/starts the mic
I2S (`i2s_stop`/`i2s_start`); the legacy ESP-IDF I2S driver can wedge after
many such cycles and deliver nothing. Result: `captureTask` starved inside the
read loop → no beep, no capture, no VAD, states change but nothing services
them. Only a reboot (fresh driver install) recovered — exactly what users
reported.

**Fixes (self-healing, `audio_io.cpp` + `ws_session.cpp`):**
- `audioIoReadUplinkFrame()` gives up after a 1 s deadline
  (`audio: mic read deadline ... — mic stalled?`)
- two consecutive empty reads while the mic should be running →
  `audioIoMicRecover()`: uninstall + reinstall the mic I2S driver in place,
  restart, re-prime (`audio: mic recovery ok`)
- repeated `mic recovery FAILED` = the mic is electrically gone (wiring on
  GPIO 12/4/13), not wedged — hardware, not software

### 4. Red herrings that burned time (recorded so they don't again)

- **PostgresNIO "run ping pong" / "Connection closed"** — the DB pool's idle
  keepalive and idle-connection reaping. Appears whenever the server is quiet,
  so it *correlates* with every idle-triggered failure while causing none of
  them. `psql_connection_id` incrementing (0→1→2) is the pool reopening on
  demand, i.e. proof it recovers.
- **"no_speech_timeout" aborts** — often the mic wedge (symptom 3) upstream,
  not VAD tuning. Check `[VAD] energy=` lines before touching thresholds.
- **clangd errors in the IDE** (`'Arduino.h' file not found`, unknown FreeRTOS
  types) — the linter has no Arduino include paths; the Arduino build is the
  source of truth.
- **Server run path** — the server is launched from **Xcode** (DerivedData
  binary), so `swift build` in the terminal does *not* update the running
  server. Restart via Xcode Stop/Run after Swift changes.

## Tried and reverted (bisect hygiene)

To rule today's changes in/out, these were added, then reverted when the
failure reproduced without them — the long-session bug predates them all:

- `enableHeartbeat(15000, 3000, 2)` on the device WS (hotspot NAT reaps idle
  TCP; worth re-adding once the mic fix soaks — pong timeout may need to be
  generous during heavy TTS streaming)
- `WiFi.setTxPower(WIFI_POWER_11dBm)` (heat/brownout mitigation)
- 30 s PROCESSING watchdog + tap-during-thinking cancel (good UX safety nets;
  candidates to re-add deliberately, one at a time)

## Verification

Long multi-turn conversation (>1 min continuous talking), then idle >5 min,
then talk again. Success criteria: every turn answered; any
`mic recovery`/`realtime socket down — reconnecting` lines in the logs are the
mechanisms working, not failures. Escape hatch at all times: long press ends
the conversation from any state.
