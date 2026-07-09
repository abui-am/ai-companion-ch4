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

private struct APIPushDevice: Decodable, Equatable {
  let id: String
  let platform: String
  let deviceToken: String
  let bundleId: String
  let environment: String
}

private final class PushAPITestHarness {
  let database: DatabaseService
  let pushDevices: PushDeviceRepository
  let deviceToken = "push-test-token"
  let logger: Logger
  let testToken = "abc123def4567890"

  init(database: DatabaseService, pushDevices: PushDeviceRepository, logger: Logger) {
    self.database = database
    self.pushDevices = pushDevices
    self.logger = logger
  }

  static func make() async throws -> PushAPITestHarness? {
    let logger = Logger(label: "PushAPITests")
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
    let pushDevices = PushDeviceRepository(database: database, logger: logger)
    try await pushDevices.migrate()
    return PushAPITestHarness(database: database, pushDevices: pushDevices, logger: logger)
  }

  func makeApp() -> Application<RouterResponder<BasicRequestContext>> {
    let router = Router()
    PushRoutes.register(
      on: router,
      pushDevices: pushDevices,
      deviceToken: deviceToken,
      logger: logger
    )
    return Application(responder: router.buildResponder())
  }

  func jsonHeaders() -> HTTPFields {
    [
      .authorization: "Bearer \(deviceToken)",
      .contentType: "application/json",
    ]
  }

  func cleanup() async {
    try? await pushDevices.delete(deviceToken: testToken)
    await database.shutdown()
  }
}

final class PushAPITests: XCTestCase {
  private var harness: PushAPITestHarness!

  override func setUp() async throws {
    guard let harness = try await PushAPITestHarness.make() else {
      throw XCTSkip("Postgres unavailable")
    }
    self.harness = harness
  }

  override func tearDown() async throws {
    await harness?.cleanup()
    harness = nil
  }

