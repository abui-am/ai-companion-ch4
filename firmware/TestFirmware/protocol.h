#pragma once

#include <Arduino.h>

#define COMPANION_UPLINK_SAMPLE_RATE 16000
#define COMPANION_DOWNLINK_SAMPLE_RATE 24000
#define COMPANION_FRAME_MS 60
#define COMPANION_UPLINK_FRAME_BYTES \
    (COMPANION_UPLINK_SAMPLE_RATE / 1000 * COMPANION_FRAME_MS * 2)
#define COMPANION_DOWNLINK_FRAME_BYTES \
    (COMPANION_DOWNLINK_SAMPLE_RATE / 1000 * COMPANION_FRAME_MS * 2)

enum ProtoMsgType {
    PROTO_MSG_UNKNOWN = 0,
    PROTO_MSG_SESSION_READY,
    PROTO_MSG_SPEAKER_READY,
    PROTO_MSG_TTS_START,
    PROTO_MSG_TTS_END,
    PROTO_MSG_ERROR,
};

struct ProtoMsg {
    ProtoMsgType type = PROTO_MSG_UNKNOWN;
    String sessionId;
    String text;
    String action;
    String errorCode;
    String errorMessage;
};

void protocolParse(const uint8_t *data, size_t len, ProtoMsg &out);
String protocolBuildSessionStart();
String protocolBuildSessionStartDumpOnly();
String protocolBuildAudioStart();
String protocolBuildAudioStop();
