import CompanionDatabase
import Foundation
import Logging
import XCTest

@testable import CompanionServer

final class MockAPNsService: APNsSending, @unchecked Sendable {
  private(set) var sentJobIDs: [String] = []
  private(set) var sentDeviceIDs: [String] = []
  var shouldFail = false

  func sendReminder(
    to device: PushDeviceRecord,
    job: ReminderJobRecord,
    remindBeforeMinutes: Int
  ) async throws {
    if shouldFail {
      throw APNsError.requestFailed(500, "mock failure")
    }
    sentJobIDs.append(job.id)
    sentDeviceIDs.append(device.id)
  }
}

final class ReminderWorkerTests: XCTestCase {
  private var database: DatabaseService!
  private var reminders: ReminderRepository!
  private var config: ConfigRepository!
  private var pushDevices: PushDeviceRepository!
  private var sessionRegistry: ActiveVoiceSessionRegistry!
  private let testLogger = Logger(label: "ReminderWorkerTests")

  override func setUp() async throws {
    let databaseURL = ProcessInfo.processInfo.environment["DATABASE_URL"]
      ?? "postgres://postgres:postgres@localhost:5432/companion"
    let settings = try DatabaseSettings(urlString: databaseURL)
    database = DatabaseService(settings: settings, logger: testLogger)
    await database.start()
    do {
      try await database.ping()
    } catch {
      throw XCTSkip("Postgres unavailable: \(error)")
    }
    reminders = ReminderRepository(database: database, logger: testLogger)
    config = ConfigRepository(database: database, logger: testLogger)
    pushDevices = PushDeviceRepository(database: database, logger: testLogger)
    try await reminders.migrate()
    try await config.migrate()
    try await pushDevices.migrate()
    sessionRegistry = ActiveVoiceSessionRegistry(logger: testLogger)
  }

  override func tearDown() async throws {
    let logger = testLogger
    try? await database.withConnection { connection in
      _ = try await connection.query(
        """
        DELETE FROM reminder_jobs
        WHERE source_id IN ('task_worker_test', 'evt_worker_test')
        """,
        logger: logger
      )
    }
    try? await pushDevices.delete(deviceToken: "worker-push-token")
    _ = try? await config.update(ConfigPatch(taskReminders: true, calendarAlerts: true))
    await database?.shutdown()
    database = nil
  }

  private func makeWorker(apns: MockAPNsService) -> ReminderWorker {
    ReminderWorker(
      reminders: reminders,
      config: config,
      pushDevices: pushDevices,
      sessionRegistry: sessionRegistry,
      apns: apns,
      logger: testLogger,
      pollInterval: .seconds(1)
    )
  }

  private func forceJobDue(sourceId: String) async throws {
    let logger = testLogger
    try await database.withConnection { connection in
      _ = try await connection.query(
        """
        UPDATE reminder_jobs
        SET fire_at = NOW() - INTERVAL '1 minute',
            status = 'pending'
        WHERE source_id = \(sourceId)
        """,
        logger: logger
      )
    }
  }

  func testSkipsWhenTaskRemindersDisabled() async throws {
    _ = try await config.update(ConfigPatch(taskReminders: false))

    let dueAt = Date().addingTimeInterval(3600)
    try await reminders.upsertTaskReminder(
      task: TaskRecord(
        id: "task_worker_test",
        title: "Test",
        completed: false,
        dueAt: dueAt,
        notes: nil
      ),
      remindBeforeMinutes: 10
    )

    let logger = testLogger
    try await database.withConnection { connection in
      _ = try await connection.query(
        """
        UPDATE reminder_jobs
        SET fire_at = NOW() - INTERVAL '1 minute'
        WHERE source_id = 'task_worker_test'
        """,
        logger: logger
      )
    }

    let mockAPNs = MockAPNsService()
    let worker = makeWorker(apns: mockAPNs)

    await worker.processDueJobs()

    let job = try await reminders.job(kind: .task, sourceId: "task_worker_test")
    XCTAssertEqual(job?.status, .skipped)
    XCTAssertEqual(job?.skipReason, "notifications_disabled")
    XCTAssertTrue(mockAPNs.sentJobIDs.isEmpty)
  }

