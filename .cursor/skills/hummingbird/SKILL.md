---
name: hummingbird
description: Build Swift WebSocket and HTTP servers with Hummingbird 2 and HummingbirdWebSocket. Use when implementing CompanionServer, WSS voice pipelines, JSON+binary frame routing, auth middleware, or when the user mentions Hummingbird, Swift on server, or esp32 voice backend.
---

# Hummingbird (Swift Server)

## When to use

- **CompanionServer** backend: WSS gateway for ESP32 / TestClient
- JSON control events + binary Opus audio on one WebSocket
- macOS demo: `swift run CompanionServer`

**Do not use** Apple's `Network` framework for the WSS server — use HummingbirdWebSocket. `Network` is optional later for Bonjour discovery only.

## Package setup

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CompanionServer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CompanionServer", targets: ["CompanionServer"]),
        .executable(name: "TestClient", targets: ["TestClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "CompanionServer",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ]
)
```

## Minimal WebSocket server

Prefer **WebSocket router + middleware** (auth on upgrade) over raw closure upgrade.

```swift
import Hummingbird
import HummingbirdWebSocket
import Logging

@main
struct CompanionServerApp {
    static func main() async throws {
        var logger = Logger(label: "CompanionServer")
        logger.logLevel = .info

        let wsRouter = Router(context: BasicWebSocketRequestContext.self)
        wsRouter.ws("/ws") { request, context in
            guard bearerToken(from: request) != nil else { return .dontUpgrade }
            return .upgrade([:])
        } onUpgrade: { inbound, outbound, context in
            let handler = VoiceSessionHandler(outbound: outbound, logger: logger)
            for try await frame in inbound {
                try await handler.handle(frame)
            }
        }

        let router = Router()
        router.get("/health") { _, _ in "ok" }

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("0.0.0.0", port: 8080)),
            server: .http1WebSocketUpgrade(webSocketRouter: wsRouter)
        )
        try await app.runService()
    }

    static func bearerToken(from request: Request) -> String? {
        request.headers[.authorization]?.split(separator: " ").last.map(String.init)
    }
}
```

## Frame routing (JSON + Opus)

Companion wire protocol: **text = JSON events**, **binary = Opus audio**.

```swift
func handle(_ frame: WebSocketFrame) async throws {
    switch frame {
    case .text(let text):
        let event = try JSONDecoder().decode(IncomingMessage.self, from: Data(text.utf8))
        try await handleJSON(event)
    case .binary(let data):
        try await handleOpus(Array(data))
    case .close:
        break
    }
}
```

Send responses:

```swift
try await outbound.write(.text(jsonString))           // session.ready, tts.start, device_command
try await outbound.write(.binary(ByteBuffer(bytes: opusData)))  // TTS downlink
```

## Session handler pattern

One `actor` or class per WebSocket connection:

```
VoiceSessionHandler
├── sessionID: String?
├── opusBuffer: [Data]          // accumulate until audio.stop
├── handleJSON(IncomingMessage)
├── handleOpus(Data)
├── runPipeline() async         // ASR → LLM → TTS after audio.stop
└── sendDeviceCommand(action:params:)
```

Keep pipeline work off the frame loop — spawn `Task` for ASR/LLM/TTS so inbound frames are not blocked.

## Auth middleware

Check `Authorization: Bearer <token>` in `shouldUpgrade` — reject with `.dontUpgrade` before WebSocket opens.

For showcase, a static `JWT_SECRET` env var is enough. No Fluent/DB needed.

## Logging latency

Log stage timestamps with `swift-log` metadata:

```swift
logger.info("ttfa", metadata: ["ms": "\(elapsedMs)", "session": .string(sessionID)])
```

Stages: `audio.stop` → `asr.done` → `llm.first_token` → `tts.first_byte`.

## Project conventions (ai-companion-ch5)

| Topic | Choice |
|-------|--------|
| Server | Hummingbird 2 + HummingbirdWebSocket |
| Client (dev) | URLSessionWebSocketTask — not Hummingbird client |
| Port | 8080 default |
| Path | `/ws` |
| VAD | Skip on server for showcase — client sends `audio.stop` (push-to-talk) |
| xiaozhi | Do not implement xiaozhi protocol |

## Wire protocol events

**Inbound JSON:** `session.start`, `audio.start`, `audio.stop`, `abort`

**Outbound JSON:** `session.ready`, `transcript.final`, `device_command`, `tts.start`, `tts.end`, `error`

**Binary:** PCM16 mono LE — 16 kHz uplink / 24 kHz downlink, 60 ms frames, **no per-frame header** (wire protocol v1). Label in JSON is `"opus"` for forward compatibility; payload is raw PCM until libopus is linked.

Stable stack reference: [docs/STABLE_V1.md](../../../docs/STABLE_V1.md)

Full event shapes and lifecycle policies: [reference.md](reference.md)

## Session lifecycle (required)

- **Disconnect:** kill session, cancel pipeline `Task`, cancel OpenAI requests, discard unsent TTS
- **Reconnect:** fresh `session.start` — no resume
- **abort:** cancel pipeline + OpenAI streams; stop binary outbound; optional `tts.end`
- **Backpressure:** buffer Opus until `audio.stop`, cap ~500 frames, single Whisper call per turn
- **latency.report:** emit structured JSON per turn (see reference.md)

## Common mistakes

| Mistake | Fix |
|---------|-----|
| Blocking `onUpgrade` loop with slow OpenAI calls | `Task { await pipeline }` per turn |
| Keeping pipeline alive after WSS disconnect | Kill session actor, cancel tasks, discard TTS buffer |
| Trust-forward LLM `device_command` | Whitelist + bounds check in CmdRouter |
| Unbounded Opus frame buffer | Cap 500 frames; drop oldest; batch ASR on `audio.stop` only |
| Sending TTS only after full LLM response | Stream first sentence to TTS early |

## Verification

```bash
cd CompanionServer
swift build
swift run CompanionServer
# another terminal:
swift run TestClient
curl http://localhost:8080/health
```

## Additional resources

- Event schemas and pipeline sketch: [reference.md](reference.md)
- Official examples: [hummingbird-examples/websocket-echo](https://github.com/hummingbird-project/hummingbird-examples/tree/main/websocket-echo)
- Tutorial: [swiftonserver.com WebSockets](https://swiftonserver.com/websockets-tutorial-using-swift-and-hummingbird/)
