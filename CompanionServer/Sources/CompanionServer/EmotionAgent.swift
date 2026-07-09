import Foundation
import Logging

/// Sub-agent that sets the robot's OLED facial expression. Sends validated
/// `device_command` messages to the ESP32 firmware (face_display.cpp), which
/// animates the eyes + a corner mark (anger vein, "!", "?", hearts, Zzz, ...)
/// and then decays back to the neutral session face.
struct EmotionAgent: SubAgent, Sendable {
    let name = "emotion"

    private static let allowedEmotions: Set<String> = [
        "neutral", "happy", "excited", "angry", "sad",
        "surprised", "confused", "sleepy", "love",
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
            Set this physical robot's facial expression on its OLED face — animated eyes \
            plus a comic-style corner mark (anger vein for angry, "!" for surprised, "?" \
            for confused, hearts for love, Zzz for sleepy, sparkles for excited).

            The face must match the dominant tone of what you are about to SAY. Exactly one \
            distinct use case each (first match wins): confused = you can't parse the turn; \
            sad = heavy moment or your reply discusses loss/disappointment; love = affection \
            aimed at or shared with you; surprised = expectation-breaking reveal of neutral or \
            unknown valence; excited = big positive (user's win, celebration, or clearly great \
            news); angry = playful mock outrage at a thing, never truly at the user; sleepy = \
            bedtime/tiredness context; happy = mild pleasant default; neutral = reset when the \
            shown expression no longer fits.

            Call it at the start of the turn so face and voice land together; at most one call \
            per turn; skip the call when the face already matches. The expression settles back \
            automatically — pass duration_ms only for a deliberately long hold. Fire-and-forget: \
            never announce or describe calling this tool; just keep talking naturally.
            """,
            "parameters": [
                "type": "object",
                "properties": [
                    "emotion": [
                        "type": "string",
                        "enum": Array(Self.allowedEmotions).sorted(),
                        "description": "Facial expression to show on the robot's face.",
                    ] as [String: Any],
                    "duration_ms": [
                        "type": "integer",
                        "description": "Optional hold time (1500–60000 ms) before the face settles back to neutral.",
                    ] as [String: Any],
                ],
                "required": ["emotion"],
            ] as [String: Any],
        ]
    }

    func execute(argumentsJSON: String) async -> String {
        guard let args = SubAgentJSON.parseArguments(argumentsJSON) else {
            return SubAgentJSON.encodeError("invalid arguments JSON")
        }
        guard let emotion = args["emotion"] as? String else {
            return SubAgentJSON.encodeError("missing emotion")
        }
        guard Self.allowedEmotions.contains(emotion) else {
            return SubAgentJSON.encodeError("unknown emotion: \(emotion)")
        }

        let durationMs = args["duration_ms"] as? Int
        logger.info(
            "emotion tool invoked",
            metadata: [
                "emotion": .string(emotion),
                "duration_ms": .string(durationMs.map { "\($0)" } ?? "default"),
            ]
        )

        let cmd = DeviceCommand(
            action: "emotion",
            params: LEDParams(pattern: emotion, durationMs: durationMs)
        )

        if let error = await gateway.send(cmd) {
            logger.warning("emotion tool failed", metadata: ["error": .string(error)])
            return SubAgentJSON.encodeError(error)
        }

        return SubAgentJSON.encode(["summary": "Face set to \(emotion)."])
    }
}
