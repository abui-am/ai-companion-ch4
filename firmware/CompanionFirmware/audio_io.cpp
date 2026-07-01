#include "audio_io.h"

#include <Arduino.h>
#include <driver/i2s.h>

#include "config.h"
#include "protocol.h"

static const i2s_port_t MIC_PORT = I2S_NUM_0;
static const i2s_port_t SPK_PORT = I2S_NUM_1;

// INMP441 outputs 24-bit audio left-justified in a 32-bit I2S word.
// Read at 32-bit and right-shift to extract the 16-bit value we send upstream.
// Increase this value if audio is clipped; decrease if it's too quiet.
#define MIC_DATA_SHIFT 13

void audioIoInit() {
#if HAS_MIC
  i2s_config_t micConfig = {
      .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
      .sample_rate = COMPANION_UPLINK_SAMPLE_RATE,
      .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
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
#else
  Serial.println("HAS_MIC=0, skipping mic I2S init");
#endif

  i2s_config_t spkConfig = {
      .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_TX),
      .sample_rate = COMPANION_DOWNLINK_SAMPLE_RATE,
      .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
      .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,
      .communication_format = I2S_COMM_FORMAT_STAND_I2S,
      .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
      .dma_buf_count = 8,
      .dma_buf_len = 512,
      // APLL is single-port on ESP32 — keep false so mic RX clock stays valid.
      .use_apll = false,
      .tx_desc_auto_clear = true,
      .fixed_mclk = 0,
  };
  i2s_driver_install(SPK_PORT, &spkConfig, 0, NULL);

  i2s_pin_config_t spkPins = {
      .bck_io_num = PIN_SPK_BCLK,
      .ws_io_num = PIN_SPK_WS,
      .data_out_num = PIN_SPK_DOUT,
      .data_in_num = I2S_PIN_NO_CHANGE,
  };
  i2s_set_pin(SPK_PORT, &spkPins);

  Serial.println("I2S mic + speaker channels ready");
}

size_t audioIoReadUplinkFrame(uint8_t *out, size_t outCapacity) {
#if HAS_MIC
  // INMP441 fills 32-bit I2S words; read raw 32-bit then downshift to 16-bit.
  static int32_t rawBuf[COMPANION_UPLINK_FRAME_BYTES / sizeof(int16_t)];
  size_t bytesRead = 0;
  esp_err_t err = i2s_read(MIC_PORT, rawBuf, sizeof(rawBuf), &bytesRead,
                           pdMS_TO_TICKS(200));
  if (err != ESP_OK) {
    Serial.printf("i2s mic read failed: %d\n", err);
    return 0;
  }
  size_t samplesRead = bytesRead / sizeof(int32_t);
  size_t outBytes = samplesRead * sizeof(int16_t);
  if (outBytes > outCapacity)
    outBytes = outCapacity;
  int16_t *dst = (int16_t *)out;
  for (size_t i = 0; i < outBytes / sizeof(int16_t); i++) {
    dst[i] = (int16_t)(rawBuf[i] >> MIC_DATA_SHIFT);
  }
  return outBytes;
#else
  return 0;
#endif
}

void audioIoWriteDownlink(const int16_t *monoSamples, size_t sampleCount) {
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
      Serial.printf("i2s speaker write failed: %d\n", err);
      break;
    }
    ptr += bytesWritten;
    bytesRemaining -= bytesWritten;
  }
}
