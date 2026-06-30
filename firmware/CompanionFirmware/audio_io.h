#pragma once

#include <stddef.h>
#include <stdint.h>

// Initializes the mic (RX) and speaker amp (TX) I2S peripherals. Call once
// during startup, before audioIoReadUplinkFrame / audioIoWriteDownlink.
void audioIoInit();

// Blocks until one COMPANION_UPLINK_FRAME_BYTES frame has been captured from
// the mic. Returns the number of bytes actually read (may be 0 on timeout).
size_t audioIoReadUplinkFrame(uint8_t *out, size_t outCapacity);

// Writes one downlink PCM chunk to the speaker amp. monoSamples are
// duplicated to both I2S slots so mono audio plays correctly regardless of
// which channel the amp's hardware select pin is wired to.
void audioIoWriteDownlink(const int16_t *monoSamples, size_t sampleCount);
