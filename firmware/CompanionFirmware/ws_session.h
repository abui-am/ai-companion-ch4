#pragma once

// Connects to CompanionServer over WS (bearer-token authed), wires up the
// touch sensor and I2S audio I/O, and runs the session state machine. No
// wake word: one tap starts a conversation, then it's hands-free — silence
// after speech ends the turn and hands it to the AI, and the device starts
// listening again the instant the AI finishes replying. A tap at any point
// ends the conversation immediately (including mid AI-reply). Call
// wsSessionBegin() once from setup(), then wsSessionLoop() from every
// Arduino loop() iteration (required by the WebSockets library to process
// incoming data and reconnects).
//
// Disconnect policy mirrors the server: on any WS close, local state resets
// to idle and any pending playback is discarded. On reconnect the server
// always issues a fresh session_id — there is no resume.
void wsSessionBegin();
void wsSessionLoop();
