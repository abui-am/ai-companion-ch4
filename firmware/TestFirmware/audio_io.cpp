#include "audio_io.h"

#include <Arduino.h>
#include <driver/i2s.h>
#include <math.h>

#include "config.h"
#include "protocol.h"

#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#if MIC_LOOPBACK_TEST_MODE
#include "button.h"
#include "mic_server_upload.h"

static volatile bool s_touchTap = false;

enum class LoopbackPhase { Idle, Recording, Playing };

static LoopbackPhase s_phase = LoopbackPhase::Idle;
static size_t s_recordLen = 0;
static uint8_t *s_recordBuf = nullptr;
static size_t s_recordBufCap = 0;
static bool s_recordBufferFull = false;

static size_t loopbackRecordBytesForSec(unsigned sec) {
  return static_cast<size_t>(COMPANION_UPLINK_SAMPLE_RATE) * 2 * sec;
}

static uint8_t *loopbackTryAlloc(size_t bytes) {
  uint8_t *p = static_cast<uint8_t *>(
      heap_caps_malloc(bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
  if (p != nullptr) {
    return p;
  }
  p = static_cast<uint8_t *>(
      heap_caps_malloc(bytes, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
  if (p != nullptr) {
    return p;
  }
  return static_cast<uint8_t *>(malloc(bytes));
}

static bool loopbackInitRecordBuffer() {
  if (s_recordBuf != nullptr) {
    return true;
  }

  const size_t frameBytes = COMPANION_UPLINK_FRAME_BYTES;
  const size_t minBytes = loopbackRecordBytesForSec(1);
  const size_t idealBytes =
      loopbackRecordBytesForSec(MIC_LOOPBACK_MAX_RECORD_SEC);

  size_t psramBlock =
      heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  size_t internalBlock =
      heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  constexpr size_t kHeapReserve = 20480;
  if (internalBlock > kHeapReserve) {
    internalBlock -= kHeapReserve;
  }
  internalBlock = (internalBlock / frameBytes) * frameBytes;
  psramBlock = (psramBlock / frameBytes) * frameBytes;

  Serial.printf(
      "[MIC LOOPBACK] alloc: want=%u psram_block=%u internal_block=%u "
      "free_heap=%u\n",
      static_cast<unsigned>(idealBytes), static_cast<unsigned>(psramBlock),
      static_cast<unsigned>(internalBlock),
      static_cast<unsigned>(ESP.getFreeHeap()));

  for (size_t tryBytes = idealBytes; tryBytes >= minBytes;
       tryBytes -= frameBytes) {
    s_recordBuf = loopbackTryAlloc(tryBytes);
    if (s_recordBuf == nullptr) {
      continue;
    }
    s_recordBufCap = tryBytes;
    const float maxSec = static_cast<float>(s_recordBufCap) /
                         static_cast<float>(COMPANION_UPLINK_SAMPLE_RATE * 2);
    const bool inPsram = esp_ptr_external_ram(s_recordBuf);
    Serial.printf("[MIC LOOPBACK] record buffer %u bytes (~%.1f sec, %s)\n",
                  static_cast<unsigned>(s_recordBufCap), maxSec,
                  inPsram ? "PSRAM" : "internal");
    if (maxSec < static_cast<float>(MIC_LOOPBACK_MAX_RECORD_SEC)) {
      Serial.printf(
          "[MIC LOOPBACK] WARNING: wanted %d sec — enable PSRAM for 10 sec "
          "recordings\n",
          MIC_LOOPBACK_MAX_RECORD_SEC);
    }
    return true;
  }

  Serial.printf("[MIC LOOPBACK] ERROR: could not allocate record buffer "
                "(free_heap=%u largest_internal=%u)\n",
                static_cast<unsigned>(ESP.getFreeHeap()),
                static_cast<unsigned>(heap_caps_get_largest_free_block(
                    MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT)));
  return false;
}
#endif

// INMP441: 24-bit audio left-justified in a 32-bit I2S word (MIC_DATA_SHIFT in
// config.h).

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
    }
  }
  Serial.flush();
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
    }
  }
  Serial.flush();
