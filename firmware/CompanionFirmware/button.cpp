#include "button.h"

#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include "config.h"

// Poll interval in ms.
#define POLL_MS 50

// Require this many consecutive "not touched" polls before a short tap fires.
// At POLL_MS=50ms, 5 polls = 250ms debounce.
#define RELEASE_DEBOUNCE_COUNT 5

// Hold at least this long to count as long press (fires once while still held).
#define LONG_PRESS_MS 800

static ButtonEventCb s_cb;
static void *s_cbCtx;

static void touchTask(void *arg) {
    pinMode(PIN_BUTTON, INPUT);
    bool lastTouched = false;
    bool longPressFired = false;
    uint32_t pressStartMs = 0;
    int releaseCounter = 0;
    while (true) {
        // External touch sensor module (e.g. TTP223) outputs digital HIGH when touched.
        bool touched = (digitalRead(PIN_BUTTON) == HIGH);
        uint32_t nowMs = millis();

        if (touched) {
            releaseCounter = 0;
            if (!lastTouched) {
                pressStartMs = nowMs;
                longPressFired = false;
                lastTouched = true;
            } else if (!longPressFired && (nowMs - pressStartMs) >= LONG_PRESS_MS) {
                longPressFired = true;
                Serial.println("[BUTTON] long press");
                if (s_cb) {
                    s_cb(BUTTON_EVENT_LONG_PRESS, s_cbCtx);
                }
            }
        } else {
            if (lastTouched) {
                releaseCounter++;
                if (releaseCounter >= RELEASE_DEBOUNCE_COUNT) {
                    if (!longPressFired) {
                        Serial.println("[BUTTON] short tap");
                        if (s_cb) {
                            s_cb(BUTTON_EVENT_SHORT_TAP, s_cbCtx);
                        }
                    }
                    lastTouched = false;
                    releaseCounter = 0;
                }
            }
        }
        vTaskDelay(pdMS_TO_TICKS(POLL_MS));
    }
}

void buttonInit(ButtonEventCb cb, void *ctx) {
    s_cb = cb;
    s_cbCtx = ctx;
    xTaskCreate(touchTask, "touch_task", 4096, NULL, 5, NULL);
}
