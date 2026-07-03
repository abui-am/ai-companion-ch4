#include "ws_session.h"

#include <Arduino.h>
#include <WebSocketsClient.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/semphr.h>
#include <freertos/task.h>

#include "audio_io.h"
#include "button.h"
#include "config.h"
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

static constexpr UBaseType_t kPlaybackQueueDepth = 12;
static constexpr UBaseType_t kInitialPrefillFrames = 4;
static constexpr UBaseType_t kMaxPrefillFrames = 12;
static constexpr int kDownlinkEnqueueMs = 100;
static constexpr int kQueueWaitMs = 120;
static constexpr int kStarvationFramesBeforeRebuffer = 8;
static constexpr int kDownlinkFrameMs = COMPANION_FRAME_MS;

static UBaseType_t s_prefillTarget = kInitialPrefillFrames;

static WebSocketsClient s_webSocket;
static SemaphoreHandle_t s_stateMutex = nullptr;
static SessionState s_state = SESSION_IDLE;
static String s_sessionId;
static volatile bool s_sessionReady = false;
static volatile bool s_playbackNeedPrefill = true;

static SemaphoreHandle_t s_wsSendMutex = nullptr;
static SemaphoreHandle_t s_captureStartSem = nullptr;
static QueueHandle_t s_playbackQueue = nullptr;

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

static void sendText(const String &text) {
    xSemaphoreTake(s_wsSendMutex, portMAX_DELAY);
    if (s_webSocket.isConnected()) {
        String copy = text;
        s_webSocket.sendTXT(copy);
    }
    xSemaphoreGive(s_wsSendMutex);
}

static void sendBinary(uint8_t *data, size_t len) {
    xSemaphoreTake(s_wsSendMutex, portMAX_DELAY);
    if (s_webSocket.isConnected()) {
        s_webSocket.sendBIN(data, len);
    }
    xSemaphoreGive(s_wsSendMutex);
}

static void flushWebSocket() {
    // Do not hold s_wsSendMutex across loop() — the CONNECTED/TEXT handlers call
    // sendText/sendBinary and would deadlock on the same mutex.
    s_webSocket.loop();
}

static void flushWebSocketRepeated(int count, int delayMs) {
    for (int i = 0; i < count; i++) {
        flushWebSocket();
        vTaskDelay(pdMS_TO_TICKS(delayMs));
    }
}

// MARK: - Capture (uplink)

static void captureTask(void *arg) {
    (void)arg;
    static uint8_t frame[COMPANION_UPLINK_FRAME_BYTES];
    int frameCount = 0;
    while (true) {
        xSemaphoreTake(s_captureStartSem, portMAX_DELAY);
        frameCount = 0;
#if HAS_MIC
        audioIoMicStart();
        audioIoPrimeMic();
#endif
        Serial.println("[MIC] capture session started");
        while (getState() == SESSION_CAPTURING) {
            size_t n = audioIoReadUplinkFrame(frame, sizeof(frame));
            if (n != COMPANION_UPLINK_FRAME_BYTES) {
                vTaskDelay(pdMS_TO_TICKS(5));
                continue;
            }
            sendBinary(frame, COMPANION_UPLINK_FRAME_BYTES);
            flushWebSocket();
            frameCount++;
        }
#if HAS_MIC
        audioIoMicStop();
#endif
        flushWebSocketRepeated(10, 5);
        Serial.printf("[MIC] capture stopped, sent %d frames\n", frameCount);
        if (getState() == SESSION_PROCESSING) {
            sendText(protocolBuildAudioStop());
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
        audioIoSpeakerBeep();
        sendText(protocolBuildAudioStart());
        setState(SESSION_CAPTURING);
        xSemaphoreGive(s_captureStartSem);
        Serial.println("[BUTTON] tap: IDLE → CAPTURING (mic ON)");
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
        setState(SESSION_IDLE);
        s_sessionReady = true;
        Serial.printf("session ready: %s\n", s_sessionId.c_str());
        Serial.println(">>> READY — hold touch sensor to speak <<<");
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
    s_wsSendMutex = xSemaphoreCreateMutex();
    s_captureStartSem = xSemaphoreCreateBinary();
    s_playbackQueue = xQueueCreate(kPlaybackQueueDepth, sizeof(PlaybackChunk));
    if (s_playbackQueue == nullptr) {
        Serial.printf("[AUDIO] WARNING: playback queue alloc failed (need %u bytes)\n",
                      static_cast<unsigned>(kPlaybackQueueDepth * sizeof(PlaybackChunk)));
    } else {
        Serial.printf("[AUDIO] playback queue ok depth=%u\n",
                      static_cast<unsigned>(kPlaybackQueueDepth));
    }

    xTaskCreate(captureTask, "audio_capture", 8192, NULL, 12, NULL);
    xTaskCreate(playbackTask, "audio_playback", 8192, NULL, 14, NULL);

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
