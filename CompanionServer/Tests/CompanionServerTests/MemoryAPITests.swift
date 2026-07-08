import CompanionDatabase
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdCore
import HummingbirdTesting
import Logging
import NIOCore
import XCTest

@testable import CompanionServer

private struct APIMemory: Decodable, Equatable {
    let id: String
    let content: String
    let source: String
    let createdAt: Date
}

private struct APIMemoriesResponse: Decodable {
    let memories: [APIMemory]
}

private struct APIStructuredToolCall: Decodable {
    let id: String
    let tool: String
    let action: String?
    let label: String
    let status: String
    let summary: String?
}

private struct APIConversationTurn: Decodable {
    let turnId: String
    let toolCalls: [APIStructuredToolCall]
}

private struct APIConversationHistoryResponse: Decodable {
    let sessionId: String
    let turns: [APIConversationTurn]
}

private final class MemoryAPITestHarness {
    let database: DatabaseService
    let memories: MemoryRepository
    let config: ConfigRepository
    let conversations: ConversationRepository
    let audioStore: ConversationAudioStore
    let audioRootDirectory: URL
    let deviceToken = "memory-test-token"
    let logger: Logger
    var createdMemoryIDs: [String] = []
    var createdSessionIDs: [String] = []

    init(
        database: DatabaseService,
        memories: MemoryRepository,
        config: ConfigRepository,
        conversations: ConversationRepository,
        audioStore: ConversationAudioStore,
        audioRootDirectory: URL,
        logger: Logger
    ) {
        self.database = database
        self.memories = memories
        self.config = config
        self.conversations = conversations
        self.audioStore = audioStore
        self.audioRootDirectory = audioRootDirectory
        self.logger = logger
    }

    static func make() async throws -> MemoryAPITestHarness? {
        let logger = Logger(label: "MemoryAPITests")
        let databaseURL = ProcessInfo.processInfo.environment["DATABASE_URL"]
            ?? "postgres://postgres:postgres@localhost:5432/companion"
        let settings = try DatabaseSettings(urlString: databaseURL)
        let database = DatabaseService(settings: settings, logger: logger)
        await database.start()
        do {
            try await database.ping()
        } catch {
            await database.shutdown()
            return nil
        }
        do {
            try await database.enableVectorExtension()
        } catch {
            // pgvector not installed on this Postgres (e.g. plain postgres:17-alpine volume
            // left over from before this feature) — skip rather than fail the suite.
            await database.shutdown()
            return nil
        }
        let memories = MemoryRepository(database: database, logger: logger)
        try await memories.migrate()
        let config = ConfigRepository(database: database, logger: logger)
        try await config.migrate()
        let conversations = ConversationRepository(database: database, logger: logger)
        try await conversations.migrate()

        let audioRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-api-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        let audioStore = ConversationAudioStore(rootDirectory: audioRoot, logger: logger)

        return MemoryAPITestHarness(
            database: database,
            memories: memories,
            config: config,
            conversations: conversations,
            audioStore: audioStore,
            audioRootDirectory: audioRoot,
            logger: logger
        )
    }

    func makeApp() -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        MemoryRoutes.register(on: router, memories: memories, config: config, deviceToken: deviceToken, logger: logger)
        ConversationRoutes.register(
            on: router,
            conversations: conversations,
            audioStore: audioStore,
            deviceToken: deviceToken,
            logger: logger
        )
        return Application(responder: router.buildResponder())
    }

    func authHeaders() -> HTTPFields {
        [.authorization: bearerValue()]
    }

    func wrongAuthHeaders() -> HTTPFields {
        [.authorization: "Bearer wrong-token"]
    }

    func bearerValue() -> String {
        "Bearer \(deviceToken)"
    }

    func trackCreatedMemory(id: String) {
        createdMemoryIDs.append(id)
    }

    func setPersonalization(_ enabled: Bool) async throws {
        _ = try await config.update(ConfigPatch(personalizationData: enabled))
    }

    @discardableResult
    func seedToolCall(
        sessionId: String,
        turnId: String = "turn-1",
        arguments: String,
        output: String
    ) async throws -> String {
        try await conversations.ensureSession(id: sessionId)
        createdSessionIDs.append(sessionId)
        let id = ConversationToolCallBuilder.makeId()
        try await conversations.appendToolCall(
            id: id,
            sessionId: sessionId,
            turnId: turnId,
            name: "memory",
            detail: ConversationToolCallBuilder.label(name: "memory", argumentsJSON: arguments),
            arguments: arguments,
            output: output,
            createdAt: Date()
        )
        return id
    }

    func cleanup() async {
        for id in createdMemoryIDs {
            try? await memories.delete(id: id)
        }
        createdMemoryIDs.removeAll()
        for id in createdSessionIDs {
            try? await conversations.deleteSession(id: id)
        }
        createdSessionIDs.removeAll()
        try? await setPersonalization(true)
        await database.shutdown()
        try? FileManager.default.removeItem(at: audioRootDirectory)
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// A deterministic 1536-dim unit vector with `1.0` at `index` and `0` elsewhere — two
    /// vectors at different indices are orthogonal (cosine distance `1.0`), so repository
    /// tests never need to call the live OpenAI Embeddings API.
    static func unitVector(at index: Int) -> [Float] {
        var vector = [Float](repeating: 0, count: MemoryVector.dimensions)
        vector[index] = 1
        return vector
    }

    /// A vector very close to `unitVector(at: index)` (cosine distance well under the dedup
    /// threshold) but not bit-identical — simulates a rephrased near-duplicate fact.
    static func nearDuplicateVector(at index: Int) -> [Float] {
        var vector = unitVector(at: index)
        vector[index] = 0.999
        vector[(index + 1) % MemoryVector.dimensions] = 0.045
        return vector
    }
}

