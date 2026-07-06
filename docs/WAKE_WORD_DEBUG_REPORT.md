# Wake Word Debug Report — ESP32-S3 + Edge Impulse

**Date:** 2026-07-04  
**Goal:** Get on-device wake phrase **"hey botchill"** working on `CompanionFirmware` without breaking the existing voice uplink path (already good for server STT).  
**Model:** Edge Impulse library `adjiemuliadi-project-1_inferencing` v1.0.3  
**Labels:** `hey_botchill`, `noise`, `unknown`  
**Status:** Firmware stable (no crash on current build); wake word **not reliably usable** due to slow inference (~3.4 s/classify) and low scores on real mic.

---

## Hardware & Arduino setup

| Item | Value |
|------|--------|
| Board | ESP32-S3 (Arduino: **ESP32S3 Dev Module**) |
| PSRAM | **QSPI PSRAM** required (~2 MB detected in logs) |
| Partition | **Huge APP (3MB No OTA/1MB SPIFFS)** — sketch ~1.7 MB with EI lib |
| Mic | INMP441 — BCLK 12, WS 4, DIN 13, L/R → GND |
| Speaker | MAX98357A — BCLK 6, WS 7, DOUT 5 |
| Sample rate | 16 kHz mono (same path for uplink + wake word) |
| `MIC_DATA_SHIFT` | **14** (voice uplink tuned for server STT; wake uses same PCM) |

Edge Impulse Studio target **ESP-EYE** is fine for training estimates only; deployed firmware uses the user's actual GPIO pins above.

---

## Model parameters (from `model_metadata.h`)

| Parameter | Value |
|-----------|--------|
| `EI_CLASSIFIER_FREQUENCY` | 16000 Hz |
| `EI_CLASSIFIER_RAW_SAMPLE_COUNT` | 16000 (1 s window) |
| `EI_CLASSIFIER_SLICES_PER_MODEL_WINDOW` | 4 (default) |
| `EI_CLASSIFIER_SLICE_SIZE` | 4000 samples (250 ms per slice) |
| `EI_CLASSIFIER_THRESHOLD` (Studio) | 0.6 |
| `EI_CLASSIFIER_TFLITE_LARGEST_ARENA_SIZE` | ~162 KB |
| Firmware threshold | **0.30** (`WAKE_WORD_THRESHOLD` in `config.h`) |

---

## Crashes fixed early in session

### 1. `EI_MAX_OVERFLOW_BUFFER_COUNT` / `StoreProhibited`

**Symptom:**
```
ERR: Failed to allocate persistent buffer of size 576, does not fit in tensor arena
     and reached EI_MAX_OVERFLOW_BUFFER_COUNT
Guru Meditation Error: Core 1 panic'ed (StoreProhibited)
```

**Cause:** ESP32-S3 **ESP-NN** optimized Conv/DepthwiseConv kernels need scratch outside the EON-compiled tensor arena. Arena size does not budget for it.

