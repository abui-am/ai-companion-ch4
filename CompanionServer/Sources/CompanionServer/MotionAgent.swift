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
            Move the companion robot on its desk — slow, gentle wheel motion only.

            Use when the user asks the bot to move, stroll, wander, turn around, come closer, \
            or explore the desk area. Keep movements small — the robot stays on a desk and must \
            not drive fast or off the edge.

            Actions:
            - stroll: short wander — forward a bit, turn, repeat (best for "walk around")
            - forward / backward: one short gentle bump
            - turn_left / turn_right: pivot in place (~quarter turn)
            - stop: stop wheels immediately

            Optional duration_ms (50–2000) for single moves — omit for stroll/stop defaults.
            After the tool returns, give a brief playful spoken reaction; do not describe PWM \
            or motor details.
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
