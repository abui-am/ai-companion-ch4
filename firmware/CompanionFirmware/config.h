#pragma once

// Edge Impulse wake-word model adds ~400 KB — sketch is ~1.7 MB total.
// Default ESP32/ESP32-S3 partition is only ~1.2 MB app; before upload set:
//   Tools → Partition Scheme → Huge APP (3MB No OTA/1MB SPIFFS)
// or, if you need OTA: Minimal SPIFFS (1.9MB APP with OTA/128KB SPIFFS).
// Both fit a standard 4MB flash module. NOTE: changing Tools → Board resets
// this menu back to the 1.2 MB default — re-check it after every board
// change or you'll see "text section exceeds available space in board".

// Fill these in before flashing. Mirrors the showcase-phase auth model in
// the plan: shared compile-time token, no rotation, LAN-only.
#define WIFI_SSID "sayaMayunn"
#define WIFI_PASSWORD "123456789"

#define COMPANION_SERVER_HOST "10.75.190.134"
#define COMPANION_SERVER_PORT 8080
#define COMPANION_SERVER_PATH "/ws"
#define COMPANION_USE_TLS false // true => wss:// (beginSSL)

// Must match the DEVICE_TOKEN env var CompanionServer was started with.
#define COMPANION_DEVICE_TOKEN                                                 \
  "O6k4xgaZBLhPHCbzsbZqiyFcPvM7LfsCrw7fdgjy4wWLW8urQ0ERSgWHoXTKDyB1"

// ESP32-S3 wiring (INMP441 mic + MAX98357A speaker).
// Classic ESP32 used different pins — see git history if porting back.

// Push-to-talk / touch sensor. GPIO4 is speaker DIN on this board — button
// moved to GPIO5; change if your module uses another free pin.
#define PIN_BUTTON 11
#define TOUCH_THRESHOLD 40 // below this value = touched; tune per enclosure

#define HAS_MIC 1

// Mic (I2S RX) — INMP441. L/R pin tied to GND → left channel.
#define PIN_MIC_BCLK 1 // SCK / BCLK
#define PIN_MIC_DIN 2  // SD / DIN
#define PIN_MIC_WS 3   // WS / LRCLK
#define MIC_CHANNEL_LEFT true

// Speaker amp (I2S TX) — MAX98357A.
#define PIN_SPK_BCLK 6 // BCK
#define PIN_SPK_WS 7   // LRC
#define PIN_SPK_DOUT 4 // DIN

// Speaker output boost (max amplitude ~32767). Lower if you hear clipping.
#define SPEAKER_BEEP_AMPLITUDE 8000
#define SPEAKER_PLAYBACK_GAIN 1.5