  func testPutDeviceRegistersToken() async throws {
    let testToken = harness.testToken
    let app = harness.makeApp()
    let headers = harness.jsonHeaders()
    let body = """
    {
      "platform": "macos",
      "deviceToken": "\(testToken)",
      "bundleId": "com.example.botchill",
      "environment": "sandbox"
    }
    """
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/push/device",
        method: .put,
        headers: headers,
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let device = try JSONDecoder().decode(APIPushDevice.self, from: response.body)
        XCTAssertEqual(device.platform, "macos")
        XCTAssertEqual(device.deviceToken, testToken)
        XCTAssertEqual(device.bundleId, "com.example.botchill")
        XCTAssertEqual(device.environment, "sandbox")
      }
    }
  }

  func testDeleteDeviceRemovesToken() async throws {
    let testToken = harness.testToken
    let app = harness.makeApp()
    let headers = harness.jsonHeaders()
    _ = try await harness.pushDevices.upsert(
      platform: .macos,
      deviceToken: testToken,
      bundleId: "com.example.botchill",
      environment: .sandbox
    )

    let body = #"{"deviceToken":"\#(testToken)"}"#
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/push/device",
        method: .delete,
        headers: headers,
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .noContent)
      }
    }
  }

  func testPutDeviceRequiresAuth() async throws {
    let testToken = harness.testToken
    let app = harness.makeApp()
    let body = """
    {
      "platform": "macos",
      "deviceToken": "\(testToken)",
      "bundleId": "com.example.botchill",
      "environment": "sandbox"
    }
    """
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/push/device",
        method: .put,
        headers: [.contentType: "application/json"],
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .unauthorized)
      }
    }
  }

  func testPutDeviceRejectsInvalidBearerToken() async throws {
    let testToken = harness.testToken
    let app = harness.makeApp()
    let body = """
    {
      "platform": "macos",
      "deviceToken": "\(testToken)",
      "bundleId": "com.example.botchill",
      "environment": "sandbox"
    }
    """
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/push/device",
        method: .put,
        headers: [
          .authorization: "Bearer wrong-token",
          .contentType: "application/json",
        ],
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .unauthorized)
      }
    }
  }

  func testPutDeviceUpsertUpdatesExistingRecord() async throws {
    let testToken = harness.testToken
    let app = harness.makeApp()
    let headers = harness.jsonHeaders()

    let firstBody = """
    {
      "platform": "macos",
      "deviceToken": "\(testToken)",
      "bundleId": "com.example.botchill",
      "environment": "sandbox"
    }
    """
    let secondBody = """
    {
      "platform": "macos",
      "deviceToken": "\(testToken)",
      "bundleId": "com.example.botchill.production",
      "environment": "production"
    }
    """

    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/push/device",
        method: .put,
        headers: headers,
        body: ByteBuffer(string: firstBody)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let device = try JSONDecoder().decode(APIPushDevice.self, from: response.body)
        XCTAssertEqual(device.environment, "sandbox")
      }
    }

    let devicesAfterFirst = try await harness.pushDevices.list()
    let firstID = try XCTUnwrap(
      devicesAfterFirst.first(where: { $0.deviceToken == testToken })?.id
    )
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/push/device",
        method: .put,
        headers: headers,
        body: ByteBuffer(string: secondBody)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let device = try JSONDecoder().decode(APIPushDevice.self, from: response.body)
        XCTAssertEqual(device.id, firstID)
        XCTAssertEqual(device.bundleId, "com.example.botchill.production")
        XCTAssertEqual(device.environment, "production")
      }
    }
  }

  func testPutDeviceRejectsEmptyToken() async throws {
    let app = harness.makeApp()
    let headers = harness.jsonHeaders()
    let body = """
    {
      "platform": "macos",
      "deviceToken": "",
      "bundleId": "com.example.botchill",
      "environment": "sandbox"
    }
    """
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/push/device",
        method: .put,
        headers: headers,
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .badRequest)
      }
    }
  }

  func testPutDeviceRejectsEmptyBundleId() async throws {
    let testToken = harness.testToken
    let app = harness.makeApp()
    let headers = harness.jsonHeaders()
    let body = """
    {
      "platform": "macos",
      "deviceToken": "\(testToken)",
      "bundleId": "",
      "environment": "sandbox"
    }
    """
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/push/device",
        method: .put,
        headers: headers,
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .badRequest)
      }
    }
  }

  func testPutDeviceRejectsUnsupportedPlatform() async throws {
    let testToken = harness.testToken
    let app = harness.makeApp()
    let headers = harness.jsonHeaders()
    let body = """
    {
      "platform": "ios",
      "deviceToken": "\(testToken)",
      "bundleId": "com.example.botchill",
      "environment": "sandbox"
    }
    """
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/push/device",
        method: .put,
        headers: headers,
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertTrue(
          response.status == .badRequest || response.status.code == 415,
          "expected 400 or 415 for invalid platform, got \(response.status.code)"
        )
      }
    }
  }

  func testDeleteDeviceReturns404WhenNotFound() async throws {
    let app = harness.makeApp()
    let headers = harness.jsonHeaders()
    let body = #"{"deviceToken":"missing-token-xyz"}"#
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/push/device",
        method: .delete,
        headers: headers,
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .notFound)
      }
    }
  }

  func testDeleteDeviceRequiresAuth() async throws {
    let testToken = harness.testToken
    let app = harness.makeApp()
    let body = #"{"deviceToken":"\#(testToken)"}"#
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/push/device",
        method: .delete,
        headers: [.contentType: "application/json"],
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .unauthorized)
      }
    }
  }

  func testDeleteDeviceRejectsEmptyToken() async throws {
    let app = harness.makeApp()
    let headers = harness.jsonHeaders()
    let body = #"{"deviceToken":""}"#
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/push/device",
        method: .delete,
        headers: headers,
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .badRequest)
      }
    }
  }
}
