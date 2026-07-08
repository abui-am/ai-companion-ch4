#pragma once

// Stable stack v1 — interaction model and pins: docs/STABLE_V1.md
// Arduino IDE: Tools → PSRAM → QSPI PSRAM (CoreS3 and most ESP32-S3 boards).

// Fill these in before flashing. Mirrors the showcase-phase auth model in
// the plan: shared compile-time token, no rotation, LAN-only.
#define WIFI_SSID "BocilServer"
#define WIFI_PASSWORD "1234567890"

#define COMPANION_SERVER_HOST "10.235.115.130"
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
#define PIN_BUTTON 11
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

// Face OLED — 1.3" SH1106 (128x64), I2C @ 0x3C. Uses Adafruit SH110X +
// FluxGarage RoboEyes (install both from Arduino Library Manager).
#define PIN_OLED_SDA 8
#define PIN_OLED_SCL 9
#define OLED_I2C_ADDRESS 0x3C
#define OLED_RESET -1

// Wheel motors — DRV8833 dual H-bridge (5 V rail shared with speaker amp).
// Left motor: AIN1/AIN2. Right motor: BIN1/BIN2.
#define PIN_MOTOR_AIN1 1
#define PIN_MOTOR_AIN2 2
#define PIN_MOTOR_BIN1 3
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
