#pragma once

// Copy values from CompanionServer/.env and your LAN before flashing.

#define WIFI_SSID "ESPServer"
#define WIFI_PASSWORD "mayunskuy123"

#define COMPANION_SERVER_HOST "10.75.190.219"
#define COMPANION_SERVER_PORT 8080
#define COMPANION_SERVER_PATH "/speaker"
#define COMPANION_USE_TLS false

// Must match DEVICE_TOKEN in CompanionServer/.env
#define COMPANION_DEVICE_TOKEN "O6k4xgaZBLhPHCbzsbZqiyFcPvM7LfsCrw7fdgjy4wWLW8urQ0ERSgWHoXTKDyB1"

// Speaker-only: receives TTS fan-out from CompanionServer. Mic is TestClient on Mac.
#define HAS_MIC 0
#define HAS_SPEAKER 1

// Kept for shared button module compilation; GPIO0 is the common BOOT button on ESP32-S3 dev boards.
#define PIN_BUTTON 0

#define PIN_SPK_BCLK 5
#define PIN_SPK_WS 6
#define PIN_SPK_DOUT 7
