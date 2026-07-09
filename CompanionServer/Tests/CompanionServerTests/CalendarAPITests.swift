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

private struct APICalendarEvent: Decodable, Equatable {
    let id: String
    let title: String
    let startsAt: Date
    let endsAt: Date
    let location: String
    let isImportant: Bool
    let notes: String?
}

private struct APICalendarEventsResponse: Decodable {
    let events: [APICalendarEvent]
}

private final class CalendarAPITestHarness {
    let database: DatabaseService
    let calendar: CalendarRepository
    let reminders: ReminderRepository
    let config: ConfigRepository
    let reminderScheduler: ReminderScheduler
    let deviceToken = "calendar-test-token"
    let logger: Logger
    var createdEventIDs: [String] = []

    init(
        database: DatabaseService,
        calendar: CalendarRepository,
        reminders: ReminderRepository,
        config: ConfigRepository,
        reminderScheduler: ReminderScheduler,
        logger: Logger
    ) {
        self.database = database
        self.calendar = calendar
        self.reminders = reminders
        self.config = config
        self.reminderScheduler = reminderScheduler
        self.logger = logger
    }

    static func make() async throws -> CalendarAPITestHarness? {
        let logger = Logger(label: "CalendarAPITests")
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
        let calendar = CalendarRepository(database: database, logger: logger)
        let reminders = ReminderRepository(database: database, logger: logger)
        let config = ConfigRepository(database: database, logger: logger)
        try await calendar.migrate()
        try await reminders.migrate()
        try await config.migrate()
        let reminderScheduler = ReminderScheduler(reminders: reminders, config: config, logger: logger)
        return CalendarAPITestHarness(
            database: database,
            calendar: calendar,
            reminders: reminders,
            config: config,
            reminderScheduler: reminderScheduler,
            logger: logger
        )
    }

