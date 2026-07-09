import CompanionDatabase
import Foundation
import Logging
import XCTest

final class PushDeviceRepositoryTests: XCTestCase {
  private var database: DatabaseService!
  private var pushDevices: PushDeviceRepository!
  private let logger = Logger(label: "PushDeviceRepositoryTests")
  private let testToken = "abc123def456"

  override func setUp() async throws {
    let databaseURL = ProcessInfo.processInfo.environment["DATABASE_URL"]
      ?? "postgres://postgres:postgres@localhost:5432/companion"
    let settings = try DatabaseSettings(urlString: databaseURL)
    database = DatabaseService(settings: settings, logger: logger)
    await database.start()
    do {
      try await database.ping()
    } catch {
      throw XCTSkip("Postgres unavailable: \(error)")
    }
    pushDevices = PushDeviceRepository(database: database, logger: logger)
    try await pushDevices.migrate()
  }

  override func tearDown() async throws {
    try? await pushDevices.delete(deviceToken: testToken)
    await database?.shutdown()
    database = nil
    pushDevices = nil
  }

  func testUpsertAndList() async throws {
    let record = try await pushDevices.upsert(
      platform: .macos,
      deviceToken: testToken,
      bundleId: "com.example.botchill",
      environment: .sandbox
    )
    XCTAssertEqual(record.platform, .macos)
    XCTAssertEqual(record.deviceToken, testToken)
    XCTAssertEqual(record.bundleId, "com.example.botchill")
    XCTAssertEqual(record.environment, .sandbox)

    let devices = try await pushDevices.list()
    XCTAssertTrue(devices.contains(where: { $0.deviceToken == testToken }))
  }

  func testDeleteDevice() async throws {
    _ = try await pushDevices.upsert(
      platform: .macos,
      deviceToken: testToken,
      bundleId: "com.example.botchill",
      environment: .sandbox
    )
    try await pushDevices.delete(deviceToken: testToken)
    let devices = try await pushDevices.list()
    XCTAssertFalse(devices.contains(where: { $0.deviceToken == testToken }))
  }

  func testRejectsEmptyDeviceToken() async throws {
    do {
      _ = try await pushDevices.upsert(
        platform: .macos,
        deviceToken: "",
        bundleId: "com.example.botchill",
        environment: .sandbox
      )
      XCTFail("expected invalidInput for empty deviceToken")
    } catch let error as PushDeviceRepositoryError {
      XCTAssertTrue(error.description.contains("deviceToken"))
    }
  }

  func testRejectsWhitespaceOnlyBundleId() async throws {
    do {
      _ = try await pushDevices.upsert(
        platform: .macos,
        deviceToken: testToken,
        bundleId: "   ",
        environment: .sandbox
      )
      XCTFail("expected invalidInput for empty bundleId")
    } catch let error as PushDeviceRepositoryError {
      XCTAssertTrue(error.description.contains("bundleId"))
    }
  }

  func testUpsertUpdatesExistingRecord() async throws {
    let first = try await pushDevices.upsert(
      platform: .macos,
      deviceToken: testToken,
      bundleId: "com.example.botchill",
      environment: .sandbox
    )
    let second = try await pushDevices.upsert(
      platform: .macos,
      deviceToken: testToken,
      bundleId: "com.example.botchill.updated",
      environment: .production
    )
    XCTAssertEqual(first.id, second.id)
    XCTAssertEqual(second.bundleId, "com.example.botchill.updated")
    XCTAssertEqual(second.environment, .production)

    let devices = try await pushDevices.list()
    XCTAssertEqual(devices.filter { $0.deviceToken == testToken }.count, 1)
  }

  func testDeviceIDFormat() async throws {
    let record = try await pushDevices.upsert(
      platform: .macos,
      deviceToken: testToken,
      bundleId: "com.example.botchill",
      environment: .sandbox
    )
    XCTAssertTrue(record.id.hasPrefix("push_macos_"))
    XCTAssertTrue(record.id.contains(String(testToken.prefix(16))))
  }

  func testDeleteNotFound() async throws {
    do {
      try await pushDevices.delete(deviceToken: "does-not-exist")
      XCTFail("expected notFound")
    } catch let error as PushDeviceRepositoryError {
      XCTAssertTrue(error.description.contains("does-not-exist"))
    }
  }

  func testDeleteRejectsEmptyToken() async throws {
    do {
      try await pushDevices.delete(deviceToken: "")
      XCTFail("expected invalidInput")
    } catch let error as PushDeviceRepositoryError {
      XCTAssertTrue(error.description.contains("deviceToken"))
    }
  }
}
