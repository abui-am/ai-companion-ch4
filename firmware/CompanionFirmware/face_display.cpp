#include "face_display.h"

#include <Adafruit_GFX.h>
#include <Adafruit_SH110X.h>
#include <FluxGarage_RoboEyes.h>
#include <Wire.h>
#include <string.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

#include "config.h"

static constexpr int kScreenWidth = 128;
static constexpr int kScreenHeight = 64;
static constexpr int kStatusBarY = 54;
static constexpr int kStatusBarHeight = 10;
static constexpr int kEyeAreaHeight = kStatusBarY;
static constexpr uint32_t kTranscriptHoldMs = 5000;
static constexpr size_t kMaxLineLen = 21;
static constexpr size_t kMaxTranscriptLen = 96;
static constexpr uint32_t kEmotionMinHoldMs = 1500;
static constexpr uint32_t kEmotionMaxHoldMs = 60000;

// Overlay marks (anger vein, "!", "?", hearts, Zzz, sparkles, thinking dots)
// live in the top-right corner of the eye area, clear of the eyes themselves.
static constexpr int kMarkCenterX = 114;
static constexpr int kMarkCenterY = 9;

static void drawFaceOverlays(Adafruit_GFX &gfx);

// RoboEyes' drawEyes() clears the buffer, draws, then calls display->display()
// — anything drawn after update() would land one flush late and flicker.
// RoboEyes dispatches display() statically on its template parameter, so this
// subclass injects the marks + status bar into the same buffer right before
// the single I2C flush of every eye frame.
class FaceCanvas : public Adafruit_SH1106G {
 public:
  FaceCanvas(uint16_t w, uint16_t h, TwoWire *wire, int8_t rst)
      : Adafruit_SH1106G(w, h, wire, rst) {}

  bool overlayEnabled = false;

  void display() {
    if (overlayEnabled) {
      drawFaceOverlays(*this);
    }
    Adafruit_SH1106G::display();
  }
};

static FaceCanvas s_display(kScreenWidth, kScreenHeight, &Wire, OLED_RESET);
static RoboEyes<FaceCanvas> s_roboEyes(s_display);

static SemaphoreHandle_t s_mutex = nullptr;
static FaceDisplayMode s_mode = FACE_BOOT;
static FaceEmotion s_emotion = EMOTION_NONE;
static uint32_t s_emotionUntilMs = 0;
static char s_statusLine[kMaxLineLen + 1] = "";
static char s_transcript[kMaxTranscriptLen + 1] = "";
static uint32_t s_transcriptUntilMs = 0;
static bool s_showTextScreen = false;
static bool s_eyesConfigured = false;

// Face currently applied to RoboEyes, and the snapshot the overlay hook reads.
static FaceDisplayMode s_appliedMode = FACE_BOOT;
static FaceEmotion s_appliedEmotion = EMOTION_NONE;
static bool s_faceApplied = false;
static FaceDisplayMode s_frameMode = FACE_BOOT;
static FaceEmotion s_frameEmotion = EMOTION_NONE;
static char s_frameStatus[kMaxLineLen + 1] = "";

// Timers for periodic liveliness ticks (all main-loop only).
static uint32_t s_nextIdleQuirkMs = 0;
static uint32_t s_nextGazeShiftMs = 0;
static uint32_t s_nextRepeatAnimMs = 0;

static void copyTruncated(char *dest, size_t destSize, const char *src) {
  if (destSize == 0) {
    return;
  }
  if (src == nullptr) {
    dest[0] = '\0';
    return;
  }
  strncpy(dest, src, destSize - 1);
  dest[destSize - 1] = '\0';
}

//
// ── Overlay marks ────────────────────────────────────────────────────────────
//

// Manga-style anger vein: four bent strokes radiating diagonally, pulsing.
static void drawAngerMark(Adafruit_GFX &gfx) {
  const int cx = kMarkCenterX;
  const int cy = kMarkCenterY;
  const int r = ((millis() / 400) % 2 == 0) ? 7 : 6;
  const int dirs[4][2] = {{1, 1}, {1, -1}, {-1, 1}, {-1, -1}};
  for (const auto &d : dirs) {
    const int x0 = cx + d[0] * 2;
    const int y0 = cy + d[1] * 2;
    const int x1 = cx + d[0] * r;
    const int y1 = cy + d[1] * r;
    gfx.drawLine(x0, y0, x1, y1, 1);
    gfx.drawLine(x0 + d[0], y0, x1 + d[0], y1, 1);
    // Short perpendicular stub at the outer end — the bent-vein look.
    gfx.drawLine(x1, y1, x1 - d[0] * 3, y1 + d[1], 1);
  }
}

