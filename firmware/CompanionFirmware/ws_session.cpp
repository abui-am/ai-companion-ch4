#include "ws_session.h"

#include <Arduino.h>
#include <WebSocketsClient.h>
#include <WiFi.h>
#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/semphr.h>
#include <freertos/task.h>

#include "audio_io.h"
#include "button.h"
#include "config.h"
#include "face_display.h"
#include "motor_drive.h"
#include "pcm_codec.h"
#include "protocol.h"

enum SessionState {
  SESSION_IDLE,
  SESSION_CAPTURING,
  SESSION_PROCESSING,
  SESSION_SPEAKING,
};

struct PlaybackChunk {
  size_t len;
  uint8_t data[COMPANION_DOWNLINK_FRAME_BYTES];
};

// Uplink capture chunk. len == 0 is a sentinel meaning "capture ended, flush
// and send audio.stop" — lets uplinkSendTask know when to close out a turn
// without needing a second cross-task signal.
struct CaptureChunk {
  size_t len;
  uint8_t data[COMPANION_UPLINK_FRAME_BYTES];
};

static constexpr UBaseType_t kPlaybackQueueDepth = 12;
static constexpr UBaseType_t kInitialPrefillFrames = 4;
static constexpr UBaseType_t kMaxPrefillFrames = 12;
static constexpr int kDownlinkEnqueueMs = 100;
static constexpr int kQueueWaitMs = 120;
static constexpr int kStarvationFramesBeforeRebuffer = 8;
static constexpr int kDownlinkFrameMs = COMPANION_FRAME_MS;

// MARK: - Uplink queue sizing (see analysis in docs / session notes)
//
// Mic produces fixed-rate frames; the queue absorbs WiFi/TCP backpressure only.
// It does NOT need to hold an entire recording if the sender keeps pace.
//
//   frame_ms        = 60
//   frame_rate      = 1000/60 ≈ 16.7 frames/s
//   frame_bytes     = 1920 (960 × int16 @ 16 kHz)
//   chunk_bytes     = sizeof(CaptureChunk) ≈ 1924
//
// I2S DMA ring (mic): dma_buf_count=8, dma_buf_len=512 @ 32-bit → ~256 ms.
// captureTask must never block longer than that on network I/O (drop-oldest).
//
// Observed uplink durations (server debug WAVs, n≈40):
//   p50 ≈ 2.6 s (43 frames)   p90 ≈ 8.2 s (136 frames)   max ≈ 19 s (316
//   frames)
//
// Queue depth should cover worst-case recording (316) plus TCP stall budget
// (~84 frames @ 5 s) when the sender blocks — cap below available PSRAM.
//
// Observed stall (queue=24, 115 captured / 86 sent / 29 dropped):
//   sender averaged ~75% of capture rate → backlog ≈ 29 frames minimum depth.
//
// Worst-case single send stall: WEBSOCKETS_TCP_TIMEOUT ≈ 5 s → 5000/60 ≈ 84
// frames. Target depth = stall_budget + margin for logging; alloc tries max first.
//
// No wake-word classifier anymore, so there's no internal-RAM DSP scratch to
// protect — the queue can use PSRAM (lazy alloc at first capture).
static constexpr int kUplinkFrameMs = COMPANION_FRAME_MS;
static constexpr int kUplinkTcpStallMs = 5000;
static constexpr int kUplinkQueueStallMarginFrames = 12;
static constexpr int kUplinkQueueTargetDepth =
    (kUplinkTcpStallMs / kUplinkFrameMs) + kUplinkQueueStallMarginFrames; // 96
static constexpr int kUplinkQueueMaxDepth = 512; // ~30.7 s @ zero send (~985 KB)
static constexpr int kUplinkQueueMinDepth =
    16; // ~1 s; used when memory is tight

static constexpr int kUplinkSendBatchMax = 4;
static constexpr int kUplinkQueueSendWaitMs = 45;
static constexpr int kUplinkDropLogInterval = 10;

static UBaseType_t s_prefillTarget = kInitialPrefillFrames;

static WebSocketsClient s_webSocket;
static SemaphoreHandle_t s_stateMutex = nullptr;
static SessionState s_state = SESSION_IDLE;
static String s_sessionId;
static volatile bool s_sessionReady = false;
static volatile bool s_playbackNeedPrefill = true;
static volatile bool s_pendingListenAfterReconnect = false;

// Trigger label for the active capture turn (tap, auto-relisten, etc.).
// captureTask runs audio.start + beep on CAPTURING entry once mic I2S is live.

// Recursive: flushWebSocket() holds this across s_webSocket.loop(), which can
// synchronously invoke webSocketEvent() (e.g. on CONNECTED/TEXT) — and that
// handler calls sendText()/handleBinaryFrame() from the *same* task/call
// stack. A plain mutex would self-deadlock there; recursive lets the same
// task re-enter. This also now serializes .loop() itself, which used to run
// concurrently from wsSessionLoop() (main loop task) and uplinkSendTask —
// WebSocketsClient isn't safe to touch from two tasks at once, and that race
// was corrupting/dropping outgoing binary frames mid-recording.
static SemaphoreHandle_t s_wsSendMutex = nullptr;
static QueueHandle_t s_playbackQueue = nullptr;
static QueueHandle_t s_uplinkQueue = nullptr;
static StaticQueue_t *s_uplinkQueueStruct = nullptr;
static uint8_t *s_uplinkQueueStorage = nullptr;
static UBaseType_t s_uplinkQueueDepth = 0;
static int s_turnCaptured = 0;
static int s_turnDropped = 0;
static volatile bool s_wsLoopTaskActive = false;
static TaskHandle_t s_wsLoopHandle = nullptr;

static SessionState getState() {
  xSemaphoreTake(s_stateMutex, portMAX_DELAY);
  SessionState s = s_state;
  xSemaphoreGive(s_stateMutex);
  return s;
}

