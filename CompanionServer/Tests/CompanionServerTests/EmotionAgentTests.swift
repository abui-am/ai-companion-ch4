import Logging
import XCTest
@testable import CompanionServer

final class EmotionAgentTests: XCTestCase {
    func testToolDefinitionIncludesEmotions() {
        let gateway = DeviceCommandGateway(outbound: MockOutboundWriter(), logger: Logger(label: "test"))
        let agent = EmotionAgent(gateway: gateway, logger: Logger(label: "test"))
        let definition = agent.toolDefinition
        XCTAssertEqual(definition["name"] as? String, "emotion")
        let parameters = definition["parameters"] as? [String: Any]
        let properties = parameters?["properties"] as? [String: Any]
        let emotion = properties?["emotion"] as? [String: Any]
        let enumValues = emotion?["enum"] as? [String]
        XCTAssertTrue(enumValues?.contains("angry") == true)
        XCTAssertTrue(enumValues?.contains("excited") == true)
        XCTAssertTrue(enumValues?.contains("neutral") == true)
    }

    func testExecuteAngrySendsDeviceCommand() async {
        let outbound = MockOutboundWriter()
        let gateway = DeviceCommandGateway(outbound: outbound, logger: Logger(label: "test"))
        let agent = EmotionAgent(gateway: gateway, logger: Logger(label: "test"))

        let output = await agent.execute(argumentsJSON: #"{"emotion":"angry"}"#)
        XCTAssertTrue(output.contains("angry"))
        XCTAssertEqual(outbound.sentTexts.count, 1)
        XCTAssertTrue(outbound.sentTexts[0].contains(#""action":"emotion"#))
        XCTAssertTrue(outbound.sentTexts[0].contains(#""pattern":"angry"#))
    }

    func testExecuteUnknownEmotionRejected() async {
        let outbound = MockOutboundWriter()
        let gateway = DeviceCommandGateway(outbound: outbound, logger: Logger(label: "test"))
        let agent = EmotionAgent(gateway: gateway, logger: Logger(label: "test"))

        let output = await agent.execute(argumentsJSON: #"{"emotion":"grumpy"}"#)
        XCTAssertTrue(output.contains("unknown emotion"))
        XCTAssertEqual(outbound.sentTexts.count, 0)
    }
}

private final class MockOutboundWriter: SessionOutboundWriter, @unchecked Sendable {
    var sentTexts: [String] = []

    func writeText(_ text: String) async throws {
        sentTexts.append(text)
    }

    func writeBinary(_ data: Data) async throws {}
}
