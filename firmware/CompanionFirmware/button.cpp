#include "button.h"

#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include "config.h"

// Poll interval in ms.
#define POLL_MS 50

// Require this many consecutive "not touched" polls before firing RELEASED.
// At POLL_MS=50ms, 5 polls = 250ms debounce.
#define RELEASE_DEBOUNCE_COUNT 5

static ButtonEventCb s_cb;
static void *s_cbCtx;

static void touchTask(void *arg) {
    pinMode(PIN_BUTTON, INPUT);
    bool lastTouched = false;
    int releaseCounter = 0;
    while (true) {
        // External touch sensor module (e.g. TTP223) outputs digital HIGH when touched.
        bool touched = (digitalRead(PIN_BUTTON) == HIGH);

        if (touched) {
            releaseCounter = 0;
            if (!lastTouched) {
                Serial.println("[BUTTON] pressed");
                if (s_cb) s_cb(BUTTON_EVENT_PRESSED, s_cbCtx);
                lastTouched = true;
            }
        } else {
            if (lastTouched) {
                releaseCounter++;
                if (releaseCounter >= RELEASE_DEBOUNCE_COUNT) {
                    Serial.println("[BUTTON] released");
                    if (s_cb) s_cb(BUTTON_EVENT_RELEASED, s_cbCtx);
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
