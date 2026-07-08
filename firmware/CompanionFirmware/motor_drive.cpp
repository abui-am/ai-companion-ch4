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
static volatile bool s_motorRunning = false;

#if ESP_ARDUINO_VERSION < ESP_ARDUINO_VERSION_VAL(3, 0, 0)
static int s_pinChannel[40];
#endif

static uint8_t s_pwmMax() { return MOTOR_PWM_MAX; }
static uint8_t s_pwmTurn() { return MOTOR_PWM_TURN; }
static uint8_t s_pwmMin() { return MOTOR_PWM_MIN; }

static void motorPwmWrite(uint8_t pin, uint16_t duty) {
#if ESP_ARDUINO_VERSION >= ESP_ARDUINO_VERSION_VAL(3, 0, 0)
  ledcWrite(pin, duty);
#else
  if (pin < sizeof(s_pinChannel) / sizeof(s_pinChannel[0])) {
    const int channel = s_pinChannel[pin];
    if (channel >= 0) {
      ledcWrite(channel, duty);
    }
  }
#endif
}

static void setSideRaw(MotorSide side, int16_t speed) {
  const uint8_t in1 = (side == MOTOR_LEFT) ? PIN_MOTOR_AIN1 : PIN_MOTOR_BIN1;
  const uint8_t in2 = (side == MOTOR_LEFT) ? PIN_MOTOR_AIN2 : PIN_MOTOR_BIN2;

  if (speed > 0) {
    motorPwmWrite(in2, 0);
    motorPwmWrite(in1, static_cast<uint16_t>(speed));
  } else if (speed < 0) {
    motorPwmWrite(in1, 0);
    motorPwmWrite(in2, static_cast<uint16_t>(-speed));
  } else {
    motorPwmWrite(in1, 0);
    motorPwmWrite(in2, 0);
  }
}

static void setDrive(int16_t leftSpeed, int16_t rightSpeed) {
  setSideRaw(MOTOR_LEFT, leftSpeed);
  setSideRaw(MOTOR_RIGHT, rightSpeed);
}

static int16_t scaleRampStep(int16_t target, int step, int steps) {
  if (target == 0) {
    return 0;
  }
  const int16_t magnitude =
      static_cast<int16_t>((abs(target) * step) / steps);
  const int16_t pwmMin = static_cast<int16_t>(s_pwmMin());
  const int16_t floored = magnitude > pwmMin ? magnitude : pwmMin;
  return target > 0 ? floored : static_cast<int16_t>(-floored);
}

static void rampTo(int16_t leftTarget, int16_t rightTarget, uint32_t rampMs) {
  const int steps = 6;
  const uint32_t stepDelay = max<uint32_t>(1, rampMs / steps);
  for (int i = 1; i <= steps && !s_stopRequested; ++i) {
    setDrive(scaleRampStep(leftTarget, i, steps),
             scaleRampStep(rightTarget, i, steps));
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
  Serial.printf("[MOTOR] forward %ums pwm=%u\n",
                static_cast<unsigned>(durationMs), s_pwmMax());
  rampTo(s_pwmMax(), s_pwmMax(), MOTOR_RAMP_MS);
  holdDrive(s_pwmMax(), s_pwmMax(), durationMs);
  rampStop(MOTOR_RAMP_MS);
}

static void moveBackward(uint32_t durationMs) {
  Serial.printf("[MOTOR] backward %ums pwm=%u\n",
                static_cast<unsigned>(durationMs), s_pwmMax());
  rampTo(-static_cast<int16_t>(s_pwmMax()), -static_cast<int16_t>(s_pwmMax()),
         MOTOR_RAMP_MS);
  holdDrive(-static_cast<int16_t>(s_pwmMax()), -static_cast<int16_t>(s_pwmMax()),
            durationMs);
  rampStop(MOTOR_RAMP_MS);
}

static void turnLeft(uint32_t durationMs) {
  Serial.printf("[MOTOR] turn_left %ums pwm=%u\n",
                static_cast<unsigned>(durationMs), s_pwmTurn());
  rampTo(-static_cast<int16_t>(s_pwmTurn()), s_pwmTurn(), MOTOR_RAMP_MS);
  holdDrive(-static_cast<int16_t>(s_pwmTurn()), s_pwmTurn(), durationMs);
  rampStop(MOTOR_RAMP_MS);
}

static void turnRight(uint32_t durationMs) {
  Serial.printf("[MOTOR] turn_right %ums pwm=%u\n",
                static_cast<unsigned>(durationMs), s_pwmTurn());
  rampTo(s_pwmTurn(), -static_cast<int16_t>(s_pwmTurn()), MOTOR_RAMP_MS);
  holdDrive(s_pwmTurn(), -static_cast<int16_t>(s_pwmTurn()), durationMs);
  rampStop(MOTOR_RAMP_MS);
}

static void strollAround() {
  Serial.println("[MOTOR] stroll start");
  for (int i = 0; i < MOTOR_STROLL_SEGMENTS && !s_stopRequested; ++i) {
    Serial.printf("[MOTOR] stroll segment %d/%d\n", i + 1, MOTOR_STROLL_SEGMENTS);
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
  Serial.println("[MOTOR] stroll done");
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
      Serial.println("[MOTOR] wake with no pending work");
      continue;
    }

    s_motorRunning = true;
    s_stopRequested = false;
    Serial.printf("[MOTOR] run pattern=%s duration=%ums\n", work.pattern,
                  static_cast<unsigned>(work.durationMs));
    runPattern(work.pattern, work.durationMs);
    setDrive(0, 0);
    s_motorRunning = false;
    Serial.printf("[MOTOR] finished pattern=%s stop=%d\n", work.pattern,
                  static_cast<int>(s_stopRequested));
  }
}

