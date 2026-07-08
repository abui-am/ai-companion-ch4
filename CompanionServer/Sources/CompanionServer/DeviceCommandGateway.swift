import Foundation
import Logging

/// Validates and forwards whitelisted `device_command` messages to the ESP32.
struct DeviceCommandGateway: Sendable {
    private let outbound: SessionOutboundWriter
    private let logger: Logger

    init(outbound: SessionOutboundWriter, logger: Logger) {
        self.outbound = outbound
        self.logger = logger
    }

    /// Returns an error message on failure, or `nil` when the command was sent.
    func send(_ cmd: DeviceCommand) async -> String? {
        do {
            let validated = try CmdRouter.validate(cmd)
            let data = try JSONEncoder().encode(validated)
            let text = String(decoding: data, as: UTF8.self)
            try await outbound.writeText(text)
            logger.info(
                "device command sent",
                metadata: [
                    "action": .string(validated.action),
                    "pattern": .string(validated.params.pattern ?? ""),
                ]
            )
            return nil
        } catch let error as ValidationError {
            logger.warning("device command rejected", metadata: ["error": .string("\(error)")])
            return error.description
        } catch {
            logger.warning("device command send failed", metadata: ["error": .string("\(error)")])
            return "\(error)"
        }
    }
}

private extension ValidationError {
    var description: String {
        switch self {
        case .unknownAction:
            "unknown device action"
        case .outOfRange:
            "device command params out of range"
        case .missingField(let field):
            "device command missing \(field)"
        }
    }
}
