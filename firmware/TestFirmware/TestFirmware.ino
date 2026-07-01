#include <WiFi.h>

#include "audio_io.h"
#include "config.h"
#include "mic_server_upload.h"
#include "ws_session.h"

static void connectWiFi() {
    WiFi.mode(WIFI_STA);
    WiFi.setAutoReconnect(true);
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

    Serial.printf("wifi: connecting to %s", WIFI_SSID);
    while (WiFi.status() != WL_CONNECTED) {
        delay(300);
        Serial.print(".");
    }
    Serial.printf(" connected (%s)\n", WiFi.localIP().toString().c_str());
}

void setup() {
    Serial.begin(MIC_LOOPBACK_SERIAL_BAUD);
    delay(500);
    Serial.println();
    Serial.println("=== TestFirmware ===");

#if MIC_LOOPBACK_TEST_MODE
    audioIoInit();
#if SPEAKER_SELF_TEST_ON_BOOT
    audioIoSpeakerSelfTest();
#else
    audioIoSpeakerBeep();
#endif
    audioIoPrimeMic();
    audioIoLogLoopbackConfig();
    if (!audioIoLoopbackAllocBuffer()) {
        Serial.println("[MIC LOOPBACK] FATAL: no record buffer — halting");
        while (true) {
            delay(1000);
        }
    }
    audioIoMicLoopbackBegin();
    connectWiFi();
    micServerUploadBegin();
#else
    connectWiFi();
    wsSessionBegin();
#endif
}

void loop() {
#if MIC_LOOPBACK_TEST_MODE
#if MIC_UPLOAD_TO_SERVER
    micServerUploadLoop();
#endif
    delay(10);
#else
    wsSessionLoop();
#endif
}
