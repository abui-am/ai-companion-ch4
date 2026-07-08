#include "motor_drive.h"

#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <freertos/task.h>

#include "config.h"

namespace {

enum MotorSide { MOTOR_LEFT, MOTOR_RIGHT };

struct PendingCommand {
  char pattern[16] = {};
  uint32_t durationMs = 0;
  bool valid = false;
};

static SemaphoreHandle_t s_mutex = nullptr;
static TaskHandle_t s_task = nullptr;
static PendingCommand s_pendingWork;
static volatile bool s_stopRequested = false;

static void setSideRaw(MotorSide side, int16_t speed) {
  const uint8_t in1 = (side == MOTOR_LEFT) ? PIN_MOTOR_AIN1 : PIN_MOTOR_BIN1;
  const uint8_t in2 = (side == MOTOR_LEFT) ? PIN_MOTOR_AIN2 : PIN_MOTOR_BIN2;

  if (speed > 0) {
    ledcWrite(in1, speed);
    ledcWrite(in2, 0);
  } else if (speed < 0) {
    ledcWrite(in1, 0);
    ledcWrite(in2, static_cast<uint16_t>(-speed));
  } else {
    ledcWrite(in1, 0);
    ledcWrite(in2, 0);
  }
}

static void setDrive(int16_t leftSpeed, int16_t rightSpeed) {
  setSideRaw(MOTOR_LEFT, leftSpeed);
  setSideRaw(MOTOR_RIGHT, rightSpeed);
}

static void rampTo(int16_t leftTarget, int16_t rightTarget, uint32_t rampMs) {
  const int steps = 8;
  const uint32_t stepDelay = rampMs / steps;
  for (int i = 1; i <= steps && !s_stopRequested; ++i) {
    const int16_t left = static_cast<int16_t>((leftTarget * i) / steps);
    const int16_t right = static_cast<int16_t>((rightTarget * i) / steps);
    setDrive(left, right);
    vTaskDelay(pdMS_TO_TICKS(stepDelay));
  }
}

static void rampStop(uint32_t rampMs) {
  rampTo(0, 0, rampMs);
  setDrive(0, 0);
}

static void holdDrive(int16_t leftSpeed, int16_t rightSpeed, uint32_t durationMs) {
  const uint32_t endAt = millis() + durationMs;
  while (!s_stopRequested && static_cast<int32_t>(millis() - endAt) < 0) {
    setDrive(leftSpeed, rightSpeed);
    vTaskDelay(pdMS_TO_TICKS(20));
  }
}

static void moveForward(uint32_t durationMs) {
  rampTo(MOTOR_PWM_MAX, MOTOR_PWM_MAX, MOTOR_RAMP_MS);
  holdDrive(MOTOR_PWM_MAX, MOTOR_PWM_MAX, durationMs);
  rampStop(MOTOR_RAMP_MS);
}

static void moveBackward(uint32_t durationMs) {
  rampTo(-MOTOR_PWM_MAX, -MOTOR_PWM_MAX, MOTOR_RAMP_MS);
  holdDrive(-MOTOR_PWM_MAX, -MOTOR_PWM_MAX, durationMs);
  rampStop(MOTOR_RAMP_MS);
}

static void turnLeft(uint32_t durationMs) {
  rampTo(-MOTOR_PWM_TURN, MOTOR_PWM_TURN, MOTOR_RAMP_MS);
  holdDrive(-MOTOR_PWM_TURN, MOTOR_PWM_TURN, durationMs);
  rampStop(MOTOR_RAMP_MS);
}

static void turnRight(uint32_t durationMs) {
  rampTo(MOTOR_PWM_TURN, -MOTOR_PWM_TURN, MOTOR_RAMP_MS);
  holdDrive(MOTOR_PWM_TURN, -MOTOR_PWM_TURN, durationMs);
  rampStop(MOTOR_RAMP_MS);
}

static void strollAround() {
  for (int i = 0; i < MOTOR_STROLL_SEGMENTS && !s_stopRequested; ++i) {
    moveForward(MOTOR_STROLL_FORWARD_MS);
    if (s_stopRequested) {
      break;
    }
    vTaskDelay(pdMS_TO_TICKS(MOTOR_STROLL_PAUSE_MS));
    if (s_stopRequested) {
      break;
    }
    if (i % 2 == 0) {
      turnLeft(MOTOR_STROLL_TURN_MS);
    } else {
      turnRight(MOTOR_STROLL_TURN_MS);
    }
    vTaskDelay(pdMS_TO_TICKS(MOTOR_STROLL_PAUSE_MS));
  }
}

static void runPattern(const char *pattern, uint32_t durationMs) {
  const uint32_t duration =
      durationMs > 0 ? durationMs : MOTOR_DEFAULT_DURATION_MS;

  if (strcmp(pattern, "stop") == 0) {
    rampStop(MOTOR_RAMP_MS);
    return;
  }
  if (strcmp(pattern, "forward") == 0) {
    moveForward(duration);
    return;
  }
  if (strcmp(pattern, "backward") == 0) {
    moveBackward(duration);
    return;
  }
  if (strcmp(pattern, "turn_left") == 0) {
    turnLeft(duration);
    return;
  }
  if (strcmp(pattern, "turn_right") == 0) {
    turnRight(duration);
    return;
  }
  if (strcmp(pattern, "stroll") == 0) {
    strollAround();
    return;
  }

  Serial.printf("[MOTOR] unknown pattern: %s\n", pattern);
}

static void motorTask(void *param) {
  (void)param;
  for (;;) {
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);

    PendingCommand work;
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    work = s_pendingWork;
    s_pendingWork.valid = false;
    xSemaphoreGive(s_mutex);

    if (!work.valid) {
      continue;
    }

    s_stopRequested = false;
    Serial.printf("[MOTOR] pattern=%s duration=%ums\n", work.pattern,
                  static_cast<unsigned>(work.durationMs));
    runPattern(work.pattern, work.durationMs);
    setDrive(0, 0);
  }
}

