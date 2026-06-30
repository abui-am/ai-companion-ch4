#pragma once

// Fill these in before flashing. Mirrors the showcase-phase auth model in
// the plan: shared compile-time token, no rotation, LAN-only.
#define WIFI_SSID "ESPServer"
#define WIFI_PASSWORD "mayunskuy123"

#define COMPANION_SERVER_HOST "192.168.1.100"
#define COMPANION_SERVER_PORT 8080
#define COMPANION_SERVER_PATH "/ws"
#define COMPANION_USE_TLS false // true => wss:// (beginSSL)

// Must match the DEVICE_TOKEN env var CompanionServer was started with.
#define COMPANION_DEVICE_TOKEN "your-device-token"

// Push-to-talk button: active-low, internal pull-up. Many ESP32-S3 dev
// boards expose GPIO0 as the BOOT button, usable for bring-up.
#define PIN_BUTTON 0

// Mic hardware not on the board yet — set to 1 and fill in real pins once
// it's wired up. Until then, audio capture is a no-op and turns are
// validated via CompanionServer/TestClient (real MacBook mic) instead.
#define HAS_MIC 0

// Mic (I2S RX) — e.g. INMP441. Unused while HAS_MIC is 0.
#define PIN_MIC_BCLK 4
#define PIN_MIC_WS 5
#define PIN_MIC_DIN 6
#define MIC_CHANNEL_LEFT true // false if your mic's L/R pin selects right

// Speaker amp (I2S TX) — e.g. MAX98357A.
#define PIN_SPK_BCLK 5
#define PIN_SPK_WS 6
#define PIN_SPK_DOUT 7
