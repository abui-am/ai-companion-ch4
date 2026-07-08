#pragma once

// Stable stack v1 — interaction model and pins: docs/STABLE_V1.md
// Arduino IDE: Tools → PSRAM → QSPI PSRAM (CoreS3 and most ESP32-S3 boards).

// Fill these in before flashing. Mirrors the showcase-phase auth model in
// the plan: shared compile-time token, no rotation, LAN-only.
#define WIFI_SSID "iphoneGung"
#define WIFI_PASSWORD "1234567890"

#define COMPANION_SERVER_HOST "172.20.10.3"
#define COMPANION_SERVER_PORT 8080
#define COMPANION_SERVER_PATH "/ws"
#define COMPANION_USE_TLS false // true => wss:// (beginSSL)

// Must match the DEVICE_TOKEN env var CompanionServer was started with.
#define COMPANION_DEVICE_TOKEN                                                 \
  "O6k4xgaZBLhPHCbzsbZqiyFcPvM7LfsCrw7fdgjy4wWLW8urQ0ERSgWHoXTKDyB1"

// Touch sensor (TTP223 etc.): HIGH when touched.
// Short tap starts a conversation from idle; during capture it forces end-of-turn
// when noisy-room VAD is stuck. Long press (~800 ms) ends the conversation
// (including barging in mid AI-reply). Turns in between are automatic — see
// ws_session.cpp's silence-based VAD turn-taking.
// GPIO3 on purpose: it's a strapping pin with no internal pull, but that only
// matters for pins the ESP32 *drives* before firmware configures them (like
// the motor lines below). Here the ESP32 only reads it, the TTP223 module
// actively drives the line itself, and buttonInit() doesn't even start
// polling until wsSessionBegin() runs near the end of setup() — so the
// boot-time float window never gets sampled.
#define PIN_BUTTON 3
#define TOUCH_THRESHOLD 40 // unused for digital touch modules; kept for compat

// Mic (I2S RX) — INMP441. L/R pin tied to GND → left channel.
#define PIN_MIC_BCLK 12 // SCK / BCLK
#define PIN_MIC_WS 4    // WS
#define PIN_MIC_DIN 13  // SD / DIN
#define MIC_CHANNEL_LEFT true
// Voice uplink / capture — INMP441 24-bit in 32-bit I2S slot; >>14 is the
// coarse level before peak normalization below.
#define MIC_DATA_SHIFT 14
// Peak-normalize uplink toward this int16 level (~-2.7 dBFS). WebRTC/STT
// guidance: avoid clipping, leave headroom; don't use fast consumer AGC.
#define MIC_UPLINK_TARGET_PEAK 24000

// Speaker amp (I2S TX) — MAX98357A.
#define PIN_SPK_BCLK 6 // BCLK
#define PIN_SPK_WS 7   // LRC
#define PIN_SPK_DOUT 5 // DIN

// Speaker output boost (max amplitude ~32767). Lower if you hear clipping.
#define SPEAKER_BEEP_AMPLITUDE 8000
#define SPEAKER_PLAYBACK_GAIN 1.5

// Face OLED — 1.3" 128x64, I2C @ 0x3C. Uses FluxGarage RoboEyes plus either
// Adafruit SH110X or Adafruit SSD1306 (install from Arduino Library Manager).
// Many 1.3" modules sold as SH1106 actually carry an SSD1306 — the tell is
// that init succeeds (chip ACKs at 0x3C) but the panel stays black, because
// the SH1106 driver never sends the SSD1306 charge-pump-enable command.
// Set to 1 for SSD1306, 0 for a real SH1106.
#define OLED_USE_SSD1306 0
#define PIN_OLED_SDA 8
#define PIN_OLED_SCL 9
#define OLED_I2C_ADDRESS 0x3C
#define OLED_RESET -1

// Wheel motors — DRV8833 dual H-bridge (5 V rail shared with speaker amp).
// Left motor: AIN1/AIN2. Right motor: BIN1/BIN2.
// BIN1 avoids GPIO3 on purpose: it's a strapping pin with *no* internal pull
// resistor, so it floats fully undefined from power-on-reset until
// motorInit() runs — long enough to glitch the DRV8833 input and spin the
// right wheel on its own at boot (the ESP32 drives this pin, unlike the
// touch sensor above, so a float here is directly visible as motion).
// GPIO11 (former button pin) has no such issue.
#define PIN_MOTOR_AIN1 1
#define PIN_MOTOR_AIN2 2
#define PIN_MOTOR_BIN1 11
#define PIN_MOTOR_BIN2 10

// Keep duty low and ramp in — avoids brownouts on the shared 5 V supply.
#define MOTOR_PWM_FREQ 20000
#define MOTOR_PWM_RES 8
#define MOTOR_PWM_MIN 100      // floor so wheels actually break static friction
#define MOTOR_PWM_MAX 150      // ~59% duty — slow but enough to move on 5 V
#define MOTOR_PWM_TURN 120     // slower pivot turns
#define MOTOR_RAMP_MS 350
#define MOTOR_DEFAULT_DURATION_MS 450
#define MOTOR_STROLL_SEGMENTS 3
#define MOTOR_STROLL_FORWARD_MS 400
#define MOTOR_STROLL_TURN_MS 250
#define MOTOR_STROLL_PAUSE_MS 200
