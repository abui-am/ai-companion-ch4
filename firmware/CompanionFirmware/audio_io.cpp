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
#define MIC_DATA_SHIFT 14

static bool s_audioInitialized = false;
static bool s_speakerActive = false;

void audioIoInit() {
  if (s_audioInitialized) {
    return;
  }

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
  esp_err_t micErr = i2s_driver_install(MIC_PORT, &micConfig, 0, NULL);
  if (micErr != ESP_OK) {
    Serial.printf("audio: mic i2s_driver_install failed err=%d\n", micErr);
  } else {
    i2s_pin_config_t micPins = {
        .mck_io_num = I2S_PIN_NO_CHANGE,
        .bck_io_num = PIN_MIC_BCLK,
        .ws_io_num = PIN_MIC_WS,
        .data_out_num = I2S_PIN_NO_CHANGE,
        .data_in_num = PIN_MIC_DIN,
    };
    micErr = i2s_set_pin(MIC_PORT, &micPins);
    if (micErr != ESP_OK) {
      Serial.printf("audio: mic i2s_set_pin failed err=%d\n", micErr);
    } else {
      Serial.printf("audio: I2S mic ready (bclk=%d ws=%d din=%d @ %d Hz)\n",
                    PIN_MIC_BCLK, PIN_MIC_WS, PIN_MIC_DIN,
                    COMPANION_UPLINK_SAMPLE_RATE);
      i2s_stop(MIC_PORT);
    }
  }
#else
  Serial.println("HAS_MIC=0, skipping mic I2S init");
#endif

  i2s_config_t spkConfig = {
      .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_TX),
      .sample_rate = COMPANION_DOWNLINK_SAMPLE_RATE,
      .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
      // MAX98357 with SD→3.3 V listens on the left slot only.
      .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
      .communication_format = I2S_COMM_FORMAT_STAND_I2S,
      .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
      .dma_buf_count = 8,
      .dma_buf_len = 512,
      // APLL is single-port on ESP32 — keep false so mic RX clock stays valid.
      .use_apll = false,
      .tx_desc_auto_clear = true,
      .fixed_mclk = 0,
  };
  esp_err_t spkErr = i2s_driver_install(SPK_PORT, &spkConfig, 0, NULL);
  if (spkErr != ESP_OK) {
    Serial.printf("audio: speaker i2s_driver_install failed err=%d\n", spkErr);
  } else {
    i2s_pin_config_t spkPins = {
        .mck_io_num = I2S_PIN_NO_CHANGE,
        .bck_io_num = PIN_SPK_BCLK,
        .ws_io_num = PIN_SPK_WS,
        .data_out_num = PIN_SPK_DOUT,
        .data_in_num = I2S_PIN_NO_CHANGE,
    };
    spkErr = i2s_set_pin(SPK_PORT, &spkPins);
    if (spkErr != ESP_OK) {
      Serial.printf("audio: speaker i2s_set_pin failed err=%d\n", spkErr);
    } else {
      Serial.printf(
          "audio: I2S speaker ready (bclk=%d ws=%d dout=%d @ %d Hz)\n",
          PIN_SPK_BCLK, PIN_SPK_WS, PIN_SPK_DOUT,
          COMPANION_DOWNLINK_SAMPLE_RATE);
      i2s_stop(SPK_PORT);
      s_speakerActive = false;
    }
  }
  Serial.flush();
  s_audioInitialized = true;
}

#if HAS_MIC
void audioIoMicStart() { i2s_start(MIC_PORT); }

void audioIoMicStop() { i2s_stop(MIC_PORT); }
#endif

void audioIoSpeakerMute() {
  if (!s_speakerActive) {
    return;
  }
  i2s_zero_dma_buffer(SPK_PORT);
  static int16_t silence[256] = {};
  size_t written = 0;
  i2s_write(SPK_PORT, silence, sizeof(silence), &written, portMAX_DELAY);
  i2s_stop(SPK_PORT);
  s_speakerActive = false;
}

static void audioIoSpeakerEnsureStarted() {
  if (s_speakerActive) {
    return;
  }
  i2s_start(SPK_PORT);
  s_speakerActive = true;
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

static void audioIoPlayTone(int frequencyHz, int durationMs, int amplitude) {
  audioIoSpeakerEnsureStarted();
  i2s_zero_dma_buffer(SPK_PORT);
  const int sampleRate = COMPANION_DOWNLINK_SAMPLE_RATE;
  const int totalSamples = sampleRate * durationMs / 1000;
  static int16_t monoBuf[256];
  int samplesPlayed = 0;
  while (samplesPlayed < totalSamples) {
    int chunk = totalSamples - samplesPlayed;
    if (chunk > static_cast<int>(sizeof(monoBuf) / sizeof(monoBuf[0])))
      chunk = sizeof(monoBuf) / sizeof(monoBuf[0]);
    for (int i = 0; i < chunk; i++) {
      float t = static_cast<float>(samplesPlayed + i) /
                static_cast<float>(sampleRate);
      monoBuf[i] = static_cast<int16_t>(
          sinf(2.0f * PI * static_cast<float>(frequencyHz) * t) *
          static_cast<float>(amplitude));
    }
    size_t written = 0;
    i2s_write(SPK_PORT, monoBuf, static_cast<size_t>(chunk) * sizeof(int16_t),
              &written, portMAX_DELAY);
    samplesPlayed += chunk;
  }
  delay(static_cast<unsigned>(durationMs) + 80);
  audioIoSpeakerMute();
}

void audioIoSpeakerBeep() { audioIoPlayTone(880, 120, SPEAKER_BEEP_AMPLITUDE); }

void audioIoWriteDownlink(const int16_t *monoSamples, size_t sampleCount) {
  audioIoSpeakerEnsureStarted();
  static int16_t buf[COMPANION_DOWNLINK_FRAME_BYTES / sizeof(int16_t)];
  if (sampleCount > sizeof(buf) / sizeof(buf[0])) {
    sampleCount = sizeof(buf) / sizeof(buf[0]);
  }
  for (size_t i = 0; i < sampleCount; i++) {
    int32_t boosted =
        static_cast<int32_t>(monoSamples[i]) * SPEAKER_PLAYBACK_GAIN;
    if (boosted > 32767) {
      boosted = 32767;
    } else if (boosted < -32768) {
      boosted = -32768;
    }
    buf[i] = static_cast<int16_t>(boosted);
  }

  const uint8_t *ptr = reinterpret_cast<const uint8_t *>(buf);
  size_t bytesRemaining = sampleCount * sizeof(int16_t);
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