static void syncFaceDisplay(SessionState s) {
  switch (s) {
  case SESSION_IDLE:
    faceDisplaySetMode(FACE_IDLE);
    faceDisplaySetStatusLine("Tap to talk");
    break;
  case SESSION_CAPTURING:
    faceDisplaySetMode(FACE_LISTENING);
    faceDisplaySetStatusLine("Listening...");
    break;
  case SESSION_PROCESSING:
    faceDisplaySetMode(FACE_THINKING);
    faceDisplaySetStatusLine("Thinking...");
    break;
  case SESSION_SPEAKING:
    faceDisplaySetMode(FACE_SPEAKING);
    faceDisplaySetStatusLine("Speaking...");
    break;
  }
}

static void setState(SessionState s) {
  SessionState previous;
  xSemaphoreTake(s_stateMutex, portMAX_DELAY);
  previous = s_state;
  s_state = s;
  xSemaphoreGive(s_stateMutex);
  syncFaceDisplay(s);
  if (s == SESSION_CAPTURING && previous != SESSION_CAPTURING) {
    motorStop();
    Serial.println("[MOTOR] stopped — mic listening");
  }
}

static void drainPlaybackQueue() {
  if (s_playbackQueue == nullptr) {
    return;
  }
  PlaybackChunk chunk;
  while (xQueueReceive(s_playbackQueue, &chunk, 0) == pdTRUE) {
  }
  s_playbackNeedPrefill = true;
}

static void drainUplinkQueue() {
  if (s_uplinkQueue == nullptr) {
    return;
  }
  CaptureChunk chunk;
  while (xQueueReceive(s_uplinkQueue, &chunk, 0) == pdTRUE) {
  }
}

static bool createUplinkQueueAtDepth(UBaseType_t depth, bool preferPsram) {
  const size_t storageBytes = static_cast<size_t>(depth) * sizeof(CaptureChunk);

  uint8_t *storage = static_cast<uint8_t *>(heap_caps_malloc(
      storageBytes, preferPsram ? (MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT)
                                : (MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT)));
  if (storage == nullptr) {
    return false;
  }

  StaticQueue_t *qstruct = static_cast<StaticQueue_t *>(heap_caps_malloc(
      sizeof(StaticQueue_t), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
  if (qstruct == nullptr) {
    heap_caps_free(storage);
    return false;
  }

  QueueHandle_t q =
      xQueueCreateStatic(depth, sizeof(CaptureChunk), storage, qstruct);
  if (q == nullptr) {
    heap_caps_free(storage);
    heap_caps_free(qstruct);
    return false;
  }

  s_uplinkQueue = q;
  s_uplinkQueueStorage = storage;
  s_uplinkQueueStruct = qstruct;
  s_uplinkQueueDepth = depth;
  Serial.printf("[AUDIO] uplink queue ok depth=%u (~%u ms, %u bytes, %s)\n",
                static_cast<unsigned>(depth),
                static_cast<unsigned>(depth * COMPANION_FRAME_MS),
                static_cast<unsigned>(storageBytes),
                esp_ptr_external_ram(storage) ? "PSRAM" : "internal");
  return true;
}

static bool createUplinkQueue() {
  const size_t chunkBytes = sizeof(CaptureChunk);
  const size_t psramBlock =
      heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  const size_t internalBlock =
      heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);

  int depthByPsram = psramBlock > chunkBytes
                         ? static_cast<int>((psramBlock * 9 / 10) / chunkBytes)
                         : 0;
  int depthByInternal =
      internalBlock > chunkBytes
          ? static_cast<int>((internalBlock * 9 / 10) / chunkBytes)
          : 0;

  int tryMax = kUplinkQueueMaxDepth;
  if (depthByPsram > 0 && depthByPsram < tryMax) {
    tryMax = depthByPsram;
  } else if (depthByPsram == 0 && depthByInternal > 0 &&
             depthByInternal < tryMax) {
    tryMax = depthByInternal;
  }

  Serial.printf("[AUDIO] uplink queue sizing: target=%d max=%d min=%d chunk=%u "
                "psram=%u internal=%u heap=%u\n",
                kUplinkQueueTargetDepth, tryMax, kUplinkQueueMinDepth,
                static_cast<unsigned>(chunkBytes),
                static_cast<unsigned>(psramBlock),
                static_cast<unsigned>(internalBlock),
                static_cast<unsigned>(ESP.getFreeHeap()));

  for (int depth = tryMax; depth >= kUplinkQueueMinDepth; depth -= 8) {
    if (createUplinkQueueAtDepth(static_cast<UBaseType_t>(depth), true)) {
      return true;
    }
    if (createUplinkQueueAtDepth(static_cast<UBaseType_t>(depth), false)) {
      return true;
    }
    Serial.printf(
        "[AUDIO] uplink queue alloc failed depth=%d (need %u bytes)\n", depth,
        static_cast<unsigned>(depth * chunkBytes));
  }

  Serial.println("[AUDIO] FATAL: uplink queue unavailable — mic will send "
                 "inline (degraded)");
  return false;
}

// Uplink queue is sized off free heap at first-capture time; allocate lazily
// rather than at boot so it can claim whatever RAM is actually available.
static void ensureUplinkQueue() {
  if (s_uplinkQueue != nullptr) {
    return;
  }
  Serial.printf("[AUDIO] lazy uplink queue alloc heap=%u psram=%u\n",
                static_cast<unsigned>(ESP.getFreeHeap()),
                static_cast<unsigned>(ESP.getFreePsram()));
  if (!createUplinkQueue()) {
    Serial.println(
        "[MIC] uplink queue unavailable — inline send for this turn");
  }
}

static void sendText(const String &text) {
  xSemaphoreTakeRecursive(s_wsSendMutex, portMAX_DELAY);
  if (s_webSocket.isConnected()) {
    String copy = text;
    s_webSocket.sendTXT(copy);
  } else {
    Serial.printf("[WS] send dropped (not connected): %.72s\n", text.c_str());
  }
  xSemaphoreGiveRecursive(s_wsSendMutex);
}

static void requestWsPump();

static void sendTextAndFlush(const String &text) {
  xSemaphoreTakeRecursive(s_wsSendMutex, portMAX_DELAY);
  if (s_webSocket.isConnected()) {
    String copy = text;
    s_webSocket.sendTXT(copy);
  } else {
    Serial.printf("[WS] send dropped (not connected): %.72s\n", text.c_str());
  }
  xSemaphoreGiveRecursive(s_wsSendMutex);
  requestWsPump();
}

// Send one uplink PCM frame. Do not call loop() here — inbound events (tts.start,
// downlink PCM) must be handled only on ws_loop or binary frames are dropped
// while state is still PROCESSING.
static int sendUplinkFrame(const uint8_t *data, size_t len) {
  if (len == 0) {
    return 0;
  }
  xSemaphoreTakeRecursive(s_wsSendMutex, portMAX_DELAY);
  int sent = 0;
  if (s_webSocket.isConnected()) {
    s_webSocket.sendBIN(data, len);
    sent = 1;
  }
  xSemaphoreGiveRecursive(s_wsSendMutex);
  if (sent) {
    requestWsPump();
  }
  return sent;
}

static int sendBinaryBatch(const CaptureChunk *chunks, int count) {
  if (count <= 0) {
    return 0;
  }
  int sent = 0;
  for (int i = 0; i < count; i++) {
    if (chunks[i].len == 0) {
      break;
    }
    sent += sendUplinkFrame(chunks[i].data, chunks[i].len);
  }
  return sent;
}

static void flushWebSocket() {
  // Recursive mutex: safe even though loop() can re-enter sendText/
  // sendBinary synchronously via webSocketEvent() on the same task.
  xSemaphoreTakeRecursive(s_wsSendMutex, portMAX_DELAY);
  s_webSocket.loop();
  xSemaphoreGiveRecursive(s_wsSendMutex);
}

static void requestWsPump() {
  if (s_wsLoopTaskActive && s_wsLoopHandle != nullptr) {
    xTaskNotifyGive(s_wsLoopHandle);
    return;
  }
  flushWebSocket();
}

static void pumpWebSocketRepeated(int count, int delayMs) {
  for (int i = 0; i < count; i++) {
    requestWsPump();
    vTaskDelay(pdMS_TO_TICKS(delayMs));
  }
}

static bool wsCanTalk() {
  return WiFi.status() == WL_CONNECTED && s_webSocket.isConnected() &&
         s_sessionReady;
}

static void wsRequestReconnect(const char *reason) {
  Serial.printf(
      "[WS] reconnect requested (%s) wifi=%d ws=%d ready=%d pending_listen=%d\n",
      reason, static_cast<int>(WiFi.status()),
      static_cast<int>(s_webSocket.isConnected()),
      static_cast<int>(s_sessionReady),
      static_cast<int>(s_pendingListenAfterReconnect));

  s_sessionReady = false;
  drainPlaybackQueue();
  drainUplinkQueue();
  audioIoSpeakerMute();
  setState(SESSION_IDLE);
  faceDisplaySetMode(FACE_CONNECTING);
  faceDisplaySetStatusLine("Reconnecting...");

  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[WS] WiFi down — reconnecting WiFi");
    WiFi.reconnect();
  }

  xSemaphoreTakeRecursive(s_wsSendMutex, portMAX_DELAY);
  if (s_webSocket.isConnected()) {
    s_webSocket.disconnect();
  } else {
#if COMPANION_USE_TLS
    s_webSocket.beginSSL(COMPANION_SERVER_HOST, COMPANION_SERVER_PORT,
                         COMPANION_SERVER_PATH);
#else
    s_webSocket.begin(COMPANION_SERVER_HOST, COMPANION_SERVER_PORT,
                      COMPANION_SERVER_PATH);
#endif
  }
  xSemaphoreGiveRecursive(s_wsSendMutex);
  requestWsPump();
}