static void attachPwmPin(uint8_t pin) {
  ledcAttach(pin, MOTOR_PWM_FREQ, MOTOR_PWM_RES);
  ledcWrite(pin, 0);
}

} // namespace

void motorInit() {
  if (s_mutex == nullptr) {
    s_mutex = xSemaphoreCreateMutex();
  }

  attachPwmPin(PIN_MOTOR_AIN1);
  attachPwmPin(PIN_MOTOR_AIN2);
  attachPwmPin(PIN_MOTOR_BIN1);
  attachPwmPin(PIN_MOTOR_BIN2);
  setDrive(0, 0);

  if (s_task == nullptr) {
    xTaskCreate(motorTask, "motor_drive", 4096, NULL, 4, &s_task);
  }
}

void motorStop() {
  s_stopRequested = true;
  rampStop(MOTOR_RAMP_MS);
}

void motorHandleCommand(const char *pattern, uint32_t durationMs) {
  if (pattern == nullptr || pattern[0] == '\0') {
    return;
  }
  if (s_mutex == nullptr) {
    motorInit();
  }

  // Stop immediately — do not ramp here (this runs on the WS thread).
  s_stopRequested = true;
  setDrive(0, 0);

  xSemaphoreTake(s_mutex, portMAX_DELAY);
  strncpy(s_pendingWork.pattern, pattern, sizeof(s_pendingWork.pattern) - 1);
  s_pendingWork.pattern[sizeof(s_pendingWork.pattern) - 1] = '\0';
  s_pendingWork.durationMs = durationMs;
  s_pendingWork.valid = true;
  xSemaphoreGive(s_mutex);

  if (s_task != nullptr) {
    xTaskNotifyGive(s_task);
  }
}
