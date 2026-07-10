#pragma once

// Copy values from CompanionServer/.env and your LAN before flashing.
#define WIFI_SSID "BocilServer"
#define WIFI_PASSWORD "1234567890"

#define COMPANION_SERVER_HOST "192.168.1.3"
#define COMPANION_SERVER_PORT 8080
#define COMPANION_SERVER_PATH "/speaker"
#define COMPANION_SERVER_WS_PATH "/ws"
#define COMPANION_USE_TLS false

// Must match DEVICE_TOKEN in CompanionServer/.env
#define COMPANION_DEVICE_TOKEN                                                 \
  "O6k4xgaZBLhPHCbzsbZqiyFcPvM7LfsCrw7fdgjy4wWLW8urQ0ERSgWHoXTKDyB1"

// Set to 1: tap to record mic, tap again to play back (no WiFi/server).
// Set to 0: speaker-only TTS test via CompanionServer /speaker.
#define MIC_LOOPBACK_TEST_MODE 0

#if MIC_LOOPBACK_TEST_MODE
#define HAS_MIC 1
#define HAS_SPEAKER 1
#define SPEAKER_SELF_TEST_ON_BOOT 1
#else
#define HAS_MIC 0
#define HAS_SPEAKER 1
#define SPEAKER_SELF_TEST_ON_BOOT 1
#endif

// Touch sensor (TTP223 etc.): HIGH when touched. Same as CompanionFirmware
// GPIO11.
#if MIC_LOOPBACK_TEST_MODE
#define USE_TOUCH_BUTTON 1
#define PIN_BUTTON 11
#else
#define USE_TOUCH_BUTTON 0
#define PIN_BUTTON 0
#endif

// Mic (I2S RX) — INMP441. L/R pin tied to GND → left channel.
#define PIN_MIC_BCLK 1 // SCK / BCLK
#define PIN_MIC_WS 3   // WS
#define PIN_MIC_DIN 2  // SD / DIN
#define MIC_CHANNEL_LEFT true
// INMP441 gain: increase to reduce clipping (try 12–13), decrease if too quiet.
#define MIC_DATA_SHIFT 13

// MAX98357A — must match your wiring (same as CompanionFirmware).
#define PIN_SPK_BCLK 6 // BCLK
#define PIN_SPK_WS 7   // LRC
#define PIN_SPK_DOUT 4 // DIN

// After tap-tap record, upload PCM to CompanionServer /ws
// (debug-audio/*-uplink.wav).
#define MIC_UPLOAD_TO_SERVER 0
#define MIC_LOOPBACK_LOG_EVERY_FRAME 0
#define MIC_LOOPBACK_SUMMARY_EVERY 30
// Max seconds per recording session (10 sec ≈ 320 KB — enable PSRAM if alloc
// fails).
#define MIC_LOOPBACK_MAX_RECORD_SEC 10
// Boost playback volume (1–4).
#define MIC_LOOPBACK_MONITOR_GAIN 4
// Serial @ 921600 recommended when logging every frame.
#define MIC_LOOPBACK_SERIAL_BAUD 921600
