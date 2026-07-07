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

private struct APIConnection: Decodable {
    let deviceName: String
    let status: String
}

private struct APINotifications: Decodable {
    let taskReminders: Bool
    let calendarAlerts: Bool
    let remindBeforeMinutes: Int
}

private struct APIPrivacy: Decodable {
    let cameraAccess: Bool
    let personalizationData: Bool
}

private struct APIConfig: Decodable {
    let personality: String
    let connection: APIConnection
    let appearance: String
    let notifications: APINotifications
    let privacy: APIPrivacy
    let language: String
}

private final class ConfigAPITestHarness {
    let database: DatabaseService
    let config: ConfigRepository
    let deviceToken = "config-test-token"
    let logger: Logger

    init(database: DatabaseService, config: ConfigRepository, logger: Logger) {
        self.database = database
        self.config = config
        self.logger = logger
    }

    static func make() async throws -> ConfigAPITestHarness? {
        let logger = Logger(label: "ConfigAPITests")
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
        let config = ConfigRepository(database: database, logger: logger)
        try await config.migrate()
        return ConfigAPITestHarness(database: database, config: config, logger: logger)
    }

    func makeApp() -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        ConfigRoutes.register(
            on: router,
            config: config,
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

    func jsonHeaders() -> HTTPFields {
        [
            .authorization: bearerValue(),
            .contentType: "application/json"
        ]
    }

    /// Restores the singleton row to its seeded defaults so tests don't leak state.
    func resetToDefaults() async throws {
        _ = try await config.update(
            ConfigPatch(
                personality: .calm,
                appearance: .light,
                taskReminders: true,
                calendarAlerts: true,
                remindBeforeMinutes: 10,
                cameraAccess: true,
                personalizationData: true,
                language: .english
            )
        )
    }

    func cleanup() async {
        try? await resetToDefaults()
        await database.shutdown()
    }
}

final class ConfigAPITests: XCTestCase {
    private var harness: ConfigAPITestHarness!

    override func setUp() async throws {
        guard let harness = try await ConfigAPITestHarness.make() else {
            throw XCTSkip("Postgres not available — start with docker-compose up -d")
        }
        self.harness = harness
    }

    override func tearDown() async throws {
        await harness?.cleanup()
        harness = nil
    }

    func testGetConfigRequiresAuth() async throws {
        let app = harness.makeApp()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/config", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testGetConfigRejectsInvalidToken() async throws {
        let app = harness.makeApp()
        let headers = harness.wrongAuthHeaders()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/config", method: .get, headers: headers) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testGetConfigReturnsSeedDefaultsAndMockConnection() async throws {
        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/config", method: .get, headers: headers) { response in
                XCTAssertEqual(response.status, .ok)
                let body = try JSONDecoder().decode(APIConfig.self, from: response.body)
                XCTAssertEqual(body.personality, "calm")
                XCTAssertEqual(body.appearance, "light")
                XCTAssertEqual(body.language, "english")
                XCTAssertEqual(body.notifications.remindBeforeMinutes, 10)
                XCTAssertEqual(body.connection.deviceName, "Bocil-Desk-01")
                XCTAssertEqual(body.connection.status, "paired")
            }
        }
    }

    func testPatchConfigUpdatesPersonalityAndKeepsMockConnection() async throws {
        let app = harness.makeApp()
        let headers = harness.jsonHeaders()
        let body = #"{"personality":"energetic"}"#
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/config",
                method: .patch,
                headers: headers,
                body: ByteBufferAllocator().buffer(string: body)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let config = try JSONDecoder().decode(APIConfig.self, from: response.body)
                XCTAssertEqual(config.personality, "energetic")
                XCTAssertEqual(config.connection.deviceName, "Bocil-Desk-01")
                XCTAssertEqual(config.connection.status, "paired")
            }
        }
    }

    func testPatchConfigIgnoresConnectionKey() async throws {
        let app = harness.makeApp()
        let headers = harness.jsonHeaders()
        let body = #"{"connection":{"deviceName":"Someone-Elses-Device","status":"unpaired"}}"#
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/config",
                method: .patch,
                headers: headers,
                body: ByteBufferAllocator().buffer(string: body)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let config = try JSONDecoder().decode(APIConfig.self, from: response.body)
                XCTAssertEqual(config.connection.deviceName, "Bocil-Desk-01")
                XCTAssertEqual(config.connection.status, "paired")
            }
        }
    }

    func testPatchConfigUpdatesNestedNotifications() async throws {
        let app = harness.makeApp()
        let headers = harness.jsonHeaders()
        let body = #"{"notifications":{"remindBeforeMinutes":30,"taskReminders":false}}"#
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/config",
                method: .patch,
                headers: headers,
                body: ByteBufferAllocator().buffer(string: body)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let config = try JSONDecoder().decode(APIConfig.self, from: response.body)
                XCTAssertEqual(config.notifications.remindBeforeMinutes, 30)
                XCTAssertEqual(config.notifications.taskReminders, false)
                XCTAssertEqual(config.notifications.calendarAlerts, true)
            }
        }
    }

    func testPatchConfigRejectsInvalidRemindBeforeMinutes() async throws {
        let app = harness.makeApp()
        let headers = harness.jsonHeaders()
        let body = #"{"notifications":{"remindBeforeMinutes":7}}"#
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/config",
                method: .patch,
                headers: headers,
                body: ByteBufferAllocator().buffer(string: body)
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
    }

    func testPatchConfigRejectsInvalidEnum() async throws {
        let app = harness.makeApp()
        let headers = harness.jsonHeaders()
        let body = #"{"personality":"grumpy"}"#
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/config",
                method: .patch,
                headers: headers,
                body: ByteBufferAllocator().buffer(string: body)
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
    }
}
