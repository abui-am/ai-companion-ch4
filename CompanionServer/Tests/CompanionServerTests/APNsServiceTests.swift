import CompanionDatabase
import CryptoKit
import Foundation
import Logging
import XCTest

@testable import CompanionServer

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = Self.handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private enum APNsTestSupport {
  static func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
  }

  static func requestBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody {
      return body
    }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
      let read = stream.read(buffer, maxLength: bufferSize)
      if read <= 0 { break }
      data.append(buffer, count: read)
    }
    return data.isEmpty ? nil : data
  }

  static func makePEM() -> String {
    P256.Signing.PrivateKey().pemRepresentation
  }

  static func makeConfiguration(defaultBundleID: String? = nil) -> APNsConfiguration {
    APNsConfiguration(
      keyID: "TESTKEYID",
      teamID: "TEAMID1234",
      privateKeyPEM: makePEM(),
      defaultBundleID: defaultBundleID
    )
  }

  static func makeDevice(
    token: String = "abc123",
    bundleId: String = "com.example.botchill",
    environment: PushEnvironment = .sandbox
  ) -> PushDeviceRecord {
    PushDeviceRecord(
      id: "push_macos_abc123",
      platform: .macos,
      deviceToken: token,
      bundleId: bundleId,
      environment: environment,
      updatedAt: Date()
    )
  }

  static func makeTaskJob() -> ReminderJobRecord {
    let fireAt = Date(timeIntervalSince1970: 1_700_000_000)
    let targetAt = fireAt.addingTimeInterval(600)
    return ReminderJobRecord(
      id: "reminder_task_task_1",
      kind: .task,
      sourceId: "task_1",
      title: "Finish report",
      fireAt: fireAt,
      targetAt: targetAt,
      status: .claimed
    )
  }

  static func makeEventJob() -> ReminderJobRecord {
    let fireAt = Date(timeIntervalSince1970: 1_700_000_000)
    let targetAt = fireAt.addingTimeInterval(900)
    return ReminderJobRecord(
      id: "reminder_event_evt_1",
      kind: .event,
      sourceId: "evt_1",
      title: "Team standup",
      fireAt: fireAt,
      targetAt: targetAt,
      status: .claimed
    )
  }
}

final class APNsServiceTests: XCTestCase {
  private let logger = Logger(label: "APNsServiceTests")

  override func tearDown() {
    MockURLProtocol.handler = nil
    super.tearDown()
  }

  func testSendReminderTaskUsesSandboxHostAndPayload() async throws {
    let captured = Locked<URLRequest?>(nil)
    MockURLProtocol.handler = { request in
      captured.value = request
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, Data())
    }

    let service = APNsService(
      configuration: APNsTestSupport.makeConfiguration(),
      logger: logger,
      session: APNsTestSupport.makeSession()
    )
    try await service.sendReminder(
      to: APNsTestSupport.makeDevice(),
      job: APNsTestSupport.makeTaskJob(),
      remindBeforeMinutes: 10
    )

    let request = try XCTUnwrap(captured.value)
    XCTAssertEqual(request.url?.host, "api.sandbox.push.apple.com")
    XCTAssertEqual(request.url?.path, "/3/device/abc123")
    XCTAssertEqual(request.value(forHTTPHeaderField: "apns-topic"), "com.example.botchill")
    XCTAssertEqual(request.value(forHTTPHeaderField: "apns-push-type"), "alert")
    XCTAssertTrue(request.value(forHTTPHeaderField: "authorization")?.hasPrefix("bearer ") == true)

    let body = try XCTUnwrap(APNsTestSupport.requestBody(request))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let aps = try XCTUnwrap(json["aps"] as? [String: Any])
    let alert = try XCTUnwrap(aps["alert"] as? [String: Any])
    XCTAssertEqual(alert["title"] as? String, "Task reminder")
    XCTAssertEqual(alert["body"] as? String, "Finish report is due in 10 minutes")
    XCTAssertEqual(aps["sound"] as? String, "default")

