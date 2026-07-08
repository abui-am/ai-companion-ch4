import Foundation

enum AllowedAction: String {
    case setLed = "set_led"
    case move = "move"
}

enum ValidationError: Error, Equatable {
    case unknownAction
    case outOfRange
    case missingField(String)
}

enum CmdRouter {
    private static let movePatterns: Set<String> = [
        "stroll", "forward", "backward", "turn_left", "turn_right", "stop",
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
                guard (50 ... 2000).contains(durationMs) else {
                    throw ValidationError.outOfRange
                }
            }
        }
        return cmd
    }
}