#else
  Serial.println("audio: speaker disabled (downlink logged only)");
#endif
}

void audioIoPrimeMic() {
#if HAS_MIC
  i2s_zero_dma_buffer(MIC_PORT);
  static uint8_t trash[COMPANION_UPLINK_FRAME_BYTES];
  int32_t bestPeak = 0;
  for (int i = 0; i < 6; i++) {
    size_t nbytes = audioIoReadUplinkFrame(trash, sizeof(trash));
    if (nbytes >= sizeof(int16_t)) {
      const int16_t *samples = reinterpret_cast<const int16_t *>(trash);
      const size_t count = nbytes / sizeof(int16_t);
      for (size_t j = 0; j < count; j++) {
        int32_t v = samples[j];
        if (v < 0) {
          v = -v;
        }
        if (v > bestPeak) {
          bestPeak = v;
        }
      }
    }
  }
  Serial.printf("audio: mic primed (peak=%ld)\n", static_cast<long>(bestPeak));
#endif
}

size_t audioIoReadUplinkFrame(uint8_t *out, size_t outCapacity) {
#if HAS_MIC
  static int32_t rawBuf[COMPANION_UPLINK_FRAME_BYTES / sizeof(int16_t)];
  size_t bytesRead = 0;
  esp_err_t err = i2s_read(MIC_PORT, rawBuf, sizeof(rawBuf), &bytesRead,
                           pdMS_TO_TICKS(200));
  if (err != ESP_OK) {
    Serial.printf("audio: mic read failed err=%d\n", err);
    return 0;
  }
  size_t samplesRead = bytesRead / sizeof(int32_t);
  if (samplesRead == 0) {
    return 0;
  }
  size_t outSamples = samplesRead;
  if (outSamples > outCapacity / sizeof(int16_t)) {
    outSamples = outCapacity / sizeof(int16_t);
  }
  int16_t *dst = reinterpret_cast<int16_t *>(out);
  for (size_t i = 0; i < outSamples; i++) {
    dst[i] = static_cast<int16_t>(rawBuf[i] >> MIC_DATA_SHIFT);
  }
  return outSamples * sizeof(int16_t);
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

#if HAS_SPEAKER
static int audioIoPlayTone(int frequencyHz, int durationMs, int amplitude) {
  i2s_zero_dma_buffer(SPK_PORT);
  const int sampleRate = COMPANION_DOWNLINK_SAMPLE_RATE;
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
      monoBuf[i] = static_cast<int16_t>(
          sinf(2.0f * PI * static_cast<float>(frequencyHz) * t) *
          static_cast<float>(amplitude));
    }
    static int16_t stereoBuf[2 * (sizeof(monoBuf) / sizeof(monoBuf[0]))];
    for (int i = 0; i < chunk; i++) {
      stereoBuf[2 * i] = monoBuf[i];
      stereoBuf[2 * i + 1] = monoBuf[i];
    }
    size_t bytesWritten = 0;
    esp_err_t err = i2s_write(SPK_PORT, stereoBuf,
                              static_cast<size_t>(chunk) * 2 * sizeof(int16_t),
                              &bytesWritten, portMAX_DELAY);
    if (err != ESP_OK || bytesWritten == 0) {
      Serial.printf("audio: tone i2s_write failed err=%d written=%u\n", err,
                    static_cast<unsigned>(bytesWritten));
      writeErrors++;
      break;
    }
    samplesPlayed += chunk;
  }

  // Let DMA clock out the full tone before mic/heap work continues.
  delay(static_cast<unsigned>(durationMs) + 80);
  return writeErrors;
}
#endif