static void drawExclaimMark(Adafruit_GFX &gfx) {
  if ((millis() % 700) >= 500) {
    return; // flash to grab attention
  }
  gfx.fillRoundRect(kMarkCenterX - 2, 1, 4, 10, 1, 1);
  gfx.fillRect(kMarkCenterX - 2, 14, 4, 3, 1);
}

static void drawQuestionMark(Adafruit_GFX &gfx) {
  if ((millis() % 1000) >= 750) {
    return;
  }
  gfx.setTextSize(2);
  gfx.setTextColor(1);
  gfx.setCursor(kMarkCenterX - 5, 1);
  gfx.print('?');
  gfx.setTextSize(1);
}

static void drawHeartMark(Adafruit_GFX &gfx) {
  const bool beat = (millis() % 900) < 200;
  const int cx = kMarkCenterX;
  const int cy = 8;
  const int r = beat ? 4 : 3;
  gfx.fillCircle(cx - r, cy - 2, r, 1);
  gfx.fillCircle(cx + r, cy - 2, r, 1);
  gfx.fillTriangle(cx - 2 * r, cy - 1, cx + 2 * r, cy - 1, cx, cy + 2 * r, 1);
}

static void drawZzzMark(Adafruit_GFX &gfx) {
  const int visible = (millis() / 600) % 4;
  const int xs[3] = {104, 111, 118};
  const int ys[3] = {13, 7, 1};
  gfx.setTextSize(1);
  gfx.setTextColor(1);
  for (int i = 0; i < visible && i < 3; i++) {
    gfx.setCursor(xs[i], ys[i]);
    gfx.print('z');
  }
}

static void drawSparkleAt(Adafruit_GFX &gfx, int cx, int cy, int r) {
  gfx.drawFastHLine(cx - r, cy, 2 * r + 1, 1);
  gfx.drawFastVLine(cx, cy - r, 2 * r + 1, 1);
  gfx.drawPixel(cx - 1, cy - 1, 1);
  gfx.drawPixel(cx + 1, cy - 1, 1);
  gfx.drawPixel(cx - 1, cy + 1, 1);
  gfx.drawPixel(cx + 1, cy + 1, 1);
}

static void drawSparklesMark(Adafruit_GFX &gfx) {
  const bool phase = (millis() / 300) % 2 == 0;
  if (phase) {
    drawSparkleAt(gfx, 106, 5, 3);
    drawSparkleAt(gfx, 121, 13, 2);
  } else {
    drawSparkleAt(gfx, 120, 4, 2);
    drawSparkleAt(gfx, 105, 14, 3);
  }
}

static void drawThinkingDots(Adafruit_GFX &gfx) {
  const int visible = (millis() / 350) % 4;
  for (int i = 0; i < visible && i < 3; i++) {
    gfx.fillRect(105 + i * 7, 5, 3, 3, 1);
  }
}

// Status line with an animated ellipsis: "Thinking..." renders as
// "Thinking" → "Thinking." → "Thinking.." → "Thinking..." on a loop.
static void drawStatusBar(Adafruit_GFX &gfx, const char *line) {
  if (line == nullptr || line[0] == '\0') {
    return;
  }

  char text[kMaxLineLen + 1];
  copyTruncated(text, sizeof(text), line);
  size_t len = strlen(text);
  bool animated = (len >= 3 && strcmp(text + len - 3, "...") == 0);
  if (animated) {
    text[len - 3] = '\0';
  }

  gfx.fillRect(0, kStatusBarY, kScreenWidth, kStatusBarHeight, 0);
  gfx.drawFastHLine(0, kStatusBarY, kScreenWidth, 1);
  gfx.setTextSize(1);
  gfx.setTextColor(1);
  gfx.setCursor(0, kStatusBarY + 2);
  gfx.print(text);
  if (animated) {
    int dots = (millis() / 400) % 4;
    for (int i = 0; i < dots; i++) {
      gfx.print('.');
    }
  }
}