static bool attachPwmPin(uint8_t pin) {
  pinMode(pin, OUTPUT);
  digitalWrite(pin, LOW);
#if ESP_ARDUINO_VERSION >= ESP_ARDUINO_VERSION_VAL(3, 0, 0)
  const bool ok = ledcAttach(pin, MOTOR_PWM_FREQ, MOTOR_PWM_RES);
#else
  static int nextChannel = 0;
  for (size_t i = 0; i < sizeof(s_pinChannel) / sizeof(s_pinChannel[0]); ++i) {
    s_pinChannel[i] = -1;
  }
  ledcSetup(nextChannel, MOTOR_PWM_FREQ, MOTOR_PWM_RES);
  ledcAttachPin(pin, nextChannel);
  if (pin < sizeof(s_pinChannel) / sizeof(s_pinChannel[0])) {
    s_pinChannel[pin] = nextChannel;
  }
  const bool ok = true;
  nextChannel++;
#endif
  motorPwmWrite(pin, 0);
  Serial.printf("[MOTOR] attach pin=%u ok=%d\n", static_cast<unsigned>(pin),
                static_cast<int>(ok));
  return ok;
}

} // namespace

void motorInit() {
  if (s_mutex == nullptr) {
    s_mutex = xSemaphoreCreateMutex();
  }

  Serial.println("[MOTOR] init");
  attachPwmPin(PIN_MOTOR_AIN1);
  attachPwmPin(PIN_MOTOR_AIN2);
  attachPwmPin(PIN_MOTOR_BIN1);
  attachPwmPin(PIN_MOTOR_BIN2);
  setDrive(0, 0);

  if (s_task == nullptr) {
    const BaseType_t ok =
        xTaskCreate(motorTask, "motor_drive", 4096, NULL, 4, &s_task);
    Serial.printf("[MOTOR] task create ok=%d handle=%p\n", static_cast<int>(ok),
                  static_cast<void *>(s_task));
  }
}

void motorStop() {
  Serial.println("[MOTOR] stop requested");
  s_stopRequested = true;
  setDrive(0, 0);
}

void motorHandleCommand(const char *pattern, uint32_t durationMs) {
  if (pattern == nullptr || pattern[0] == '\0') {
    Serial.println("[MOTOR] handleCommand: empty pattern");
    return;
  }
  if (s_mutex == nullptr) {
    motorInit();
  }

  Serial.printf("[MOTOR] handleCommand pattern=%s duration=%ums running=%d\n",
                pattern, static_cast<unsigned>(durationMs),
                static_cast<int>(s_motorRunning));

  if (s_motorRunning) {
    s_stopRequested = true;
    setDrive(0, 0);
  }

  xSemaphoreTake(s_mutex, portMAX_DELAY);
  strncpy(s_pendingWork.pattern, pattern, sizeof(s_pendingWork.pattern) - 1);
  s_pendingWork.pattern[sizeof(s_pendingWork.pattern) - 1] = '\0';
  s_pendingWork.durationMs = durationMs;
  s_pendingWork.valid = true;
  xSemaphoreGive(s_mutex);

  if (s_task != nullptr) {
    xTaskNotifyGive(s_task);
    Serial.println("[MOTOR] queued + notified motor task");
  } else {
    Serial.println("[MOTOR] ERROR: motor task missing");
  }
}
