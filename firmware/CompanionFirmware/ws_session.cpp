#include "ws_session.h"

#include <Arduino.h>
#include <WebSocketsClient.h>
#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/semphr.h>
#include <freertos/task.h>

#include "audio_io.h"
#include "button.h"
#include "config.h"
#include "pcm_codec.h"
#include "protocol.h"
#include "wake_word.h"

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
//   p50 ≈ 2.6 s (43 frames)   p90 ≈ 8.2 s (136 frames)   max ≈ 19 s (316 frames)
//
// Observed stall (queue=24, 115 captured / 86 sent / 29 dropped):
//   sender averaged ~75% of capture rate → backlog ≈ 29 frames minimum depth.
//
// Worst-case single send stall: WEBSOCKETS_TCP_TIMEOUT ≈ 5 s → 5000/60 ≈ 84 frames.
// Target depth = stall_budget + margin, capped below p90 recording when sender is
// fully blocked (full-session buffering would need 136+ frames / 260 KB+).
static constexpr int kUplinkFrameMs = COMPANION_FRAME_MS;
static constexpr int kUplinkTcpStallMs = 5000;
static constexpr int kUplinkQueueStallMarginFrames = 12;
static constexpr int kUplinkQueueTargetDepth =
    (kUplinkTcpStallMs / kUplinkFrameMs) + kUplinkQueueStallMarginFrames; // 96
static constexpr int kUplinkQueueMaxDepth = 128; // ~7.7 s @ zero send; covers observed ~115-frame turns
static constexpr int kUplinkQueueMinDepth = 32;  // ~1.9 s; below this, drops are likely on LAN

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

static SessionState getState() {
    xSemaphoreTake(s_stateMutex, portMAX_DELAY);
    SessionState s = s_state;
    xSemaphoreGive(s_stateMutex);
    return s;
}

