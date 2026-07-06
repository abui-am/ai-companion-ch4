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

// Per-frame metrics for the adaptive noise-floor VAD in ws_session.cpp.
// Samples are high-pass filtered (~300 Hz) before measurement so HVAC
// rumble doesn't dominate energy in noisy rooms. crestX100 is peak*100/mean
// (speech is spikier than steady fan noise); zcrX1000 is zero-crossings per
// 1000 samples on the filtered signal.
struct AudioFrameVadMetrics {
  uint32_t energy;
  uint32_t peak;
  uint32_t crestX100;
  uint32_t zcrX1000;
};

void audioIoVadFilterReset();

// Analyze one mono 16-bit PCM uplink frame for VAD. Uplink audio is unchanged.
AudioFrameVadMetrics audioIoAnalyzeVadFrame(const uint8_t *frame, size_t len);

// Mean absolute amplitude without filtering — legacy helper.
uint32_t audioIoFrameEnergy(const uint8_t *frame, size_t len);

// Flush silence and stop speaker I2S clocks so the amp stays quiet when idle.
void audioIoSpeakerMute();

#if HAS_MIC
void audioIoMicStart();
void audioIoMicStop();
bool audioIoMicIsRunning();
void audioIoPrimeMic();
#endif
