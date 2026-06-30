#include "button.h"

#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/task.h>

#include "config.h"

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