static void startListening(const char *trigger);

// Service the Links2004 WebSocket client on the WiFi core. The upgrade handshake
// and session.ready must be read within WEBSOCKETS_TCP_TIMEOUT (5 s default);
// relying on Arduino loop() alone was letting capture/I2C starve loop() long
// enough that the client disconnected before WStype_CONNECTED fired.
static void wsMaintenanceTask(void *arg) {
  (void)arg;
  while (true) {
    flushWebSocket();
    // Wake promptly after uplink/control sends via requestWsPump().
    (void)ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(5));
  }
}

// MARK: - Seamless turn-taking, bookended by taps
//
// STABLE (2026-07-06) — tap + adaptive noisy-room VAD. Constants below are
// canonical; update docs/STABLE_V1.md § Client VAD if you change them.
//
// One tap starts a conversation; from then on it runs hands-free — talk,
// pause, the AI answers, talk again — until a long press ends it (or, as a
// safety net, the user never says anything at all). Short tap during capture
// forces end-of-turn when noisy-room VAD is stuck. No wake word.
//
//   short tap -> talk -> silence ~1s -> AI answers -> ... (or short tap if
//   VAD stuck) -> long press (ends conversation any time)
static constexpr uint32_t kEndOfSpeechSilenceMs =
    1000; // pause after speech -> send turn to AI
static constexpr uint32_t kNoSpeechTimeoutMs =
    4000; // never spoke at all -> give up, end conversation

// A fixed amplitude threshold gets fooled by room noise (fans/AC/etc. — see
// docs/WAKE_WORD_DEBUG_REPORT.md, the "noise" label dominated 0.7-0.95 of
// the old wake-word classifier's output for the same reason). Instead track
// a slow-moving noise floor from frames that *aren't* speech, and require
// several consecutive speech-like frames above floor+onset margin before
// latching voice. Hysteresis (higher onset, lower offset) plus crest factor
// and zero-crossing rate reject steady HVAC noise that shares amplitude with
// speech but not its dynamics.
static constexpr float kNoiseFloorRiseAlpha =
    0.04f; // EMA smoothing when a non-voiced frame is *louder* than the floor
