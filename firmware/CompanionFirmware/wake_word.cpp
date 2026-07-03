#include "wake_word.h"

// Leaves EIDSP_QUANTIZE_FILTERBANK at the library default (1 = quantized).
// Disabling it doubles per-slice DSP scratch allocations, which pushed the
// classifier's heap requirement over the top on internal SRAM alone (see
// -1002 / EIDSP_OUT_OF_MEM). The ~169 KB TFLite tensor arena is the real
// memory hog; see wakeWordInit() below — needs PSRAM on 4MB modules.

#include <Arduino.h>
#include <adjiemuliadi-project-1_inferencing.h>
#include <string.h>

namespace {

constexpr const char *kWakeLabel = "hey_botchill";
constexpr uint32_t kCooldownMs = 3000;

int16_t s_slices[2][EI_CLASSIFIER_SLICE_SIZE];
uint8_t s_activeSlice = 0;
size_t s_sliceFill = 0;
uint32_t s_lastTriggerMs = 0;
bool s_initialized = false;

int getSignalData(size_t offset, size_t length, float *outPtr) {
    numpy::int16_to_float(&s_slices[s_activeSlice][offset], outPtr, length);
    return 0;
}

// Runs one classification pass over the just-filled slice. The continuous
// classifier maintains its own sliding window across calls (see
// EI_CLASSIFIER_SLICES_PER_MODEL_WINDOW), so this only needs to hand it one
// fresh slice at a time.
bool classifySlice() {
    signal_t signal;
    signal.total_length = EI_CLASSIFIER_SLICE_SIZE;
    signal.get_data = &getSignalData;

    ei_impulse_result_t result = {};
    EI_IMPULSE_ERROR err = run_classifier_continuous(&signal, &result, false);
    if (err != EI_IMPULSE_OK) {
        Serial.printf("[WAKE] classifier error %d\n", static_cast<int>(err));
        return false;
    }

    for (size_t i = 0; i < EI_CLASSIFIER_LABEL_COUNT; i++) {
        if (strcmp(result.classification[i].label, kWakeLabel) == 0) {
            return result.classification[i].value >= EI_CLASSIFIER_THRESHOLD;
        }
    }
    return false;
}

} // namespace

void wakeWordInit() {
    // The TFLite tensor arena (~169 KB, see EI_CLASSIFIER_TFLITE_LARGEST_ARENA_SIZE
    // in model_metadata.h) is heap-allocated here via run_classifier_init().
    // On internal SRAM alone this leaves almost nothing for WiFi, task
    // stacks, and the DSP stage's own scratch buffers — hence "ERR: Failed
    // to run DSP process (-1002)" (EIDSP_OUT_OF_MEM) if PSRAM isn't enabled.
    // Log heap/PSRAM before and after so a shrinking free-heap number (with
    // free-psram barely moving) means the arena landed in internal RAM —
    // check Tools -> PSRAM is enabled and matches your board's chip.
    Serial.printf("[MEM] before classifier init: heap=%u psram=%u psramFound=%d\n",
                  ESP.getFreeHeap(), ESP.getFreePsram(), psramFound());

    run_classifier_init();

    Serial.printf("[MEM] after classifier init:  heap=%u psram=%u\n",
                  ESP.getFreeHeap(), ESP.getFreePsram());

    s_activeSlice = 0;
    s_sliceFill = 0;
    s_lastTriggerMs = 0;
    s_initialized = true;
    Serial.printf("[WAKE] Edge Impulse classifier ready (label=\"%s\", threshold=%.2f)\n",
                  kWakeLabel, EI_CLASSIFIER_THRESHOLD);
}

bool wakeWordFeed(const int16_t *samples, size_t sampleCount) {
    if (!s_initialized) return false;

    bool detected = false;
    size_t offset = 0;
    while (offset < sampleCount) {
        size_t room = EI_CLASSIFIER_SLICE_SIZE - s_sliceFill;
        size_t chunk = sampleCount - offset;
        if (chunk > room) chunk = room;

        memcpy(&s_slices[s_activeSlice][s_sliceFill], &samples[offset], chunk * sizeof(int16_t));
        s_sliceFill += chunk;
        offset += chunk;

        if (s_sliceFill >= EI_CLASSIFIER_SLICE_SIZE) {
            s_sliceFill = 0;
            bool hit = classifySlice();
            // Flip only after reading — getSignalData() reads s_activeSlice.
            s_activeSlice ^= 1;
            if (hit) {
                uint32_t now = millis();
                if (now - s_lastTriggerMs >= kCooldownMs) {
                    s_lastTriggerMs = now;
                    detected = true;
                }
            }
        }
    }
    return detected;
}