final class MemoryAPITests: XCTestCase {
    private var harness: MemoryAPITestHarness!

    override func setUp() async throws {
        guard let harness = try await MemoryAPITestHarness.make() else {
            throw XCTSkip("Postgres with pgvector not available — start with docker-compose up -d")
        }
        self.harness = harness
    }

    override func tearDown() async throws {
        await harness?.cleanup()
        harness = nil
    }

    // MARK: - Repository

    func testInsertAndSearchWithFixedVectors() async throws {
        let dog = try await harness.memories.insert(
            content: "User's dog is named Max",
            embedding: MemoryAPITestHarness.unitVector(at: 0)
        )
        harness.trackCreatedMemory(id: dog.id)
        let coffee = try await harness.memories.insert(
            content: "User drinks coffee black",
            embedding: MemoryAPITestHarness.unitVector(at: 1)
        )
        harness.trackCreatedMemory(id: coffee.id)

        let results = try await harness.memories.search(
            embedding: MemoryAPITestHarness.unitVector(at: 0),
            limit: 5,
            maxDistance: 0.35
        )

        XCTAssertEqual(results.map(\.id), [dog.id])
        XCTAssertEqual(results.first?.content, "User's dog is named Max")
    }

    func testSearchDropsMatchesBeyondThreshold() async throws {
        let record = try await harness.memories.insert(
            content: "User's dog is named Max",
            embedding: MemoryAPITestHarness.unitVector(at: 0)
        )
        harness.trackCreatedMemory(id: record.id)

        let results = try await harness.memories.search(
            embedding: MemoryAPITestHarness.unitVector(at: 1),
            limit: 5,
            maxDistance: 0.35
        )

        XCTAssertTrue(results.isEmpty)
    }

    func testFindDuplicateDetectsNearIdenticalEmbedding() async throws {
        let record = try await harness.memories.insert(
            content: "User's dog is named Max",
            embedding: MemoryAPITestHarness.unitVector(at: 0)
        )
        harness.trackCreatedMemory(id: record.id)

        let duplicate = try await harness.memories.findDuplicate(
            embedding: MemoryAPITestHarness.nearDuplicateVector(at: 0),
            maxDistance: 0.08
        )

        XCTAssertEqual(duplicate?.id, record.id)
    }

    func testFindDuplicateIgnoresUnrelatedEmbedding() async throws {
        let record = try await harness.memories.insert(
            content: "User's dog is named Max",
            embedding: MemoryAPITestHarness.unitVector(at: 0)
        )
        harness.trackCreatedMemory(id: record.id)

        let duplicate = try await harness.memories.findDuplicate(
            embedding: MemoryAPITestHarness.unitVector(at: 1),
            maxDistance: 0.08
        )

        XCTAssertNil(duplicate)
    }

