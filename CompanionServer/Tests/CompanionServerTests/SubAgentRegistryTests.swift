import XCTest
@testable import CompanionServer

private struct MockSubAgent: SubAgent {
    let name: String

    var toolDefinition: [String: Any] {
        [
            "type": "function",
            "name": name,
            "description": "Mock tool for \(name)",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any],
            ] as [String: Any],
        ]
    }

    init(name: String) {
        self.name = name
    }

    func execute(argumentsJSON: String) async -> String {
        "{\"result\":\"\(name)\"}"
    }
}

final class SubAgentRegistryTests: XCTestCase {
    func testToolDefinitionsAggregatesRegisteredAgents() {
        let registry = SubAgentRegistry(agents: [
            MockSubAgent(name: "web_search"),
            MockSubAgent(name: "weather"),
        ])

        XCTAssertFalse(registry.isEmpty)
        XCTAssertEqual(registry.toolDefinitions.count, 2)

        let names = Set(registry.toolDefinitions.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, ["web_search", "weather"])
    }

    func testAgentNamedReturnsRegisteredAgent() {
        let registry = SubAgentRegistry(agents: [MockSubAgent(name: "web_search")])

        XCTAssertNotNil(registry.agent(named: "web_search"))
        XCTAssertNil(registry.agent(named: "unknown"))
    }

    func testEmptyRegistryHasNoTools() {
        let registry = SubAgentRegistry(agents: [])

        XCTAssertTrue(registry.isEmpty)
        XCTAssertTrue(registry.toolDefinitions.isEmpty)
        XCTAssertNil(registry.agent(named: "web_search"))
    }
}
