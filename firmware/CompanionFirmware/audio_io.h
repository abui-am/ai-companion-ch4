#pragma once

#include <stddef.h>
#include <stdint.h>

#include "config.h"

// Initializes the mic (RX) and speaker amp (TX) I2S peripherals. Call once
// during startup, before audioIoReadUplinkFrame / audioIoWriteDownlink.
void audioIoInit();

// Blocks until one COMPANION_UPLINK_FRAME_BYTES frame has been captured from
// the mic. Returns the number of bytes actually read (may be 0 on timeout).
size_t audioIoReadUplinkFrame(uint8_t *out, size_t outCapacity);

// Writes one downlink PCM chunk to the speaker amp. monoSamples are sent on
// the left I2S slot (tie MAX98357 SD/LRC-select to 3.3 V for left channel).
void audioIoWriteDownlink(const int16_t *monoSamples, size_t sampleCount);

// Short confirmation beep on the speaker. Call after audioIoInit().
void audioIoSpeakerBeep();

// Flush silence and stop speaker I2S clocks so the amp stays quiet when idle.
void audioIoSpeakerMute();

#if HAS_MIC
// Stop/start mic I2S clocks when not capturing — reduces crosstalk into speaker.
void audioIoMicStart();
void audioIoMicStop();
#endif
