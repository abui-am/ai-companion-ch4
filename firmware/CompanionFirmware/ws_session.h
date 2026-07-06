#pragma once

// Connects to CompanionServer over WS (bearer-token authed), wires up the
// touch sensor and I2S audio I/O, and runs the session state machine.
// Stable interaction (v2): short tap to start / force end-of-turn, long press
// to end conversation, hands-free VAD turns in between — see docs/STABLE_V1.md
// § Client VAD. No on-device wake word.
// Call wsSessionBegin() once from setup(), then wsSessionLoop() from every
// Arduino loop() iteration (required by the WebSockets library to process
// incoming data and reconnects).
//
// Disconnect policy mirrors the server: on any WS close, local state resets
// to idle and any pending playback is discarded. On reconnect the server
// always issues a fresh session_id — there is no resume.
void wsSessionBegin();
void wsSessionLoop();
