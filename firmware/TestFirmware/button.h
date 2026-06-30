#pragma once

enum ButtonEvent {
    BUTTON_EVENT_PRESSED,
    BUTTON_EVENT_RELEASED,
};

typedef void (*ButtonEventCb)(ButtonEvent event, void *ctx);

void buttonInit(ButtonEventCb cb, void *ctx);