static constexpr uint32_t kNoiseFloorMin =
    80; // clamp so a silent room doesn't zero the margin
static constexpr uint32_t kNoiseFloorMax =
    550; // cap runaway floor inflation in loud ambient rooms
static constexpr uint32_t kVoiceOnsetMargin =
    450; // filtered energy must clear floor + this to start speech
static constexpr uint32_t kVoiceOffsetMargin =
    150; // once latched, lower bar keeps soft trailing syllables alive
static constexpr uint32_t kVoiceOnsetMinFrames =
    3; // consecutive speech-like frames (~180ms @ 60ms frames)
static constexpr uint32_t kFloorSeedFrames =
    3; // minimum of this many frames for initial floor (floor also warms in IDLE)
static constexpr uint32_t kMinCrestX100 =
    220; // peak/mean >= 2.2 — speech is spikier than steady fan hum
static constexpr uint32_t kMinOffsetCrestX100 =
    140; // looser crest gate while latched — still rejects flat HVAC hum
static constexpr uint32_t kMinOffsetZcrX1000 =
    85; // offset path also needs speech-like crossings — rejects steady hiss
static constexpr uint32_t kMinZcrX1000 =
    55; // ~5.5% crossings — rejects low-frequency rumble

static bool vadFrameLooksLikeSpeech(const AudioFrameVadMetrics &metrics) {
  return metrics.crestX100 >= kMinCrestX100 &&
         metrics.zcrX1000 >= kMinZcrX1000;
}

static void vadTrackNoiseFloor(uint32_t frameEnergy, float &noiseFloor) {
  if (frameEnergy < static_cast<uint32_t>(noiseFloor)) {
    noiseFloor = static_cast<float>(frameEnergy);
  } else {
    noiseFloor +=
        (static_cast<float>(frameEnergy) - noiseFloor) * kNoiseFloorRiseAlpha;
  }
  if (noiseFloor < static_cast<float>(kNoiseFloorMin)) {
    noiseFloor = static_cast<float>(kNoiseFloorMin);
  }
  if (noiseFloor > static_cast<float>(kNoiseFloorMax)) {
    noiseFloor = static_cast<float>(kNoiseFloorMax);
  }
}

// Updates the adaptive noise floor and reports whether this frame counts as
// active voice for silence-timer purposes. `noiseFloor`/`seedCount`/
// `onsetStreak` persist across calls; pass `speechLatched=true` once the user
// has started speaking this turn so offset (not onset) thresholds apply.
static bool vadUpdate(const AudioFrameVadMetrics &metrics, float &noiseFloor,
                      uint32_t &seedCount, uint32_t &onsetStreak,
                      bool speechLatched) {
  const uint32_t energy = metrics.energy;

  if (seedCount < kFloorSeedFrames) {
    // Minimum, not average, while seeding — a single loud transient
    // right after mic prime/beep/button-tap can otherwise drag the
    // "floor" well above the real ambient level for many seconds
    // (observed: seeded at 1390 while actual ambient was ~150-300,
    // silently eating real speech under the inflated threshold).
    if (seedCount == 0 || energy < static_cast<uint32_t>(noiseFloor)) {
      noiseFloor = static_cast<float>(energy);
    }
    seedCount++;
    onsetStreak = 0;
    return false;
  }

  const uint32_t onsetThreshold =
      static_cast<uint32_t>(noiseFloor) + kVoiceOnsetMargin;
  const uint32_t offsetThreshold =
      static_cast<uint32_t>(noiseFloor) + kVoiceOffsetMargin;
  const bool meetsOnset = energy >= onsetThreshold &&
                          vadFrameLooksLikeSpeech(metrics);
  const bool meetsOffset = energy >= offsetThreshold &&
                           metrics.crestX100 >= kMinOffsetCrestX100 &&
                           metrics.zcrX1000 >= kMinOffsetZcrX1000;

  bool isVoiceFrame = false;
  if (speechLatched) {
    isVoiceFrame = meetsOffset;
    if (!isVoiceFrame) {
      vadTrackNoiseFloor(energy, noiseFloor);
    }
  } else if (meetsOnset) {
    onsetStreak++;
    isVoiceFrame = onsetStreak >= kVoiceOnsetMinFrames;
  } else {
    onsetStreak = 0;
    vadTrackNoiseFloor(energy, noiseFloor);
  }

  return isVoiceFrame;
}

// captureTask owns the full turn open sequence on CAPTURING entry: mic is
// already running/primed above, then audio.start, beep, then frame capture.
// The beep is the user's "start speaking" cue — it only fires after mic I2S
// is live, so there is no cross-task semaphore race.
static const char *s_captureTrigger = "capture";

static void beginCapture(const char *trigger) {
  if (!wsCanTalk()) {
    Serial.printf("[SESSION] %s but WS not ready — will listen after reconnect\n",
                  trigger);
    s_pendingListenAfterReconnect = true;
    wsRequestReconnect(trigger);
    return;
  }
  s_captureTrigger = trigger;
  setState(SESSION_CAPTURING);
}

static void startListening(const char *trigger) { beginCapture(trigger); }

static void kickoffCaptureAsync(const char *trigger) { beginCapture(trigger); }

// Ends the whole conversation right now: tells the server (so it cancels
// any in-flight response instead of being left waiting on a turn that's
// never coming — see cancelResponse()'s activeTurnResponseId guard on the
// server side), clears local audio state, and goes back to idle. Used both
// for a deliberate tap-to-end and for the no-speech safety timeout.
static void endConversation(const char *reason) {
  sendTextAndFlush(protocolBuildAbort(s_sessionId, reason));
  drainPlaybackQueue();
  drainUplinkQueue();
  audioIoSpeakerMute();
  setState(SESSION_IDLE);
  Serial.printf("[SESSION] end conversation (%s) → IDLE\n", reason);
}

