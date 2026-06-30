#include "ws_session.h"

#include <Arduino.h>
#include <WebSocketsClient.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/semphr.h>
#include <freertos/task.h>

#include "audio_io.h"
#include "config.h"
#include "pcm_codec.h"
#include "protocol.h"

enum SpeakerState {
    SPEAKER_IDLE,
    SPEAKER_PLAYING,
};

struct PlaybackChunk {
    uint8_t *data;
    size_t len;
};

static WebSocketsClient s_webSocket;
static SemaphoreHandle_t s_stateMutex;
static SpeakerState s_state = SPEAKER_IDLE;
static QueueHandle_t s_playbackQueue;
static uint32_t s_downlinkFramesReceived = 0;

static const char *stateName(SpeakerState s) {
    switch (s) {
    case SPEAKER_IDLE: return "idle";
    case SPEAKER_PLAYING: return "playing";
    default: return "unknown";
    }
}

static SpeakerState getState() {
    xSemaphoreTake(s_stateMutex, portMAX_DELAY);
    SpeakerState s = s_state;
    xSemaphoreGive(s_stateMutex);
    return s;
}

static void setState(SpeakerState s) {
    xSemaphoreTake(s_stateMutex, portMAX_DELAY);
    if (s_state != s) {
        Serial.printf("state: %s -> %s\n", stateName(s_state), stateName(s));
    }
    s_state = s;
    xSemaphoreGive(s_stateMutex);
}

static void drainPlaybackQueue() {
    PlaybackChunk chunk;
    while (xQueueReceive(s_playbackQueue, &chunk, 0) == pdTRUE) {
        free(chunk.data);
    }
}

static void playbackTask(void *arg) {
    (void)arg;
    PlaybackChunk chunk;
    static int16_t samples[COMPANION_DOWNLINK_FRAME_BYTES / sizeof(int16_t)];
    while (true) {
        if (xQueueReceive(s_playbackQueue, &chunk, portMAX_DELAY) == pdTRUE) {
            size_t sampleCount = pcmCodecDecodeDownlinkFrame(
                chunk.data, chunk.len, samples, sizeof(samples) / sizeof(samples[0]));
            Serial.printf("downlink frame %lu (%u bytes, %u samples)\n",
                          static_cast<unsigned long>(s_downlinkFramesReceived),
                          static_cast<unsigned>(chunk.len),
                          static_cast<unsigned>(sampleCount));
            audioIoWriteDownlink(samples, sampleCount);
            free(chunk.data);
        }
    }
}

static void handleTextFrame(uint8_t *payload, size_t len) {
    String json(reinterpret_cast<char *>(payload), len);
    Serial.printf("ws recv text: %s\n", json.c_str());

    ProtoMsg msg;
    protocolParse(payload, len, msg);

    switch (msg.type) {
    case PROTO_MSG_SPEAKER_READY:
        drainPlaybackQueue();
        setState(SPEAKER_IDLE);
        s_downlinkFramesReceived = 0;
        Serial.println("speaker ready — waiting for TTS from TestClient");
        break;
    case PROTO_MSG_TTS_START:
        s_downlinkFramesReceived = 0;
        drainPlaybackQueue();
        setState(SPEAKER_PLAYING);
        break;
    case PROTO_MSG_TTS_END:
        Serial.printf("tts complete: downlink_frames=%lu\n",
                      static_cast<unsigned long>(s_downlinkFramesReceived));
        setState(SPEAKER_IDLE);
        break;
    case PROTO_MSG_ERROR:
        Serial.printf("server error: code=%s message=%s\n",
                      msg.errorCode.c_str(), msg.errorMessage.c_str());
        drainPlaybackQueue();
        setState(SPEAKER_IDLE);
        break;
    default:
        break;
    }
}

static void handleBinaryFrame(uint8_t *payload, size_t len) {
    if (getState() != SPEAKER_PLAYING) {
        Serial.printf("ignored downlink binary (%u bytes) state=%s\n",
                      static_cast<unsigned>(len), stateName(getState()));
        return;
    }
    s_downlinkFramesReceived++;
    uint8_t *copy = (uint8_t *)malloc(len);
    if (copy == nullptr) {
        Serial.println("oom copying downlink frame");
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
        Serial.println("ws connected to /speaker");
        break;
    case WStype_DISCONNECTED:
        Serial.println("ws disconnected — resetting speaker");
        drainPlaybackQueue();
        setState(SPEAKER_IDLE);
        break;
    case WStype_TEXT:
        handleTextFrame(payload, length);
        break;
    case WStype_BIN:
        Serial.printf("ws recv binary: %u bytes\n", static_cast<unsigned>(length));
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
    s_playbackQueue = xQueueCreate(16, sizeof(PlaybackChunk));

    audioIoInit();

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

    Serial.println("TestFirmware ready (speaker-only)");
    Serial.printf("  server: %s:%d%s\n", COMPANION_SERVER_HOST, COMPANION_SERVER_PORT, COMPANION_SERVER_PATH);
#if HAS_SPEAKER
    Serial.println("  output: I2S speaker");
#else
    Serial.println("  output: log only (HAS_SPEAKER=0)");
#endif
    Serial.println("  mic: TestClient on Mac (/ws)");
}

void wsSessionLoop() {
    s_webSocket.loop();
}