    func makeApp() -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        CalendarRoutes.register(
            on: router,
            calendar: calendar,
            reminderScheduler: reminderScheduler,
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
            .contentType: "application/json",
        ]
    }

    func trackCreatedEvent(id: String) {
        createdEventIDs.append(id)
    }

    func cleanup() async {
        for id in createdEventIDs {
            try? await calendar.deleteEvent(id: id)
        }
        createdEventIDs.removeAll()
        await database.shutdown()
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

final class CalendarAPITests: XCTestCase {
    private var harness: CalendarAPITestHarness!

    override func setUp() async throws {
        guard let harness = try await CalendarAPITestHarness.make() else {
            throw XCTSkip("Postgres not available — start with docker-compose up -d")
        }
        self.harness = harness
    }

    override func tearDown() async throws {
        await harness?.cleanup()
        harness = nil
    }

    func testListEventsRequiresAuth() async throws {
        let app = harness.makeApp()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/calendar/events", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testListEventsRejectsInvalidToken() async throws {
        let app = harness.makeApp()
        let headers = harness.wrongAuthHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/calendar/events",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testListEventsReturnsSeedEvent() async throws {
        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/calendar/events",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let body = try CalendarAPITestHarness.makeDecoder().decode(
                    APICalendarEventsResponse.self,
                    from: response.body
                )
                XCTAssertTrue(body.events.contains(where: { $0.id == "evt_abc123" }))
                let standup = body.events.first(where: { $0.id == "evt_abc123" })
                XCTAssertEqual(standup?.title, "Team Standup")
                XCTAssertEqual(standup?.location, "Zoom")
                XCTAssertEqual(standup?.isImportant, false)
                XCTAssertNil(standup?.notes)
            }
        }
    }

    func testGetEventByID() async throws {
        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/calendar/events/evt_abc123",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let event = try CalendarAPITestHarness.makeDecoder().decode(
                    APICalendarEvent.self,
                    from: response.body
                )
                XCTAssertEqual(event.id, "evt_abc123")
                XCTAssertEqual(event.title, "Team Standup")
                XCTAssertEqual(event.location, "Zoom")
            }
        }
    }

    func testGetEventNotFound() async throws {
        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/calendar/events/evt_missing",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .notFound)
            }
        }
    }

    func testCreateEvent() async throws {
        let body = """
        {
          "title": "Dentist",
          "startsAt": "2026-07-08T14:00:00Z",
          "endsAt": "2026-07-08T15:00:00Z",
          "location": "Clinic",
          "isImportant": true,
          "notes": "Bring insurance card"
        }
        """
        let app = harness.makeApp()
        let headers = harness.jsonHeaders()
        let createdID = try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/calendar/events",
                method: .post,
                headers: headers,
                body: ByteBufferAllocator().buffer(string: body)
            ) { response -> String in
                XCTAssertEqual(response.status, .ok)
                let event = try CalendarAPITestHarness.makeDecoder().decode(
                    APICalendarEvent.self,
                    from: response.body
                )
                XCTAssertTrue(event.id.hasPrefix("evt_"))
                XCTAssertEqual(event.title, "Dentist")
                XCTAssertEqual(event.location, "Clinic")
                XCTAssertEqual(event.isImportant, true)
                XCTAssertEqual(event.notes, "Bring insurance card")
                return event.id
            }
        }
        harness.trackCreatedEvent(id: createdID)
    }

    func testCreateEventRejectsInvalidRange() async throws {
        let body = """
        {
          "title": "Bad Range",
          "startsAt": "2026-07-08T15:00:00Z",
          "endsAt": "2026-07-08T14:00:00Z",
          "location": "Nowhere",
          "isImportant": false,
          "notes": null
        }
        """
        let app = harness.makeApp()
        let headers = harness.jsonHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/calendar/events",
                method: .post,
                headers: headers,
                body: ByteBufferAllocator().buffer(string: body)
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
    }

    func testListEventsFiltersByDateRange() async throws {
        let created = try await harness.calendar.createEvent(
            title: "July Meetup",
            startsAt: ISO8601DateFormatter().date(from: "2026-07-15T18:00:00Z")!,
            endsAt: ISO8601DateFormatter().date(from: "2026-07-15T19:00:00Z")!,
            location: "Cafe",
            isImportant: false,
            notes: nil
        )
        harness.trackCreatedEvent(id: created.id)
        let createdID = created.id

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/calendar/events?from=2026-07-15T00:00:00Z&to=2026-07-15T23:59:59Z",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let body = try CalendarAPITestHarness.makeDecoder().decode(
                    APICalendarEventsResponse.self,
                    from: response.body
                )
                XCTAssertTrue(body.events.contains(where: { $0.id == createdID }))
                XCTAssertFalse(body.events.contains(where: { $0.title == "Team Standup" }))
            }
        }
    }

    func testPatchEventUpdatesFields() async throws {
        let created = try await harness.calendar.createEvent(
            title: "Patch me",
            startsAt: ISO8601DateFormatter().date(from: "2026-07-20T09:00:00Z")!,
            endsAt: ISO8601DateFormatter().date(from: "2026-07-20T10:00:00Z")!,
            location: "Office",
            isImportant: false,
            notes: "Original"
        )
        harness.trackCreatedEvent(id: created.id)

        let body = """
        {
          "title": "Patched title",
          "location": "Zoom",
          "isImportant": true,
          "notes": null
        }
        """
        let app = harness.makeApp()
        let headers = harness.jsonHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/calendar/events/\(created.id)",
                method: .patch,
                headers: headers,
                body: ByteBufferAllocator().buffer(string: body)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let event = try CalendarAPITestHarness.makeDecoder().decode(
                    APICalendarEvent.self,
                    from: response.body
                )
                XCTAssertEqual(event.id, created.id)
                XCTAssertEqual(event.title, "Patched title")
                XCTAssertEqual(event.location, "Zoom")
                XCTAssertEqual(event.isImportant, true)
                XCTAssertNil(event.notes)
            }
        }
    }

    func testPatchEventRejectsInvalidRange() async throws {
        let body = """
        {
          "startsAt": "2026-07-08T15:00:00Z",
          "endsAt": "2026-07-08T14:00:00Z"
        }
        """
        let app = harness.makeApp()
        let headers = harness.jsonHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/calendar/events/evt_abc123",
                method: .patch,
                headers: headers,
                body: ByteBufferAllocator().buffer(string: body)
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
    }

    func testPatchEventNotFound() async throws {
        let body = #"{"title": "Nope"}"#
        let app = harness.makeApp()
        let headers = harness.jsonHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/calendar/events/evt_missing",
                method: .patch,
                headers: headers,
                body: ByteBufferAllocator().buffer(string: body)
            ) { response in
                XCTAssertEqual(response.status, .notFound)
            }
        }
    }

    func testDeleteEvent() async throws {
        let created = try await harness.calendar.createEvent(
            title: "Delete me",
            startsAt: ISO8601DateFormatter().date(from: "2026-07-21T09:00:00Z")!,
            endsAt: ISO8601DateFormatter().date(from: "2026-07-21T10:00:00Z")!,
            location: "",
            isImportant: false,
            notes: nil
        )
        let createdID = created.id

        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/calendar/events/\(createdID)",
                method: .delete,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .noContent)
            }

            try await client.execute(
                uri: "/api/v1/calendar/events/\(createdID)",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .notFound)
            }
        }
    }

    func testDeleteEventNotFound() async throws {
        let app = harness.makeApp()
        let headers = harness.authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/calendar/events/evt_missing",
                method: .delete,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .notFound)
            }
        }
    }
}