void audioIoSpeakerBeep() {
#if HAS_SPEAKER
  constexpr int kBeepMs = 400;
  if (audioIoPlayTone(880, kBeepMs, 12000) == 0) {
    Serial.printf("[SPEAKER] beep OK (%d ms @ 880 Hz)\n", kBeepMs);
  } else {
    Serial.println("[SPEAKER] beep FAILED — check I2S speaker wiring");
  }
#else
  Serial.println("[SPEAKER] beep skipped (HAS_SPEAKER=0)");
#endif
}

void audioIoSpeakerSelfTest() {
#if HAS_SPEAKER
  constexpr int kTestMs = 1000;
  if (audioIoPlayTone(440, kTestMs, 10000) == 0) {
    Serial.printf("[SPEAKER TEST] OK — %d ms @ 440 Hz\n", kTestMs);
  } else {
    Serial.println("[SPEAKER TEST] FAIL — i2s_write errors");
  }
#else
  Serial.println("[SPEAKER TEST] skipped (HAS_SPEAKER=0)");
#endif
}

#if MIC_LOOPBACK_TEST_MODE

struct PcmStats {
  int32_t rms;
  int32_t peak;
  int32_t dc;
  uint32_t clip;
  uint32_t zeroCrossings;
};

static PcmStats analyzePcm(const int16_t *samples, size_t count) {
  PcmStats stats = {};
  if (count == 0) {
    return stats;
  }
  int64_t sum = 0;
  int64_t sumSq = 0;
  int16_t prev = samples[0];
  for (size_t i = 0; i < count; i++) {
    int32_t v = samples[i];
    sum += v;
    sumSq += static_cast<int64_t>(v) * v;
    int32_t absV = v < 0 ? -v : v;
    if (absV > stats.peak) {
      stats.peak = absV;
    }
    if (absV > 30000) {
      stats.clip++;
    }
    if (i > 0) {
      if ((prev <= 0 && v > 0) || (prev >= 0 && v < 0)) {
        stats.zeroCrossings++;
      }
    }
    prev = static_cast<int16_t>(v);
  }
  stats.dc = static_cast<int32_t>(sum / static_cast<int64_t>(count));
  stats.rms = static_cast<int32_t>(
      sqrt(static_cast<double>(sumSq) / static_cast<double>(count)));
  return stats;
}

struct IntervalStats {
  uint32_t count = 0;
  float minMs = 1e9f;
  float maxMs = 0.0f;
  float meanMs = 0.0f;
  float m2 = 0.0f;

  void reset() {
    count = 0;
    minMs = 1e9f;
    maxMs = 0.0f;
    meanMs = 0.0f;
    m2 = 0.0f;
  }

  void add(float value) {
    count++;
    if (value < minMs) {
      minMs = value;
    }
    if (value > maxMs) {
      maxMs = value;
    }
    float delta = value - meanMs;
    meanMs += delta / static_cast<float>(count);
    float delta2 = value - meanMs;
    m2 += delta * delta2;
  }

  float stdDev() const {
    return count > 1 ? sqrtf(m2 / static_cast<float>(count)) : 0.0f;
  }
};

struct LoopbackCounters {
  uint32_t frames = 0;
  uint32_t shortReads = 0;
  uint32_t readErrors = 0;
  uint32_t writeErrors = 0;
  uint32_t partialWrites = 0;
  uint32_t idleLoops = 0;
};

static void applyMonitorGain(const int16_t *in, int16_t *out,
                             size_t sampleCount) {
  for (size_t i = 0; i < sampleCount; i++) {
    int32_t v = static_cast<int32_t>(in[i]) * MIC_LOOPBACK_MONITOR_GAIN;
    if (v > 32767) {
      v = 32767;
    } else if (v < -32768) {
      v = -32768;
    }
    out[i] = static_cast<int16_t>(v);
  }
}

