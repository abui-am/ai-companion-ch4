#include "audio_io.h"

#include <Arduino.h>
#include <driver/i2s.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include "config.h"
#include "protocol.h"

static const i2s_port_t MIC_PORT = I2S_NUM_0;
static const i2s_port_t SPK_PORT = I2S_NUM_1;

static bool s_audioInitialized = false;
static bool s_speakerActive = false;
static bool s_micRunning = false;
// Q15 smoothed gain for uplink peak normalization (1.0 == 32768).
static int32_t s_uplinkGainQ15 = 32768;

static int16_t audioIoSaturateI16(int32_t sample) {
  if (sample > 32767) {
    return 32767;
  }
  if (sample < -32768) {
    return -32768;
  }
  return static_cast<int16_t>(sample);
}

static int16_t audioIoConvertMicSample(int32_t raw) {
  return audioIoSaturateI16(raw >> MIC_DATA_SHIFT);
}

static void audioIoUplinkGainReset() { s_uplinkGainQ15 = 32768; }

// Slow peak targeting (WebRTC adaptive-digital style): cut gain quickly when
// a frame would clip, raise slowly so quiet speech isn't drowned by noise.
static void audioIoNormalizeUplinkFrame(int16_t *samples, size_t count) {
  if (count == 0) {
    return;
  }

  int32_t peak = 0;
  for (size_t i = 0; i < count; i++) {
    int32_t absSample = samples[i];
    if (absSample < 0) {
      absSample = -absSample;
    }
    if (absSample > peak) {
      peak = absSample;
    }
  }
  // Ignore near-silence so we don't crank up idle noise between words.
  if (peak < 768) {
    return;
  }

  int32_t desiredGainQ15 =
      (static_cast<int32_t>(MIC_UPLINK_TARGET_PEAK) << 15) / peak;
  if (desiredGainQ15 > 40960) { // max +25% boost
    desiredGainQ15 = 40960;
  }
  if (desiredGainQ15 < 8192) { // max -75% cut for very hot input
    desiredGainQ15 = 8192;
  }

  int32_t smoothedGainQ15 = s_uplinkGainQ15;
  if (desiredGainQ15 < smoothedGainQ15) {
    // Instant attack — limiter-style; no smoothing on cut.
    smoothedGainQ15 = desiredGainQ15;
  } else {
    // Slow release — avoid pumping between syllables.
    smoothedGainQ15 =
        (smoothedGainQ15 * 15 + desiredGainQ15) / 16;
  }
  s_uplinkGainQ15 = smoothedGainQ15;

  for (size_t i = 0; i < count; i++) {
    int32_t scaled =
        (static_cast<int32_t>(samples[i]) * smoothedGainQ15) >> 15;
    samples[i] = audioIoSaturateI16(scaled);
  }
}

static bool audioIoInstallMicDriver() {
  i2s_config_t micConfig = {
      .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
      .sample_rate = COMPANION_UPLINK_SAMPLE_RATE,
      .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
      .channel_format = MIC_CHANNEL_LEFT ? I2S_CHANNEL_FMT_ONLY_LEFT
                                         : I2S_CHANNEL_FMT_ONLY_RIGHT,
      .communication_format = I2S_COMM_FORMAT_STAND_I2S,
      .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
      .dma_buf_count = 8,
      .dma_buf_len = 512,
      .use_apll = false,
      .tx_desc_auto_clear = false,
      .fixed_mclk = 0,
  };
  esp_err_t micErr = i2s_driver_install(MIC_PORT, &micConfig, 0, NULL);
  if (micErr != ESP_OK) {
    Serial.printf("audio: mic i2s_driver_install failed err=%d\n", micErr);
    return false;
  }
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
    return false;
  }
  return true;
}