    func testUpdateOnDedupHitReplacesContentWithoutInsertingNewRow() async throws {
        let record = try await harness.memories.insert(
            content: "User's dog is named Max",
            embedding: MemoryAPITestHarness.unitVector(at: 0)
        )
        harness.trackCreatedMemory(id: record.id)

        let updated = try await harness.memories.update(
            id: record.id,
            content: "User's dog, Max, is a golden retriever",
            embedding: MemoryAPITestHarness.nearDuplicateVector(at: 0)
        )

        XCTAssertEqual(updated.id, record.id)
        XCTAssertEqual(updated.content, "User's dog, Max, is a golden retriever")

        let all = try await harness.memories.list(limit: 100)
        XCTAssertEqual(all.filter { $0.id == record.id }.count, 1)
    }

    func testDeleteBestMatchRemovesClosestMatchAboveThreshold() async throws {
        let record = try await harness.memories.insert(
            content: "User's dog is named Max",
            embedding: MemoryAPITestHarness.unitVector(at: 0)
        )
        harness.trackCreatedMemory(id: record.id)

        let deleted = try await harness.memories.deleteBestMatch(
            embedding: MemoryAPITestHarness.unitVector(at: 0),
            maxDistance: 0.35
        )

        XCTAssertEqual(deleted?.id, record.id)
        let remaining = try await harness.memories.list(limit: 100)
        XCTAssertFalse(remaining.contains(where: { $0.id == record.id }))
    }

    func testDeleteBestMatchReturnsNilWhenNothingMatches() async throws {
        let record = try await harness.memories.insert(
            content: "User's dog is named Max",
            embedding: MemoryAPITestHarness.unitVector(at: 0)
        )
        harness.trackCreatedMemory(id: record.id)

        let deleted = try await harness.memories.deleteBestMatch(
            embedding: MemoryAPITestHarness.unitVector(at: 1),
            maxDistance: 0.35
        )

        XCTAssertNil(deleted)
    }

    func testListOrdersMostRecentFirst() async throws {
        let older = try await harness.memories.insert(
            content: "Older fact",
            embedding: MemoryAPITestHarness.unitVector(at: 0)
        )
        harness.trackCreatedMemory(id: older.id)
        let newer = try await harness.memories.insert(
            content: "Newer fact",
            embedding: MemoryAPITestHarness.unitVector(at: 1)
        )
        harness.trackCreatedMemory(id: newer.id)

        let all = try await harness.memories.list(limit: 100)
        let olderIndex = try XCTUnwrap(all.firstIndex(where: { $0.id == older.id }))
        let newerIndex = try XCTUnwrap(all.firstIndex(where: { $0.id == newer.id }))
        XCTAssertLessThan(newerIndex, olderIndex)
    }

    // MARK: - MemoryAgent privacy gate

    func testAgentReturnsErrorWhenPersonalizationDisabled() async throws {
        try await harness.setPersonalization(false)
        let agent = MemoryAgent(
            memories: harness.memories,
            embeddings: OpenAIEmbeddingService(apiKey: "unused", model: "unused", logger: harness.logger),
            config: harness.config,
            logger: harness.logger
        )

        let output = await agent.execute(argumentsJSON: #"{"action":"list"}"#)

        XCTAssertTrue(output.contains("Memory is off"))
    }

    func testAgentAllowsListWhenPersonalizationEnabled() async throws {
        try await harness.setPersonalization(true)
        let record = try await harness.memories.insert(
            content: "User's dog is named Max",
            embedding: MemoryAPITestHarness.unitVector(at: 0)
        )
        harness.trackCreatedMemory(id: record.id)
        let agent = MemoryAgent(
            memories: harness.memories,
            embeddings: OpenAIEmbeddingService(apiKey: "unused", model: "unused", logger: harness.logger),
            config: harness.config,
            logger: harness.logger
        )

        let output = await agent.execute(argumentsJSON: #"{"action":"list"}"#)

        XCTAssertTrue(output.contains(record.id))
        XCTAssertTrue(output.contains("User's dog is named Max"))
    }

    // MARK: - REST

    func testListMemoriesRequiresAuth() async throws {
        let app = harness.makeApp()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/memories", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testListMemoriesRejectsInvalidToken() async throws {
        let app = harness.makeApp()
        let headers = harness.wrongAuthHeaders()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/memories", method: .get, headers: headers) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testListMemoriesReturnsInsertedMemories() async throws {
        try await harness.setPersonalization(true)
        let record = try await harness.memories.insert(
            content: "User's dog is named Max",
            embedding: MemoryAPITestHarness.unitVector(at: 0)
        )
        harness.trackCreatedMemory(id: record.id)

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/memories", method: .get, headers: headers) { response in
                XCTAssertEqual(response.status, .ok)
                let body = try MemoryAPITestHarness.makeDecoder().decode(APIMemoriesResponse.self, from: response.body)
                XCTAssertTrue(body.memories.contains(where: { $0.id == record.id && $0.content == record.content }))
            }
        }
    }

