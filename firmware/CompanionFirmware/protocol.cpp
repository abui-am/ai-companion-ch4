#include "protocol.h"

#include <ArduinoJson.h>

void protocolParse(const uint8_t *data, size_t len, ProtoMsg &out) {
    out = ProtoMsg();

    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, data, len);
    if (err) {
        return;
    }

    const char *type = doc["type"] | "";

    if (strcmp(type, "session.ready") == 0) {
        out.type = PROTO_MSG_SESSION_READY;
        out.sessionId = String((const char *)(doc["session_id"] | ""));
    } else if (strcmp(type, "transcript.final") == 0) {
        out.type = PROTO_MSG_TRANSCRIPT_FINAL;
        out.sessionId = String((const char *)(doc["session_id"] | ""));
        out.text = String((const char *)(doc["text"] | ""));
    } else if (strcmp(type, "device_command") == 0) {
        out.type = PROTO_MSG_DEVICE_COMMAND;
        out.action = String((const char *)(doc["action"] | ""));
    } else if (strcmp(type, "tts.start") == 0) {
        out.type = PROTO_MSG_TTS_START;
        out.sessionId = String((const char *)(doc["session_id"] | ""));
    } else if (strcmp(type, "tts.end") == 0) {
        out.type = PROTO_MSG_TTS_END;
        out.sessionId = String((const char *)(doc["session_id"] | ""));
    } else if (strcmp(type, "error") == 0) {
        out.type = PROTO_MSG_ERROR;
        out.errorCode = String((const char *)(doc["code"] | ""));
        out.errorMessage = String((const char *)(doc["message"] | ""));
    } else if (strcmp(type, "latency.report") == 0) {
        out.type = PROTO_MSG_LATENCY_REPORT;
    }
}

String protocolBuildSessionStart() {
    JsonDocument doc;
    doc["type"] = "session.start";
    JsonObject audio = doc["audio"].to<JsonObject>();
    audio["format"] = "opus";
    audio["sample_rate"] = COMPANION_UPLINK_SAMPLE_RATE;
    audio["frame_ms"] = COMPANION_FRAME_MS;
    String out;
    serializeJson(doc, out);
    return out;
}

String protocolBuildAudioStart() {
    return "{\"type\":\"audio.start\"}";
}

String protocolBuildAudioStop() {
    return "{\"type\":\"audio.stop\"}";
}

String protocolBuildAbort(const String &sessionId, const String &reason) {
    JsonDocument doc;
    doc["type"] = "abort";
    doc["session_id"] = sessionId;
    doc["reason"] = reason;
    String out;
    serializeJson(doc, out);
    return out;
}
