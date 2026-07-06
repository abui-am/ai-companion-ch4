#pragma once

enum ButtonEvent {
    BUTTON_EVENT_SHORT_TAP,  // quick touch-and-release
    BUTTON_EVENT_LONG_PRESS, // held past the long-press threshold (once)
};

typedef void (*ButtonEventCb)(ButtonEvent event, void *ctx);

// Configures PIN_BUTTON as a digital touch input (HIGH when touched) and
// starts a polling task that invokes cb on short tap or long press. Call
// once from setup().
void buttonInit(ButtonEventCb cb, void *ctx);
