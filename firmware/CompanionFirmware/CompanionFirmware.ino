#include <WiFi.h>

#include "audio_io.h"
#include "config.h"
#include "face_display.h"
#include "ws_session.h"

static void connectWiFi() {
    WiFi.mode(WIFI_STA);
    WiFi.setAutoReconnect(true);
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

    Serial.printf("connecting to %s", WIFI_SSID);
    while (WiFi.status() != WL_CONNECTED) {
        delay(300);
        Serial.print(".");
    }
    Serial.println(" connected");
}

void setup() {
    Serial.begin(115200);
    delay(800);
    Serial.printf("\n[BOOT] CompanionFirmware heap=%u psram=%u psramFound=%d\n",
                  static_cast<unsigned>(ESP.getFreeHeap()),
                  static_cast<unsigned>(ESP.getFreePsram()),
                  psramFound());
    faceDisplayInit();
    faceDisplaySetMode(FACE_BOOT);
    faceDisplaySetStatusLine("Booting...");
    audioIoInit();
    audioIoSpeakerBeep();
    connectWiFi();
    faceDisplaySetMode(FACE_CONNECTING);
    faceDisplaySetStatusLine("Connecting...");
    wsSessionBegin();
}

void loop() {
    wsSessionLoop();
    faceDisplayLoop();
}