static void drawFaceOverlays(Adafruit_GFX &gfx) {
  switch (s_frameEmotion) {
  case EMOTION_ANGRY:
    drawAngerMark(gfx);
    break;
  case EMOTION_SURPRISED:
    drawExclaimMark(gfx);
    break;
  case EMOTION_CONFUSED:
    drawQuestionMark(gfx);
    break;
  case EMOTION_SLEEPY:
    drawZzzMark(gfx);
    break;
  case EMOTION_LOVE:
    drawHeartMark(gfx);
    break;
  case EMOTION_EXCITED:
    drawSparklesMark(gfx);
    break;
  default:
    // No emotion mark — session mode may still want one.
    if (s_frameMode == FACE_THINKING) {
      drawThinkingDots(gfx);
    } else if (s_frameMode == FACE_ERROR) {
      drawExclaimMark(gfx);
    }
    break;
  }

  drawStatusBar(gfx, s_frameStatus);
}

//
// ── Face configuration ───────────────────────────────────────────────────────
//

static void configureEyesGeometry() {
  s_roboEyes.setWidth(32, 32);
  s_roboEyes.setHeight(28, 28);
  s_roboEyes.setBorderradius(8, 8);
  s_roboEyes.setSpacebetween(12);
  s_roboEyes.setDisplayColors(0, 1);
}

// Reset everything a previous face may have touched, so each face starts
// from the same baseline instead of inheriting stray flicker/sweat/geometry.
static void resetFaceBaseline() {
  configureEyesGeometry();
  s_roboEyes.setCuriosity(OFF);
  s_roboEyes.setSweat(OFF);
  s_roboEyes.setHFlicker(OFF);
  s_roboEyes.setVFlicker(OFF);
  s_roboEyes.setPosition(0); // centered
  s_eyesConfigured = true;
}

static void applyModeFace(FaceDisplayMode mode) {
  switch (mode) {
  case FACE_BOOT:
    s_roboEyes.setMood(DEFAULT);
    s_roboEyes.setAutoblinker(ON, 2, 1);
    s_roboEyes.setIdleMode(OFF, 1, 2);
    break;
  case FACE_CONNECTING:
    s_roboEyes.setMood(TIRED);
    s_roboEyes.setAutoblinker(ON, 3, 2);
    s_roboEyes.setIdleMode(ON, 2, 3);
    break;
  case FACE_IDLE:
    s_roboEyes.setMood(DEFAULT);
    s_roboEyes.setAutoblinker(ON, 2, 3);
    s_roboEyes.setIdleMode(ON, 2, 4);
    s_roboEyes.setCuriosity(ON);
    break;
  case FACE_LISTENING:
    // Attentive: wide eyes locked on the user, slow deliberate blinks.
    s_roboEyes.setMood(DEFAULT);
    s_roboEyes.setHeight(32, 32);
    s_roboEyes.setCuriosity(ON);
    s_roboEyes.setAutoblinker(ON, 4, 2);
    s_roboEyes.setIdleMode(OFF, 1, 2);
    break;
  case FACE_THINKING:
    // Half-lidded, gaze drifting between up-left/up/up-right (tick below),
    // with animated dots in the corner.
    s_roboEyes.setMood(TIRED);
    s_roboEyes.setAutoblinker(OFF, 0, 0);
    s_roboEyes.setIdleMode(OFF, 1, 2);
    s_roboEyes.setPosition(N);
    break;
  case FACE_SPEAKING:
    // Happy with a subtle vertical bob — reads as talking rhythm.
    s_roboEyes.setMood(HAPPY);
    s_roboEyes.setAutoblinker(ON, 3, 2);
    s_roboEyes.setIdleMode(ON, 1, 2);
    s_roboEyes.setVFlicker(ON, 2);
    break;
  case FACE_ERROR:
    s_roboEyes.setMood(ANGRY);
    s_roboEyes.setAutoblinker(OFF, 0, 0);
    s_roboEyes.setIdleMode(OFF, 1, 2);
    s_roboEyes.anim_confused();
    break;
  }
}

