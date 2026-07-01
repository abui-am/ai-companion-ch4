#include "mic_server_upload.h"

#include <Arduino.h>
#include <WebSocketsClient.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

#include "config.h"
#include "protocol.h"

#if MIC_LOOPBACK_TEST_MODE && MIC_UPLOAD_TO_SERVER

static WebSocketsClient s_webSocket;
static SemaphoreHandle_t s_wsSendMutex;
static volatile bool s_sessionReady = false;
static String s_sessionId;

static void sendText(const String &text) {
    xSemaphoreTake(s_wsSendMutex, portMAX_DELAY);
    if (s_webSocket.isConnected()) {
        String copy = text;
        s_webSocket.sendTXT(copy);
    }
    xSemaphoreGive(s_wsSendMutex);
}

static void sendBinary(const uint8_t *data, size_t len) {
    xSemaphoreTake(s_wsSendMutex, portMAX_DELAY);
    if (s_webSocket.isConnected()) {
        s_webSocket.sendBIN(const_cast<uint8_t *>(data), len);
    }
    xSemaphoreGive(s_wsSendMutex);
}

static void webSocketEvent(WStype_t type, uint8_t *payload, size_t length) {
    switch (type) {
    case WStype_CONNECTED:
        Serial.println("[WS] connected — session.start");
        sendText(protocolBuildSessionStartDumpOnly());
        break;
    case WStype_DISCONNECTED:
        s_sessionReady = false;
        Serial.println("[WS] disconnected");
        break;
    case WStype_TEXT: {
        ProtoMsg msg;
        protocolParse(payload, length, msg);
        if (msg.type == PROTO_MSG_SESSION_READY) {
            s_sessionId = msg.sessionId;
            s_sessionReady = true;
            Serial.printf("[WS] session ready: %s\n", s_sessionId.c_str());
            Serial.println("[WS] tap to record, tap again to upload → debug-audio/");
        } else if (msg.type == PROTO_MSG_ERROR) {
            Serial.printf("[WS] error: %s — %s\n", msg.errorCode.c_str(),
                          msg.errorMessage.c_str());
        }
        break;
    }
    case WStype_ERROR:
        Serial.println("[WS] error");
        break;
    default:
        break;
    }
}

void micServerUploadBegin() {
    s_wsSendMutex = xSemaphoreCreateMutex();
    static String authHeader = String("Authorization: Bearer ") + COMPANION_DEVICE_TOKEN;
    s_webSocket.setExtraHeaders(authHeader.c_str());
    s_webSocket.onEvent(webSocketEvent);
    s_webSocket.setReconnectInterval(5000);

#if COMPANION_USE_TLS
    s_webSocket.beginSSL(COMPANION_SERVER_HOST, COMPANION_SERVER_PORT,
                         COMPANION_SERVER_WS_PATH);
#else
    s_webSocket.begin(COMPANION_SERVER_HOST, COMPANION_SERVER_PORT,
                      COMPANION_SERVER_WS_PATH);
#endif
    Serial.printf("[WS] connecting to %s:%d%s\n", COMPANION_SERVER_HOST,
                  COMPANION_SERVER_PORT, COMPANION_SERVER_WS_PATH);
}

void micServerUploadLoop() { s_webSocket.loop(); }

bool micServerUploadIsReady() {
    return s_sessionReady && s_webSocket.isConnected();
}

bool micServerUploadSend(const uint8_t *pcm, size_t bytes) {
    if (pcm == nullptr || bytes < sizeof(int16_t)) {
        Serial.println("[MIC UPLOAD] nothing to send");
        return false;
    }
    if (!micServerUploadIsReady()) {
        Serial.println("[MIC UPLOAD] server not ready — wait for session.ready");
        return false;
    }

    sendText(protocolBuildAudioStart());

    size_t offset = 0;
    uint32_t frames = 0;
    while (offset < bytes) {
        size_t chunk = bytes - offset;
        if (chunk > COMPANION_UPLINK_FRAME_BYTES) {
            chunk = COMPANION_UPLINK_FRAME_BYTES;
        }
        sendBinary(pcm + offset, chunk);
        frames++;
        offset += chunk;
        delay(COMPANION_FRAME_MS);
    }

    sendText(protocolBuildAudioStop());
    Serial.printf(
        "[MIC UPLOAD] sent %lu frames (%u bytes) — check Mac debug-audio/*-uplink.wav\n",
        static_cast<unsigned long>(frames), static_cast<unsigned>(bytes));
    return true;
}

#else

void micServerUploadBegin() {}
void micServerUploadLoop() {}
bool micServerUploadIsReady() { return false; }
bool micServerUploadSend(const uint8_t *, size_t) { return false; }

#endif