  func testSkipsWhenCalendarAlertsDisabled() async throws {
    _ = try await config.update(ConfigPatch(calendarAlerts: false))

    let startsAt = Date().addingTimeInterval(3600)
    try await reminders.upsertEventReminder(
      event: CalendarEventRecord(
        id: "evt_worker_test",
        title: "Standup",
        startsAt: startsAt,
        endsAt: startsAt.addingTimeInterval(1800),
        location: "Zoom",
        isImportant: false,
        notes: nil
      ),
      remindBeforeMinutes: 10
    )
    try await forceJobDue(sourceId: "evt_worker_test")

    let mockAPNs = MockAPNsService()
    let worker = makeWorker(apns: mockAPNs)
    await worker.processDueJobs()

    let job = try await reminders.job(kind: .event, sourceId: "evt_worker_test")
    XCTAssertEqual(job?.status, .skipped)
    XCTAssertEqual(job?.skipReason, "notifications_disabled")
    XCTAssertTrue(mockAPNs.sentJobIDs.isEmpty)
  }

  func testSendsPushToRegisteredDevices() async throws {
    _ = try await config.update(ConfigPatch(taskReminders: true))

    let device = try await pushDevices.upsert(
      platform: .macos,
      deviceToken: "worker-push-token",
      bundleId: "com.example.botchill",
      environment: .sandbox
    )

    let dueAt = Date().addingTimeInterval(3600)
    try await reminders.upsertTaskReminder(
      task: TaskRecord(
        id: "task_worker_test",
        title: "Test",
        completed: false,
        dueAt: dueAt,
        notes: nil
      ),
      remindBeforeMinutes: 10
    )
    try await forceJobDue(sourceId: "task_worker_test")

    let mockAPNs = MockAPNsService()
    let worker = makeWorker(apns: mockAPNs)
    await worker.processDueJobs()

    let job = try await reminders.job(kind: .task, sourceId: "task_worker_test")
    XCTAssertEqual(job?.status, .fired)
    XCTAssertEqual(mockAPNs.sentJobIDs, [job?.id].compactMap { $0 })
    XCTAssertEqual(mockAPNs.sentDeviceIDs, [device.id])
  }

  func testMarksFiredWhenNoDevicesRegistered() async throws {
    _ = try await config.update(ConfigPatch(taskReminders: true))

    let dueAt = Date().addingTimeInterval(3600)
    try await reminders.upsertTaskReminder(
      task: TaskRecord(
        id: "task_worker_test",
        title: "Test",
        completed: false,
        dueAt: dueAt,
        notes: nil
      ),
      remindBeforeMinutes: 10
    )
    try await forceJobDue(sourceId: "task_worker_test")

    let mockAPNs = MockAPNsService()
    let worker = makeWorker(apns: mockAPNs)
    await worker.processDueJobs()

    let job = try await reminders.job(kind: .task, sourceId: "task_worker_test")
    XCTAssertEqual(job?.status, .fired)
    XCTAssertTrue(mockAPNs.sentJobIDs.isEmpty)
  }

  func testMarksFiredWhenAPNsSendFails() async throws {
    _ = try await config.update(ConfigPatch(taskReminders: true))
    _ = try await pushDevices.upsert(
      platform: .macos,
      deviceToken: "worker-push-token",
      bundleId: "com.example.botchill",
      environment: .sandbox
    )

    let dueAt = Date().addingTimeInterval(3600)
    try await reminders.upsertTaskReminder(
      task: TaskRecord(
        id: "task_worker_test",
        title: "Test",
        completed: false,
        dueAt: dueAt,
        notes: nil
      ),
      remindBeforeMinutes: 10
    )
    try await forceJobDue(sourceId: "task_worker_test")

    let mockAPNs = MockAPNsService()
    mockAPNs.shouldFail = true
    let worker = makeWorker(apns: mockAPNs)
    await worker.processDueJobs()

    let job = try await reminders.job(kind: .task, sourceId: "task_worker_test")
    XCTAssertEqual(job?.status, .fired)
    XCTAssertEqual(mockAPNs.sentJobIDs.count, 0)
  }
}
