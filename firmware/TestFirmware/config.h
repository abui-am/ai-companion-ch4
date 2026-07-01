#pragma once

// Copy values from CompanionServer/.env and your LAN before flashing.
#define WIFI_SSID "Wifi iuran"
#define WIFI_PASSWORD "sekgangguan"

#define COMPANION_SERVER_HOST "192.168.1.3"
#define COMPANION_SERVER_PORT 8080
#define COMPANION_SERVER_PATH "/speaker"
#define COMPANION_USE_TLS false

// Must match DEVICE_TOKEN in CompanionServer/.env
#define COMPANION_DEVICE_TOKEN                                                 \
  "O6k4xgaZBLhPHCbzsbZqiyFcPvM7LfsCrw7fdgjy4wWLW8urQ0ERSgWHoXTKDyB1"

// Speaker-only: receives TTS fan-out from CompanionServer. Mic is TestClient on
// Mac.
#define HAS_MIC 0
#define HAS_SPEAKER 1

// Play a 440 Hz beep on boot to verify I2S + amp wiring before testing the
// server pipeline.
#define SPEAKER_SELF_TEST_ON_BOOT 1

// Kept for shared button module compilation; GPIO0 is the common BOOT button on
// ESP32-S3 dev boards.
#define PIN_BUTTON 0

// MAX98357A — must match your wiring (same as CompanionFirmware).
// Do NOT use GPIO 6–11 on ESP32: they are wired to SPI flash and will
// WDT-reset.
#define PIN_SPK_BCLK 33 // BCK
#define PIN_SPK_WS 25   // LRC
#define PIN_SPK_DOUT 32 // DIN
