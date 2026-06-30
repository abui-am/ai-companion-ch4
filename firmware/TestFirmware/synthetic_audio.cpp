#include "synthetic_audio.h"

#include <Arduino.h>
#include <math.h>

#include "protocol.h"

// Formant-ish tone so Whisper may pick up *something* during bench tests.
// Primary goal is exercising the WS binary uplink + server pipeline.
static uint32_t s_sampleIndex = 0;

void syntheticAudioReset() {
    s_sampleIndex = 0;
}

size_t syntheticAudioReadFrame(uint8_t *out, size_t outCapacity) {
    if (outCapacity < COMPANION_UPLINK_FRAME_BYTES) {
        return 0;
    }

    auto *samples = reinterpret_cast<int16_t *>(out);
    const size_t sampleCount = COMPANION_UPLINK_FRAME_BYTES / sizeof(int16_t);
    const float sampleRate = static_cast<float>(COMPANION_UPLINK_SAMPLE_RATE);

    for (size_t i = 0; i < sampleCount; i++) {
        const float t = static_cast<float>(s_sampleIndex + i) / sampleRate;
        const float envelope = 0.35f + 0.65f * sinf(2.0f * PI * 2.5f * t);
        const float voice = sinf(2.0f * PI * 180.0f * t)
            + 0.55f * sinf(2.0f * PI * 360.0f * t)
            + 0.25f * sinf(2.0f * PI * 720.0f * t);
        const float scaled = envelope * voice * 6000.0f;
        samples[i] = static_cast<int16_t>(scaled);
    }

    s_sampleIndex += sampleCount;
    return COMPANION_UPLINK_FRAME_BYTES;
}
