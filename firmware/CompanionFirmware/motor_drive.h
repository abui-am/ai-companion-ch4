#pragma once

#include <Arduino.h>

void motorInit();
void motorStop();

// Non-blocking: runs on a background task. Re-entrant — a new command stops the
// previous motion first.
void motorHandleCommand(const char *pattern, uint32_t durationMs);