    func testListMemoriesReturnsEmptyWhenPersonalizationDisabled() async throws {
        try await harness.setPersonalization(false)
        let record = try await harness.memories.insert(
            content: "User's dog is named Max",
            embedding: MemoryAPITestHarness.unitVector(at: 0)
        )
        harness.trackCreatedMemory(id: record.id)

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/memories", method: .get, headers: headers) { response in
                XCTAssertEqual(response.status, .ok)
                let body = try MemoryAPITestHarness.makeDecoder().decode(APIMemoriesResponse.self, from: response.body)
                XCTAssertTrue(body.memories.isEmpty)
            }
        }
    }

    func testDeleteMemory() async throws {
        let record = try await harness.memories.insert(
            content: "Delete me",
            embedding: MemoryAPITestHarness.unitVector(at: 0)
        )

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/memories/\(record.id)", method: .delete, headers: headers) { response in
                XCTAssertEqual(response.status, .noContent)
            }
        }

        let remaining = try await harness.memories.list(limit: 100)
        XCTAssertFalse(remaining.contains(where: { $0.id == record.id }))
    }

    func testDeleteMemoryNotFound() async throws {
        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/memories/mem_missing", method: .delete, headers: headers) { response in
                XCTAssertEqual(response.status, .notFound)
            }
        }
    }

    // MARK: - Tool call history integration

    func testMemoryToolCallAppearsInConversationHistoryWithLabelAndSummary() async throws {
        let sessionId = UUID().uuidString
        let arguments = #"{"action":"remember","content":"User's dog is named Max"}"#
        let output = #"{"summary":"Saved memory.","id":"mem_a1b2c3d4e5f6","content":"User's dog is named Max","updated":false}"#
        try await harness.seedToolCall(sessionId: sessionId, arguments: arguments, output: output)

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionId)/history",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let body = try MemoryAPITestHarness.makeDecoder().decode(
                    APIConversationHistoryResponse.self,
                    from: response.body
                )
                let call = try XCTUnwrap(body.turns.first?.toolCalls.first)
                XCTAssertEqual(call.tool, "memory")
                XCTAssertEqual(call.action, "remember")
                XCTAssertEqual(call.label, "remember: User's dog is named Max")
                XCTAssertEqual(call.status, "success")
                XCTAssertEqual(call.summary, "Saved memory.")
            }
        }
    }
}

/// Pure function tests for `ConversationToolCallBuilder.label` on the `memory` tool — no
/// database required.
final class MemoryToolCallLabelTests: XCTestCase {
    func testRememberLabelIncludesContent() {
        let label = ConversationToolCallBuilder.label(
            name: "memory",
            argumentsJSON: #"{"action":"remember","content":"User's dog is named Max"}"#
        )
        XCTAssertEqual(label, "remember: User's dog is named Max")
    }

    func testSearchLabelIncludesQuery() {
        let label = ConversationToolCallBuilder.label(
            name: "memory",
            argumentsJSON: #"{"action":"search","query":"dog's name"}"#
        )
        XCTAssertEqual(label, "search: dog's name")
    }

    func testForgetLabelPrefersQueryOverId() {
        let label = ConversationToolCallBuilder.label(
            name: "memory",
            argumentsJSON: #"{"action":"forget","query":"dog's name","id":"mem_abc"}"#
        )
        XCTAssertEqual(label, "forget: dog's name")
    }

    func testForgetLabelFallsBackToId() {
        let label = ConversationToolCallBuilder.label(
            name: "memory",
            argumentsJSON: #"{"action":"forget","id":"mem_abc"}"#
        )
        XCTAssertEqual(label, "forget: mem_abc")
    }

    func testListLabelIsBareAction() {
        let label = ConversationToolCallBuilder.label(name: "memory", argumentsJSON: #"{"action":"list"}"#)
        XCTAssertEqual(label, "list")
    }

    func testRememberLabelTruncatesLongContent() {
        let longContent = String(repeating: "a", count: 100)
        let label = ConversationToolCallBuilder.label(
            name: "memory",
            argumentsJSON: #"{"action":"remember","content":"\#(longContent)"}"#
        )
        XCTAssertTrue(label.hasPrefix("remember: "))
        XCTAssertTrue(label.hasSuffix("…"))
        XCTAssertLessThan(label.count, longContent.count)
    }
}
