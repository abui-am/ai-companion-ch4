import Logging
import XCTest
@testable import CompanionServer

final class MotionAgentTests: XCTestCase {
    func testToolDefinitionIncludesStrollAction() {
        let gateway = DeviceCommandGateway(outbound: MockOutboundWriter(), logger: Logger(label: "test"))
        let agent = MotionAgent(gateway: gateway, logger: Logger(label: "test"))
        let definition = agent.toolDefinition
        XCTAssertEqual(definition["name"] as? String, "move")
        let parameters = definition["parameters"] as? [String: Any]
        let properties = parameters?["properties"] as? [String: Any]
        let action = properties?["action"] as? [String: Any]
        let enumValues = action?["enum"] as? [String]
        XCTAssertTrue(enumValues?.contains("stroll") == true)
        XCTAssertTrue(enumValues?.contains("turn_left") == true)
    }

    func testExecuteStrollSendsDeviceCommand() async {
        let outbound = MockOutboundWriter()
        let gateway = DeviceCommandGateway(outbound: outbound, logger: Logger(label: "test"))
        let agent = MotionAgent(gateway: gateway, logger: Logger(label: "test"))

        let output = await agent.execute(argumentsJSON: #"{"action":"stroll"}"#)
        XCTAssertTrue(output.contains("Strolling"))
        XCTAssertEqual(outbound.sentTexts.count, 1)
        XCTAssertTrue(outbound.sentTexts[0].contains(#""action":"move"#))
        XCTAssertTrue(outbound.sentTexts[0].contains(#""pattern":"stroll"#))
    }
}

private final class MockOutboundWriter: SessionOutboundWriter, @unchecked Sendable {
    var sentTexts: [String] = []

    func writeText(_ text: String) async throws {
        sentTexts.append(text)
    }

    func writeBinary(_ data: Data) async throws {}
}
