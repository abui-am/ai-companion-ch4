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
    size_t len;
    uint8_t data[COMPANION_DOWNLINK_FRAME_BYTES];
};

static constexpr UBaseType_t kPlaybackQueueDepth = 32;
static constexpr UBaseType_t kInitialPrefillFrames = 8;
static constexpr UBaseType_t kMaxPrefillFrames = 16;
static constexpr int kQueueWaitMs = 120;
static constexpr int kStarvationFramesBeforeRebuffer = 8;
static constexpr int kDownlinkFrameMs = COMPANION_FRAME_MS;

static UBaseType_t s_prefillTarget = kInitialPrefillFrames;

static WebSocketsClient s_webSocket;
static SemaphoreHandle_t s_stateMutex;
static SpeakerState s_state = SPEAKER_IDLE;
static QueueHandle_t s_playbackQueue;
static uint32_t s_downlinkFramesReceived = 0;
static volatile bool s_playbackNeedPrefill = true;
#if SPEAKER_SELF_TEST_ON_BOOT
static bool s_selfTestScheduled = false;
#endif

#if SPEAKER_SELF_TEST_ON_BOOT
static void speakerSelfTestTask(void *arg) {
    (void)arg;
    // Let setup() return and the WebSocket task start before blocking on I2S.
    vTaskDelay(pdMS_TO_TICKS(300));
    Serial.println("[SPEAKER TEST] listen for 440 Hz beep (~1 s)...");
    Serial.flush();
    audioIoSpeakerSelfTest();
    vTaskDelete(NULL);
}
#endif

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
    }
    s_playbackNeedPrefill = true;
}

static void playbackTask(void *arg) {
    (void)arg;
    PlaybackChunk chunk;
    static int16_t samples[COMPANION_DOWNLINK_FRAME_BYTES / sizeof(int16_t)];
    static int16_t silence[COMPANION_DOWNLINK_FRAME_BYTES / sizeof(int16_t)] = {};
    TickType_t nextWake = 0;
    uint32_t framesPlayed = 0;
    int starvationFrames = 0;

    while (true) {
        if (s_playbackNeedPrefill) {
            if (uxQueueMessagesWaiting(s_playbackQueue) < s_prefillTarget) {
                vTaskDelay(pdMS_TO_TICKS(5));
                continue;
            }
            s_playbackNeedPrefill = false;
            framesPlayed = 0;
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
            if (getState() != SPEAKER_PLAYING) {
                continue;
            }
            // Pad short gaps with silence instead of stopping immediately.
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
        framesPlayed++;
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

        if ((framesPlayed % 20) == 0) {
            Serial.printf("[AUDIO] played %lu frames (queue=%u)\n",
                          static_cast<unsigned long>(framesPlayed),
                          static_cast<unsigned>(uxQueueMessagesWaiting(s_playbackQueue)));
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
        Serial.println("speaker ready — waiting for TTS from TestClient / SpeakerBenchmark");
        break;
    case PROTO_MSG_TTS_START:
        s_downlinkFramesReceived = 0;
        drainPlaybackQueue();
        s_prefillTarget = kInitialPrefillFrames;
        s_playbackNeedPrefill = true;
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
    if (len > COMPANION_DOWNLINK_FRAME_BYTES) {
        Serial.printf("truncating oversized downlink frame %u -> %u bytes\n",
                      static_cast<unsigned>(len),
                      static_cast<unsigned>(COMPANION_DOWNLINK_FRAME_BYTES));
        len = COMPANION_DOWNLINK_FRAME_BYTES;
    }
    PlaybackChunk chunk = {};
    chunk.len = len;
    memcpy(chunk.data, payload, len);
    if (xQueueSend(s_playbackQueue, &chunk, 0) != pdTRUE) {
        Serial.println("playback queue full, dropping frame");
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
    s_playbackQueue = xQueueCreate(kPlaybackQueueDepth, sizeof(PlaybackChunk));
    if (s_playbackQueue == nullptr) {
        Serial.printf("[AUDIO] FATAL: playback queue alloc failed (need %u bytes)\n",
                      static_cast<unsigned>(kPlaybackQueueDepth * sizeof(PlaybackChunk)));
    }

    audioIoInit();

    xTaskCreate(playbackTask, "audio_playback", 8192, NULL, 14, NULL);

#if SPEAKER_SELF_TEST_ON_BOOT
    if (!s_selfTestScheduled) {
        s_selfTestScheduled = true;
        xTaskCreate(speakerSelfTestTask, "spk_selftest", 4096, NULL, 1, NULL);
    }
#endif

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
    Serial.println("  uplink: TestClient or SpeakerBenchmark on Mac (/ws)");
}

void wsSessionLoop() {
    s_webSocket.loop();
}
