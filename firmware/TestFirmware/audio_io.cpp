#include "audio_io.h"

#include <Arduino.h>
#include <driver/i2s.h>
#include <esp_task_wdt.h>
#include <math.h>

#include "config.h"
#include "protocol.h"

static const i2s_port_t MIC_PORT = I2S_NUM_0;
#if HAS_MIC
static const i2s_port_t SPK_PORT = I2S_NUM_1;
#else
// Speaker-only: use I2S port 0 (mic port unused).
static const i2s_port_t SPK_PORT = I2S_NUM_0;
#endif

void audioIoInit() {
#if HAS_MIC
  i2s_config_t micConfig = {
      .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
      .sample_rate = COMPANION_UPLINK_SAMPLE_RATE,
      .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
      .channel_format = MIC_CHANNEL_LEFT ? I2S_CHANNEL_FMT_ONLY_LEFT
                                         : I2S_CHANNEL_FMT_ONLY_RIGHT,
      .communication_format = I2S_COMM_FORMAT_STAND_I2S,
      .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
      .dma_buf_count = 4,
      .dma_buf_len = 256,
      .use_apll = false,
      .tx_desc_auto_clear = false,
      .fixed_mclk = 0,
  };
  i2s_driver_install(MIC_PORT, &micConfig, 0, NULL);

  i2s_pin_config_t micPins = {
      .bck_io_num = PIN_MIC_BCLK,
      .ws_io_num = PIN_MIC_WS,
      .data_out_num = I2S_PIN_NO_CHANGE,
      .data_in_num = PIN_MIC_DIN,
  };
  i2s_set_pin(MIC_PORT, &micPins);
  Serial.println("audio: I2S mic ready");
#else
  Serial.println("audio: mic disabled (USE_SYNTHETIC_MIC or HAS_MIC=0)");
  Serial.flush();
#endif

#if HAS_SPEAKER
  i2s_config_t spkConfig = {
      .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_TX),
      .sample_rate = COMPANION_DOWNLINK_SAMPLE_RATE,
      .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
      .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,
      .communication_format = I2S_COMM_FORMAT_STAND_I2S,
      .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
      .dma_buf_count = 8,
      .dma_buf_len = 512,
      .use_apll = true,
      .tx_desc_auto_clear = true,
      .fixed_mclk = 0,
  };
  esp_err_t spkErr = i2s_driver_install(SPK_PORT, &spkConfig, 0, NULL);
  if (spkErr != ESP_OK) {
    Serial.printf("audio: speaker i2s_driver_install failed err=%d\n", spkErr);
    return;
  }

  i2s_pin_config_t spkPins = {
      .bck_io_num = PIN_SPK_BCLK,
      .ws_io_num = PIN_SPK_WS,
      .data_out_num = PIN_SPK_DOUT,
      .data_in_num = I2S_PIN_NO_CHANGE,
  };
  spkErr = i2s_set_pin(SPK_PORT, &spkPins);
  if (spkErr != ESP_OK) {
    Serial.printf("audio: speaker i2s_set_pin failed err=%d\n", spkErr);
    return;
  }
  Serial.println("audio: I2S speaker ready");
  Serial.flush();
#else
  Serial.println("audio: speaker disabled (downlink logged only)");
#endif
}

size_t audioIoReadUplinkFrame(uint8_t *out, size_t outCapacity) {
#if HAS_MIC
  size_t bytesRead = 0;
  esp_err_t err =
      i2s_read(MIC_PORT, out, outCapacity, &bytesRead, pdMS_TO_TICKS(200));
  if (err != ESP_OK) {
    Serial.printf("audio: mic read failed err=%d\n", err);
    return 0;
  }
  return bytesRead;
#else
  (void)out;
  (void)outCapacity;
  return 0;
#endif
}

void audioIoWriteDownlink(const int16_t *monoSamples, size_t sampleCount) {
#if HAS_SPEAKER
  static int16_t
      stereoBuf[2 * (COMPANION_DOWNLINK_FRAME_BYTES / sizeof(int16_t))];
  size_t maxSamples = sizeof(stereoBuf) / sizeof(stereoBuf[0]) / 2;
  if (sampleCount > maxSamples) {
    sampleCount = maxSamples;
  }
  for (size_t i = 0; i < sampleCount; i++) {
    stereoBuf[2 * i] = monoSamples[i];
    stereoBuf[2 * i + 1] = monoSamples[i];
  }

  const uint8_t *ptr = reinterpret_cast<const uint8_t *>(stereoBuf);
  size_t bytesRemaining = sampleCount * 2 * sizeof(int16_t);
  while (bytesRemaining > 0) {
    size_t bytesWritten = 0;
    esp_err_t err =
        i2s_write(SPK_PORT, ptr, bytesRemaining, &bytesWritten, portMAX_DELAY);
    if (err != ESP_OK || bytesWritten == 0) {
      Serial.printf("audio: speaker write failed err=%d\n", err);
      break;
    }
    ptr += bytesWritten;
    bytesRemaining -= bytesWritten;
  }
#else
  (void)monoSamples;
  (void)sampleCount;
#endif
}

void audioIoSpeakerSelfTest() {
#if HAS_SPEAKER
  const int sampleRate = COMPANION_DOWNLINK_SAMPLE_RATE;
  const float frequencyHz = 440.0f;
  const int durationMs = 1000;
  const int totalSamples = sampleRate * durationMs / 1000;
  static int16_t monoBuf[256];
  int samplesPlayed = 0;
  int writeErrors = 0;

  while (samplesPlayed < totalSamples) {
    int chunk = totalSamples - samplesPlayed;
    if (chunk > static_cast<int>(sizeof(monoBuf) / sizeof(monoBuf[0]))) {
      chunk = sizeof(monoBuf) / sizeof(monoBuf[0]);
    }
    for (int i = 0; i < chunk; i++) {
      float t = static_cast<float>(samplesPlayed + i) /
                static_cast<float>(sampleRate);
      monoBuf[i] =
          static_cast<int16_t>(sinf(2.0f * PI * frequencyHz * t) * 8000.0f);
    }
    static int16_t stereoBuf[2 * (sizeof(monoBuf) / sizeof(monoBuf[0]))];
    for (int i = 0; i < chunk; i++) {
      stereoBuf[2 * i] = monoBuf[i];
      stereoBuf[2 * i + 1] = monoBuf[i];
    }
    size_t bytesWritten = 0;
    esp_err_t err = i2s_write(SPK_PORT, stereoBuf,
                              static_cast<size_t>(chunk) * 2 * sizeof(int16_t),
                              &bytesWritten, pdMS_TO_TICKS(500));
    if (err != ESP_OK) {
      writeErrors++;
    }
    samplesPlayed += chunk;
    yield();
    esp_task_wdt_reset();
  }

  if (writeErrors == 0) {
    Serial.printf("[SPEAKER TEST] OK — played %d ms @ %d Hz (%d samples)\n",
                  durationMs, static_cast<int>(frequencyHz), totalSamples);
  } else {
    Serial.printf("[SPEAKER TEST] FAIL — i2s_write errors=%d\n", writeErrors);
  }
#else
  Serial.println("[SPEAKER TEST] skipped (HAS_SPEAKER=0)");
#endif
}