// 16 kHz mic → 24 kHz speaker (same rate as TTS downlink path).
static size_t resample16kTo24k(const int16_t *in, size_t inCount, int16_t *out,
                               size_t outCapacity) {
  size_t outCount = (inCount * 3) / 2;
  if (outCount > outCapacity) {
    outCount = outCapacity;
  }
  for (size_t i = 0; i < outCount; i++) {
    float pos = static_cast<float>(i) * (2.0f / 3.0f);
    size_t idx = static_cast<size_t>(pos);
    float frac = pos - static_cast<float>(idx);
    if (idx >= inCount) {
      idx = inCount - 1;
    }
    size_t idx2 = (idx + 1 < inCount) ? idx + 1 : idx;
    float sample = static_cast<float>(in[idx]) * (1.0f - frac) +
                   static_cast<float>(in[idx2]) * frac;
    out[i] = static_cast<int16_t>(sample);
  }
  return outCount;
}

static bool loopbackPlayMicFrame(const int16_t *monoSamples,
                                 size_t sampleCount) {
  static int16_t gainBuf[COMPANION_UPLINK_FRAME_BYTES / sizeof(int16_t)];
  static int16_t resampledBuf[COMPANION_DOWNLINK_FRAME_BYTES / sizeof(int16_t)];
  applyMonitorGain(monoSamples, gainBuf, sampleCount);
  size_t outCount =
      resample16kTo24k(gainBuf, sampleCount, resampledBuf,
                       sizeof(resampledBuf) / sizeof(resampledBuf[0]));
  audioIoWriteDownlink(resampledBuf, outCount);
  return outCount > 0;
}

#if MIC_LOOPBACK_TEST_MODE
static void loopbackConfirmBeep() { audioIoSpeakerBeep(); }
#endif

static size_t loopbackWriteDownlink(const int16_t *monoSamples,
                                    size_t sampleCount, bool *writeOk) {
  *writeOk = loopbackPlayMicFrame(monoSamples, sampleCount);
  size_t outCount = (sampleCount * 3) / 2;
  return outCount * 2 * sizeof(int16_t);
}

static void
logLoopbackSummary(const LoopbackCounters &counters, uint32_t windowFrames,
                   const IntervalStats &interval, const IntervalStats &readUs,
                   const IntervalStats &writeUs, int32_t rmsMin, int32_t rmsMax,
                   int32_t rmsSum, int32_t peakMax, uint32_t clipSum) {
  float rmsAvg = windowFrames > 0 ? static_cast<float>(rmsSum) /
                                        static_cast<float>(windowFrames)
                                  : 0.0f;
  Serial.println("[LOOPBACK SUMMARY] --------------------------------");
  Serial.printf("  session_frames=%lu window_frames=%lu short_reads=%lu "
                "write_err=%lu clip_sum=%lu heap=%u\n",
                static_cast<unsigned long>(counters.frames),
                static_cast<unsigned long>(windowFrames),
                static_cast<unsigned long>(counters.shortReads),
                static_cast<unsigned long>(counters.writeErrors),
                static_cast<unsigned long>(clipSum),
                static_cast<unsigned>(ESP.getFreeHeap()));
  Serial.printf("  interval_ms min=%.2f max=%.2f avg=%.2f std=%.2f "
                "(expected=%d)\n",
                interval.minMs, interval.maxMs, interval.meanMs,
                interval.stdDev(), COMPANION_FRAME_MS);
  Serial.printf(
      "  read_us   min=%.0f max=%.0f avg=%.0f (hw wait ~%dms — normal)\n",
      readUs.minMs, readUs.maxMs, readUs.meanMs, COMPANION_FRAME_MS);
  if (writeUs.count > 0) {
    Serial.printf("  write_us  min=%.0f max=%.0f avg=%.0f std=%.0f\n",
                  writeUs.minMs, writeUs.maxMs, writeUs.meanMs,
                  writeUs.stdDev());
  }
  Serial.printf("  rms_avg=%.0f rms_min=%ld rms_max=%ld peak_max=%ld\n", rmsAvg,
                static_cast<long>(rmsMin), static_cast<long>(rmsMax),
                static_cast<long>(peakMax));
  if (clipSum > 0) {
    Serial.printf(
        "  WARNING: clipping detected — try MIC_DATA_SHIFT=%d in config.h\n",
        MIC_DATA_SHIFT + 1);
  }
  Serial.println("[LOOPBACK SUMMARY] --------------------------------");
}

