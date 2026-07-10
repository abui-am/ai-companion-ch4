import Foundation

enum AllowedAction: String {
    case setLed = "set_led"
    case move = "move"
    case emotion = "emotion"
}

enum ValidationError: Error, Equatable {
    case unknownAction
    case outOfRange
    case missingField(String)
}

enum CmdRouter {
    // Mirrors firmware motor_drive.cpp runPattern.
    private static let movePatterns: Set<String> = [
        "stroll", "forward", "backward", "turn_left", "turn_right", "stop",
        "spin_left", "spin_right", "circle", "wiggle", "dance",
    ]

    // Mirrors firmware face_display.cpp kEmotions.
    static let emotionPatterns: Set<String> = [
        "neutral", "happy", "excited", "angry", "sad",
        "surprised", "confused", "sleepy", "love",
    ]

    static func validate(_ cmd: DeviceCommand) throws -> DeviceCommand {
        guard let action = AllowedAction(rawValue: cmd.action) else {
            throw ValidationError.unknownAction
        }
        switch action {
        case .setLed:
            guard let r = cmd.params.r,
                  let g = cmd.params.g,
                  let b = cmd.params.b,
                  (0 ... 255).contains(r),
                  (0 ... 255).contains(g),
                  (0 ... 255).contains(b)
            else {
                throw ValidationError.outOfRange
            }
        case .move:
            guard let pattern = cmd.params.pattern, movePatterns.contains(pattern) else {
                throw ValidationError.outOfRange
            }
            if let durationMs = cmd.params.durationMs {
                // Spins/circles run longer than single bumps, hence 4000.
                guard (50 ... 4000).contains(durationMs) else {
                    throw ValidationError.outOfRange
                }
            }
        case .emotion:
            guard let pattern = cmd.params.pattern, emotionPatterns.contains(pattern) else {
                throw ValidationError.outOfRange
            }
            if let durationMs = cmd.params.durationMs {
                guard (1500 ... 60000).contains(durationMs) else {
                    throw ValidationError.outOfRange
                }
            }
        }
        return cmd
    }
}
