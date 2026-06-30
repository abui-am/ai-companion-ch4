import Foundation

enum AllowedAction: String {
    case setLed = "set_led"
}

enum ValidationError: Error, Equatable {
    case unknownAction
    case outOfRange
}

enum CmdRouter {
    static func validate(_ cmd: DeviceCommand) throws -> DeviceCommand {
        guard let action = AllowedAction(rawValue: cmd.action) else {
            throw ValidationError.unknownAction
        }
        switch action {
        case .setLed:
            guard (0...255).contains(cmd.params.r),
                  (0...255).contains(cmd.params.g),
                  (0...255).contains(cmd.params.b)
            else {
                throw ValidationError.outOfRange
            }
        }
        return cmd
    }
}