#if MIC_LOOPBACK_TEST_MODE
static int32_t pcmPeak(const int16_t *samples, size_t count) {
  int32_t peak = 0;
  for (size_t i = 0; i < count; i++) {
    int32_t v = samples[i];
    if (v < 0) {
      v = -v;
    }
    if (v > peak) {
      peak = v;
    }
  }
  return peak;
}

static int audioIoPlayPcmMono(const int16_t *samples, size_t sampleCount,
                              int sampleRateHz) {
  i2s_zero_dma_buffer(SPK_PORT);
  esp_err_t clkErr = i2s_set_clk(SPK_PORT, static_cast<uint32_t>(sampleRateHz),
                                 I2S_BITS_PER_SAMPLE_16BIT, I2S_CHANNEL_STEREO);
  if (clkErr != ESP_OK) {
    Serial.printf("audio: i2s_set_clk %d Hz failed err=%d\n", sampleRateHz,
                  clkErr);
    return -1;
  }

  static int16_t monoBuf[256];
  size_t offset = 0;
  int writeErrors = 0;
  while (offset < sampleCount) {
    size_t chunk = sampleCount - offset;
    if (chunk > sizeof(monoBuf) / sizeof(monoBuf[0])) {
      chunk = sizeof(monoBuf) / sizeof(monoBuf[0]);
    }
    for (size_t i = 0; i < chunk; i++) {
      int32_t v =
          static_cast<int32_t>(samples[offset + i]) * MIC_LOOPBACK_MONITOR_GAIN;
      if (v > 32767) {
        v = 32767;
      } else if (v < -32768) {
        v = -32768;
      }
      monoBuf[i] = static_cast<int16_t>(v);
    }
    static int16_t stereoBuf[2 * (sizeof(monoBuf) / sizeof(monoBuf[0]))];
    for (size_t i = 0; i < chunk; i++) {
      stereoBuf[2 * i] = monoBuf[i];
      stereoBuf[2 * i + 1] = monoBuf[i];
    }
    size_t bytesWritten = 0;
    esp_err_t err = i2s_write(SPK_PORT, stereoBuf, chunk * 2 * sizeof(int16_t),
                              &bytesWritten, portMAX_DELAY);
    if (err != ESP_OK || bytesWritten == 0) {
      Serial.printf("audio: pcm i2s_write failed err=%d written=%u\n", err,
                    static_cast<unsigned>(bytesWritten));
      writeErrors++;
      break;
    }
    offset += chunk;
  }

  const unsigned durationMs = static_cast<unsigned>(
      sampleCount * 1000 / static_cast<size_t>(sampleRateHz));
  delay(durationMs + 80);

  clkErr = i2s_set_clk(SPK_PORT, COMPANION_DOWNLINK_SAMPLE_RATE,
                       I2S_BITS_PER_SAMPLE_16BIT, I2S_CHANNEL_STEREO);
  if (clkErr != ESP_OK) {
    Serial.printf("audio: i2s_set_clk restore 24k failed err=%d\n", clkErr);
  }
  return writeErrors;
}

static void playbackRecording(size_t bytes) {
  if (s_recordBuf == nullptr || bytes < sizeof(int16_t)) {
    Serial.println("[MIC LOOPBACK] nothing to play back");
    return;
  }
  const int16_t *samples = reinterpret_cast<const int16_t *>(s_recordBuf);
  const size_t sampleCount = bytes / sizeof(int16_t);
  const int32_t peak = pcmPeak(samples, sampleCount);
  const unsigned durationMs =
      static_cast<unsigned>(sampleCount * 1000 / COMPANION_UPLINK_SAMPLE_RATE);
  Serial.printf("[MIC] (6) playback (~%u ms, %u samples, peak=%ld)...\n",
                durationMs, static_cast<unsigned>(sampleCount),
                static_cast<long>(peak));
  if (peak < 200) {
    Serial.println(
        "[MIC] WARNING: recording very quiet — check mic wiring/shift");
  }

  if (audioIoPlayPcmMono(samples, sampleCount, COMPANION_UPLINK_SAMPLE_RATE) !=
      0) {
    Serial.println("[MIC] playback FAILED — i2s_write error");
  } else {
    Serial.println("[MIC] playback done — tap to record again");
  }
}

