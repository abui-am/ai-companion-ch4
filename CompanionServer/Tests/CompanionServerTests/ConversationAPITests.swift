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
    let voiceCount: Int
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

private struct APIStructuredToolCall: Decodable {
    let id: String
    let tool: String
    let action: String?
    let label: String
    let status: String
    let input: [String: JSONValue]
    let output: [String: JSONValue]
    let summary: String?
    let createdAt: Date
}

private struct APIConversationTurnMessage: Decodable {
    let id: String
    let content: String
    let audioUrl: String?
    let createdAt: Date
}

private struct APIConversationTurn: Decodable {
    let turnId: String
    let user: APIConversationTurnMessage?
    let toolCalls: [APIStructuredToolCall]
    let assistant: APIConversationTurnMessage?
}

private struct APIConversationHistoryResponse: Decodable {
    let sessionId: String
    let turns: [APIConversationTurn]
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
        guard !createdSessionIDs.contains(id) else { return }
        createdSessionIDs.append(id)
    }

    /// Creates a bare session row (no messages) and tracks it for cleanup.
    @discardableResult
    func createSession(id: String = UUID().uuidString) async throws -> String {
        try await conversations.ensureSession(id: id)
        trackCreatedSession(id: id)
        return id
    }

    /// Appends one turn (user + assistant message) to `sessionId`, creating the session row
    /// first if it doesn't already exist. Returns the (userMessageId, assistantMessageId) pair.
    @discardableResult
    func seedTurn(
        sessionId: String,
        turnId: String = "turn-1",
        userContent: String = "Hello there",
        assistantContent: String = "Hi! How can I help?",
        withAudio: Bool = false
    ) async throws -> (userMessageId: String, assistantMessageId: String) {
        try await conversations.ensureSession(id: sessionId)
        trackCreatedSession(id: sessionId)
        let uplinkPath = withAudio
            ? audioStore.saveUplink(sessionId: sessionId, turnId: turnId, pcm: Data([0, 1, 2, 3]))
            : nil
        let downlinkPath = withAudio
            ? audioStore.saveDownlink(sessionId: sessionId, turnId: turnId, pcm: Data([4, 5, 6, 7]))
            : nil
        let userMessage = try await conversations.appendMessage(
            sessionId: sessionId,
            turnId: turnId,
            role: "user",
            content: userContent,
            audioPath: uplinkPath
        )
        let assistantMessage = try await conversations.appendMessage(
            sessionId: sessionId,
            turnId: turnId,
            role: "assistant",
            content: assistantContent,
            audioPath: downlinkPath
        )
        return (userMessage.id, assistantMessage.id)
    }

    /// Convenience for the common single-turn case; returns just the session ID.
    @discardableResult
    func seedSessionWithOneTurn(withAudio: Bool = false) async throws -> String {
        let sessionId = UUID().uuidString
        _ = try await seedTurn(sessionId: sessionId, withAudio: withAudio)
        return sessionId
    }

    /// Appends one tool call row to `sessionId`/`turnId`, creating the session row first if
    /// needed. Mirrors `seedTurn` for tool-call coverage of `GET /{id}/history`.
    @discardableResult
    func seedToolCall(
        sessionId: String,
        turnId: String = "turn-1",
        name: String = "calendar",
        detail: String = "list",
        arguments: String = #"{"action":"list"}"#,
        output: String = #"{"summary":"Found 2 event(s).","events":[]}"#
    ) async throws -> String {
        try await conversations.ensureSession(id: sessionId)
        trackCreatedSession(id: sessionId)
        let id = "ctool_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))"
        try await conversations.appendToolCall(
            id: id,
            sessionId: sessionId,
            turnId: turnId,
            name: name,
            detail: detail,
            arguments: arguments,
            output: output,
            createdAt: Date()
        )
        return id
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

    static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
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

    // MARK: - Auth

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

    func testGetSessionRequiresAuth() async throws {
        let sessionId = try await harness.createSession()
        let app = harness.makeApp()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/conversations/\(sessionId)", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testGetSessionRejectsInvalidToken() async throws {
        let sessionId = try await harness.createSession()
        let app = harness.makeApp()
        let headers = harness.wrongAuthHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionId)",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testListMessagesRequiresAuth() async throws {
        let sessionId = try await harness.createSession()
        let app = harness.makeApp()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/conversations/\(sessionId)/messages", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testListMessagesRejectsInvalidToken() async throws {
        let sessionId = try await harness.createSession()
        let app = harness.makeApp()
        let headers = harness.wrongAuthHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionId)/messages",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testAudioEndpointRequiresAuth() async throws {
        let sessionId = try await harness.seedSessionWithOneTurn(withAudio: true)
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

    func testAudioEndpointRejectsInvalidToken() async throws {
        let sessionId = try await harness.seedSessionWithOneTurn(withAudio: true)
        let app = harness.makeApp()
        let headers = harness.wrongAuthHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionId)/messages/does-not-matter/audio",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    // MARK: - List sessions

    func testListConversationsReturnsSeededSession() async throws {
        let sessionId = try await harness.seedSessionWithOneTurn()

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

    func testListConversationsOrderedByStartedAtDescending() async throws {
        let now = Date()
        let older = try await harness.createSession()
        let newer = try await harness.createSession()

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        let uri = "/api/v1/conversations"
            + "?from=\(ConversationAPITestHarness.iso(now.addingTimeInterval(-30)))"
            + "&to=\(ConversationAPITestHarness.iso(now.addingTimeInterval(30)))"
            + "&limit=1000"
        try await app.test(.router) { client in
            try await client.execute(uri: uri, method: .get, headers: headers) { response in
                XCTAssertEqual(response.status, .ok)
                let body = try ConversationAPITestHarness.makeDecoder().decode(
                    APIConversationSessionsResponse.self,
                    from: response.body
                )
                let ids = body.sessions.map(\.id)
                let olderIndex = try XCTUnwrap(ids.firstIndex(of: older))
                let newerIndex = try XCTUnwrap(ids.firstIndex(of: newer))
                XCTAssertLessThan(newerIndex, olderIndex, "more recently started session should be listed first")
            }
        }
    }

    func testListConversationsFiltersByDateRange() async throws {
        let sessionId = try await harness.createSession()
        let now = Date()

        let app = harness.makeApp()
        let headers = harness.authHeaders()

        // In range — from/to bracketing "now" should include the seeded session.
        let inRangeURI = "/api/v1/conversations"
            + "?from=\(ConversationAPITestHarness.iso(now.addingTimeInterval(-3_600)))"
            + "&to=\(ConversationAPITestHarness.iso(now.addingTimeInterval(3_600)))"
        try await app.test(.router) { client in
            try await client.execute(uri: inRangeURI, method: .get, headers: headers) { response in
                let body = try ConversationAPITestHarness.makeDecoder().decode(
                    APIConversationSessionsResponse.self,
                    from: response.body
                )
                XCTAssertTrue(body.sessions.contains(where: { $0.id == sessionId }))
            }
        }

        // `to` entirely in the past excludes the seeded session.
        let beforeURI = "/api/v1/conversations?to=\(ConversationAPITestHarness.iso(now.addingTimeInterval(-3_600)))"
        try await app.test(.router) { client in
            try await client.execute(uri: beforeURI, method: .get, headers: headers) { response in
                let body = try ConversationAPITestHarness.makeDecoder().decode(
                    APIConversationSessionsResponse.self,
                    from: response.body
                )
                XCTAssertFalse(body.sessions.contains(where: { $0.id == sessionId }))
            }
        }

        // `from` entirely in the future excludes the seeded session.
        let afterURI = "/api/v1/conversations?from=\(ConversationAPITestHarness.iso(now.addingTimeInterval(3_600)))"
        try await app.test(.router) { client in
            try await client.execute(uri: afterURI, method: .get, headers: headers) { response in
                let body = try ConversationAPITestHarness.makeDecoder().decode(
                    APIConversationSessionsResponse.self,
                    from: response.body
                )
                XCTAssertFalse(body.sessions.contains(where: { $0.id == sessionId }))
            }
        }
    }

    func testListConversationsRespectsLimit() async throws {
        let now = Date()
        try await harness.createSession()
        try await harness.createSession()
        try await harness.createSession()

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        let uri = "/api/v1/conversations"
            + "?from=\(ConversationAPITestHarness.iso(now.addingTimeInterval(-30)))"
            + "&to=\(ConversationAPITestHarness.iso(now.addingTimeInterval(30)))"
            + "&limit=2"
        try await app.test(.router) { client in
            try await client.execute(uri: uri, method: .get, headers: headers) { response in
                XCTAssertEqual(response.status, .ok)
                let body = try ConversationAPITestHarness.makeDecoder().decode(
                    APIConversationSessionsResponse.self,
                    from: response.body
                )
                XCTAssertEqual(body.sessions.count, 2)
            }
        }
    }

    // MARK: - Get session

    func testGetSessionReturnsSeededSessionWithNullEndedAt() async throws {
        let sessionId = try await harness.createSession()

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionId)",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let session = try ConversationAPITestHarness.makeDecoder().decode(
                    APIConversationSession.self,
                    from: response.body
                )
                XCTAssertEqual(session.id, sessionId)
                XCTAssertNil(session.endedAt)
                XCTAssertEqual(session.voiceCount, 0)
            }
        }
    }

    func testGetSessionVoiceCountReflectsDistinctTurns() async throws {
        let sessionId = try await harness.createSession()
        try await harness.seedTurn(sessionId: sessionId, turnId: "turn-1")
        try await harness.seedTurn(sessionId: sessionId, turnId: "turn-2")

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionId)",
                method: .get,
                headers: headers
            ) { response in
                let session = try ConversationAPITestHarness.makeDecoder().decode(
                    APIConversationSession.self,
                    from: response.body
                )
                XCTAssertEqual(session.voiceCount, 2)
            }
        }
    }

    func testListConversationsIncludesVoiceCount() async throws {
        let sessionId = try await harness.createSession()
        try await harness.seedTurn(sessionId: sessionId, turnId: "turn-1")

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations",
                method: .get,
                headers: headers
            ) { response in
                let body = try ConversationAPITestHarness.makeDecoder().decode(
                    APIConversationSessionsResponse.self,
                    from: response.body
                )
                let session = try XCTUnwrap(body.sessions.first(where: { $0.id == sessionId }))
                XCTAssertEqual(session.voiceCount, 1)
            }
        }
    }

    func testGetSessionReflectsEndedAtAfterEndSession() async throws {
        let sessionId = try await harness.createSession()
        try await harness.conversations.endSession(id: sessionId)

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionId)",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let session = try ConversationAPITestHarness.makeDecoder().decode(
                    APIConversationSession.self,
                    from: response.body
                )
                XCTAssertNotNil(session.endedAt)
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

    // MARK: - List messages

    func testListMessagesReturnsTranscriptWithoutAudioUrlWhenNoAudio() async throws {
        let sessionId = try await harness.seedSessionWithOneTurn(withAudio: false)

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

    func testListMessagesOrderedChronologicallyAcrossTurns() async throws {
        let sessionId = try await harness.createSession()
        try await harness.seedTurn(sessionId: sessionId, turnId: "turn-1", userContent: "First turn")
        try await harness.seedTurn(sessionId: sessionId, turnId: "turn-2", userContent: "Second turn")

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
                XCTAssertEqual(body.messages.map(\.turnId), ["turn-1", "turn-1", "turn-2", "turn-2"])
                XCTAssertEqual(body.messages.map(\.role), ["user", "assistant", "user", "assistant"])
                XCTAssertEqual(body.messages.first?.content, "First turn")
                XCTAssertEqual(body.messages.last?.content, "Hi! How can I help?")
            }
        }
    }

    func testListMessagesRespectsLimitAndOffset() async throws {
        let sessionId = try await harness.createSession()
        try await harness.seedTurn(sessionId: sessionId, turnId: "turn-1")
        try await harness.seedTurn(sessionId: sessionId, turnId: "turn-2")

        let app = harness.makeApp()
        let headers = harness.authHeaders()

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionId)/messages?limit=2",
                method: .get,
                headers: headers
            ) { response in
                let body = try ConversationAPITestHarness.makeDecoder().decode(
                    APIConversationMessagesResponse.self,
                    from: response.body
                )
                XCTAssertEqual(body.messages.map(\.turnId), ["turn-1", "turn-1"])
            }
        }

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionId)/messages?limit=2&offset=2",
                method: .get,
                headers: headers
            ) { response in
                let body = try ConversationAPITestHarness.makeDecoder().decode(
                    APIConversationMessagesResponse.self,
                    from: response.body
                )
                XCTAssertEqual(body.messages.map(\.turnId), ["turn-2", "turn-2"])
            }
        }
    }

    func testMessageWithAudioOnlyHasEmptyContentButStillExposesAudioUrl() async throws {
        let sessionId = try await harness.createSession()
        let uplinkPath = harness.audioStore.saveUplink(sessionId: sessionId, turnId: "turn-1", pcm: Data([9, 9, 9, 9]))
        try await harness.conversations.appendMessage(
            sessionId: sessionId,
            turnId: "turn-1",
            role: "user",
            content: "",
            audioPath: uplinkPath
        )

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionId)/messages",
                method: .get,
                headers: headers
            ) { response in
                let body = try ConversationAPITestHarness.makeDecoder().decode(
                    APIConversationMessagesResponse.self,
                    from: response.body
                )
                let message = try XCTUnwrap(body.messages.first)
                XCTAssertEqual(message.content, "")
                XCTAssertNotNil(message.audioUrl)
            }
        }
    }

    // MARK: - Audio download

    func testMessageWithAudioExposesAudioUrlAndDownloadReturnsUplinkWavBytes() async throws {
        let sessionId = try await harness.seedSessionWithOneTurn(withAudio: true)

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
                XCTAssertEqual(response.headers[.contentLength], "48")
                // WAV = 44-byte header + 4 bytes of fixture PCM; the last 4 bytes are the raw
                // uplink PCM samples written by `seedTurn`.
                XCTAssertEqual(response.body.readableBytes, 48)
                let bytes = [UInt8](response.body.readableBytesView)
                XCTAssertEqual(Array(bytes.suffix(4)), [0, 1, 2, 3])
            }
        }
    }

    func testMessageWithAudioDownloadReturnsDownlinkWavBytes() async throws {
        let sessionId = try await harness.seedSessionWithOneTurn(withAudio: true)

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
                let assistantMessage = try XCTUnwrap(body.messages.first(where: { $0.role == "assistant" }))
                return try XCTUnwrap(assistantMessage.audioUrl)
            }
        }

        try await app.test(.router) { client in
            try await client.execute(uri: audioUrl, method: .get, headers: headers) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.contentType], "audio/wav")
                let bytes = [UInt8](response.body.readableBytesView)
                XCTAssertEqual(Array(bytes.suffix(4)), [4, 5, 6, 7])
            }
        }
    }

    func testAudioEndpointReturnsNotFoundWhenMessageHasNoAudio() async throws {
        let sessionId = try await harness.seedSessionWithOneTurn(withAudio: false)

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

    func testAudioEndpointReturnsNotFoundForUnknownMessageId() async throws {
        let sessionId = try await harness.createSession()

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionId)/messages/cmsg_does_not_exist/audio",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .notFound)
            }
        }
    }

    func testAudioEndpointReturnsNotFoundWhenMessageBelongsToDifferentSession() async throws {
        let sessionA = try await harness.seedSessionWithOneTurn(withAudio: true)
        let sessionB = try await harness.createSession()

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        let messageIdFromA = try await app.test(.router) { client -> String in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionA)/messages",
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
                uri: "/api/v1/conversations/\(sessionB)/messages/\(messageIdFromA)/audio",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .notFound)
            }
        }
    }

    // MARK: - History

    func testHistoryRequiresAuth() async throws {
        let sessionId = try await harness.createSession()
        let app = harness.makeApp()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/conversations/\(sessionId)/history", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testHistoryForUnknownSessionReturnsNotFound() async throws {
        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/session-does-not-exist/history",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .notFound)
            }
        }
    }

    func testHistoryGroupsUserAssistantAndToolCallsIntoOneTurn() async throws {
        let sessionId = try await harness.createSession()
        try await harness.seedTurn(sessionId: sessionId, turnId: "turn-1")
        try await harness.seedToolCall(sessionId: sessionId, turnId: "turn-1")

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionId)/history",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let body = try ConversationAPITestHarness.makeDecoder().decode(
                    APIConversationHistoryResponse.self,
                    from: response.body
                )
                XCTAssertEqual(body.sessionId, sessionId)
                let turn = try XCTUnwrap(body.turns.first)
                XCTAssertEqual(body.turns.count, 1)
                XCTAssertEqual(turn.turnId, "turn-1")
                XCTAssertEqual(turn.user?.content, "Hello there")
                XCTAssertEqual(turn.assistant?.content, "Hi! How can I help?")

                let call = try XCTUnwrap(turn.toolCalls.first)
                XCTAssertEqual(turn.toolCalls.count, 1)
                XCTAssertEqual(call.tool, "calendar")
                XCTAssertEqual(call.label, "list")
                XCTAssertEqual(call.status, "success")
                XCTAssertEqual(call.action, "list")
                XCTAssertEqual(call.input["action"], .string("list"))
                XCTAssertEqual(call.output["summary"], .string("Found 2 event(s)."))
                XCTAssertEqual(call.summary, "Found 2 event(s).")
            }
        }
    }

    func testHistoryDerivesErrorStatusFromOutputError() async throws {
        let sessionId = try await harness.createSession()
        try await harness.seedToolCall(
            sessionId: sessionId,
            name: "tasks",
            detail: "create",
            arguments: #"{"action":"create"}"#,
            output: #"{"error":"create requires title"}"#
        )

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionId)/history",
                method: .get,
                headers: headers
            ) { response in
                let body = try ConversationAPITestHarness.makeDecoder().decode(
                    APIConversationHistoryResponse.self,
                    from: response.body
                )
                let call = try XCTUnwrap(body.turns.first?.toolCalls.first)
                XCTAssertEqual(call.status, "error")
                XCTAssertEqual(call.output["error"], .string("create requires title"))
                XCTAssertNil(call.summary)
            }
        }
    }

    func testHistoryDerivesDuplicateStatusFromSummary() async throws {
        let sessionId = try await harness.createSession()
        try await harness.seedToolCall(
            sessionId: sessionId,
            name: "web_search",
            detail: "weather in Jakarta",
            arguments: #"{"query":"weather in Jakarta"}"#,
            output: #"{"summary":"\#(ConversationToolCallBuilder.duplicateSummary)"}"#
        )

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionId)/history",
                method: .get,
                headers: headers
            ) { response in
                let body = try ConversationAPITestHarness.makeDecoder().decode(
                    APIConversationHistoryResponse.self,
                    from: response.body
                )
                let call = try XCTUnwrap(body.turns.first?.toolCalls.first)
                XCTAssertEqual(call.status, "duplicate")
                XCTAssertNil(call.action)
            }
        }
    }

    func testHistoryOrdersTurnsNumericallyAcrossTenPlusTurns() async throws {
        let sessionId = try await harness.createSession()
        // "turn-10" sorts before "turn-2" lexicographically but must sort after it numerically.
        try await harness.seedTurn(sessionId: sessionId, turnId: "turn-2", userContent: "Second turn")
        try await harness.seedTurn(sessionId: sessionId, turnId: "turn-10", userContent: "Tenth turn")
        try await harness.seedTurn(sessionId: sessionId, turnId: "turn-1", userContent: "First turn")

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionId)/history?limit=100",
                method: .get,
                headers: headers
            ) { response in
                let body = try ConversationAPITestHarness.makeDecoder().decode(
                    APIConversationHistoryResponse.self,
                    from: response.body
                )
                XCTAssertEqual(body.turns.map(\.turnId), ["turn-1", "turn-2", "turn-10"])
                XCTAssertEqual(body.turns.map { $0.user?.content }, ["First turn", "Second turn", "Tenth turn"])
            }
        }
    }

    func testHistoryRespectsLimitAndOffsetOnTurns() async throws {
        let sessionId = try await harness.createSession()
        try await harness.seedTurn(sessionId: sessionId, turnId: "turn-1")
        try await harness.seedTurn(sessionId: sessionId, turnId: "turn-2")
        try await harness.seedTurn(sessionId: sessionId, turnId: "turn-3")

        let app = harness.makeApp()
        let headers = harness.authHeaders()

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionId)/history?limit=2",
                method: .get,
                headers: headers
            ) { response in
                let body = try ConversationAPITestHarness.makeDecoder().decode(
                    APIConversationHistoryResponse.self,
                    from: response.body
                )
                XCTAssertEqual(body.turns.map(\.turnId), ["turn-1", "turn-2"])
            }
        }

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionId)/history?limit=2&offset=2",
                method: .get,
                headers: headers
            ) { response in
                let body = try ConversationAPITestHarness.makeDecoder().decode(
                    APIConversationHistoryResponse.self,
                    from: response.body
                )
                XCTAssertEqual(body.turns.map(\.turnId), ["turn-3"])
            }
        }
    }

    func testHistoryReturnsEmptyToolCallsForTurnWithoutTools() async throws {
        let sessionId = try await harness.seedSessionWithOneTurn()

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/conversations/\(sessionId)/history",
                method: .get,
                headers: headers
            ) { response in
                let body = try ConversationAPITestHarness.makeDecoder().decode(
                    APIConversationHistoryResponse.self,
                    from: response.body
                )
                XCTAssertEqual(body.turns.first?.toolCalls.count, 0)
            }
        }
    }
}
