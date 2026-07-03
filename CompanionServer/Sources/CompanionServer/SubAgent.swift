import Foundation

/// A cheap text-only worker invoked by the Realtime orchestrator via function tools.
protocol SubAgent: Sendable {
    var name: String { get }
    var toolDefinition: [String: Any] { get }
    func execute(argumentsJSON: String) async -> String
}

/// Registry of sub-agents exposed as Realtime function tools.
struct SubAgentRegistry: Sendable {
    private let agentsByName: [String: any SubAgent]

    init(agents: [any SubAgent]) {
        agentsByName = Dictionary(uniqueKeysWithValues: agents.map { ($0.name, $0) })
    }

    var toolDefinitions: [[String: Any]] {
        agentsByName.values.map(\.toolDefinition)
    }

    var isEmpty: Bool {
        agentsByName.isEmpty
    }

    func agent(named name: String) -> (any SubAgent)? {
        agentsByName[name]
    }
}
