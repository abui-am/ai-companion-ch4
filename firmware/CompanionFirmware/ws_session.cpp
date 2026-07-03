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

// Jitter buffer sized for ~720 ms at 60 ms/frame; server paces sends so this
// rarely fills. Storage is static inside the queue (no per-frame malloc).
static constexpr UBaseType_t kPlaybackQueueDepth = 6;
static constexpr UBaseType_t kInitialPrefillFrames = 3;
static constexpr UBaseType_t kMaxPrefillFrames = 6;
static constexpr int kQueueWaitMs = 120;
static constexpr int kStarvationFramesBeforeRebuffer = 8;
static constexpr int kDownlinkFrameMs = COMPANION_FRAME_MS;

static UBaseType_t s_prefillTarget = kInitialPrefillFrames;

static WebSocketsClient s_webSocket;
static SemaphoreHandle_t s_stateMutex;
static SessionState s_state = SESSION_IDLE;
static String s_sessionId;
static volatile bool s_sessionReady = false;
static volatile bool s_playbackNeedPrefill = true;

// WebSocketsClient isn't documented as safe to call concurrently from
// multiple tasks; sendTXT/sendBIN happen from both the capture task and the
// button callback (which runs on the button task), so all sends go through
// this mutex.
static SemaphoreHandle_t s_wsSendMutex;

static QueueHandle_t s_playbackQueue;

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
    PlaybackChunk chunk;
    while (xQueueReceive(s_playbackQueue, &chunk, 0) == pdTRUE) {
        // chunk storage lives in the queue — nothing to free
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

// MARK: - IDLE -> CAPTURING transition (shared by button + wake word)

static void startListening(const char *trigger) {
    audioIoSpeakerBeep();
    sendText(protocolBuildAudioStart());
    setState(SESSION_CAPTURING);
    Serial.printf("%s: IDLE -> CAPTURING (mic ON)\n", trigger);
}

// MARK: - Capture (uplink) + wake-word listening

// Single task owns every mic read so only one caller ever touches the I2S
// RX port. While idle it feeds the wake-word classifier; while capturing it
// streams frames to the server; while processing/speaking it drops frames
// (the mic would otherwise pick up the device's own TTS output).
static void captureTask(void *arg) {
    static uint8_t frame[COMPANION_UPLINK_FRAME_BYTES];
    int frameCount = 0;
    SessionState lastState = SESSION_IDLE;
    while (true) {
        size_t n = audioIoReadUplinkFrame(frame, sizeof(frame));
        if (n == 0) continue;

        SessionState s = getState();
        if (s != lastState) {
            if (lastState == SESSION_CAPTURING) {
                Serial.printf("[MIC] capture stopped, sent %d frames\n", frameCount);
            }
            if (s == SESSION_CAPTURING) {
                frameCount = 0;
                Serial.println("[MIC] capture session started");
            }
            lastState = s;
        }

        switch (s) {
        case SESSION_CAPTURING:
            frameCount++;
            sendBinary(frame, n);
            break;
        case SESSION_IDLE:
            if (s_sessionReady &&
                wakeWordFeed(reinterpret_cast<const int16_t *>(frame), n / sizeof(int16_t))) {
                startListening("[WAKE] \"hey_botchill\" detected");
            }
            break;
        case SESSION_PROCESSING:
        case SESSION_SPEAKING:
            break;
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

        bool gotFrame = xQueueReceive(s_playbackQueue, &chunk, pdMS_TO_TICKS(kQueueWaitMs)) == pdTRUE;
        if (!gotFrame) {
            if (getState() != SESSION_SPEAKING) {
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

// Toggle logic: tap once = mic ON, tap again = mic OFF.
// Half-duplex: taps are ignored while the AI is speaking to prevent the mic
// from picking up speaker output.
static void onButtonEvent(ButtonEvent event, void *ctx) {
    SessionState s = getState();
    if (!s_sessionReady) {
        Serial.println("[BUTTON] ignored — session not ready yet");
        return;
    }

    if (event != BUTTON_EVENT_PRESSED) return;

    switch (s) {
    case SESSION_IDLE:
        startListening("[BUTTON] tap");
        break;
    case SESSION_CAPTURING:
        sendText(protocolBuildAudioStop());
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
        Serial.println(">>> READY — say \"hey botchill\" or tap the touch sensor <<<");
        break;
    case PROTO_MSG_TRANSCRIPT_FINAL:
        Serial.printf("transcript: %s\n", msg.text.c_str());
        break;
    case PROTO_MSG_DEVICE_COMMAND:
        // No LED hardware wired up yet — log and ignore. Server already
        // validates/bounds-checks before forwarding, so this is safe to
        // no-op rather than reject.
        Serial.printf("device_command ignored (no actuator wired): action=%s\n", msg.action.c_str());
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
        Serial.println("[TTS] END — back to idle");
        break;
    case PROTO_MSG_ERROR:
        Serial.printf("server error: code=%s message=%s\n", msg.errorCode.c_str(), msg.errorMessage.c_str());
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
        Serial.printf("[AUDIO] ignored %u bytes — not in SESSION_SPEAKING\n", len);
        return; // ignore stray binary frames outside an active TTS turn
    }
    if (len > COMPANION_DOWNLINK_FRAME_BYTES) {
        Serial.printf("[AUDIO] truncating oversized frame %u -> %u bytes\n",
                      static_cast<unsigned>(len),
                      static_cast<unsigned>(COMPANION_DOWNLINK_FRAME_BYTES));
        len = COMPANION_DOWNLINK_FRAME_BYTES;
    }
    PlaybackChunk chunk = {};
    chunk.len = len;
    memcpy(chunk.data, payload, len);
    if (xQueueSend(s_playbackQueue, &chunk, 0) != pdTRUE) {
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
    s_stateMutex = xSemaphoreCreateMutex();
    s_wsSendMutex = xSemaphoreCreateMutex();
    s_playbackQueue = xQueueCreate(kPlaybackQueueDepth, sizeof(PlaybackChunk));
    if (s_playbackQueue == nullptr) {
        Serial.printf("[AUDIO] FATAL: playback queue alloc failed (need %u bytes)\n",
                      static_cast<unsigned>(kPlaybackQueueDepth * sizeof(PlaybackChunk)));
    }

    audioIoInit();
    wakeWordInit();

    // Bumped from 8192: this task now also runs the Edge Impulse classifier
    // (MFCC + TFLite invoke), not just I2S reads.
    xTaskCreate(captureTask, "audio_capture", 16384, NULL, 12, NULL);
    // Playback above capture + loop so I2S drains the queue before it backs up.
    xTaskCreate(playbackTask, "audio_playback", 8192, NULL, 14, NULL);

    static String authHeader = String("Authorization: Bearer ") + COMPANION_DEVICE_TOKEN;
    s_webSocket.setExtraHeaders(authHeader.c_str());
    s_webSocket.onEvent(webSocketEvent);
    s_webSocket.setReconnectInterval(0);  // no auto-reconnect

#if COMPANION_USE_TLS
    s_webSocket.beginSSL(COMPANION_SERVER_HOST, COMPANION_SERVER_PORT, COMPANION_SERVER_PATH);
#else
    s_webSocket.begin(COMPANION_SERVER_HOST, COMPANION_SERVER_PORT, COMPANION_SERVER_PATH);
#endif

    buttonInit(onButtonEvent, NULL);
    Serial.println("connecting to server, please wait...");
}

void wsSessionLoop() {
    s_webSocket.loop();
}