static void finishRecordingSession(LoopbackCounters &counters,
                                   IntervalStats &intervalStats,
                                   IntervalStats &readUsStats,
                                   IntervalStats &writeUsStats, int32_t rmsMin,
                                   int32_t rmsMax, int32_t rmsSum,
                                   int32_t peakMax, uint32_t clipSum,
                                   bool haveSessionStats) {
  const size_t bytes = s_recordLen;
  s_recordLen = 0;
  s_recordBufferFull = false;

  if (bytes < sizeof(int16_t)) {
    Serial.println("[MIC LOOPBACK] too short — tap to record again");
    if (haveSessionStats) {
      logLoopbackSummary(counters, intervalStats.count, intervalStats,
                         readUsStats, writeUsStats, rmsMin, rmsMax, rmsSum,
                         peakMax, clipSum);
    }
    return;
  }

  s_phase = LoopbackPhase::Playing;

  const int16_t *samples = reinterpret_cast<const int16_t *>(s_recordBuf);
  const size_t sampleCount = bytes / sizeof(int16_t);
  const int32_t peak = pcmPeak(samples, sampleCount);
  const unsigned durationMs =
      static_cast<unsigned>(sampleCount * 1000 / COMPANION_UPLINK_SAMPLE_RATE);
  Serial.printf("[MIC] captured %u samples (~%u ms) peak=%ld\n",
                static_cast<unsigned>(sampleCount), durationMs,
                static_cast<long>(peak));
  if (peak < 200) {
    Serial.println(
        "[MIC] WARNING: recording very quiet — check mic wiring/shift");
  }

#if MIC_UPLOAD_TO_SERVER
  Serial.println("[MIC] (6) uploading to CompanionServer...");
  if (!micServerUploadSend(reinterpret_cast<const uint8_t *>(s_recordBuf),
                           bytes)) {
    Serial.println("[MIC] upload FAILED");
  }
#else
  playbackRecording(bytes);
#endif

  s_phase = LoopbackPhase::Idle;

  if (haveSessionStats) {
    logLoopbackSummary(counters, intervalStats.count, intervalStats,
                       readUsStats, writeUsStats, rmsMin, rmsMax, rmsSum,
                       peakMax, clipSum);
  }
}

static void onLoopbackButton(ButtonEvent event, void *ctx) {
  (void)ctx;
  if (event != BUTTON_EVENT_PRESSED) {
    return;
  }
  static uint32_t s_lastTapMs = 0;
  const uint32_t nowMs = millis();
  if (nowMs - s_lastTapMs < 400) {
    return;
  }
  s_lastTapMs = nowMs;
  s_touchTap = true;
}
#endif

