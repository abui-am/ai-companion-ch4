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
// Frames are already HPF + noise-gated in audioIoReadUplinkFrame(); metrics
// are taken on that conditioned uplink audio (same bytes sent to the server).
struct AudioFrameVadMetrics {
  uint32_t energy;
  uint32_t peak;
  uint32_t crestX100;
  uint32_t zcrX1000;
};

void audioIoVadFilterReset();

// Peak-normalized before return — see MIC_UPLINK_TARGET_PEAK in config.h.
AudioFrameVadMetrics audioIoAnalyzeVadFrame(const uint8_t *frame, size_t len);

// Mean absolute amplitude without filtering — legacy helper.
uint32_t audioIoFrameEnergy(const uint8_t *frame, size_t len);

// Flush silence and stop speaker I2S clocks so the amp stays quiet when idle.
void audioIoSpeakerMute();

void audioIoMicStart();
void audioIoMicStop();

// Reinstalls the mic I2S driver after it wedges (reads returning no data).
// Returns true when the driver came back; leaves the mic running.
bool audioIoMicRecover();
bool audioIoMicIsRunning();
void audioIoPrimeMic();
// Lighter prime after mic was stopped for TTS/PROCESSING — avoids mic-ready
// semaphore timeout on auto-relisten (full prime can exceed 2 s).
void audioIoPrimeMicAfterPause();
