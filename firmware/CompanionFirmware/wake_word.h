#pragma once

#include <stddef.h>
#include <stdint.h>

// On-device wake-word detection using the Edge Impulse model exported as the
// "adjiemuliadi-project-1_inferencing" Arduino library (labels: hey_botchill,
// noise, unknown). Runs on the same 16 kHz mono mic feed already produced by
// audio_io.h — there is no separate I2S port for this.

// Initializes the Edge Impulse classifier. Call once during startup, after
// audioIoInit(). Allocates ~16 KB of slice buffers plus the model's TFLite
// arena (see EI_CLASSIFIER_TFLITE_LARGEST_ARENA_SIZE in model_metadata.h).
void wakeWordInit();

// Feeds mono 16-bit PCM samples (16 kHz, matching COMPANION_UPLINK_SAMPLE_RATE)
// into the classifier's sliding window. Call only while idle and listening
// for the wake word — not while a session is capturing (that audio is
// already streaming to the server) or speaking (that's the device's own TTS
// output, not the user).
//
// Returns true once "hey_botchill" crosses the model's confidence threshold.
// Internally cooldown-limited so a single utterance can't fire twice.
bool wakeWordFeed(const int16_t *samples, size_t sampleCount);