static void micLoopbackTask(void *arg) {
  (void)arg;

  static uint8_t micBuf[COMPANION_UPLINK_FRAME_BYTES];
  LoopbackCounters counters;
  IntervalStats intervalStats;
  IntervalStats readUsStats;
  IntervalStats writeUsStats;
  int32_t rmsMin = INT32_MAX;
  int32_t rmsMax = 0;
  int32_t rmsSum = 0;
  int32_t peakMax = 0;
  uint32_t clipSum = 0;

  uint32_t lastFrameUs = micros();
  const size_t expectedBytes = COMPANION_UPLINK_FRAME_BYTES;
  bool haveSessionStats = false;

  const unsigned maxSec = static_cast<unsigned>(
      s_recordBufCap / (COMPANION_UPLINK_SAMPLE_RATE * 2));
  Serial.println("=== Mic record/playback ===");
  Serial.println("  1. tap");
  Serial.println("  2. mic listening");
  Serial.println("  3. speak (up to 10 sec)");
  Serial.println("  4. tap");
  Serial.println("  5. mic stop → 6. upload to server (debug-audio/)");
  Serial.printf("  (buffer max ~%u sec)\n", maxSec);
  Serial.flush();

  while (true) {
    if (s_phase == LoopbackPhase::Playing) {
      vTaskDelay(pdMS_TO_TICKS(20));
      continue;
    }

    if (s_touchTap) {
      if (s_phase == LoopbackPhase::Idle) {
#if MIC_UPLOAD_TO_SERVER
        if (!micServerUploadIsReady()) {
          Serial.println("[MIC] wait for [WS] session ready before recording");
        } else
#endif
        {
          s_touchTap = false;
          s_recordLen = 0;
          s_recordBufferFull = false;
          counters = {};
          intervalStats.reset();
          readUsStats.reset();
          writeUsStats.reset();
          rmsMin = INT32_MAX;
          rmsMax = 0;
          rmsSum = 0;
          peakMax = 0;
          clipSum = 0;
          haveSessionStats = false;
          lastFrameUs = micros();
          s_phase = LoopbackPhase::Recording;
          audioIoPrimeMic();
          loopbackConfirmBeep();
          Serial.println("[MIC] (1) tap");
          Serial.println("[MIC] (2) listening — speak now");
        }
      } else if (s_phase == LoopbackPhase::Recording) {
        s_touchTap = false;
        const float sec = static_cast<float>(s_recordLen) /
                          static_cast<float>(COMPANION_UPLINK_SAMPLE_RATE * 2);
        Serial.println("[MIC] (4) tap");
        Serial.printf("[MIC] (5) mic stopped — %.1f sec captured\n", sec);
        finishRecordingSession(counters, intervalStats, readUsStats,
                               writeUsStats, rmsMin, rmsMax, rmsSum, peakMax,
                               clipSum, haveSessionStats);
        counters = {};
        intervalStats.reset();
        readUsStats.reset();
        writeUsStats.reset();
        rmsMin = INT32_MAX;
        rmsMax = 0;
        rmsSum = 0;
        peakMax = 0;
        clipSum = 0;
        haveSessionStats = false;
      }
    }

    if (s_phase != LoopbackPhase::Recording) {
      vTaskDelay(pdMS_TO_TICKS(20));
      continue;
    }

    uint32_t readStartUs = micros();
    size_t nbytes = audioIoReadUplinkFrame(micBuf, sizeof(micBuf));
    uint32_t readElapsedUs = micros() - readStartUs;

    if (nbytes < sizeof(int16_t)) {
      counters.idleLoops++;
      vTaskDelay(pdMS_TO_TICKS(5));
      continue;
    }

    uint32_t nowUs = micros();
    float frameIntervalMs = static_cast<float>(nowUs - lastFrameUs) / 1000.0f;
    lastFrameUs = nowUs;

    size_t sampleCount = nbytes / sizeof(int16_t);
    const int16_t *samples = reinterpret_cast<int16_t *>(micBuf);
    PcmStats pcm = analyzePcm(samples, sampleCount);

    if (s_recordLen + nbytes <= s_recordBufCap) {
      memcpy(s_recordBuf + s_recordLen, micBuf, nbytes);
      s_recordLen += nbytes;
    } else if (!s_recordBufferFull) {
      s_recordBufferFull = true;
      const float sec = static_cast<float>(s_recordLen) /
                        static_cast<float>(COMPANION_UPLINK_SAMPLE_RATE * 2);
      Serial.printf(
          "[MIC LOOPBACK] buffer full at ~%.1f sec — tap to stop & play\n",
          sec);
    }

    if ((counters.frames % 17) == 0 && counters.frames > 0) {
      const float sec = static_cast<float>(s_recordLen) /
                        static_cast<float>(COMPANION_UPLINK_SAMPLE_RATE * 2);
      Serial.printf("[MIC] (3) recording... %.1f sec peak=%ld rms=%ld\n", sec,
                    static_cast<long>(pcm.peak), static_cast<long>(pcm.rms));
    }

    counters.frames++;
    if (nbytes != expectedBytes) {
      counters.shortReads++;
    }
    intervalStats.add(frameIntervalMs);
    readUsStats.add(static_cast<float>(readElapsedUs));

    if (pcm.rms < rmsMin) {
      rmsMin = pcm.rms;
    }
    if (pcm.rms > rmsMax) {
      rmsMax = pcm.rms;
    }
    rmsSum += pcm.rms;
    if (pcm.peak > peakMax) {
      peakMax = pcm.peak;
    }
    clipSum += pcm.clip;
    haveSessionStats = true;
  }
}

