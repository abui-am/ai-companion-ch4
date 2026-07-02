#pragma once

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

// Capacitive touch toggle button. GPIO4 = Touch0 on ESP32 dev module.
// Tap once to start listening, tap again to stop.
#define PIN_BUTTON 4
#define TOUCH_THRESHOLD 40 // below this value = touched; tune per enclosure

#define HAS_MIC 1

// Mic (I2S RX) — INMP441. L/R pin tied to GND → left channel.
#define PIN_MIC_BCLK 14 // SCK
#define PIN_MIC_WS 12   // WS
#define PIN_MIC_DIN 35  // SD
#define MIC_CHANNEL_LEFT true

// Speaker amp (I2S TX) — MAX98357A.
#define PIN_SPK_BCLK 33 // BCK
#define PIN_SPK_WS 25   // LRC
#define PIN_SPK_DOUT 32 // DIN

// Speaker output boost (max amplitude ~32767). Lower if you hear clipping.
#define SPEAKER_BEEP_AMPLITUDE 8000
#define SPEAKER_PLAYBACK_GAIN 2
