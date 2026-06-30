#pragma once

#include <stddef.h>
#include <stdint.h>

// Software uplink source for bench tests without a mic.
void syntheticAudioReset();
size_t syntheticAudioReadFrame(uint8_t *out, size_t outCapacity);
