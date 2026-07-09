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

private struct APIPersonaState: Decodable {
    let active: String?
    let available: [String]
}

private struct APIConfig: Decodable {
    let personality: String
    let persona: APIPersonaState
    let connection: APIConnection
    let appearance: String
    let notifications: APINotifications
    let privacy: APIPrivacy
    let language: String
}

private struct APIPersonality: Decodable {
    let personality: String
}

private final class ConfigAPITestHarness {
    let database: DatabaseService
    let config: ConfigRepository
    let reminders: ReminderRepository
    let reminderScheduler: ReminderScheduler
    let personas: PersonaStore
    let deviceToken = "config-test-token"
    let logger: Logger

    init(
        database: DatabaseService,
        config: ConfigRepository,
        reminders: ReminderRepository,
        reminderScheduler: ReminderScheduler,
        personas: PersonaStore,
        logger: Logger
    ) {
        self.database = database
        self.config = config
        self.reminders = reminders
        self.reminderScheduler = reminderScheduler
        self.personas = personas
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
        let reminders = ReminderRepository(database: database, logger: logger)
        try await config.migrate()
        try await reminders.migrate()
        let reminderScheduler = ReminderScheduler(reminders: reminders, config: config, logger: logger)
        let personas = PersonaStore(logger: logger)
        return ConfigAPITestHarness(
            database: database,
            config: config,
            reminders: reminders,
            reminderScheduler: reminderScheduler,
            personas: personas,
            logger: logger
        )
    }

    func makeApp() -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        ConfigRoutes.register(
            on: router,
            config: config,
            reminderScheduler: reminderScheduler,
            personas: personas,
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
        try? await personas.setActive(nil)
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
                XCTAssertNil(body.persona.active)
                XCTAssertTrue(body.persona.available.contains("jokowi"))
            }
        }
    }

    func testPutPersonaActivatesJokowi() async throws {
        let app = harness.makeApp()
        let headers = harness.jsonHeaders()
        let authHeaders = harness.authHeaders()
        let body = #"{"name":"jokowi"}"#
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/config/persona",
                method: .put,
                headers: headers,
                body: ByteBufferAllocator().buffer(string: body)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let persona = try JSONDecoder().decode(APIPersonaState.self, from: response.body)
                XCTAssertEqual(persona.active, "jokowi")
                XCTAssertTrue(persona.available.contains("jokowi"))
            }
        }

        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/config", method: .get, headers: authHeaders) { response in
                let config = try JSONDecoder().decode(APIConfig.self, from: response.body)
                XCTAssertEqual(config.persona.active, "jokowi")
            }
        }
    }

    func testPutPersonaClearsActivePersona() async throws {
        let app = harness.makeApp()
        let headers = harness.jsonHeaders()
        try await harness.personas.setActive("jokowi")
        let body = #"{"name":null}"#
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/config/persona",
                method: .put,
                headers: headers,
                body: ByteBufferAllocator().buffer(string: body)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let persona = try JSONDecoder().decode(APIPersonaState.self, from: response.body)
                XCTAssertNil(persona.active)
            }
        }
    }

    func testPutPersonaRejectsUnknownName() async throws {
        let app = harness.makeApp()
        let headers = harness.jsonHeaders()
        let body = #"{"name":"not-a-real-persona"}"#
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/config/persona",
                method: .put,
                headers: headers,
                body: ByteBufferAllocator().buffer(string: body)
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
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

    func testPutPersonalityUpdatesPersonality() async throws {
        let app = harness.makeApp()
        let headers = harness.jsonHeaders()
        let authHeaders = harness.authHeaders()
        let body = #"{"personality":"professional"}"#
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/config/personality",
                method: .put,
                headers: headers,
                body: ByteBufferAllocator().buffer(string: body)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let result = try JSONDecoder().decode(APIPersonality.self, from: response.body)
                XCTAssertEqual(result.personality, "professional")
            }
        }

        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/config", method: .get, headers: authHeaders) { response in
                let config = try JSONDecoder().decode(APIConfig.self, from: response.body)
                XCTAssertEqual(config.personality, "professional")
            }
        }
    }

    func testPutPersonalityRejectsInvalidEnum() async throws {
        let app = harness.makeApp()
        let headers = harness.jsonHeaders()
        let body = #"{"personality":"grumpy"}"#
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/config/personality",
                method: .put,
                headers: headers,
                body: ByteBufferAllocator().buffer(string: body)
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
    }

    func testPutPersonalityRequiresAuth() async throws {
        let app = harness.makeApp()
        let body = #"{"personality":"calm"}"#
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/config/personality",
                method: .put,
                headers: [.contentType: "application/json"],
                body: ByteBufferAllocator().buffer(string: body)
            ) { response in
                XCTAssertEqual(response.status, .unauthorized)
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
