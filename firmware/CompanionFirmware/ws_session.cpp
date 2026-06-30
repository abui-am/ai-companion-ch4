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
    uint8_t *data;
    size_t len;
};

static WebSocketsClient s_webSocket;
static SemaphoreHandle_t s_stateMutex;
static SessionState s_state = SESSION_IDLE;
static String s_sessionId;

// WebSocketsClient isn't documented as safe to call concurrently from
// multiple tasks; sendTXT/sendBIN happen from both the capture task and the
// button callback (which runs on the button task), so all sends go through
// this mutex.
static SemaphoreHandle_t s_wsSendMutex;

static SemaphoreHandle_t s_captureStartSem;
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
        free(chunk.data);
    }
}

static void sendText(const String &text) {
    xSemaphoreTake(s_wsSendMutex, portMAX_DELAY);
    if (s_webSocket.isConnected()) {
        s_webSocket.sendTXT(text);
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

// MARK: - Capture (uplink)

static void captureTask(void *arg) {
    static uint8_t frame[COMPANION_UPLINK_FRAME_BYTES];
    while (true) {
        xSemaphoreTake(s_captureStartSem, portMAX_DELAY);
        while (getState() == SESSION_CAPTURING) {
            size_t n = audioIoReadUplinkFrame(frame, sizeof(frame));
            if (n > 0) {
                sendBinary(frame, n);
            }
        }
    }
}

// MARK: - Playback (downlink)

static void playbackTask(void *arg) {
    PlaybackChunk chunk;
    static int16_t samples[COMPANION_DOWNLINK_FRAME_BYTES / sizeof(int16_t)];
    while (true) {
        if (xQueueReceive(s_playbackQueue, &chunk, portMAX_DELAY) == pdTRUE) {
            size_t sampleCount = pcmCodecDecodeDownlinkFrame(
                chunk.data, chunk.len, samples, sizeof(samples) / sizeof(samples[0]));
            audioIoWriteDownlink(samples, sampleCount);
            free(chunk.data);
        }
    }
}

// MARK: - Button -> session transitions

static void onButtonEvent(ButtonEvent event, void *ctx) {
    if (event == BUTTON_EVENT_PRESSED) {
        SessionState s = getState();
        if (s == SESSION_IDLE) {
#if HAS_MIC
            sendText(protocolBuildAudioStart());
            setState(SESSION_CAPTURING);
            xSemaphoreGive(s_captureStartSem);
#else
            Serial.println("HAS_MIC=0, ignoring button press (no mic to capture from yet)");
#endif
        } else if (s == SESSION_SPEAKING) {
            // Barge-in: abort the current TTS turn. User can press again to
            // start a new capture once the server confirms with tts.end (or
            // we recover to idle via the error/disconnect paths).
            sendText(protocolBuildAbort(s_sessionId, "user"));
            drainPlaybackQueue();
            setState(SESSION_IDLE);
        }
        // CAPTURING / PROCESSING: mid-turn already, ignore extra presses.
    } else { // BUTTON_EVENT_RELEASED
        if (getState() == SESSION_CAPTURING) {
            sendText(protocolBuildAudioStop());
            setState(SESSION_PROCESSING);
        }
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
        Serial.printf("session ready: %s\n", s_sessionId.c_str());
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
        setState(SESSION_SPEAKING);
        break;
    case PROTO_MSG_TTS_END:
        setState(SESSION_IDLE);
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
        return; // ignore stray binary frames outside an active TTS turn
    }
    uint8_t *copy = (uint8_t *)malloc(len);
    if (copy == nullptr) {
        Serial.println("oom copying downlink frame, dropping");
        return;
    }
    memcpy(copy, payload, len);
    PlaybackChunk chunk = { copy, len };
    if (xQueueSend(s_playbackQueue, &chunk, 0) != pdTRUE) {
        Serial.println("playback queue full, dropping frame");
        free(copy);
    }
}

static void webSocketEvent(WStype_t type, uint8_t *payload, size_t length) {
    switch (type) {
    case WStype_CONNECTED:
        Serial.println("ws connected");
        sendText(protocolBuildSessionStart());
        break;
    case WStype_DISCONNECTED:
        // Kill-on-disconnect, mirrored client-side: drop whatever turn was
        // in flight. The library auto-reconnects; the server always issues
        // a fresh session_id on the new connection, so there is nothing to
        // resume here.
        Serial.println("ws disconnected, resetting local session state");
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
    s_captureStartSem = xSemaphoreCreateBinary();
    s_playbackQueue = xQueueCreate(16, sizeof(PlaybackChunk));

    audioIoInit();

    xTaskCreate(captureTask, "audio_capture", 4096, NULL, 12, NULL);
    xTaskCreate(playbackTask, "audio_playback", 4096, NULL, 12, NULL);

    static String authHeader = String("Authorization: Bearer ") + COMPANION_DEVICE_TOKEN;
    s_webSocket.setExtraHeaders(authHeader.c_str());
    s_webSocket.onEvent(webSocketEvent);
    s_webSocket.setReconnectInterval(2000);

#if COMPANION_USE_TLS
    s_webSocket.beginSSL(COMPANION_SERVER_HOST, COMPANION_SERVER_PORT, COMPANION_SERVER_PATH);
#else
    s_webSocket.begin(COMPANION_SERVER_HOST, COMPANION_SERVER_PORT, COMPANION_SERVER_PATH);
#endif

    buttonInit(onButtonEvent, NULL);

    Serial.println("ready, hold button to talk");
}

void wsSessionLoop() {
    s_webSocket.loop();
}