// Tear down and reinstall the mic I2S driver. The legacy driver can wedge
// after many stop/start cycles (long conversations) — reads then return no
// data forever and capture starves until reboot. Reinstalling recovers it
// in place; audioIoReadUplinkFrame's deadline is what detects the condition.
bool audioIoMicRecover() {
  Serial.println("audio: mic recovery — reinstalling I2S driver");
  i2s_driver_uninstall(MIC_PORT);
  if (!audioIoInstallMicDriver()) {
    Serial.println("audio: mic recovery FAILED — check wiring/power");
    s_micRunning = false;
    return false;
  }
  i2s_start(MIC_PORT);
  s_micRunning = true;
  Serial.println("audio: mic recovery ok");
  return true;
}

void audioIoInit() {
  if (s_audioInitialized) {
    return;
  }

  if (audioIoInstallMicDriver()) {
    Serial.printf("audio: I2S mic ready (bclk=%d ws=%d din=%d @ %d Hz)\n",
                  PIN_MIC_BCLK, PIN_MIC_WS, PIN_MIC_DIN,
                  COMPANION_UPLINK_SAMPLE_RATE);
    i2s_stop(MIC_PORT);
  }

  i2s_config_t spkConfig = {
      .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_TX),
      .sample_rate = COMPANION_DOWNLINK_SAMPLE_RATE,
      .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
      // Stereo interleaved; mono samples duplicated in audioIoWriteDownlink.
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

void audioIoMicStart() {
  audioIoUplinkGainReset();
  i2s_start(MIC_PORT);
  s_micRunning = true;
}

void audioIoMicStop() {
  i2s_stop(MIC_PORT);
  s_micRunning = false;
}

bool audioIoMicIsRunning() { return s_micRunning; }

static void audioIoPrimeMicInternal(int maxRounds, const char *label) {
  audioIoVadFilterReset();
  audioIoUplinkGainReset();
  i2s_zero_dma_buffer(MIC_PORT);
  vTaskDelay(pdMS_TO_TICKS(50));
  static uint8_t trash[COMPANION_UPLINK_FRAME_BYTES];
  int32_t peak = 5000;
  for (int round = 0; round < maxRounds && peak > 4000; round++) {
    for (int i = 0; i < 8; i++) {
      audioIoReadUplinkFrame(trash, sizeof(trash));
    }
    peak = 0;
    for (int i = 0; i < 4; i++) {
      size_t nbytes = audioIoReadUplinkFrame(trash, sizeof(trash));
      if (nbytes < sizeof(int16_t)) {
        continue;
      }
      const int16_t *samples = reinterpret_cast<const int16_t *>(trash);
      const size_t count = nbytes / sizeof(int16_t);
      for (size_t j = 0; j < count; j++) {
        int32_t v = samples[j];
        if (v < 0) {
          v = -v;
        }
        if (v > peak) {
          peak = v;
        }
      }
    }
  }
  if (peak > 4000) {
    Serial.printf("audio: mic primed %s (peak=%ld — I2S still settling)\n",
                  label, static_cast<long>(peak));
  } else {
    Serial.printf("audio: mic primed %s (peak=%ld)\n", label,
                  static_cast<long>(peak));
  }
}

void audioIoPrimeMic() { audioIoPrimeMicInternal(8, "full"); }

void audioIoPrimeMicAfterPause() { audioIoPrimeMicInternal(2, "after-pause"); }

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

// High-pass ~300 Hz @ 16 kHz — shared by uplink conditioning and VAD metrics.
static constexpr float kUplinkHpfAlpha = 0.889f;
static float s_uplinkHpfPrevIn = 0.0f;
static float s_uplinkHpfPrevOut = 0.0f;

// Frames below this mean |sample| after HPF are strongly attenuated before
// peak normalization so HVAC/room hiss isn't boosted toward MIC_UPLINK_TARGET_PEAK.
static constexpr uint32_t kUplinkNoiseGateEnergy = 450;
static constexpr int kUplinkNoiseAttenuateShift = 3; // ÷8

static int16_t audioIoUplinkHighPassSample(int16_t sample) {
  const float x = static_cast<float>(sample);
  const float y =
      kUplinkHpfAlpha * (s_uplinkHpfPrevOut + x - s_uplinkHpfPrevIn);
  s_uplinkHpfPrevIn = x;
  s_uplinkHpfPrevOut = y;
  if (y > 32767.0f) {
    return 32767;
  }
  if (y < -32768.0f) {
    return -32768;
  }
  return static_cast<int16_t>(y);
}

static void audioIoConditionUplinkFrame(int16_t *samples, size_t count) {
  if (count == 0) {
    return;
  }

  int64_t sumAbs = 0;
  for (size_t i = 0; i < count; i++) {
    samples[i] = audioIoUplinkHighPassSample(samples[i]);
    int32_t absSample = samples[i];
    if (absSample < 0) {
      absSample = -absSample;
    }
    sumAbs += absSample;
  }

  const uint32_t energy =
      static_cast<uint32_t>(sumAbs / static_cast<int64_t>(count));
  if (energy < kUplinkNoiseGateEnergy) {
    for (size_t i = 0; i < count; i++) {
      samples[i] = static_cast<int16_t>(samples[i] >> kUplinkNoiseAttenuateShift);
    }
  }

  audioIoNormalizeUplinkFrame(samples, count);
}

size_t audioIoReadUplinkFrame(uint8_t *out, size_t outCapacity) {
  if (outCapacity < COMPANION_UPLINK_FRAME_BYTES) {
    return 0;
  }
  // Block until one full 60 ms protocol frame is assembled — but never
  // forever: if the mic I2S wedges and stops delivering (seen after long
  // sessions), bail out so the caller can run audioIoMicRecover() instead
  // of starving capture for good (which also kills the turn beep).
  static int32_t rawBuf[COMPANION_UPLINK_FRAME_BYTES / sizeof(int16_t)];
  const size_t targetSamples = COMPANION_UPLINK_FRAME_BYTES / sizeof(int16_t);
  int16_t *dst = reinterpret_cast<int16_t *>(out);
  size_t outSamples = 0;
  const uint32_t deadlineMs = millis() + 1000;
  while (outSamples < targetSamples) {
    if (millis() > deadlineMs) {
      Serial.printf("audio: mic read deadline (%u/%u samples) — mic stalled?\n",
                    static_cast<unsigned>(outSamples),
                    static_cast<unsigned>(targetSamples));
      return 0;
    }
    size_t bytesRead = 0;
    esp_err_t err = i2s_read(MIC_PORT, rawBuf, sizeof(rawBuf), &bytesRead,
                             pdMS_TO_TICKS(200));
    if (err != ESP_OK) {
      Serial.printf("i2s mic read failed: %d (have %u samples)\n", err,
                    static_cast<unsigned>(outSamples));
      if (outSamples == 0) {
        return 0;
      }
      vTaskDelay(pdMS_TO_TICKS(2));
      continue;
    }
    if (bytesRead == 0) {
      vTaskDelay(pdMS_TO_TICKS(2));
      continue;
    }
    size_t samplesRead = bytesRead / sizeof(int32_t);
    for (size_t i = 0; i < samplesRead && outSamples < targetSamples; i++) {
      dst[outSamples++] = audioIoConvertMicSample(rawBuf[i]);
    }
  }
  audioIoConditionUplinkFrame(dst, outSamples);
  return outSamples * sizeof(int16_t);
}

static void audioIoPlayTone(int frequencyHz, int durationMs, int amplitude) {
  audioIoSpeakerEnsureStarted();
  i2s_zero_dma_buffer(SPK_PORT);
  const int sampleRate = COMPANION_DOWNLINK_SAMPLE_RATE;
  const int totalSamples = sampleRate * durationMs / 1000;
  static int16_t stereoBuf[512];
  int samplesPlayed = 0;
  while (samplesPlayed < totalSamples) {
    int chunk = totalSamples - samplesPlayed;
    if (chunk > static_cast<int>(sizeof(stereoBuf) / sizeof(stereoBuf[0]) / 2)) {
      chunk = static_cast<int>(sizeof(stereoBuf) / sizeof(stereoBuf[0]) / 2);
    }
    for (int i = 0; i < chunk; i++) {
      float t = static_cast<float>(samplesPlayed + i) /
                static_cast<float>(sampleRate);
      int16_t sample = static_cast<int16_t>(
          sinf(2.0f * PI * static_cast<float>(frequencyHz) * t) *
          static_cast<float>(amplitude));
      stereoBuf[2 * i] = sample;
      stereoBuf[2 * i + 1] = sample;
    }
    size_t written = 0;
    i2s_write(SPK_PORT, stereoBuf,
              static_cast<size_t>(chunk) * 2 * sizeof(int16_t), &written,
              portMAX_DELAY);
    samplesPlayed += chunk;
  }
  delay(static_cast<unsigned>(durationMs) + 80);
  audioIoSpeakerMute();
}

void audioIoSpeakerBeep() { audioIoPlayTone(880, 120, SPEAKER_BEEP_AMPLITUDE); }

void audioIoVadFilterReset() {
  s_uplinkHpfPrevIn = 0.0f;
  s_uplinkHpfPrevOut = 0.0f;
}

AudioFrameVadMetrics audioIoAnalyzeVadFrame(const uint8_t *frame, size_t len) {
  AudioFrameVadMetrics metrics = {};
  const int16_t *samples = reinterpret_cast<const int16_t *>(frame);
  const size_t count = len / sizeof(int16_t);
  if (count == 0) {
    return metrics;
  }

  int64_t sumAbs = 0;
  uint32_t peak = 0;
  uint32_t zeroCrossings = 0;
  int32_t prevSign = 0;

  for (size_t i = 0; i < count; i++) {
    const int16_t sample = samples[i];
    const int32_t absSample = (sample < 0) ? -sample : sample;
    sumAbs += absSample;
    if (static_cast<uint32_t>(absSample) > peak) {
      peak = static_cast<uint32_t>(absSample);
    }
    const int32_t sign =
        (sample > 0) ? 1 : ((sample < 0) ? -1 : 0);
    if (sign != 0 && prevSign != 0 && sign != prevSign) {
      zeroCrossings++;
    }
    if (sign != 0) {
      prevSign = sign;
    }
  }

  metrics.energy =
      static_cast<uint32_t>(sumAbs / static_cast<int64_t>(count));
  metrics.peak = peak;
  metrics.crestX100 =
      metrics.energy > 0 ? (peak * 100U) / metrics.energy : 0U;
  metrics.zcrX1000 =
      static_cast<uint32_t>((zeroCrossings * 1000ULL) / count);
  return metrics;
}

uint32_t audioIoFrameEnergy(const uint8_t *frame, size_t len) {
  return audioIoAnalyzeVadFrame(frame, len).energy;
}

void audioIoWriteDownlink(const int16_t *monoSamples, size_t sampleCount) {
  audioIoSpeakerEnsureStarted();
  static int16_t stereoBuf[2 * (COMPANION_DOWNLINK_FRAME_BYTES /
                                 sizeof(int16_t))];
  size_t maxSamples = sizeof(stereoBuf) / sizeof(stereoBuf[0]) / 2;
  if (sampleCount > maxSamples) {
    sampleCount = maxSamples;
  }
  for (size_t i = 0; i < sampleCount; i++) {
    int32_t boosted =
        static_cast<int32_t>(monoSamples[i]) * SPEAKER_PLAYBACK_GAIN;
    if (boosted > 32767) {
      boosted = 32767;
    } else if (boosted < -32768) {
      boosted = -32768;
    }
    int16_t sample = static_cast<int16_t>(boosted);
    stereoBuf[2 * i] = sample;
    stereoBuf[2 * i + 1] = sample;
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