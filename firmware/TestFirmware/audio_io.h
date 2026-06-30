#pragma once

#include <stddef.h>
#include <stdint.h>

void audioIoInit();
size_t audioIoReadUplinkFrame(uint8_t *out, size_t outCapacity);
void audioIoWriteDownlink(const int16_t *monoSamples, size_t sampleCount);
