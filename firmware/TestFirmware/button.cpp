#include "button.h"

#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/task.h>

#include "config.h"

#if USE_TOUCH_BUTTON

#define POLL_MS 50
#define RELEASE_DEBOUNCE_COUNT 5

static ButtonEventCb s_cb;
static void *s_cbCtx;

static void touchTask(void *arg) {
    (void)arg;
    pinMode(PIN_BUTTON, INPUT);
    bool lastTouched = false;
    int releaseCounter = 0;
    while (true) {
        bool touched = (digitalRead(PIN_BUTTON) == HIGH);
        if (touched) {
            releaseCounter = 0;
            if (!lastTouched) {
                Serial.println("[BUTTON] touch pressed");
                if (s_cb) {
                    s_cb(BUTTON_EVENT_PRESSED, s_cbCtx);
                }
                lastTouched = true;
            }
        } else {
            if (lastTouched) {
                releaseCounter++;
                if (releaseCounter >= RELEASE_DEBOUNCE_COUNT) {
                    Serial.println("[BUTTON] touch released");
                    if (s_cb) {
                        s_cb(BUTTON_EVENT_RELEASED, s_cbCtx);
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

#else

#define DEBOUNCE_MS 30

static QueueHandle_t s_isrQueue;
static ButtonEventCb s_cb;
static void *s_cbCtx;

static void IRAM_ATTR isrHandler() {
    uint32_t dummy = 0;
    BaseType_t woken = pdFALSE;
    xQueueSendFromISR(s_isrQueue, &dummy, &woken);
    if (woken) {
        portYIELD_FROM_ISR();
    }
}

static void buttonTask(void *arg) {
    (void)arg;
    uint32_t dummy;
    int lastLevel = HIGH;

    while (true) {
        if (xQueueReceive(s_isrQueue, &dummy, portMAX_DELAY)) {
            vTaskDelay(pdMS_TO_TICKS(DEBOUNCE_MS));
            int level = digitalRead(PIN_BUTTON);
            if (level == lastLevel) {
                continue;
            }
            lastLevel = level;

            if (s_cb == nullptr) {
                continue;
            }
            if (level == LOW) {
                Serial.println("button: pressed");
                s_cb(BUTTON_EVENT_PRESSED, s_cbCtx);
            } else {
                Serial.println("button: released");
                s_cb(BUTTON_EVENT_RELEASED, s_cbCtx);
            }
        }
    }
}

void buttonInit(ButtonEventCb cb, void *ctx) {
    s_cb = cb;
    s_cbCtx = ctx;
    s_isrQueue = xQueueCreate(8, sizeof(uint32_t));

    pinMode(PIN_BUTTON, INPUT_PULLUP);
    attachInterrupt(digitalPinToInterrupt(PIN_BUTTON), isrHandler, CHANGE);

    xTaskCreate(buttonTask, "button_task", 2048, NULL, 10, NULL);
}

#endif