static void finishCaptureSession(int frameCount, int droppedCount) {
  audioIoMicStop();
  Serial.printf("[MIC] capture stopped, captured %d frames from mic",
                frameCount);
  if (droppedCount > 0) {
    Serial.printf(" (%d dropped before send)\n", droppedCount);
  } else {
    Serial.println();
  }
  if (s_uplinkQueue != nullptr) {
    CaptureChunk endMarker = {};
    endMarker.len = 0;
    s_turnCaptured = frameCount;
    s_turnDropped = droppedCount;
    xQueueSend(s_uplinkQueue, &endMarker, portMAX_DELAY);
  } else if (getState() == SESSION_PROCESSING) {
    sendTextAndFlush(protocolBuildAudioStop());
    Serial.printf("[MIC] uplink inline: sent %d frames to server\n",
                  frameCount);
  }
}

// MARK: - Capture (uplink)
//
// Reading the mic and sending over the network used to happen in the same
// loop iteration (read → sendBIN → loop()). sendBIN() blocks the calling
// task for up to WEBSOCKETS_TCP_TIMEOUT (5 s) whenever the TCP write stalls,
// but the I2S DMA ring only holds ~256 ms of audio — any hiccup longer than
// that silently overwrites unread mic samples, which is heard as the
// recording being "cut off". captureTask now only talks to the mic and
// pushes frames onto a queue; uplinkSendTask (below) drains that queue and
// owns all the network I/O, so a slow/stalled socket write no longer blocks
// mic reads.
//
// No wake word: capture starts on a tap or automatically right after the AI
// finishes speaking (see PROTO_MSG_TTS_END). While capturing, this task also
// runs the adaptive noise-floor VAD (see vadUpdate() above) to decide when
// the turn is over — kEndOfSpeechSilenceMs / kNoSpeechTimeoutMs.

static void captureTask(void *arg) {
  (void)arg;
  static uint8_t frame[COMPANION_UPLINK_FRAME_BYTES];
  int frameCount = 0;
  int droppedCount = 0;
  SessionState lastState = SESSION_IDLE;
  bool micActive = false;
  uint32_t turnStartMs = 0;
  uint32_t lastVoiceMs = 0;
  bool heardVoiceThisTurn = false;
  // Adaptive VAD state — persists across IDLE/CAPTURING so the noise floor
  // keeps tracking the room even between turns; onsetStreak resets per turn.
  float noiseFloor = 0.0f;
  uint32_t noiseFloorSeedCount = 0;
  uint32_t onsetStreak = 0;
  uint32_t vadLogCounter = 0;

  while (true) {
    SessionState s = getState();

    if (lastState == SESSION_CAPTURING && s != SESSION_CAPTURING) {
      finishCaptureSession(frameCount, droppedCount);
      frameCount = 0;
      droppedCount = 0;
    }

    if (s == SESSION_PROCESSING || s == SESSION_SPEAKING) {
      if (micActive) {
        audioIoMicStop();
        micActive = false;
      }
      lastState = s;
      vTaskDelay(pdMS_TO_TICKS(20));
      continue;
    }

    if (!micActive) {
      audioIoMicStart();
      if (lastState == SESSION_PROCESSING || lastState == SESSION_SPEAKING) {
        audioIoPrimeMicAfterPause();
      } else {
        audioIoPrimeMic();
      }
      micActive = true;
    }

    if (s == SESSION_CAPTURING && lastState != SESSION_CAPTURING) {
      ensureUplinkQueue();
      drainUplinkQueue();
      frameCount = 0;
      droppedCount = 0;
      lastVoiceMs = 0;
      heardVoiceThisTurn = false;
      onsetStreak = 0;
      audioIoVadFilterReset();
      Serial.println("[MIC] capture session starting");
      Serial.printf("[MIC] queue=%p heap=%u\n", s_uplinkQueue,
                    static_cast<unsigned>(ESP.getFreeHeap()));
      sendTextAndFlush(protocolBuildAudioStart());
      audioIoSpeakerBeep();
      turnStartMs = millis();
      Serial.printf("%s: → CAPTURING (mic ON, beep done — speak now)\n",
                    s_captureTrigger);
    }

    lastState = s;

    size_t n = audioIoReadUplinkFrame(frame, sizeof(frame));
    if (n == 0) {
      continue;
    }

    switch (s) {
    case SESSION_IDLE: {
      // No turn in progress — just keep the noise floor adapted so
      // it's already warm when a turn actually starts.
      uint32_t idleStreak = 0;
      const AudioFrameVadMetrics idleMetrics =
          audioIoAnalyzeVadFrame(frame, n);
      vadUpdate(idleMetrics, noiseFloor, noiseFloorSeedCount, idleStreak,
                false);
      break;
    }
    case SESSION_CAPTURING: {
      if (n != COMPANION_UPLINK_FRAME_BYTES) {
        vTaskDelay(pdMS_TO_TICKS(5));
        break;
      }

      const AudioFrameVadMetrics metrics = audioIoAnalyzeVadFrame(frame, n);
      uint32_t nowMs = millis();
      if (vadUpdate(metrics, noiseFloor, noiseFloorSeedCount, onsetStreak,
                    heardVoiceThisTurn)) {
        lastVoiceMs = nowMs;
        heardVoiceThisTurn = true;
      }
      // ~1 line/sec so the threshold/margin can be tuned from serial
      // logs without drowning them.
      if ((vadLogCounter++ % 16) == 0) {
        const uint32_t onsetThr =
            static_cast<uint32_t>(noiseFloor) + kVoiceOnsetMargin;
        const uint32_t offsetThr =
            static_cast<uint32_t>(noiseFloor) + kVoiceOffsetMargin;
        Serial.printf(
            "[VAD] energy=%u peak=%u crest=%u zcr=%u floor=%d "
            "on=%u off=%u streak=%u voiced=%d\n",
            static_cast<unsigned>(metrics.energy),
            static_cast<unsigned>(metrics.peak),
            static_cast<unsigned>(metrics.crestX100),
            static_cast<unsigned>(metrics.zcrX1000),
            static_cast<int>(noiseFloor), static_cast<unsigned>(onsetThr),
            static_cast<unsigned>(offsetThr),
            static_cast<unsigned>(onsetStreak), heardVoiceThisTurn ? 1 : 0);
      }
      if (heardVoiceThisTurn) {
        if (nowMs - lastVoiceMs >= kEndOfSpeechSilenceMs) {
          Serial.println(
              "[VAD] user paused after speaking — ending turn, sending to AI");
          setState(SESSION_PROCESSING);
          break;
        }
      } else if (nowMs - turnStartMs >= kNoSpeechTimeoutMs) {
        Serial.println(
            "[VAD] no speech at all — giving up, ending conversation");
        endConversation("no_speech_timeout");
        break;
      }

      if (s_uplinkQueue == nullptr) {
        sendUplinkFrame(frame, n);
        frameCount++;
        break;
      }
      CaptureChunk chunk;
      chunk.len = n;
      memcpy(chunk.data, frame, n);
      if (xQueueSend(s_uplinkQueue, &chunk,
                     pdMS_TO_TICKS(kUplinkQueueSendWaitMs)) != pdTRUE) {
        CaptureChunk discard;
        xQueueReceive(s_uplinkQueue, &discard, 0);
        xQueueSend(s_uplinkQueue, &chunk, 0);
        droppedCount++;
        if (droppedCount == 1 || droppedCount % kUplinkDropLogInterval == 0) {
          Serial.printf("[MIC] uplink queue full — dropped oldest frame "
                        "(network stalled, total=%d)\n",
                        droppedCount);
        }
      }
      frameCount++;
      break;
    }
    case SESSION_PROCESSING:
    case SESSION_SPEAKING:
      break;
    }
  }
}

