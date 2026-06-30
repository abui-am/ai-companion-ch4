#pragma once

#include <stddef.h>
#include <stdint.h>

// Placeholder Opus<->PCM bridging — mirrors CompanionServer's OpusCodec.swift
// placeholder. Real Opus requires a libopus port for arduino-esp32; not
// wired up on either end yet, so frames travel as raw 16-bit PCM mono and
// the "opus" label in session.start is aspirational. Swap this file's
// implementation for real encode/decode once the server side is wired up —
// callers (audio_io, ws_session) don't need to change.

size_t pcmCodecEncodeUplinkFrame(const int16_t *pcmSamples, size_t sampleCount,
                                  uint8_t *out, size_t outCapacity);

size_t pcmCodecDecodeDownlinkFrame(const uint8_t *frame, size_t frameLen,
                                    int16_t *outSamples, size_t outCapacitySamples);
