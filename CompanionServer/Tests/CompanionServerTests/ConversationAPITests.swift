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

private struct APIConversationSession: Decodable {
    let id: String
    let startedAt: Date
    let endedAt: Date?
}

private struct APIConversationSessionsResponse: Decodable {
    let sessions: [APIConversationSession]
}

private struct APIConversationMessage: Decodable {
    let id: String
    let sessionId: String
    let turnId: String
    let role: String
    let content: String
    let audioUrl: String?
    let createdAt: Date
}

private struct APIConversationMessagesResponse: Decodable {
    let messages: [APIConversationMessage]
}

private final class ConversationAPITestHarness {
    let database: DatabaseService
    let conversations: ConversationRepository
    let audioStore: ConversationAudioStore
    let audioRootDirectory: URL
    let deviceToken = "conversation-test-token"
    let logger: Logger
    var createdSessionIDs: [String] = []

    init(
        database: DatabaseService,
        conversations: ConversationRepository,
        audioStore: ConversationAudioStore,
        audioRootDirectory: URL,
        logger: Logger
    ) {
        self.database = database
        self.conversations = conversations
        self.audioStore = audioStore
        self.audioRootDirectory = audioRootDirectory
        self.logger = logger
    }

    static func make() async throws -> ConversationAPITestHarness? {
        let logger = Logger(label: "ConversationAPITests")
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
        let conversations = ConversationRepository(database: database, logger: logger)
        try await conversations.migrate()

        let audioRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("conversation-audio-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        let audioStore = ConversationAudioStore(rootDirectory: audioRoot, logger: logger)

        return ConversationAPITestHarness(
            database: database,
            conversations: conversations,
            audioStore: audioStore,
            audioRootDirectory: audioRoot,
            logger: logger
        )
    }

    func makeApp() -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
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

    func trackCreatedSession(id: String) {
        createdSessionIDs.append(id)
    }

    /// Creates a session with one turn (user + assistant message) and returns the session ID.
    /// Pass `withAudio: true` to also write a fixture WAV via `audioStore`.
    func seedTurn(sessionId: String = UUID().uuidString, turnId: String = "turn-1", withAudio: Bool = false) async throws -> String {
        try await conversations.ensureSession(id: sessionId)
        trackCreatedSession(id: sessionId)
        let uplinkPath = withAudio
            ? audioStore.saveUplink(sessionId: sessionId, turnId: turnId, pcm: Data([0, 1, 2, 3]))
            : nil
        let downlinkPath = withAudio
            ? audioStore.saveDownlink(sessionId: sessionId, turnId: turnId, pcm: Data([4, 5, 6, 7]))
            : nil
        try await conversations.appendMessage(
            sessionId: sessionId,
            turnId: turnId,
            role: "user",
            content: "Hello there",
            audioPath: uplinkPath
        )
        try await conversations.appendMessage(
            sessionId: sessionId,
            turnId: turnId,
            role: "assistant",
            content: "Hi! How can I help?",
            audioPath: downlinkPath
        )
        return sessionId
    }

    func cleanup() async {
        for id in createdSessionIDs {
            try? await conversations.deleteSession(id: id)
        }
        createdSessionIDs.removeAll()
        await database.shutdown()
        try? FileManager.default.removeItem(at: audioRootDirectory)
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

final class ConversationAPITests: XCTestCase {
    private var harness: ConversationAPITestHarness!

    override func setUp() async throws {
        guard let harness = try await ConversationAPITestHarness.make() else {
            throw XCTSkip("Postgres not available — start with docker-compose up -d")
        }
        self.harness = harness
    }

    override func tearDown() async throws {
        await harness?.cleanup()
        harness = nil
    }

    func testListConversationsRequiresAuth() async throws {
        let app = harness.makeApp()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/conversations", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testListConversationsRejectsInvalidToken() async throws {
        let app = harness.makeApp()
        let headers = harness.wrongAuthHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testListConversationsReturnsSeededSession() async throws {
        let sessionId = try await harness.seedTurn()

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let body = try ConversationAPITestHarness.makeDecoder().decode(
                    APIConversationSessionsResponse.self,
                    from: response.body
                )
                XCTAssertTrue(body.sessions.contains(where: { $0.id == sessionId }))
            }
        }
    }

    func testGetSessionNotFound() async throws {
        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/session-does-not-exist",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .notFound)
            }
        }
    }

    func testListMessagesReturnsTranscriptWithoutAudioUrlWhenNoAudio() async throws {
        let sessionId = try await harness.seedTurn(withAudio: false)

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionId)/messages",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let body = try ConversationAPITestHarness.makeDecoder().decode(
                    APIConversationMessagesResponse.self,
                    from: response.body
                )
                XCTAssertEqual(body.messages.count, 2)
                XCTAssertEqual(body.messages.first?.role, "user")
                XCTAssertEqual(body.messages.first?.content, "Hello there")
                XCTAssertNil(body.messages.first?.audioUrl)
                XCTAssertEqual(body.messages.last?.role, "assistant")
            }
        }
    }

    func testListMessagesForUnknownSessionReturnsNotFound() async throws {
        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/session-does-not-exist/messages",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .notFound)
            }
        }
    }

    func testMessageWithAudioExposesAudioUrlAndDownloadReturnsWavBytes() async throws {
        let sessionId = try await harness.seedTurn(withAudio: true)

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        let audioUrl = try await app.test(.router) { client -> String in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionId)/messages",
                method: .get,
                headers: headers
            ) { response in
                let body = try ConversationAPITestHarness.makeDecoder().decode(
                    APIConversationMessagesResponse.self,
                    from: response.body
                )
                let userMessage = try XCTUnwrap(body.messages.first(where: { $0.role == "user" }))
                return try XCTUnwrap(userMessage.audioUrl)
            }
        }

        try await app.test(.router) { client in
            try await client.execute(uri: audioUrl, method: .get, headers: headers) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.contentType], "audio/wav")
                // WAV = 44-byte header + 4 bytes of fixture PCM.
                XCTAssertEqual(response.body.readableBytes, 48)
            }
        }
    }

    func testAudioEndpointReturnsNotFoundWhenMessageHasNoAudio() async throws {
        let sessionId = try await harness.seedTurn(withAudio: false)

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        let messageId = try await app.test(.router) { client -> String in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionId)/messages",
                method: .get,
                headers: headers
            ) { response in
                let body = try ConversationAPITestHarness.makeDecoder().decode(
                    APIConversationMessagesResponse.self,
                    from: response.body
                )
                let userMessage = try XCTUnwrap(body.messages.first(where: { $0.role == "user" }))
                return userMessage.id
            }
        }

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionId)/messages/\(messageId)/audio",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .notFound)
            }
        }
    }

    func testAudioEndpointRequiresAuth() async throws {
        let sessionId = try await harness.seedTurn(withAudio: true)
        let app = harness.makeApp()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionId)/messages/does-not-matter/audio",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }
}