// MARK: - Uplink sender (network)

static void finishUplinkTurn(int sentCount) {
  if (getState() == SESSION_PROCESSING) {
    sendTextAndFlush(protocolBuildAudioStop());
  } else {
    pumpWebSocketRepeated(10, 5);
  }
  const int captured = s_turnCaptured;
  const int dropped = s_turnDropped;
  const int sendPct = captured > 0 ? (sentCount * 100) / captured : 0;
  Serial.printf("[MIC] uplink turn: captured=%d sent=%d dropped=%d "
                "send_rate=%d%% queue_depth=%u\n",
                captured, sentCount, dropped, sendPct,
                static_cast<unsigned>(s_uplinkQueueDepth));
  s_turnCaptured = 0;
  s_turnDropped = 0;
}

static void uplinkSendTask(void *arg) {
  (void)arg;
  static CaptureChunk batch[kUplinkSendBatchMax];
  int sentCount = 0;
  while (true) {
    if (s_uplinkQueue == nullptr) {
      vTaskDelay(pdMS_TO_TICKS(100));
      continue;
    }
    if (xQueueReceive(s_uplinkQueue, &batch[0], portMAX_DELAY) != pdTRUE) {
      continue;
    }
    if (batch[0].len == 0) {
      finishUplinkTurn(sentCount);
      sentCount = 0;
      continue;
    }

    int batchCount = 1;
    while (batchCount < kUplinkSendBatchMax) {
      CaptureChunk next;
      if (xQueueReceive(s_uplinkQueue, &next, 0) != pdTRUE) {
        break;
      }
      if (next.len == 0) {
        sentCount += sendBinaryBatch(batch, batchCount);
        finishUplinkTurn(sentCount);
        sentCount = 0;
        batchCount = 0;
        break;
      }
      batch[batchCount++] = next;
    }

    if (batchCount > 0) {
      sentCount += sendBinaryBatch(batch, batchCount);
    }
  }
}

// MARK: - Playback (downlink)

static void playbackTask(void *arg) {
  (void)arg;
  PlaybackChunk chunk;
  static int16_t samples[COMPANION_DOWNLINK_FRAME_BYTES / sizeof(int16_t)];
  static int16_t silence[COMPANION_DOWNLINK_FRAME_BYTES / sizeof(int16_t)] = {};
  TickType_t nextWake = 0;
  int starvationFrames = 0;

  while (true) {
    if (s_playbackQueue == nullptr) {
      vTaskDelay(pdMS_TO_TICKS(100));
      continue;
    }
    if (s_playbackNeedPrefill) {
      if (uxQueueMessagesWaiting(s_playbackQueue) < s_prefillTarget) {
        vTaskDelay(pdMS_TO_TICKS(5));
        continue;
      }
      s_playbackNeedPrefill = false;
      starvationFrames = 0;
      nextWake = xTaskGetTickCount();
      Serial.printf(
          "[AUDIO] prefill complete — playback starting (target=%u)\n",
          static_cast<unsigned>(s_prefillTarget));
    }

    TickType_t now = xTaskGetTickCount();
    if (now < nextWake) {
      vTaskDelay(nextWake - now);
    }

    bool gotFrame = xQueueReceive(s_playbackQueue, &chunk,
                                  pdMS_TO_TICKS(kQueueWaitMs)) == pdTRUE;
    if (!gotFrame) {
      if (getState() != SESSION_SPEAKING) {
        audioIoSpeakerMute();
        continue;
      }
      audioIoWriteDownlink(silence, sizeof(silence) / sizeof(silence[0]));
      starvationFrames++;
      nextWake += pdMS_TO_TICKS(kDownlinkFrameMs);
      now = xTaskGetTickCount();
      if (nextWake < now) {
        nextWake = now;
      }
      if (starvationFrames >= kStarvationFramesBeforeRebuffer) {
        s_playbackNeedPrefill = true;
        if (s_prefillTarget < kMaxPrefillFrames) {
          s_prefillTarget += 2;
        }
        Serial.printf("[AUDIO] underrun — re-buffering (next target=%u)\n",
                      static_cast<unsigned>(s_prefillTarget));
        starvationFrames = 0;
      }
      continue;
    }

    starvationFrames = 0;
    size_t sampleCount = pcmCodecDecodeDownlinkFrame(
        chunk.data, chunk.len, samples, sizeof(samples) / sizeof(samples[0]));
    audioIoWriteDownlink(samples, sampleCount);

    int frameMs =
        static_cast<int>(sampleCount * 1000 / COMPANION_DOWNLINK_SAMPLE_RATE);
    if (frameMs < 1) {
      frameMs = kDownlinkFrameMs;
    }
    nextWake += pdMS_TO_TICKS(frameMs);
    now = xTaskGetTickCount();
    if (nextWake < now) {
      nextWake = now;
    }
  }
}

