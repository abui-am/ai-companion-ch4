#pragma once

#include <stdint.h>

// 1.3" SH1106 OLED face — FluxGarage RoboEyes + optional status text.
// All drawing runs from the main loop (faceDisplayLoop); other tasks may
// call the notify/set APIs — they only update shared state under a mutex.

enum FaceDisplayMode {
  FACE_BOOT = 0,
  FACE_CONNECTING,
  FACE_IDLE,
  FACE_LISTENING,
  FACE_THINKING,
  FACE_SPEAKING,
  FACE_ERROR,
};

// Emotion overlay driven by the LLM (device_command action="emotion").
// Rides on top of the session mode: mood + corner mark + micro-animations,
// then decays back to the mode's default face when the hold expires.
enum FaceEmotion {
  EMOTION_NONE = 0,
  EMOTION_HAPPY,
  EMOTION_EXCITED,
  EMOTION_ANGRY,
  EMOTION_SAD,
  EMOTION_SURPRISED,
  EMOTION_CONFUSED,
  EMOTION_SLEEPY,
  EMOTION_LOVE,
};

void faceDisplayInit();
void faceDisplayLoop();

void faceDisplaySetMode(FaceDisplayMode mode);
void faceDisplaySetStatusLine(const char *text);
void faceDisplayShowTranscript(const char *text);

// name: neutral|happy|excited|angry|sad|surprised|confused|sleepy|love.
// holdMs 0 picks a default hold; "neutral" clears immediately.
// Returns false when name isn't a known emotion.
bool faceDisplaySetEmotion(const char *name, uint32_t holdMs);