    let companion = try XCTUnwrap(json["companion"] as? [String: Any])
    XCTAssertEqual(companion["type"] as? String, "reminder")
    XCTAssertEqual(companion["kind"] as? String, "task")
    XCTAssertEqual(companion["id"] as? String, "task_1")
    XCTAssertEqual(companion["title"] as? String, "Finish report")
    XCTAssertEqual(companion["remindBeforeMinutes"] as? Int, 10)
    XCTAssertNotNil(companion["dueAt"])
    XCTAssertNil(companion["startsAt"])
  }

  func testSendReminderEventUsesProductionHostAndStartsAt() async throws {
    let captured = Locked<URLRequest?>(nil)
    MockURLProtocol.handler = { request in
      captured.value = request
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, Data())
    }

    let service = APNsService(
      configuration: APNsTestSupport.makeConfiguration(),
      logger: logger,
      session: APNsTestSupport.makeSession()
    )
    let device = APNsTestSupport.makeDevice(environment: .production)
    try await service.sendReminder(
      to: device,
      job: APNsTestSupport.makeEventJob(),
      remindBeforeMinutes: 15
    )

    let request = try XCTUnwrap(captured.value)
    XCTAssertEqual(request.url?.host, "api.push.apple.com")

    let body = try XCTUnwrap(APNsTestSupport.requestBody(request))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let aps = try XCTUnwrap(json["aps"] as? [String: Any])
    let alert = try XCTUnwrap(aps["alert"] as? [String: Any])
    XCTAssertEqual(alert["title"] as? String, "Calendar reminder")
    XCTAssertEqual(alert["body"] as? String, "Team standup is due in 15 minutes")

    let companion = try XCTUnwrap(json["companion"] as? [String: Any])
    XCTAssertEqual(companion["kind"] as? String, "event")
    XCTAssertNotNil(companion["startsAt"])
    XCTAssertNil(companion["dueAt"])
  }

  func testSendReminderUsesDefaultBundleIDWhenDeviceBundleEmpty() async throws {
    let captured = Locked<URLRequest?>(nil)
    MockURLProtocol.handler = { request in
      captured.value = request
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, Data())
    }

    let service = APNsService(
      configuration: APNsTestSupport.makeConfiguration(defaultBundleID: "com.fallback.bundle"),
      logger: logger,
      session: APNsTestSupport.makeSession()
    )
    let device = APNsTestSupport.makeDevice(bundleId: "")
    try await service.sendReminder(
      to: device,
      job: APNsTestSupport.makeTaskJob(),
      remindBeforeMinutes: 10
    )

    let request = try XCTUnwrap(captured.value)
    XCTAssertEqual(request.value(forHTTPHeaderField: "apns-topic"), "com.fallback.bundle")
  }

  func testSendReminderThrowsWhenTopicMissing() async throws {
    let service = APNsService(
      configuration: APNsTestSupport.makeConfiguration(defaultBundleID: nil),
      logger: logger,
      session: APNsTestSupport.makeSession()
    )
    let device = APNsTestSupport.makeDevice(bundleId: "")

    do {
      try await service.sendReminder(
        to: device,
        job: APNsTestSupport.makeTaskJob(),
        remindBeforeMinutes: 10
      )
      XCTFail("expected APNsError.notConfigured")
    } catch let error as APNsError {
      XCTAssertEqual(error.description, "APNs is not configured")
    }
  }

  func testSendReminderThrowsOnNonSuccessStatus() async throws {
    MockURLProtocol.handler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 410,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, Data("Unregistered".utf8))
    }

    let service = APNsService(
      configuration: APNsTestSupport.makeConfiguration(),
      logger: logger,
      session: APNsTestSupport.makeSession()
    )

    do {
      try await service.sendReminder(
        to: APNsTestSupport.makeDevice(),
        job: APNsTestSupport.makeTaskJob(),
        remindBeforeMinutes: 10
      )
      XCTFail("expected APNsError.requestFailed")
    } catch let error as APNsError {
      XCTAssertTrue(error.description.contains("410"))
      XCTAssertTrue(error.description.contains("Unregistered"))
    }
  }

  func testSendReminderAcceptsEnvStyleEscapedPrivateKey() async throws {
    let pem = "\"\(APNsTestSupport.makePEM().replacingOccurrences(of: "\n", with: "\\n"))\""
    let captured = Locked<URLRequest?>(nil)
    MockURLProtocol.handler = { request in
      captured.value = request
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, Data())
    }

    let service = APNsService(
      configuration: APNsConfiguration(
        keyID: "TESTKEYID",
        teamID: "TEAMID1234",
        privateKeyPEM: pem,
        defaultBundleID: nil
      ),
      logger: logger,
      session: APNsTestSupport.makeSession()
    )

    try await service.sendReminder(
      to: APNsTestSupport.makeDevice(),
      job: APNsTestSupport.makeTaskJob(),
      remindBeforeMinutes: 10
    )

    let auth = try XCTUnwrap(captured.value?.value(forHTTPHeaderField: "authorization"))
    let parts = auth.split(separator: " ", maxSplits: 1)
    XCTAssertEqual(parts.first, "bearer")
    let jwtParts = parts.last?.split(separator: ".")
    XCTAssertEqual(jwtParts?.count, 3)
    XCTAssertFalse(jwtParts?.last?.isEmpty ?? true)
  }
}

/// Thread-safe box for capturing values from URLProtocol callbacks.
private final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var _value: Value

  init(_ value: Value) {
    _value = value
  }

  var value: Value {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _value
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      _value = newValue
    }
  }
}
