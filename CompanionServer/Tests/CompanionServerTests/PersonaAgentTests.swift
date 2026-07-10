import Logging
import XCTest
@testable import CompanionServer

final class PersonaAgentTests: XCTestCase {
    private var tempDir: URL!
    private var store: PersonaStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("persona-tests-\(UUID().uuidString)", isDirectory: true)
        store = PersonaStore(directory: tempDir, logger: Logger(label: "test"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Name resolution (STT-noise tolerant)

    func testResolveExactAndCaseInsensitive() {
        let available = ["grumpy", "pirate", "minion"]
        XCTAssertEqual(PersonaAgent.resolve("grumpy", in: available), "grumpy")
        XCTAssertEqual(PersonaAgent.resolve("Pirate", in: available), "pirate")
        XCTAssertEqual(PersonaAgent.resolve("MINION", in: available), "minion")
    }

    func testResolvePrefixAndEmbeddedMatches() {
        let available = ["grumpy", "pirate", "detective"]
        XCTAssertEqual(PersonaAgent.resolve("grump", in: available), "grumpy")
        XCTAssertEqual(PersonaAgent.resolve("the pirate", in: available), "pirate")
        XCTAssertEqual(PersonaAgent.resolve("detective marlowe", in: available), "detective")
    }

    func testResolveRejectsUnknownAndAmbiguous() {
        XCTAssertNil(PersonaAgent.resolve("ninja", in: ["grumpy", "pirate"]))
        XCTAssertNil(PersonaAgent.resolve("p", in: ["pirate", "professor"]))
        XCTAssertNil(PersonaAgent.resolve("", in: ["pirate"]))
    }

    // MARK: - Tool execution against a real store

    func testExecuteSetActivatesPersona() async throws {
        try await store.save(name: "pirate", content: "# Pirate\nBe a pirate.")
        let agent = PersonaAgent(personas: store, logger: Logger(label: "test"))

        let output = await agent.execute(argumentsJSON: #"{"action":"set","name":"the pirate"}"#)
        XCTAssertTrue(output.contains("switched to pirate"), output)
        let active = await store.activeName()
        XCTAssertEqual(active, "pirate")
    }

    func testExecuteSetUnknownReturnsAvailableList() async throws {
        try await store.save(name: "pirate", content: "# Pirate\nBe a pirate.")
        let agent = PersonaAgent(personas: store, logger: Logger(label: "test"))

        let output = await agent.execute(argumentsJSON: #"{"action":"set","name":"ninja"}"#)
        XCTAssertTrue(output.contains("unknown persona"), output)
        XCTAssertTrue(output.contains("pirate"), output)
    }

    func testExecuteClearResetsActive() async throws {
        try await store.save(name: "pirate", content: "# Pirate\nBe a pirate.")
        try await store.setActive("pirate")
        let agent = PersonaAgent(personas: store, logger: Logger(label: "test"))

        let output = await agent.execute(argumentsJSON: #"{"action":"clear"}"#)
        XCTAssertTrue(output.contains("cleared"), output)
        let active = await store.activeName()
        XCTAssertNil(active)
    }

    func testExecuteListNamesPersonas() async throws {
        try await store.save(name: "pirate", content: "# Pirate\nBe a pirate.")
        try await store.save(name: "wizard", content: "# Wizard\nBe a wizard.")
        let agent = PersonaAgent(personas: store, logger: Logger(label: "test"))

        let output = await agent.execute(argumentsJSON: #"{"action":"list"}"#)
        XCTAssertTrue(output.contains("pirate"), output)
        XCTAssertTrue(output.contains("wizard"), output)
    }

    // MARK: - Store CRUD (backs the Mac app endpoints)

    func testSaveCreatesReadableInstruction() async throws {
        try await store.save(name: "custom", content: "# Custom\nBe custom.")
        let instruction = await store.instruction(for: "custom")
        XCTAssertEqual(instruction, "# Custom\nBe custom.")
        let available = await store.available()
        XCTAssertEqual(available, ["custom"])
    }

    func testSaveRejectsInvalidNameAndEmptyContent() async {
        do {
            try await store.save(name: "../evil", content: "x")
            XCTFail("expected invalidName")
        } catch let error as PersonaError {
            XCTAssertTrue(error.description.contains("Invalid persona name"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        do {
            try await store.save(name: "ok", content: "   \n  ")
            XCTFail("expected emptyContent")
        } catch let error as PersonaError {
            XCTAssertTrue(error.description.contains("must not be empty"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testDeleteRemovesAndClearsActive() async throws {
        try await store.save(name: "pirate", content: "# Pirate\nBe a pirate.")
        try await store.setActive("pirate")
        try await store.delete(name: "pirate")

        let available = await store.available()
        XCTAssertTrue(available.isEmpty)
        let active = await store.activeName()
        XCTAssertNil(active)
    }

    func testDeleteUnknownThrows() async {
        do {
            try await store.delete(name: "ghost")
            XCTFail("expected unknownPersona")
        } catch let error as PersonaError {
            XCTAssertTrue(error.description.contains("Unknown persona"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
