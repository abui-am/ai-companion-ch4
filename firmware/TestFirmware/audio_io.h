#pragma once

#include <stddef.h>
#include <stdint.h>

void audioIoInit();
void audioIoPrimeMic();
size_t audioIoReadUplinkFrame(uint8_t *out, size_t outCapacity);
void audioIoWriteDownlink(const int16_t *monoSamples, size_t sampleCount);

// Plays a short sine tone on the downlink I2S path. Call after audioIoInit().
void audioIoSpeakerSelfTest();
void audioIoSpeakerBeep();

// Local monitor: read mic frames and play on speaker (requires HAS_MIC + HAS_SPEAKER).
void audioIoLogLoopbackConfig();
bool audioIoLoopbackAllocBuffer(); // call before audioIoInit() in loopback mode
void audioIoMicLoopbackBegin();