**Fix (required, permanent):** `firmware/CompanionFirmware/build_opt.h`:
```
-DEI_CLASSIFIER_TFLITE_ENABLE_ESP_NN=0
```
Reference: [Edge Impulse forum #14712](https://forum.edgeimpulse.com/t/esp32-s3-cam-failed-to-allocate-persistent-buffer-of-size-576-does-not-fit-in-tensor-arena-and-reached-ei-max-overflow-buffer-count/14712)

**Note:** Re-enabling ESP-NN (`=1`) was tried again later and **reproduced the same crash deterministically** on first inference. ESP-NN must stay off for this model + board.

### 2. PSRAM allocation for classifier scratch

**Symptom:** `EI_IMPULSE_ALLOC_FAILED` / `-1002` / `EIDSP_OUT_OF_MEM` without PSRAM.

**Fix:** Override `ei_malloc` / `ei_calloc` / `ei_free` in `wake_word.cpp` to prefer **PSRAM**, 16-byte aligned (`heap_caps_aligned_alloc`). Tools → PSRAM → **QSPI PSRAM** must be enabled.

### 3. Uplink queue release while send task blocked

**Symptom:** Crash when releasing uplink queue while `uplinkSendTask` was blocked on network I/O.

**Fix:** Queue kept allocated; only drained, not released mid-session (`ws_session.cpp`).

---

## Wake word behavior (scores & detection)

### Typical serial output (ESP-NN off, async build)

```
[WAKE] Predictions (DSP: 22 ms., Classification: 3462 ms.):
    hey_botchill: 0.020
    noise: 0.879
    unknown: 0.102
```

- **`noise` dominates** (0.7–0.95) in most idle windows.
- **`hey_botchill`** usually **0.01–0.17** when speaking; threshold 0.30 rarely met.
- **One successful trigger** was observed early in session (~0.6+ score) after long idle (~18 s) with clean MFCC window; after TTS + mic restart, scores dropped again.

### I2S startup garbage

**Symptom:** `audio: mic primed (peak=25532)` or `peak=10024` — far above normal speech levels.

**Impact:** Poisons the continuous classifier's sliding MFCC window if fed before settling.

**Mitigations tried:**
- `audioIoPrimeMic()` — discard loops until peak &lt; 4000 (up to 8 rounds)
- `wakeWordOnMicPrimed()` — `run_classifier_init()` after prime
- Post-TTS delays / skip-ms (later removed when reverting to example-style code)
- Boot-time mic warmup (later removed)

Peak often improved to **~1000–3000** after aggressive prime, but scores stayed low on real utterances.

---

## Approaches tried (chronological)

| # | Approach | Result |
|---|----------|--------|
| 1 | Verbose 2 s diagnostic logs (peak/RMS/all scores) | Noisy; showed "always noise" but didn't isolate root cause |
| 2 | Separate wake gain/shift (`prepWakeSample`, `kWakeExtraShift`) | **Worse** scores; user asked to keep uplink path unchanged |
| 3 | Global `MIC_DATA_SHIFT` 12/13 + soft-clip | Broke voice path; reverted |
| 4 | `EI_MAX_OVERFLOW_BUFFER_COUNT=50` in build opts alone | Ineffective without ESP-NN fix |
| 5 | Pure Edge Impulse example port (`inference_t`, `buf_ready`, sync classify) | Correct structure; **buffer overrun** when NN &gt; 250 ms |
| 6 | `EI_CLASSIFIER_SLICES_PER_MODEL_WINDOW=2` (500 ms budget) | Still overrun with ~3.4 s NN |
| 7 | ESP-NN re-enabled | **Crash** (same overflow buffer error) |
| 8 | Async inference task (first attempt) | **Crash** — overwrote buffer classifier was still reading |
| 9 | Async + snapshot copy + drop-if-busy + ESP-NN off | **Stable**; ~3.4 s per classify, most slices dropped |

---

## Architecture evolution (current)

```
captureTask (ws_session.cpp)
    │
    ├─ audioIoReadUplinkFrame()  ──► voice uplink queue (when CAPTURING)
    │
    └─ wakeWordFeed()  ──► audioInferenceCallback()
                              ping-pong buffers[2] (EI slice size)
                              when slice full:
                                  if classify task busy → drop slice (log)
                                  else memcpy → classifyBuf, signal wake_word task

wake_word task (core 1, 32 KB stack)
    │
    └─ run_classifier_continuous() on classifyBuf snapshot
       print Predictions every run
       trigger if hey_botchill ≥ 0.30 (3 s cooldown)
```

**Deliberate deviation from Edge Impulse `esp32_microphone_continuous.ino`:** classification runs on a **separate FreeRTOS task** with a **snapshot buffer**, because synchronous `loop()`-style classify cannot finish within one slice period on this hardware (NN ~3.4 s with ESP-NN disabled).

**Voice uplink unchanged:** Same 16 kHz PCM, `MIC_DATA_SHIFT=14`, same I2S mic path. Wake word only runs in `SESSION_IDLE` when `s_sessionReady`.

---

## Key files (as of report)

| File | Role |
|------|------|
| `firmware/CompanionFirmware/wake_word.cpp` | EI continuous audio, PSRAM alloc overrides, async classify task |
| `firmware/CompanionFirmware/wake_word.h` | `wakeWordInit`, `wakeWordOnMicPrimed`, `wakeWordFeed`, `wakeWordTakeTrigger` |
| `firmware/CompanionFirmware/build_opt.h` | `ESP_NN=0` (mandatory) |
| `firmware/CompanionFirmware/config.h` | `WAKE_WORD_LABEL`, `WAKE_WORD_THRESHOLD` (0.30) |
| `firmware/CompanionFirmware/audio_io.cpp` | I2S mic/speaker; `audioIoPrimeMic()` |
| `firmware/CompanionFirmware/ws_session.cpp` | Feeds wake word in idle; mic stop during TTS |
| `firmware/CompanionFirmware/CompanionFirmware.ino` | `wakeWordInit()` in setup |

---

## Timing constraints (why wake word feels broken)

| Config | Slice period | NN time (observed) | Outcome |
|--------|--------------|-------------------|---------|
| ESP-NN **on** | 250 ms | N/A (crashes) | `StoreProhibited` |
| ESP-NN **off**, sync example | 250 ms | ~3462 ms | Buffer overrun spam |
| ESP-NN **off**, slices=2 | 500 ms | ~3462 ms | Still overrun |
| ESP-NN **off**, async + drop | 250 ms fill | ~3462 ms classify | Stable; **~1 classify / 3.5 s**, most slices dropped |

Edge Impulse continuous audio assumes inference keeps up with real-time slices. This model on ESP32-S3 without ESP-NN **does not**.

---

## User mistakes noted

- Flashed Edge Impulse demo **`esp32_microphone_continuous.ino`** instead of **`CompanionFirmware.ino`** (wrong pins, "Edge Impulse Inferencing Demo" banner).
- Said **"hey bochil"** vs trained label **`hey_botchill`** — pronunciation matters for keyword spotting.
- Spoke immediately on `>>> READY` before mic/classifier was actually listening (2–3 s gap before first slice in some builds).

---

## Bench tools in repo

| Tool | Purpose |
|------|---------|
| `firmware/TestFirmware` + `MIC_LOOPBACK_TEST_MODE=1` | Hear yourself on speaker; verify INMP441 wiring (no server) |
| `hey_bochil_te3st.m4a` / `.wav` in repo root | Test clip for Edge Impulse Live Classification |
| `CompanionServer/debug-audio/*-uplink.wav` | Server-side uplink captures for STT quality |

---

## Recommendations (priority order)

### 1. Edge Impulse Studio — model fit for ESP32

- Run **Live classification** on device-recorded WAV (INMP441, same room).
- If Studio scores are high but device scores low → **training data mismatch** (re-record with this mic).
- If Studio scores also low → retrain with more **hey botchill** samples.
- Consider **smaller model** (fewer MFCC filters / smaller NN) for ESP32 latency targets.
- In Deployment, try increasing **tensor arena** if ESP-NN is ever required (may not fix EON overflow alone).

### 2. Do not re-enable ESP-NN without Studio/arena changes

Confirmed crash twice with identical error. `build_opt.h` must keep `EI_CLASSIFIER_TFLITE_ENABLE_ESP_NN=0` until the exported model supports ESP32-S3 optimized kernels.

### 3. Accept async + slow classify is a stopgap only

Current firmware avoids crashes but wake latency is poor (~3.5 s between useful classifications). Not a product-ready wake word experience.

### 4. Alternative product paths

- **Tap-to-talk only** (already works) until model is retrained/faster.
- **Server-side wake word** on uplink stream (higher latency, no on-device NN).
- Different wake engine (e.g. Porcupine, custom smaller model) if Edge Impulse export cannot meet &lt;300 ms inference on S3.

---

## Flash checklist

1. Sketch: **`firmware/CompanionFirmware/CompanionFirmware.ino`**
2. Board: **ESP32S3 Dev Module**
3. PSRAM: **QSPI PSRAM**
4. Partition: **Huge APP (3MB)**
5. Library: **`adjiemuliadi-project-1_inferencing`** (Arduino Libraries)
6. Serial: **115200**
7. Wait for **`[WAKE] Predictions`** lines; say **"hey botchill"** clearly and repeatedly if testing slow async build.

---

## Git note

Firmware changes from this debug session were **not committed** as of this report. See `git status` for modified files under `firmware/CompanionFirmware/`.
