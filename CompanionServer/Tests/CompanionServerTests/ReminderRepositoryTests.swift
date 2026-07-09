import CompanionDatabase
import Foundation
import Logging
import XCTest

final class ReminderRepositoryTests: XCTestCase {
  private var database: DatabaseService!
  private var reminders: ReminderRepository!
  private var tasks: TaskRepository!
  private let logger = Logger(label: "ReminderRepositoryTests")
  private var createdTaskIDs: [String] = []

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
    reminders = ReminderRepository(database: database, logger: logger)
    tasks = TaskRepository(database: database, logger: logger)
    try await reminders.migrate()
    try await tasks.migrate()
  }

  override func tearDown() async throws {
    for id in createdTaskIDs {
      try? await tasks.deleteTask(id: id)
    }
    createdTaskIDs.removeAll()
    await database?.shutdown()
    database = nil
    reminders = nil
    tasks = nil
  }

  func testUpsertTaskReminderComputesFireAt() async throws {
    let dueAt = Date().addingTimeInterval(3600)
    let record = try await tasks.createTask(title: "Water plants", dueAt: dueAt, notes: nil)
    createdTaskIDs.append(record.id)

    try await reminders.upsertTaskReminder(task: record, remindBeforeMinutes: 10)

    let job = try await reminders.job(kind: .task, sourceId: record.id)
    XCTAssertNotNil(job)
    XCTAssertEqual(job?.status, .pending)
    XCTAssertEqual(job?.title, "Water plants")
    let expectedFireAt = dueAt.addingTimeInterval(-600)
    XCTAssertEqual(job?.fireAt.timeIntervalSince1970 ?? 0, expectedFireAt.timeIntervalSince1970, accuracy: 1)
  }

  func testUpsertTaskReminderCancelsWhenCompleted() async throws {
    let record = try await tasks.createTask(title: "No due", dueAt: nil, notes: nil)
    createdTaskIDs.append(record.id)

    try await reminders.upsertTaskReminder(task: record, remindBeforeMinutes: 10)
    try await reminders.cancel(kind: .task, sourceId: record.id)

    let updated = try await tasks.updateTask(
      id: record.id,
      patch: TaskPatch(completed: true)
    )
    try await reminders.upsertTaskReminder(task: updated, remindBeforeMinutes: 10)

    let job = try await reminders.job(kind: .task, sourceId: record.id)
    XCTAssertNil(job)
  }

  func testClaimDueJobsMarksClaimed() async throws {
    let dueAt = Date().addingTimeInterval(30)
    let record = try await tasks.createTask(title: "Soon", dueAt: dueAt, notes: nil)
    createdTaskIDs.append(record.id)

    try await reminders.upsertTaskReminder(
      task: record,
      remindBeforeMinutes: 1,
      now: Date().addingTimeInterval(-120)
    )

    let claimed = try await reminders.claimDueJobs(now: Date().addingTimeInterval(60))
    XCTAssertEqual(claimed.count, 1)
    XCTAssertEqual(claimed.first?.status, .claimed)
    XCTAssertEqual(claimed.first?.sourceId, record.id)
  }

  func testRecomputePendingFireTimes() async throws {
    let dueAt = Date().addingTimeInterval(7200)
    let record = try await tasks.createTask(title: "Later", dueAt: dueAt, notes: nil)
    createdTaskIDs.append(record.id)

    try await reminders.upsertTaskReminder(task: record, remindBeforeMinutes: 10)
    try await reminders.recomputePendingFireTimes(remindBeforeMinutes: 30)

    let job = try await reminders.job(kind: .task, sourceId: record.id)
    let expectedFireAt = dueAt.addingTimeInterval(-1800)
    XCTAssertEqual(job?.fireAt.timeIntervalSince1970 ?? 0, expectedFireAt.timeIntervalSince1970, accuracy: 1)
  }
}
