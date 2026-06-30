#include "pcm_codec.h"

#include <string.h>

size_t pcmCodecEncodeUplinkFrame(const int16_t *pcmSamples, size_t sampleCount,
                                  uint8_t *out, size_t outCapacity) {
    size_t bytes = sampleCount * sizeof(int16_t);
    if (bytes > outCapacity) {
        bytes = outCapacity - (outCapacity % sizeof(int16_t));
    }
    memcpy(out, pcmSamples, bytes);
    return bytes;
}

size_t pcmCodecDecodeDownlinkFrame(const uint8_t *frame, size_t frameLen,
                                    int16_t *outSamples, size_t outCapacitySamples) {
    size_t sampleCount = frameLen / sizeof(int16_t);
    if (sampleCount > outCapacitySamples) {
        sampleCount = outCapacitySamples;
    }
    memcpy(outSamples, frame, sampleCount * sizeof(int16_t));
    return sampleCount;
}
