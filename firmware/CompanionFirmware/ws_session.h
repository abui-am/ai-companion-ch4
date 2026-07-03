#pragma once

// Connects to CompanionServer over WS (bearer-token authed), wires up the
// push-to-talk button, on-device "hey_botchill" wake-word detection, and
// I2S audio I/O, and runs the session state machine. Call wsSessionBegin()
// once from setup(), then wsSessionLoop() from every Arduino loop()
// iteration (required by the WebSockets library to process incoming data
// and reconnects).
//
// Disconnect policy mirrors the server: on any WS close, local state resets
// to idle and any pending playback is discarded. On reconnect the server
// always issues a fresh session_id — there is no resume.
void wsSessionBegin();
void wsSessionLoop();
