import Foundation
import Logging

/// Sub-agent for gentle desk-area wheel motion. Sends validated `device_command`
/// messages to the ESP32 firmware (DRV8833 motor driver).
struct MotionAgent: SubAgent, Sendable {
    let name = "move"

    private static let allowedActions: Set<String> = [
        "stroll", "forward", "backward", "turn_left", "turn_right", "stop",
    ]

    private let gateway: DeviceCommandGateway
    private let logger: Logger

    init(gateway: DeviceCommandGateway, logger: Logger) {
        self.gateway = gateway
        self.logger = logger
    }

    var toolDefinition: [String: Any] {
        [
            "type": "function",
            "name": name,
            "description": """
            Move this physical desk robot's wheels — slow, gentle motion only. \
            **Required** whenever the user wants the bot to move; speech alone does not move the hardware.

            Trigger on: move, stroll, wander, walk/roll/drive/go/throw around (the desk/deck), \
            turn around, come closer, back up, explore the desk, stop moving.

            Speech-to-text often mishears — "throw around the deck" usually means stroll on the desk.

            Actions:
            - stroll: short wander — forward a bit, turn, repeat (default for "walk/throw/stroll around")
            - forward / backward: one short gentle bump
            - turn_left / turn_right: pivot in place
            - stop: halt wheels immediately

            Call this tool before confirming movement in speech. Optional duration_ms (50–2000) for \
            single moves; omit for stroll/stop.
            """,
            "parameters": [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": Array(Self.allowedActions).sorted(),
                        "description": "Movement pattern to run on the device.",
                    ] as [String: Any],
                    "duration_ms": [
                        "type": "integer",
                        "description": "Optional duration for forward/back/turn moves (50–2000 ms).",
                    ] as [String: Any],
                ],
                "required": ["action"],
            ] as [String: Any],
        ]
    }

    func execute(argumentsJSON: String) async -> String {
        guard let args = SubAgentJSON.parseArguments(argumentsJSON) else {
            return SubAgentJSON.encodeError("invalid arguments JSON")
        }
        guard let action = args["action"] as? String else {
            return SubAgentJSON.encodeError("missing action")
        }
        guard Self.allowedActions.contains(action) else {
            return SubAgentJSON.encodeError("unknown action: \(action)")
        }

        let durationMs = args["duration_ms"] as? Int
        logger.info(
            "move tool invoked",
            metadata: [
                "action": .string(action),
                "duration_ms": .string(durationMs.map { "\($0)" } ?? "default"),
                "arguments": .string(argumentsJSON),
            ]
        )

        let cmd = DeviceCommand(
            action: "move",
            params: LEDParams(pattern: action, durationMs: durationMs)
        )

        if let error = await gateway.send(cmd) {
            logger.warning("move tool failed", metadata: ["error": .string(error)])
            return SubAgentJSON.encodeError(error)
        }

        let summary: String = switch action {
        case "stroll": "Strolling around the desk."
        case "stop": "Stopped."
        case "forward": "Moved forward gently."
        case "backward": "Moved backward gently."
        case "turn_left": "Turned left."
        case "turn_right": "Turned right."
        default: "Moving."
        }
        return SubAgentJSON.encode(["summary": summary])
    }
}
