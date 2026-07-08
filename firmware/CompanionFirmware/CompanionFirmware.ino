#include <WiFi.h>

#include "audio_io.h"
#include "config.h"
#include "face_display.h"
#include "motor_drive.h"
#include "ws_session.h"

static void connectWiFi() {
    WiFi.mode(WIFI_STA);
    WiFi.setAutoReconnect(true);
    // Modem sleep drops idle TCP sockets within a few seconds — kills /ws before
    // session.ready is read unless loop() services the socket continuously.
    WiFi.setSleep(false);
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

    Serial.printf("connecting to %s", WIFI_SSID);
    while (WiFi.status() != WL_CONNECTED) {
        // Keep the face alive while blocked here — loop() (the only other
        // place eyes render) doesn't run until this returns.
        for (int i = 0; i < 10; i++) {
            faceDisplayLoop();
            delay(30);
        }
        Serial.print(".");
    }
    Serial.printf(" connected (%s)\n", WiFi.localIP().toString().c_str());
}

// Force the motor driver inputs to a defined LOW state before anything else
// runs (Serial/display init take long enough for a floating pin to glitch
// the DRV8833 and twitch a wheel at boot). motorInit() re-configures these
// pins for PWM later; this only closes the gap between reset and that call.
static void motorSafeStateEarly() {
    const uint8_t pins[] = {PIN_MOTOR_AIN1, PIN_MOTOR_AIN2, PIN_MOTOR_BIN1,
                             PIN_MOTOR_BIN2};
    for (uint8_t pin : pins) {
        pinMode(pin, OUTPUT);
        digitalWrite(pin, LOW);
    }
}

void setup() {
    motorSafeStateEarly();
    Serial.begin(115200);
    // Native USB-CDC re-enumerates after reset; wait (up to 4 s) for the
    // monitor to reattach so early boot lines like [FACE] aren't dropped.
    const uint32_t serialWaitStart = millis();
    while (!Serial && millis() - serialWaitStart < 4000) {
        delay(10);
    }
    delay(300);
    Serial.printf("\n[BOOT] CompanionFirmware heap=%u psram=%u psramFound=%d\n",
                  static_cast<unsigned>(ESP.getFreeHeap()),
                  static_cast<unsigned>(ESP.getFreePsram()),
                  psramFound());
    faceDisplayInit();
    faceDisplaySetMode(FACE_BOOT);
    faceDisplaySetStatusLine("Booting...");
    motorInit();
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