// MARK: - Button -> session transitions
//
// Failsafe when noisy-room VAD never sees 1 s of silence (stuck in CAPTURING):
//   short tap  -> force end-of-turn (same as VAD pause-after-speech)
//   long press -> end whole conversation → IDLE
//
// From IDLE: short tap starts a conversation; long press is a no-op.
// During TTS: short tap barges in (abort playback, auto-relisten on tts.end);
// long press ends the conversation.

static void forceEndCaptureTurn(const char *reason) {
  if (getState() != SESSION_CAPTURING) {
    return;
  }
  Serial.printf("[BUTTON] force end turn (%s) → PROCESSING\n", reason);
  setState(SESSION_PROCESSING);
}

static void bargeInDuringTts() {
  sendTextAndFlush(protocolBuildAbort(s_sessionId, "user_barge_in"));
  drainPlaybackQueue();
  audioIoSpeakerMute();
  // Stay out of IDLE — server's abort-cleanup tts.end will kick off capture.
  Serial.println("[BUTTON] barge-in — waiting for TTS cleanup");
}

static void onButtonShortTap() {
  SessionState s = getState();
  switch (s) {
  case SESSION_IDLE:
    startListening("[BUTTON] short tap");
    break;
  case SESSION_CAPTURING:
    forceEndCaptureTurn("user_short_tap");
    break;
  case SESSION_SPEAKING:
    bargeInDuringTts();
    break;
  case SESSION_PROCESSING:
    break;
  }
}

static void onButtonLongPress() {
  SessionState s = getState();
  if (s == SESSION_IDLE) {
    return;
  }
  endConversation("user_long_press");
}

static void onButtonEvent(ButtonEvent event, void *ctx) {
  (void)ctx;
  switch (event) {
  case BUTTON_EVENT_SHORT_TAP:
    onButtonShortTap();
    break;
  case BUTTON_EVENT_LONG_PRESS:
    onButtonLongPress();
    break;
  }
}

// MARK: - WebSocket event handling

static void handleTextFrame(uint8_t *payload, size_t len) {
  ProtoMsg msg;
  protocolParse(payload, len, msg);

  switch (msg.type) {
  case PROTO_MSG_SESSION_READY:
    s_sessionId = msg.sessionId;
    drainPlaybackQueue();
    drainUplinkQueue();
    setState(SESSION_IDLE);
    s_sessionReady = true;
    faceDisplaySetMode(FACE_IDLE);
    faceDisplaySetStatusLine("Tap to talk");
    Serial.printf("session ready: %s\n", s_sessionId.c_str());
    Serial.println(
        ">>> READY — connecting mic / server OK; wait for LISTENING <<<");
    if (s_pendingListenAfterReconnect) {
      s_pendingListenAfterReconnect = false;
      startListening("[WS] reconnected");
    }
    break;
  case PROTO_MSG_TRANSCRIPT_FINAL:
    Serial.printf("transcript: %s\n", msg.text.c_str());
    faceDisplayShowTranscript(msg.text.c_str());
    break;
  case PROTO_MSG_DEVICE_COMMAND:
    Serial.printf("[WS] device_command action=%s pattern=%s duration=%u\n",
                  msg.action.c_str(), msg.pattern.c_str(),
                  static_cast<unsigned>(msg.durationMs));
    if (msg.action == "move") {
      if (msg.pattern.length() > 0) {
        motorHandleCommand(msg.pattern.c_str(), msg.durationMs);
      } else {
        Serial.println("[MOTOR] move command missing pattern");
      }
    } else {
      Serial.printf("[WS] device_command ignored: action=%s\n", msg.action.c_str());
    }
    break;
  case PROTO_MSG_TTS_START:
    drainPlaybackQueue();
    s_prefillTarget = kInitialPrefillFrames;
    s_playbackNeedPrefill = true;
    setState(SESSION_SPEAKING);
    faceDisplaySetStatusLine("Speaking...");
    Serial.println("[TTS] START — AI speaking");
    break;
  case PROTO_MSG_TTS_END: {
    // The server also sends tts.end as part of cleaning up after an
    // `abort` (e.g. our own no-speech timeout, or a tap-to-end) even
    // though nothing was ever spoken — SESSION_SPEAKING only happens
    // after a real tts.start. Auto-relistening on that non-playback
    // tts.end would loop forever: abort -> tts.end -> capture -> ...
    bool wasSpeaking = (getState() == SESSION_SPEAKING);
    drainUplinkQueue();
    audioIoSpeakerMute();
    if (wasSpeaking) {
      Serial.println("[TTS] END — listening for reply");
      kickoffCaptureAsync("[AUTO] AI finished speaking");
    } else {
      setState(SESSION_IDLE);
      Serial.println("[TTS] END (no active playback) — back to idle");
    }
    break;
  }
  case PROTO_MSG_ERROR:
    Serial.printf("server error: code=%s message=%s\n", msg.errorCode.c_str(),
                  msg.errorMessage.c_str());
    drainPlaybackQueue();
    drainUplinkQueue();
    setState(SESSION_IDLE);
    faceDisplaySetMode(FACE_ERROR);
    faceDisplaySetStatusLine("Error");
    break;
  case PROTO_MSG_LATENCY_REPORT:
    Serial.println("latency.report received");
    break;
  case PROTO_MSG_UNKNOWN:
  default:
    break;
  }
}

