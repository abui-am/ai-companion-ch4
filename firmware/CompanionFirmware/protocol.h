#pragma once

#include <Arduino.h>

// Stable wire protocol version — see docs/STABLE_V1.md.
#define COMPANION_PROTOCOL_VERSION "v1"

// Mirrors CompanionServer/Sources/CompanionServer/WireProtocol.swift.
// Audio is sent as raw 16-bit PCM, mono, little-endian — labeled "opus" in
// session.start for forward compatibility, but matching the server's current
// OpusCodec placeholder, which does not actually decode Opus yet.
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
    PROTO_MSG_TRANSCRIPT_FINAL,
    PROTO_MSG_DEVICE_COMMAND,
    PROTO_MSG_TTS_START,
    PROTO_MSG_TTS_END,
    PROTO_MSG_ERROR,
    PROTO_MSG_LATENCY_REPORT,
};

struct ProtoMsg {
    ProtoMsgType type = PROTO_MSG_UNKNOWN;
    String sessionId;
    String text;
    String action;
    String errorCode;
    String errorMessage;
};

// Parses an inbound text frame into out. Unrecognized/malformed JSON yields
// PROTO_MSG_UNKNOWN rather than an error — the firmware ignores what it
// doesn't understand instead of crashing on a protocol it can't parse.
void protocolParse(const uint8_t *data, size_t len, ProtoMsg &out);

String protocolBuildSessionStart();
String protocolBuildAudioStart();
String protocolBuildAudioStop();
String protocolBuildAbort(const String &sessionId, const String &reason);
