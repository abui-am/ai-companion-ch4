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

private struct APIProfile: Decodable {
  let name: String?
  let role: String?
  let focusSecondsToday: Int
  let date: String
  let updatedAt: Date
}

private final class ProfileAPITestHarness {
  let database: DatabaseService
  let profile: ProfileRepository
  let deviceToken = "profile-test-token"
  let logger: Logger

  init(database: DatabaseService, profile: ProfileRepository, logger: Logger) {
    self.database = database
    self.profile = profile
    self.logger = logger
  }

  static func make() async throws -> ProfileAPITestHarness? {
    let logger = Logger(label: "ProfileAPITests")
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
    let profile = ProfileRepository(database: database, logger: logger)
    try await profile.migrate()
    return ProfileAPITestHarness(database: database, profile: profile, logger: logger)
  }

  func makeApp() -> Application<RouterResponder<BasicRequestContext>> {
    let router = Router()
    ProfileRoutes.register(
      on: router,
      profile: profile,
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

  func resetToDefaults() async throws {
    _ = try await profile.updateProfile(
      ProfilePatch(
        name: nil,
        role: nil,
        updateName: true,
        updateRole: true
      )
    )
    let current = try await profile.getProfile()
    if current.focusSecondsToday > 0 {
      let queryLogger = logger
      _ = try await database.withConnection { connection in
        try await connection.query(
          """
          UPDATE companion_profile
          SET focus_seconds_today = 0,
              focus_date = \(current.date),
              updated_at = NOW()
          WHERE id = 'default'
          """,
          logger: queryLogger
        )
      }
    }
  }

  func forceStoredDate(_ date: String) async throws {
    let queryLogger = logger
    _ = try await database.withConnection { connection in
      try await connection.query(
        """
        UPDATE companion_profile
        SET focus_date = \(date)
        WHERE id = 'default'
        """,
        logger: queryLogger
      )
    }
  }

  func cleanup() async {
    try? await resetToDefaults()
    await database.shutdown()
  }

  static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

final class ProfileAPITests: XCTestCase {
  private var harness: ProfileAPITestHarness!

  override func setUp() async throws {
    guard let harness = try await ProfileAPITestHarness.make() else {
      throw XCTSkip("Postgres not available — start with docker-compose up -d")
    }
    self.harness = harness
  }

  override func tearDown() async throws {
    await harness?.cleanup()
    harness = nil
  }

  func testGetProfileRequiresAuth() async throws {
    let app = harness.makeApp()
    try await app.test(.router) { client in
      try await client.execute(uri: "/api/v1/profile", method: .get) { response in
        XCTAssertEqual(response.status, .unauthorized)
      }
    }
  }

  func testGetProfileRejectsInvalidToken() async throws {
    let app = harness.makeApp()
    let headers = harness.wrongAuthHeaders()
    try await app.test(.router) { client in
      try await client.execute(uri: "/api/v1/profile", method: .get, headers: headers) { response in
        XCTAssertEqual(response.status, .unauthorized)
      }
    }
  }

  func testGetProfileReturnsDefaultShape() async throws {
    try await harness.resetToDefaults()
    let app = harness.makeApp()
    let headers = harness.authHeaders()
    try await app.test(.router) { client in
      try await client.execute(uri: "/api/v1/profile", method: .get, headers: headers) { response in
        XCTAssertEqual(response.status, .ok)
        let body = try ProfileAPITestHarness.makeDecoder().decode(APIProfile.self, from: response.body)
        XCTAssertNil(body.name)
        XCTAssertNil(body.role)
        XCTAssertEqual(body.focusSecondsToday, 0)
        XCTAssertFalse(body.date.isEmpty)
      }
    }
  }

  func testPatchProfileUpdatesAndTrimsFields() async throws {
    let body = #"{"name":"  yuyun  ","role":"  student "}"#
    let app = harness.makeApp()
    let headers = harness.jsonHeaders()
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/profile",
        method: .patch,
        headers: headers,
        body: ByteBufferAllocator().buffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let profile = try ProfileAPITestHarness.makeDecoder().decode(APIProfile.self, from: response.body)
        XCTAssertEqual(profile.name, "yuyun")
        XCTAssertEqual(profile.role, "student")
      }
    }
  }

  func testPatchProfileAllowsNoopPayload() async throws {
    _ = try await harness.profile.updateProfile(
      ProfilePatch(name: "yuyun", updateName: true)
    )
    let app = harness.makeApp()
    let headers = harness.jsonHeaders()
    let body = #"{}"#
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/profile",
        method: .patch,
        headers: headers,
        body: ByteBufferAllocator().buffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let profile = try ProfileAPITestHarness.makeDecoder().decode(APIProfile.self, from: response.body)
        XCTAssertEqual(profile.name, "yuyun")
      }
    }
  }

  func testPatchProfileClearsFieldWithEmptyString() async throws {
    _ = try await harness.profile.updateProfile(
      ProfilePatch(name: "yuyun", updateName: true)
    )
    let app = harness.makeApp()
    let headers = harness.jsonHeaders()
    let body = #"{"name":""}"#
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/profile",
        method: .patch,
        headers: headers,
        body: ByteBufferAllocator().buffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let profile = try ProfileAPITestHarness.makeDecoder().decode(APIProfile.self, from: response.body)
        XCTAssertNil(profile.name)
      }
    }
  }

  func testPatchProfileRejectsTooLongName() async throws {
    let tooLong = String(repeating: "a", count: 101)
    let body = #"{"name":"\#(tooLong)"}"#
    let app = harness.makeApp()
    let headers = harness.jsonHeaders()
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/profile",
        method: .patch,
        headers: headers,
        body: ByteBufferAllocator().buffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .badRequest)
      }
    }
  }

  func testAddFocusAccumulatesSeconds() async throws {
    let app = harness.makeApp()
    let headers = harness.jsonHeaders()
    let body = #"{"seconds":2760}"#
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/profile/focus",
        method: .post,
        headers: headers,
        body: ByteBufferAllocator().buffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let profile = try ProfileAPITestHarness.makeDecoder().decode(APIProfile.self, from: response.body)
        XCTAssertEqual(profile.focusSecondsToday, 2760)
      }
      try await client.execute(
        uri: "/api/v1/profile/focus",
        method: .post,
        headers: headers,
        body: ByteBufferAllocator().buffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let profile = try ProfileAPITestHarness.makeDecoder().decode(APIProfile.self, from: response.body)
        XCTAssertEqual(profile.focusSecondsToday, 5520)
      }
    }
  }

  func testAddFocusRejectsNegativeSeconds() async throws {
    let app = harness.makeApp()
    let headers = harness.jsonHeaders()
    let body = #"{"seconds":-1}"#
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/profile/focus",
        method: .post,
        headers: headers,
        body: ByteBufferAllocator().buffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .badRequest)
      }
    }
  }

  func testGetResetsFocusWhenStoredDateIsInPast() async throws {
    _ = try await harness.profile.addFocus(seconds: 300)
    try await harness.forceStoredDate("2000-01-01")
    let app = harness.makeApp()
    let headers = harness.authHeaders()
    try await app.test(.router) { client in
      try await client.execute(uri: "/api/v1/profile", method: .get, headers: headers) { response in
        XCTAssertEqual(response.status, .ok)
        let profile = try ProfileAPITestHarness.makeDecoder().decode(APIProfile.self, from: response.body)
        XCTAssertEqual(profile.focusSecondsToday, 0)
        XCTAssertNotEqual(profile.date, "2000-01-01")
      }
    }
  }
}