static void applyEmotionFace(FaceEmotion emotion) {
  const uint32_t now = millis();
  switch (emotion) {
  case EMOTION_HAPPY:
    s_roboEyes.setMood(HAPPY);
    s_roboEyes.setAutoblinker(ON, 2, 2);
    s_roboEyes.setIdleMode(ON, 2, 3);
    s_roboEyes.anim_laugh();
    break;
  case EMOTION_EXCITED:
    s_roboEyes.setMood(HAPPY);
    s_roboEyes.setAutoblinker(ON, 1, 1);
    s_roboEyes.setIdleMode(ON, 1, 2);
    s_roboEyes.setVFlicker(ON, 2);
    s_roboEyes.anim_laugh();
    s_nextRepeatAnimMs = now + 2600;
    break;
  case EMOTION_ANGRY:
    // Angry brows + a trembling shake + pulsing anger vein overlay.
    s_roboEyes.setMood(ANGRY);
    s_roboEyes.setAutoblinker(ON, 4, 2);
    s_roboEyes.setIdleMode(OFF, 1, 2);
    s_roboEyes.setHFlicker(ON, 1);
    break;
  case EMOTION_SAD:
    // Droopy eyes looking down, with a single tear (library sweat drop).
    s_roboEyes.setMood(TIRED);
    s_roboEyes.setAutoblinker(ON, 4, 2);
    s_roboEyes.setIdleMode(OFF, 1, 2);
    s_roboEyes.setPosition(S);
    s_roboEyes.setSweat(ON);
    break;
  case EMOTION_SURPRISED:
    // Big round eyes + flashing "!" in the corner.
    s_roboEyes.setMood(DEFAULT);
    s_roboEyes.setWidth(36, 36);
    s_roboEyes.setHeight(36, 36);
    s_roboEyes.setBorderradius(14, 14);
    s_roboEyes.setSpacebetween(8);
    s_roboEyes.setAutoblinker(OFF, 0, 0);
    s_roboEyes.setIdleMode(OFF, 1, 2);
    s_roboEyes.blink();
    break;
  case EMOTION_CONFUSED:
    s_roboEyes.setMood(DEFAULT);
    s_roboEyes.setAutoblinker(ON, 3, 2);
    s_roboEyes.setIdleMode(OFF, 1, 2);
    s_roboEyes.anim_confused();
    s_nextRepeatAnimMs = now + 3200;
    s_nextGazeShiftMs = now + 900;
    break;
  case EMOTION_SLEEPY:
    s_roboEyes.setMood(TIRED);
    s_roboEyes.setHeight(16, 16);
    s_roboEyes.setAutoblinker(ON, 3, 1);
    s_roboEyes.setIdleMode(OFF, 1, 2);
    break;
  case EMOTION_LOVE:
    s_roboEyes.setMood(HAPPY);
    s_roboEyes.setAutoblinker(ON, 2, 2);
    s_roboEyes.setIdleMode(ON, 2, 3);
    break;
  case EMOTION_NONE:
    break;
  }
}

static void applyFace(FaceDisplayMode mode, FaceEmotion emotion) {
  resetFaceBaseline();
  if (emotion != EMOTION_NONE) {
    applyEmotionFace(emotion);
  } else {
    applyModeFace(mode);
  }
}

//
// ── Per-frame liveliness ticks ───────────────────────────────────────────────
//

static void tickFaceBehavior(FaceDisplayMode mode, FaceEmotion emotion) {
  const uint32_t now = millis();

  if (emotion == EMOTION_EXCITED) {
    if (now >= s_nextRepeatAnimMs) {
      s_roboEyes.anim_laugh();
      s_nextRepeatAnimMs = now + random(2200, 3400);
    }
    return;
  }

  if (emotion == EMOTION_CONFUSED) {
    if (now >= s_nextRepeatAnimMs) {
      s_roboEyes.anim_confused();
      s_nextRepeatAnimMs = now + random(2800, 4200);
    }
    if (now >= s_nextGazeShiftMs) {
      // Look left, then right, like weighing two answers.
      static bool lookEast = false;
      s_roboEyes.setPosition(lookEast ? E : W);
      lookEast = !lookEast;
      s_nextGazeShiftMs = now + random(800, 1400);
    }
    return;
  }

  if (emotion != EMOTION_NONE) {
    return;
  }

  switch (mode) {
  case FACE_THINKING:
    // Pondering gaze wander: mostly up, sometimes up-left/up-right.
    if (now >= s_nextGazeShiftMs) {
      const unsigned char spots[4] = {N, NE, N, NW};
      s_roboEyes.setPosition(spots[random(4)]);
      s_nextGazeShiftMs = now + random(700, 1300);
    }
    break;
  case FACE_IDLE:
    // Occasional quirk so the idle face never looks frozen.
    if (now >= s_nextIdleQuirkMs) {
      switch (random(3)) {
      case 0:
        s_roboEyes.blink();
        break;
      case 1:
        s_roboEyes.anim_laugh();
        break;
      default:
        s_roboEyes.blink(random(2) == 0, true); // playful wink-ish blink
        break;
      }
      s_nextIdleQuirkMs = now + random(6000, 16000);
    }
    break;
  default:
    break;
  }
}

