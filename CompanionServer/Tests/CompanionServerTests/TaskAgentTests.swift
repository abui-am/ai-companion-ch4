import CompanionDatabase
import Logging
import XCTest
@testable import CompanionServer

final class TaskAgentTests: XCTestCase {
    func testToolDefinitionIncludesRequiredActions() throws {
        let agent = try makeTaskAgent()
        let definition = agent.toolDefinition

        XCTAssertEqual(definition["name"] as? String, "tasks")
        XCTAssertEqual(definition["type"] as? String, "function")

        let parameters = definition["parameters"] as? [String: Any]
        let properties = parameters?["properties"] as? [String: Any]
        let action = properties?["action"] as? [String: Any]
        let enumValues = action?["enum"] as? [String]
        XCTAssertEqual(enumValues, ["list", "create", "update", "delete"])
    }

    func testExecuteRejectsMissingAction() async throws {
        let agent = try makeTaskAgent()
        let output = await agent.execute(argumentsJSON: #"{"title":"Buy milk"}"#)
        XCTAssertTrue(output.contains("missing action"))
    }

    func testExecuteRejectsInvalidJSON() async throws {
        let agent = try makeTaskAgent()
        let output = await agent.execute(argumentsJSON: "not-json")
        XCTAssertTrue(output.contains("invalid arguments JSON"))
    }

    private func makeTaskAgent() throws -> TaskAgent {
        let logger = Logger(label: "test")
        let settings = try DatabaseSettings(urlString: "postgres://postgres:postgres@127.0.0.1:1/none")
        let database = DatabaseService(settings: settings, logger: logger)
        return TaskAgent(tasks: TaskRepository(database: database, logger: logger), timeZoneIdentifier: "Asia/Jakarta", logger: logger)
    }
}

final class CalendarAgentTests: XCTestCase {
    func testToolDefinitionIncludesRequiredActions() throws {
        let agent = try makeCalendarAgent()
        let definition = agent.toolDefinition

        XCTAssertEqual(definition["name"] as? String, "calendar")

        let parameters = definition["parameters"] as? [String: Any]
        let properties = parameters?["properties"] as? [String: Any]
        let action = properties?["action"] as? [String: Any]
        let enumValues = action?["enum"] as? [String]
        XCTAssertEqual(enumValues, ["list", "create", "delete"])
    }

    func testExecuteRejectsMissingAction() async throws {
        let agent = try makeCalendarAgent()
        let output = await agent.execute(argumentsJSON: #"{"title":"Dentist"}"#)
        XCTAssertTrue(output.contains("missing action"))
    }

    private func makeCalendarAgent() throws -> CalendarAgent {
        let logger = Logger(label: "test")
        let settings = try DatabaseSettings(urlString: "postgres://postgres:postgres@127.0.0.1:1/none")
        let database = DatabaseService(settings: settings, logger: logger)
        return CalendarAgent(calendar: CalendarRepository(database: database, logger: logger), timeZoneIdentifier: "Asia/Jakarta", logger: logger)
    }
}