static void handleBinaryFrame(uint8_t *payload, size_t len) {
  SessionState s = getState();
  // Accept during PROCESSING too — uplink used to call loop() and drop early
  // downlink frames before tts.start flipped state to SESSION_SPEAKING.
  if (s != SESSION_SPEAKING && s != SESSION_PROCESSING) {
    Serial.printf("[AUDIO] ignored %u bytes — state=%d (need speaking/processing)\n",
                  static_cast<unsigned>(len), static_cast<int>(s));
    return;
  }
  if (len > COMPANION_DOWNLINK_FRAME_BYTES) {
    Serial.printf("[AUDIO] truncating oversized frame %u -> %u bytes\n",
                  static_cast<unsigned>(len),
                  static_cast<unsigned>(COMPANION_DOWNLINK_FRAME_BYTES));
    len = COMPANION_DOWNLINK_FRAME_BYTES;
  }
  if (s_playbackQueue == nullptr) {
    Serial.printf("[AUDIO] no playback queue — dropping %u bytes\n",
                  static_cast<unsigned>(len));
    return;
  }
  PlaybackChunk chunk = {};
  chunk.len = len;
  memcpy(chunk.data, payload, len);
  if (xQueueSend(s_playbackQueue, &chunk, pdMS_TO_TICKS(kDownlinkEnqueueMs)) !=
      pdTRUE) {
    Serial.printf("[AUDIO] queue full, dropping %u bytes\n",
                  static_cast<unsigned>(len));
  }
}

static void webSocketEvent(WStype_t type, uint8_t *payload, size_t length) {
  switch (type) {
  case WStype_CONNECTED:
    Serial.println("ws connected");
    sendText(protocolBuildSessionStart());
    requestWsPump();
    break;
  case WStype_DISCONNECTED:
    Serial.printf("[WS] DISCONNECTED (was in state %d) — resetting\n",
                  (int)getState());
    s_sessionReady = false;
    drainPlaybackQueue();
    drainUplinkQueue();
    audioIoSpeakerMute();
    setState(SESSION_IDLE);
    faceDisplaySetMode(FACE_CONNECTING);
    faceDisplaySetStatusLine("Reconnecting...");
    break;
  case WStype_TEXT:
    Serial.printf("[WS] text (%u bytes)\n", static_cast<unsigned>(length));
    handleTextFrame(payload, length);
    break;
  case WStype_BIN:
    handleBinaryFrame(payload, length);
    break;
  case WStype_ERROR:
    Serial.println("ws error");
    break;
  default:
    break;
  }
}

void wsSessionBegin() {
  Serial.printf("[BOOT] wsSessionBegin heap=%u psram=%u\n",
                static_cast<unsigned>(ESP.getFreeHeap()),
                static_cast<unsigned>(ESP.getFreePsram()));

  s_stateMutex = xSemaphoreCreateMutex();
  s_wsSendMutex = xSemaphoreCreateRecursiveMutex();

  s_playbackQueue = xQueueCreate(kPlaybackQueueDepth, sizeof(PlaybackChunk));
  if (s_playbackQueue == nullptr) {
    Serial.printf(
        "[AUDIO] WARNING: playback queue alloc failed (need %u bytes)\n",
        static_cast<unsigned>(kPlaybackQueueDepth * sizeof(PlaybackChunk)));
  } else {
    Serial.printf("[AUDIO] playback queue ok depth=%u\n",
                  static_cast<unsigned>(kPlaybackQueueDepth));
  }
  Serial.println(
      "[AUDIO] uplink queue deferred until first capture (saves RAM at boot)");

  BaseType_t captureOk =
      xTaskCreate(captureTask, "audio_capture", 8192, NULL, 12, NULL);
  BaseType_t uplinkOk =
      xTaskCreate(uplinkSendTask, "audio_uplink_send", 8192, NULL, 13, NULL);
  BaseType_t playbackOk =
      xTaskCreate(playbackTask, "audio_playback", 8192, NULL, 14, NULL);
  if (captureOk != pdPASS || uplinkOk != pdPASS || playbackOk != pdPASS) {
    Serial.printf("[AUDIO] FATAL: task create failed capture=%d uplink=%d "
                  "playback=%d heap=%u\n",
                  static_cast<int>(captureOk), static_cast<int>(uplinkOk),
                  static_cast<int>(playbackOk),
                  static_cast<unsigned>(ESP.getFreeHeap()));
  }

  static String authHeader =
      String("Authorization: Bearer ") + COMPANION_DEVICE_TOKEN;
  s_webSocket.setExtraHeaders(authHeader.c_str());
  s_webSocket.onEvent(webSocketEvent);
  s_webSocket.setReconnectInterval(2000);

  // 12 KB stack: Links2004 callbacks + binary TTS frames nest several frames deep;
  // 4 KB overflowed (Guru Meditation) once AI downlink started after capture.
  BaseType_t wsLoopOk = xTaskCreatePinnedToCore(
      wsMaintenanceTask, "ws_loop", 12288, NULL, 5, &s_wsLoopHandle, 0);
  s_wsLoopTaskActive = (wsLoopOk == pdPASS);
  if (!s_wsLoopTaskActive) {
    Serial.println("[WS] WARNING: ws_loop task failed — falling back to loop()");
  }

#if COMPANION_USE_TLS
  s_webSocket.beginSSL(COMPANION_SERVER_HOST, COMPANION_SERVER_PORT,
                       COMPANION_SERVER_PATH);
#else
  s_webSocket.begin(COMPANION_SERVER_HOST, COMPANION_SERVER_PORT,
                    COMPANION_SERVER_PATH);
#endif

  buttonInit(onButtonEvent, NULL);
  Serial.println("connecting to server, please wait...");
}

void wsSessionLoop() {
  // wsMaintenanceTask owns loop() when running — avoid two tasks calling it
  // during TTS (corrupts parser state / doubles stack use in the library).
  if (!s_wsLoopTaskActive) {
    flushWebSocket();
  }
}