static void setState(SessionState s) {
    xSemaphoreTake(s_stateMutex, portMAX_DELAY);
    s_state = s;
    xSemaphoreGive(s_stateMutex);
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
    const size_t storageBytes =
        static_cast<size_t>(depth) * sizeof(CaptureChunk);

    uint8_t *storage = static_cast<uint8_t *>(heap_caps_malloc(
        storageBytes,
        preferPsram ? (MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT)
                    : (MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT)));
    if (storage == nullptr) {
        return false;
    }

    StaticQueue_t *qstruct = static_cast<StaticQueue_t *>(
        heap_caps_malloc(sizeof(StaticQueue_t), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
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
    Serial.printf(
        "[AUDIO] uplink queue ok depth=%u (~%u ms, %u bytes, %s)\n",
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

    int depthByPsram =
        psramBlock > chunkBytes
            ? static_cast<int>((psramBlock * 9 / 10) / chunkBytes)
            : 0;
    int depthByInternal =
        internalBlock > chunkBytes + 8192
            ? static_cast<int>(((internalBlock - 8192) * 9 / 10) / chunkBytes)
            : 0;

    int tryMax = kUplinkQueueMaxDepth;
    if (depthByPsram > 0 && depthByPsram < tryMax) {
        tryMax = depthByPsram;
    } else if (depthByInternal > 0 && depthByPsram == 0 && depthByInternal < tryMax) {
        tryMax = depthByInternal;
    }

    Serial.printf(
        "[AUDIO] uplink queue sizing: target=%d max=%d min=%d chunk=%u psram=%u internal=%u heap=%u\n",
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
            "[AUDIO] uplink queue alloc failed depth=%d (need %u bytes)\n",
            depth, static_cast<unsigned>(depth * chunkBytes));
    }

    Serial.println("[AUDIO] FATAL: uplink queue unavailable — mic will send inline (degraded)");
    return false;
}

static void sendText(const String &text) {
    xSemaphoreTakeRecursive(s_wsSendMutex, portMAX_DELAY);
    if (s_webSocket.isConnected()) {
        String copy = text;
        s_webSocket.sendTXT(copy);
    }
    xSemaphoreGiveRecursive(s_wsSendMutex);
}

static void sendTextAndFlush(const String &text) {
    xSemaphoreTakeRecursive(s_wsSendMutex, portMAX_DELAY);
    if (s_webSocket.isConnected()) {
        String copy = text;
        s_webSocket.sendTXT(copy);
        s_webSocket.loop();
    }
    xSemaphoreGiveRecursive(s_wsSendMutex);
}

// Send one uplink PCM frame; loop() after each BIN so the WebSockets library
// actually pushes the frame (batching multiple sendBIN before one loop() was
// leaving frames stuck in the client buffer).
static int sendUplinkFrame(const uint8_t *data, size_t len) {
    if (len == 0) {
        return 0;
    }
    xSemaphoreTakeRecursive(s_wsSendMutex, portMAX_DELAY);
    int sent = 0;
    if (s_webSocket.isConnected()) {
        s_webSocket.sendBIN(data, len);
        s_webSocket.loop();
        sent = 1;
    }
    xSemaphoreGiveRecursive(s_wsSendMutex);
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

static void flushWebSocketRepeated(int count, int delayMs) {
    for (int i = 0; i < count; i++) {
        flushWebSocket();
        vTaskDelay(pdMS_TO_TICKS(delayMs));
    }
}

// MARK: - IDLE -> CAPTURING transition (shared by button + wake word)

static void startListening(const char *trigger) {
    setState(SESSION_CAPTURING);
    sendTextAndFlush(protocolBuildAudioStart());
    Serial.printf("%s: IDLE → CAPTURING (mic ON)\n", trigger);
    audioIoSpeakerBeep();
}

static void finishCaptureSession(int frameCount, int droppedCount) {
#if HAS_MIC
    audioIoMicStop();
#endif
    Serial.printf("[MIC] capture stopped, captured %d frames from mic", frameCount);
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
        Serial.printf("[MIC] uplink inline: sent %d frames to server\n", frameCount);
    }
}

// MARK: - Capture (uplink) + wake-word listening
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
// While idle (and session-ready) this task also feeds the Edge Impulse
// wake-word classifier on the same mic stream.

static void captureTask(void *arg) {
    (void)arg;
    static uint8_t frame[COMPANION_UPLINK_FRAME_BYTES];
    int frameCount = 0;
    int droppedCount = 0;
    SessionState lastState = SESSION_IDLE;
    bool micActive = false;

    while (true) {
        SessionState s = getState();

        if (lastState == SESSION_CAPTURING && s != SESSION_CAPTURING) {
            finishCaptureSession(frameCount, droppedCount);
            frameCount = 0;
            droppedCount = 0;
        }

        if (s == SESSION_PROCESSING || s == SESSION_SPEAKING) {
            if (micActive) {
#if HAS_MIC
                audioIoMicStop();
#endif
                micActive = false;
            }
            lastState = s;
            vTaskDelay(pdMS_TO_TICKS(20));
            continue;
        }

        if (!micActive) {
#if HAS_MIC
            audioIoMicStart();
#endif
            micActive = true;
        }

        if (s == SESSION_CAPTURING && lastState != SESSION_CAPTURING) {
            drainUplinkQueue();
            frameCount = 0;
            droppedCount = 0;
#if HAS_MIC
            audioIoPrimeMic();
#endif
            Serial.println("[MIC] capture session started");
            Serial.printf("[MIC] queue=%p heap=%u\n", s_uplinkQueue,
                          static_cast<unsigned>(ESP.getFreeHeap()));
        }

        lastState = s;

        size_t n = audioIoReadUplinkFrame(frame, sizeof(frame));
        if (n == 0) {
            continue;
        }

        switch (s) {
        case SESSION_IDLE:
            if (s_sessionReady &&
                wakeWordFeed(reinterpret_cast<const int16_t *>(frame),
                             n / sizeof(int16_t))) {
                startListening("[WAKE] \"hey_botchill\" detected");
            }
            break;
        case SESSION_CAPTURING:
            if (n != COMPANION_UPLINK_FRAME_BYTES) {
                vTaskDelay(pdMS_TO_TICKS(5));
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
            if (xQueueSend(s_uplinkQueue, &chunk, pdMS_TO_TICKS(kUplinkQueueSendWaitMs)) != pdTRUE) {
                CaptureChunk discard;
                xQueueReceive(s_uplinkQueue, &discard, 0);
                xQueueSend(s_uplinkQueue, &chunk, 0);
                droppedCount++;
                if (droppedCount == 1 || droppedCount % kUplinkDropLogInterval == 0) {
                    Serial.printf(
                        "[MIC] uplink queue full — dropped oldest frame (network stalled, total=%d)\n",
                        droppedCount);
                }
            }
            frameCount++;
            break;
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
        flushWebSocketRepeated(10, 5);
    }
    const int captured = s_turnCaptured;
    const int dropped = s_turnDropped;
    const int sendPct = captured > 0 ? (sentCount * 100) / captured : 0;
    Serial.printf(
        "[MIC] uplink turn: captured=%d sent=%d dropped=%d send_rate=%d%% queue_depth=%u\n",
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
            Serial.printf("[AUDIO] prefill complete — playback starting (target=%u)\n",
                          static_cast<unsigned>(s_prefillTarget));
        }

        TickType_t now = xTaskGetTickCount();
        if (now < nextWake) {
            vTaskDelay(nextWake - now);
        }

        bool gotFrame =
            xQueueReceive(s_playbackQueue, &chunk, pdMS_TO_TICKS(kQueueWaitMs)) == pdTRUE;
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

        int frameMs = static_cast<int>(sampleCount * 1000 / COMPANION_DOWNLINK_SAMPLE_RATE);
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

static void onButtonEvent(ButtonEvent event, void *ctx) {
    (void)ctx;
    SessionState s = getState();
    if (!s_sessionReady) {
        Serial.println("[BUTTON] ignored — session not ready yet");
        return;
    }

    if (event != BUTTON_EVENT_PRESSED) {
        return;
    }

    switch (s) {
    case SESSION_IDLE:
        startListening("[BUTTON] tap");
        break;
    case SESSION_CAPTURING:
        setState(SESSION_PROCESSING);
        Serial.println("[BUTTON] tap: CAPTURING → PROCESSING (mic OFF)");
        break;
    case SESSION_SPEAKING:
        Serial.println("[BUTTON] tap: IGNORED — AI speaking (half-duplex)");
        break;
    case SESSION_PROCESSING:
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
        Serial.printf("session ready: %s\n", s_sessionId.c_str());
        Serial.println(">>> READY — say \"hey botchill\" or tap the touch sensor <<<");
        break;
    case PROTO_MSG_TRANSCRIPT_FINAL:
        Serial.printf("transcript: %s\n", msg.text.c_str());
        break;
    case PROTO_MSG_DEVICE_COMMAND:
        Serial.printf("device_command ignored (no actuator wired): action=%s\n",
                      msg.action.c_str());
        break;
    case PROTO_MSG_TTS_START:
        drainPlaybackQueue();
        s_prefillTarget = kInitialPrefillFrames;
        s_playbackNeedPrefill = true;
        setState(SESSION_SPEAKING);
        Serial.println("[TTS] START — AI speaking");
        break;
    case PROTO_MSG_TTS_END:
        setState(SESSION_IDLE);
        audioIoSpeakerMute();
        Serial.println("[TTS] END — back to idle");
        break;
    case PROTO_MSG_ERROR:
        Serial.printf("server error: code=%s message=%s\n", msg.errorCode.c_str(),
                      msg.errorMessage.c_str());
        drainPlaybackQueue();
        drainUplinkQueue();
        setState(SESSION_IDLE);
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
    if (getState() != SESSION_SPEAKING) {
        Serial.printf("[AUDIO] ignored %u bytes — not in SESSION_SPEAKING\n",
                      static_cast<unsigned>(len));
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
    if (xQueueSend(s_playbackQueue, &chunk, pdMS_TO_TICKS(kDownlinkEnqueueMs)) != pdTRUE) {
        Serial.printf("[AUDIO] queue full, dropping %u bytes\n", static_cast<unsigned>(len));
    }
}

static void webSocketEvent(WStype_t type, uint8_t *payload, size_t length) {
    switch (type) {
    case WStype_CONNECTED:
        Serial.println("ws connected");
        sendText(protocolBuildSessionStart());
        break;
    case WStype_DISCONNECTED:
        Serial.printf("[WS] DISCONNECTED (was in state %d) — resetting\n", (int)getState());
        s_sessionReady = false;
        drainPlaybackQueue();
        drainUplinkQueue();
        setState(SESSION_IDLE);
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
    Serial.printf("[BOOT] wsSessionBegin heap=%u\n",
                  static_cast<unsigned>(ESP.getFreeHeap()));

    s_stateMutex = xSemaphoreCreateMutex();
    s_wsSendMutex = xSemaphoreCreateRecursiveMutex();
    s_playbackQueue = xQueueCreate(kPlaybackQueueDepth, sizeof(PlaybackChunk));
    if (s_playbackQueue == nullptr) {
        Serial.printf("[AUDIO] WARNING: playback queue alloc failed (need %u bytes)\n",
                      static_cast<unsigned>(kPlaybackQueueDepth * sizeof(PlaybackChunk)));
    } else {
        Serial.printf("[AUDIO] playback queue ok depth=%u\n",
                      static_cast<unsigned>(kPlaybackQueueDepth));
    }
    if (!createUplinkQueue()) {
        Serial.println("[MIC] will use inline uplink (no queue buffer)");
    }

    wakeWordInit();

    // Bumped from 8192: this task also runs the Edge Impulse classifier
    // (MFCC + TFLite invoke) while idle, not just I2S reads.
    BaseType_t captureOk =
        xTaskCreate(captureTask, "audio_capture", 16384, NULL, 12, NULL);
    BaseType_t uplinkOk =
        xTaskCreate(uplinkSendTask, "audio_uplink_send", 8192, NULL, 13, NULL);
    BaseType_t playbackOk =
        xTaskCreate(playbackTask, "audio_playback", 8192, NULL, 14, NULL);
    if (captureOk != pdPASS || uplinkOk != pdPASS || playbackOk != pdPASS) {
        Serial.printf("[AUDIO] FATAL: task create failed capture=%d uplink=%d playback=%d heap=%u\n",
                      static_cast<int>(captureOk), static_cast<int>(uplinkOk),
                      static_cast<int>(playbackOk),
                      static_cast<unsigned>(ESP.getFreeHeap()));
    }

    static String authHeader = String("Authorization: Bearer ") + COMPANION_DEVICE_TOKEN;
    s_webSocket.setExtraHeaders(authHeader.c_str());
    s_webSocket.onEvent(webSocketEvent);
    s_webSocket.setReconnectInterval(0);

#if COMPANION_USE_TLS
    s_webSocket.beginSSL(COMPANION_SERVER_HOST, COMPANION_SERVER_PORT, COMPANION_SERVER_PATH);
#else
    s_webSocket.begin(COMPANION_SERVER_HOST, COMPANION_SERVER_PORT, COMPANION_SERVER_PATH);
#endif

    buttonInit(onButtonEvent, NULL);
    Serial.println("connecting to server, please wait...");
}

void wsSessionLoop() {
    flushWebSocket();
}
