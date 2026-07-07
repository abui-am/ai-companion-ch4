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

static Adafruit_SH1106G s_display(kScreenWidth, kScreenHeight, &Wire, OLED_RESET);
static RoboEyes<Adafruit_SH1106G> s_roboEyes(s_display);

static SemaphoreHandle_t s_mutex = nullptr;
static FaceDisplayMode s_mode = FACE_BOOT;
static FaceDisplayMode s_appliedMode = FACE_BOOT;
static char s_statusLine[kMaxLineLen + 1] = "";
static char s_transcript[kMaxTranscriptLen + 1] = "";
static uint32_t s_transcriptUntilMs = 0;
static bool s_showTextScreen = false;
static bool s_eyesConfigured = false;

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

static void configureEyesGeometry() {
  if (s_eyesConfigured) {
    return;
  }
  s_roboEyes.setWidth(32, 32);
  s_roboEyes.setHeight(28, 28);
  s_roboEyes.setBorderradius(8, 8);
  s_roboEyes.setSpacebetween(12);
  s_roboEyes.setDisplayColors(0, 1);
  s_eyesConfigured = true;
}

static void applyModeAnimation(FaceDisplayMode mode) {
  configureEyesGeometry();

  switch (mode) {
  case FACE_BOOT:
    s_roboEyes.setMood(DEFAULT);
    s_roboEyes.setAutoblinker(ON, 2, 1);
    s_roboEyes.setIdleMode(OFF, 1, 2);
    break;
  case FACE_CONNECTING:
    s_roboEyes.setMood(TIRED);
    s_roboEyes.setAutoblinker(ON, 3, 2);
    s_roboEyes.setIdleMode(ON, 1, 3);
    break;
  case FACE_IDLE:
    s_roboEyes.setMood(DEFAULT);
    s_roboEyes.setAutoblinker(ON, 3, 2);
    s_roboEyes.setIdleMode(ON, 2, 4);
    break;
  case FACE_LISTENING:
    s_roboEyes.setMood(HAPPY);
    s_roboEyes.setAutoblinker(OFF, 0, 0);
    s_roboEyes.setIdleMode(ON, 1, 2);
    break;
  case FACE_THINKING:
    s_roboEyes.setMood(TIRED);
    s_roboEyes.setAutoblinker(OFF, 0, 0);
    s_roboEyes.setIdleMode(OFF, 1, 2);
    s_roboEyes.setPosition(N);
    break;
  case FACE_SPEAKING:
    s_roboEyes.setMood(HAPPY);
    s_roboEyes.setAutoblinker(ON, 2, 1);
    s_roboEyes.setIdleMode(ON, 1, 2);
    break;
  case FACE_ERROR:
    s_roboEyes.setMood(ANGRY);
    s_roboEyes.setAutoblinker(OFF, 0, 0);
    s_roboEyes.setIdleMode(OFF, 1, 2);
    break;
  }
}

static void drawStatusBar(const char *line) {
  if (line == nullptr || line[0] == '\0') {
    return;
  }

  s_display.fillRect(0, kStatusBarY, kScreenWidth, kStatusBarHeight, 0);
  s_display.drawFastHLine(0, kStatusBarY, kScreenWidth, 1);
  s_display.setTextSize(1);
  s_display.setTextColor(1);
  s_display.setCursor(0, kStatusBarY + 1);
  s_display.print(line);
}

static void drawTextScreen(const char *title, const char *body) {
  s_display.clearDisplay();
  s_display.setTextSize(1);
  s_display.setTextColor(1);
  s_display.setCursor(0, 0);
  if (title != nullptr && title[0] != '\0') {
    s_display.println(title);
    s_display.println();
  }

  if (body == nullptr || body[0] == '\0') {
    s_display.display();
    return;
  }

  int y = (title != nullptr && title[0] != '\0') ? 16 : 0;
  const int lineHeight = 8;
  const int maxLines = (kScreenHeight - y) / lineHeight;
  int line = 0;
  size_t i = 0;

  while (body[i] != '\0' && line < maxLines) {
    char chunk[kMaxLineLen + 1];
    size_t chunkLen = 0;
    while (body[i] != '\0' && chunkLen < kMaxLineLen) {
      chunk[chunkLen++] = body[i++];
    }
    chunk[chunkLen] = '\0';
    s_display.setCursor(0, y + line * lineHeight);
    s_display.print(chunk);
    line++;
  }

  s_display.display();
}

static void refreshDisplay(FaceDisplayMode mode, const char *statusLine,
                           bool showTextScreen, const char *transcript) {
  if (showTextScreen) {
    drawTextScreen("You said:", transcript);
    return;
  }

  if (s_appliedMode != mode) {
    applyModeAnimation(mode);
    s_appliedMode = mode;
  }

  s_roboEyes.update();

  if (statusLine[0] != '\0') {
    drawStatusBar(statusLine);
    s_display.display();
  }
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

  configureEyesGeometry();
  s_roboEyes.begin(kScreenWidth, kEyeAreaHeight, 30);
  applyModeAnimation(FACE_BOOT);
  copyTruncated(s_statusLine, sizeof(s_statusLine), "Booting...");
  s_appliedMode = FACE_BOOT;

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

void faceDisplayLoop() {
  if (s_mutex == nullptr) {
    return;
  }

  FaceDisplayMode mode = FACE_BOOT;
  char statusLine[kMaxLineLen + 1];
  char transcript[kMaxTranscriptLen + 1];
  bool showTextScreen = false;

  xSemaphoreTake(s_mutex, portMAX_DELAY);
  mode = s_mode;
  copyTruncated(statusLine, sizeof(statusLine), s_statusLine);
  copyTruncated(transcript, sizeof(transcript), s_transcript);
  showTextScreen = s_showTextScreen;
  if (showTextScreen && millis() >= s_transcriptUntilMs) {
    s_showTextScreen = false;
    showTextScreen = false;
  }
  xSemaphoreGive(s_mutex);

  refreshDisplay(mode, statusLine, showTextScreen, transcript);
}
