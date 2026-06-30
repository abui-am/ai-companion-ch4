#pragma once

enum ButtonEvent {
    BUTTON_EVENT_PRESSED,
    BUTTON_EVENT_RELEASED,
};

typedef void (*ButtonEventCb)(ButtonEvent event, void *ctx);

// Configures PIN_BUTTON as an active-low input with interrupt-driven
// debounce and starts a task that invokes cb on each transition. Call once
// from setup().
void buttonInit(ButtonEventCb cb, void *ctx);