#else

static void micLoopbackTask(void *arg) {
  (void)arg;
  static uint8_t micBuf[COMPANION_UPLINK_FRAME_BYTES];
  uint32_t frames = 0;

  Serial.println("[MIC LOOPBACK] running — speak into the mic");
  while (true) {
    size_t nbytes = audioIoReadUplinkFrame(micBuf, sizeof(micBuf));
    if (nbytes >= sizeof(int16_t)) {
      size_t sampleCount = nbytes / sizeof(int16_t);
      audioIoWriteDownlink(reinterpret_cast<int16_t *>(micBuf), sampleCount);
      frames++;
      if ((frames % 50) == 0) {
        Serial.printf("[MIC LOOPBACK] %lu frames (%u samples/frame)\n",
                      static_cast<unsigned long>(frames),
                      static_cast<unsigned>(sampleCount));
      }
    } else {
      vTaskDelay(pdMS_TO_TICKS(5));
    }
  }
}

#endif

void audioIoLogLoopbackConfig() {
#if MIC_LOOPBACK_TEST_MODE
  Serial.printf("mode: mic loopback diagnostics @ %u baud\n",
                static_cast<unsigned>(MIC_LOOPBACK_SERIAL_BAUD));
  Serial.printf("  uplink_rate=%d Hz frame_ms=%d frame_bytes=%d\n",
                COMPANION_UPLINK_SAMPLE_RATE, COMPANION_FRAME_MS,
                COMPANION_UPLINK_FRAME_BYTES);
  Serial.printf("  mic_gpio bclk=%d ws=%d din=%d shift=%d\n", PIN_MIC_BCLK,
                PIN_MIC_WS, PIN_MIC_DIN, MIC_DATA_SHIFT);
  Serial.printf("  spk_gpio bclk=%d ws=%d dout=%d\n", PIN_SPK_BCLK, PIN_SPK_WS,
                PIN_SPK_DOUT);
  Serial.printf("  monitor_gain=%d log_every_frame=%d\n",
                MIC_LOOPBACK_MONITOR_GAIN, MIC_LOOPBACK_LOG_EVERY_FRAME);
  Serial.printf("  button_gpio=%d touch_mode=%d\n", PIN_BUTTON,
                USE_TOUCH_BUTTON);
  Serial.printf("  free_heap=%u bytes\n",
                static_cast<unsigned>(ESP.getFreeHeap()));
#endif
}

bool audioIoLoopbackAllocBuffer() {
#if MIC_LOOPBACK_TEST_MODE
  return loopbackInitRecordBuffer();
#else
  return true;
#endif
}

void audioIoMicLoopbackBegin() {
#if HAS_MIC && HAS_SPEAKER
#if MIC_LOOPBACK_TEST_MODE
  if (s_recordBuf == nullptr) {
    Serial.println(
        "[MIC LOOPBACK] ERROR: call audioIoLoopbackAllocBuffer() first");
    return;
  }
  buttonInit(onLoopbackButton, NULL);
#endif
  xTaskCreate(micLoopbackTask, "mic_loopback", 12288, NULL, 10, NULL);
#else
  Serial.println("[MIC LOOPBACK] requires HAS_MIC=1 and HAS_SPEAKER=1");
#endif
}
