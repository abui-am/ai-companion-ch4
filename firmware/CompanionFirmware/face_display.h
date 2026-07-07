#pragma once

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

void faceDisplayInit();
void faceDisplayLoop();

void faceDisplaySetMode(FaceDisplayMode mode);
void faceDisplaySetStatusLine(const char *text);
void faceDisplayShowTranscript(const char *text);