//
// ── Transcript text screen ───────────────────────────────────────────────────
//

// Word-wrapped so words no longer break mid-character-cell.
static void drawTextScreen(const char *title, const char *body) {
  s_display.clearDisplay();
  s_display.setTextSize(1);
  s_display.setTextColor(1);
  s_display.setCursor(0, 0);
  if (title != nullptr && title[0] != '\0') {
    s_display.println(title);
    s_display.drawFastHLine(0, 10, kScreenWidth, 1);
  }

  if (body == nullptr || body[0] == '\0') {
    s_display.display();
    return;
  }

  int y = (title != nullptr && title[0] != '\0') ? 15 : 0;
  const int lineHeight = 9;
  const int maxLines = (kScreenHeight - y) / lineHeight;
  int line = 0;
  size_t i = 0;

  while (body[i] != '\0' && line < maxLines) {
    while (body[i] == ' ') {
      i++;
    }
    if (body[i] == '\0') {
      break;
    }

    size_t remaining = strlen(body + i);
    size_t chunkLen = remaining < kMaxLineLen ? remaining : kMaxLineLen;
    if (chunkLen < remaining) {
      // Break at the last space that fits; fall back to a hard cut.
      size_t breakAt = chunkLen;
      while (breakAt > 0 && body[i + breakAt] != ' ') {
        breakAt--;
      }
      if (breakAt > 0) {
        chunkLen = breakAt;
      }
    }

    char chunk[kMaxLineLen + 1];
    memcpy(chunk, body + i, chunkLen);
    chunk[chunkLen] = '\0';
    s_display.setCursor(0, y + line * lineHeight);
    s_display.print(chunk);
    i += chunkLen;
    line++;
  }

  s_display.display();
}

//
// ── Render + public API ──────────────────────────────────────────────────────
//

static void refreshDisplay(FaceDisplayMode mode, FaceEmotion emotion,
                           const char *statusLine, bool showTextScreen,
                           const char *transcript) {
  if (showTextScreen) {
    s_display.overlayEnabled = false;
    drawTextScreen("You said:", transcript);
    s_faceApplied = false; // force re-apply when the eyes come back
    return;
  }

  if (!s_faceApplied || s_appliedMode != mode || s_appliedEmotion != emotion) {
    applyFace(mode, emotion);
    s_appliedMode = mode;
    s_appliedEmotion = emotion;
    s_faceApplied = true;
  }

  tickFaceBehavior(mode, emotion);

  // Snapshot for the overlay hook, which runs inside update()'s flush.
  s_frameMode = mode;
  s_frameEmotion = emotion;
  copyTruncated(s_frameStatus, sizeof(s_frameStatus), statusLine);
  s_display.overlayEnabled = true;
  s_roboEyes.update();
}

void faceDisplayInit() {
  s_mutex = xSemaphoreCreateMutex();

  Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
  delay(250);

  if (!s_display.begin(OLED_I2C_ADDRESS, true)) {
    Serial.println("[FACE] SH1106 init failed — check wiring / 0x3C address");
    return;
  }

  s_display.clearDisplay();
  s_display.display();

  resetFaceBaseline();
  s_roboEyes.begin(kScreenWidth, kEyeAreaHeight, 30);
  applyFace(FACE_BOOT, EMOTION_NONE);
  copyTruncated(s_statusLine, sizeof(s_statusLine), "Booting...");
  s_appliedMode = FACE_BOOT;
  s_appliedEmotion = EMOTION_NONE;
  s_faceApplied = true;

  Serial.printf("[FACE] SH1106 128x64 @ 0x%02X SDA=%d SCL=%d\n", OLED_I2C_ADDRESS,
                PIN_OLED_SDA, PIN_OLED_SCL);
}

