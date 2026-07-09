import Foundation
import Logging
import PostgresNIO

public enum ReminderRepositoryError: Error, CustomStringConvertible, Sendable {
  case notFound(String)
  case invalidInput(String)

  public var description: String {
    switch self {
    case .notFound(let id):
      "Reminder job not found: \(id)"
    case .invalidInput(let message):
      message
    }
  }
}

public actor ReminderRepository {
  private let database: DatabaseService
  private let logger: Logger

  public init(database: DatabaseService, logger: Logger) {
    self.database = database
    self.logger = logger
  }

  public func migrate() async throws {
    try await database.withConnection { connection in
      try await connection.query(
        """
        CREATE TABLE IF NOT EXISTS reminder_jobs (
          id TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          source_id TEXT NOT NULL,
          title TEXT NOT NULL,
          fire_at TIMESTAMPTZ NOT NULL,
          target_at TIMESTAMPTZ NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending',
          skip_reason TEXT,
          created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          UNIQUE (kind, source_id)
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        CREATE INDEX IF NOT EXISTS reminder_jobs_pending_fire_at_idx
          ON reminder_jobs (status, fire_at)
          WHERE status = 'pending'
        """,
        logger: logger
      )
    }
    logger.info("reminder migrations applied")
  }

  public func upsertTaskReminder(
    task: TaskRecord,
    remindBeforeMinutes: Int,
    now: Date = Date()
  ) async throws {
    if task.completed || task.dueAt == nil {
      try await cancel(kind: .task, sourceId: task.id)
      return
    }
    guard let dueAt = task.dueAt else { return }
    let fireAt = dueAt.addingTimeInterval(-TimeInterval(remindBeforeMinutes * 60))
    if fireAt <= now {
      try await upsert(
        kind: .task,
        sourceId: task.id,
        title: task.title,
        fireAt: fireAt,
        targetAt: dueAt,
        status: .skipped,
        skipReason: "fire_at_in_past"
      )
      return
    }
    try await upsert(
      kind: .task,
      sourceId: task.id,
      title: task.title,
      fireAt: fireAt,
      targetAt: dueAt,
      status: .pending,
      skipReason: nil
    )
  }

  public func upsertEventReminder(
    event: CalendarEventRecord,
    remindBeforeMinutes: Int,
    now: Date = Date()
  ) async throws {
    let fireAt = event.startsAt.addingTimeInterval(-TimeInterval(remindBeforeMinutes * 60))
    if fireAt <= now {
      try await upsert(
        kind: .event,
        sourceId: event.id,
        title: event.title,
        fireAt: fireAt,
        targetAt: event.startsAt,
        status: .skipped,
        skipReason: "fire_at_in_past"
      )
      return
    }
    try await upsert(
      kind: .event,
      sourceId: event.id,
      title: event.title,
      fireAt: fireAt,
      targetAt: event.startsAt,
      status: .pending,
      skipReason: nil
    )
  }

  public func cancel(kind: ReminderKind, sourceId: String) async throws {
    let id = Self.makeJobID(kind: kind, sourceId: sourceId)
    try await database.withConnection { connection in
      _ = try await connection.query(
        """
        UPDATE reminder_jobs
        SET status = 'cancelled',
            skip_reason = NULL,
            updated_at = NOW()
        WHERE id = \(id)
          AND status IN ('pending', 'claimed')
        """,
        logger: logger
      )
    }
  }

  public func recomputePendingFireTimes(remindBeforeMinutes: Int) async throws {
    try await database.withConnection { connection in
      _ = try await connection.query(
        """
        UPDATE reminder_jobs
        SET fire_at = target_at - (\(remindBeforeMinutes) * INTERVAL '1 minute'),
            updated_at = NOW()
        WHERE status = 'pending'
        """,
        logger: logger
      )
    }
  }

  public func releaseStaleClaims(olderThan: TimeInterval = 60) async throws {
    try await database.withConnection { connection in
      _ = try await connection.query(
        """
        UPDATE reminder_jobs
        SET status = 'pending',
            updated_at = NOW()
        WHERE status = 'claimed'
          AND updated_at < NOW() - (\(Int(olderThan)) * INTERVAL '1 second')
        """,
        logger: logger
      )
    }
  }

  public func claimDueJobs(now: Date = Date(), limit: Int = 20) async throws -> [ReminderJobRecord] {
    try await releaseStaleClaims()
    return try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        WITH due AS (
          SELECT id
          FROM reminder_jobs
          WHERE status = 'pending'
            AND fire_at <= \(now)
          ORDER BY fire_at ASC
          LIMIT \(limit)
          FOR UPDATE SKIP LOCKED
        )
        UPDATE reminder_jobs AS j
        SET status = 'claimed',
            updated_at = NOW()
        FROM due
        WHERE j.id = due.id
        RETURNING j.id, j.kind, j.source_id, j.title, j.fire_at, j.target_at, j.status, j.skip_reason
        """,
        logger: logger
      )
      var jobs: [ReminderJobRecord] = []
      for try await row in rows.decode(
        (String, String, String, String, Date, Date, String, String?).self
      ) {
        let (id, kindRaw, sourceId, title, fireAt, targetAt, statusRaw, skipReason) = row
        guard let kind = ReminderKind(rawValue: kindRaw),
              let status = ReminderJobStatus(rawValue: statusRaw)
        else { continue }
        jobs.append(
          ReminderJobRecord(
            id: id,
            kind: kind,
            sourceId: sourceId,
            title: title,
            fireAt: fireAt,
            targetAt: targetAt,
            status: status,
            skipReason: skipReason
          )
        )
      }
      return jobs
    }
  }

  public func markFired(id: String) async throws {
    try await database.withConnection { connection in
      _ = try await connection.query(
        """
        UPDATE reminder_jobs
        SET status = 'fired',
            skip_reason = NULL,
            updated_at = NOW()
        WHERE id = \(id)
        """,
        logger: logger
      )
    }
  }

  public func markSkipped(id: String, reason: String) async throws {
    try await database.withConnection { connection in
      _ = try await connection.query(
        """
        UPDATE reminder_jobs
        SET status = 'skipped',
            skip_reason = \(reason),
            updated_at = NOW()
        WHERE id = \(id)
        """,
        logger: logger
      )
    }
  }

  public func job(kind: ReminderKind, sourceId: String) async throws -> ReminderJobRecord? {
    let id = Self.makeJobID(kind: kind, sourceId: sourceId)
    return try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        SELECT id, kind, source_id, title, fire_at, target_at, status, skip_reason
        FROM reminder_jobs
        WHERE id = \(id)
        LIMIT 1
        """,
        logger: logger
      )
      for try await row in rows.decode(
        (String, String, String, String, Date, Date, String, String?).self
      ) {
        let (id, kindRaw, sourceId, title, fireAt, targetAt, statusRaw, skipReason) = row
        guard let kind = ReminderKind(rawValue: kindRaw),
              let status = ReminderJobStatus(rawValue: statusRaw)
        else { return nil }
        return ReminderJobRecord(
          id: id,
          kind: kind,
          sourceId: sourceId,
          title: title,
          fireAt: fireAt,
          targetAt: targetAt,
          status: status,
          skipReason: skipReason
        )
      }
      return nil
    }
  }

  private func upsert(
    kind: ReminderKind,
    sourceId: String,
    title: String,
    fireAt: Date,
    targetAt: Date,
    status: ReminderJobStatus,
    skipReason: String?
  ) async throws {
    let id = Self.makeJobID(kind: kind, sourceId: sourceId)
    try await database.withConnection { connection in
      _ = try await connection.query(
        """
        INSERT INTO reminder_jobs (
          id, kind, source_id, title, fire_at, target_at, status, skip_reason
        )
        VALUES (
          \(id), \(kind.rawValue), \(sourceId), \(title), \(fireAt), \(targetAt),
          \(status.rawValue), \(skipReason)
        )
        ON CONFLICT (kind, source_id) DO UPDATE SET
          title = EXCLUDED.title,
          fire_at = EXCLUDED.fire_at,
          target_at = EXCLUDED.target_at,
          status = EXCLUDED.status,
          skip_reason = EXCLUDED.skip_reason,
          updated_at = NOW()
        """,
        logger: logger
      )
    }
  }

  static func makeJobID(kind: ReminderKind, sourceId: String) -> String {
    "reminder_\(kind.rawValue)_\(sourceId)"
  }
}