void faceDisplaySetMode(FaceDisplayMode mode) {
  if (s_mutex == nullptr) {
    return;
  }
  xSemaphoreTake(s_mutex, portMAX_DELAY);
  s_mode = mode;
  xSemaphoreGive(s_mutex);
}

void faceDisplaySetStatusLine(const char *text) {
  if (s_mutex == nullptr) {
    return;
  }
  xSemaphoreTake(s_mutex, portMAX_DELAY);
  copyTruncated(s_statusLine, sizeof(s_statusLine), text);
  xSemaphoreGive(s_mutex);
}

void faceDisplayShowTranscript(const char *text) {
  if (s_mutex == nullptr) {
    return;
  }
  xSemaphoreTake(s_mutex, portMAX_DELAY);
  copyTruncated(s_transcript, sizeof(s_transcript), text);
  s_transcriptUntilMs = millis() + kTranscriptHoldMs;
  s_showTextScreen = (text != nullptr && text[0] != '\0');
  xSemaphoreGive(s_mutex);
}

bool faceDisplaySetEmotion(const char *name, uint32_t holdMs) {
  if (name == nullptr || name[0] == '\0') {
    return false;
  }

  struct EmotionEntry {
    const char *name;
    FaceEmotion emotion;
    uint32_t defaultHoldMs;
  };
  static const EmotionEntry kEmotions[] = {
      {"neutral", EMOTION_NONE, 0},
      {"happy", EMOTION_HAPPY, 8000},
      {"excited", EMOTION_EXCITED, 8000},
      {"angry", EMOTION_ANGRY, 10000},
      {"sad", EMOTION_SAD, 12000},
      {"surprised", EMOTION_SURPRISED, 5000},
      {"confused", EMOTION_CONFUSED, 8000},
      {"sleepy", EMOTION_SLEEPY, 15000},
      {"love", EMOTION_LOVE, 8000},
  };

  const EmotionEntry *match = nullptr;
  for (const auto &entry : kEmotions) {
    if (strcasecmp(name, entry.name) == 0) {
      match = &entry;
      break;
    }
  }
  if (match == nullptr) {
    return false;
  }

  uint32_t hold = (holdMs > 0) ? holdMs : match->defaultHoldMs;
  if (hold < kEmotionMinHoldMs) {
    hold = kEmotionMinHoldMs;
  }
  if (hold > kEmotionMaxHoldMs) {
    hold = kEmotionMaxHoldMs;
  }

  if (s_mutex == nullptr) {
    return false;
  }
  xSemaphoreTake(s_mutex, portMAX_DELAY);
  s_emotion = match->emotion;
  s_emotionUntilMs = (match->emotion == EMOTION_NONE) ? 0 : millis() + hold;
  xSemaphoreGive(s_mutex);

  Serial.printf("[FACE] emotion=%s hold=%ums\n", match->name,
                static_cast<unsigned>(match->emotion == EMOTION_NONE ? 0 : hold));
  return true;
}

void faceDisplayLoop() {
  if (s_mutex == nullptr) {
    return;
  }

  FaceDisplayMode mode = FACE_BOOT;
  FaceEmotion emotion = EMOTION_NONE;
  char statusLine[kMaxLineLen + 1];
  char transcript[kMaxTranscriptLen + 1];
  bool showTextScreen = false;

  xSemaphoreTake(s_mutex, portMAX_DELAY);
  mode = s_mode;
  if (s_emotion != EMOTION_NONE && millis() >= s_emotionUntilMs) {
    s_emotion = EMOTION_NONE; // emotion expired — settle back to the mode face
  }
  emotion = s_emotion;
  copyTruncated(statusLine, sizeof(statusLine), s_statusLine);
  copyTruncated(transcript, sizeof(transcript), s_transcript);
  showTextScreen = s_showTextScreen;
  if (showTextScreen && millis() >= s_transcriptUntilMs) {
    s_showTextScreen = false;
    showTextScreen = false;
  }
  xSemaphoreGive(s_mutex);

  refreshDisplay(mode, emotion, statusLine, showTextScreen, transcript);
}
