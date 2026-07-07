import Foundation
import Logging
import PostgresNIO

public enum CalendarRepositoryError: Error, CustomStringConvertible, Sendable {
  case notFound(String)
  case invalidRange

  public var description: String {
    switch self {
    case .notFound(let id):
      "Calendar event not found: \(id)"
    case .invalidRange:
      "endsAt must be after startsAt"
    }
  }
}

public actor CalendarRepository {
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
        CREATE TABLE IF NOT EXISTS calendar_events (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          starts_at TIMESTAMPTZ NOT NULL,
          ends_at TIMESTAMPTZ NOT NULL,
          location TEXT NOT NULL DEFAULT '',
          is_important BOOLEAN NOT NULL DEFAULT FALSE,
          notes TEXT,
          created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        CREATE INDEX IF NOT EXISTS calendar_events_starts_at_idx
          ON calendar_events (starts_at)
        """,
        logger: logger
      )
      try await connection.query(
        """
        INSERT INTO calendar_events (id, title, starts_at, ends_at, location, is_important, notes)
        VALUES (
          'evt_abc123',
          'Team Standup',
          TIMESTAMPTZ '2026-07-07 09:00:00+00',
          TIMESTAMPTZ '2026-07-07 09:30:00+00',
          'Zoom',
          FALSE,
          NULL
        )
        ON CONFLICT (id) DO NOTHING
        """,
        logger: logger
      )
    }
    logger.info("calendar migrations applied")
  }

  public func listEvents(from: Date?, to: Date?) async throws -> [CalendarEventRecord] {
    try await database.withConnection { connection in
      let rows: PostgresRowSequence
      if let from, let to {
        guard to >= from else { throw CalendarRepositoryError.invalidRange }
        rows = try await connection.query(
          """
          SELECT id, title, starts_at, ends_at, location, is_important, notes
          FROM calendar_events
          WHERE ends_at >= \(from) AND starts_at <= \(to)
          ORDER BY starts_at ASC
          """,
          logger: logger
        )
      } else if let from {
        rows = try await connection.query(
          """
          SELECT id, title, starts_at, ends_at, location, is_important, notes
          FROM calendar_events
          WHERE ends_at >= \(from)
          ORDER BY starts_at ASC
          """,
          logger: logger
        )
      } else if let to {
        rows = try await connection.query(
          """
          SELECT id, title, starts_at, ends_at, location, is_important, notes
          FROM calendar_events
          WHERE starts_at <= \(to)
          ORDER BY starts_at ASC
          """,
          logger: logger
        )
      } else {
        rows = try await connection.query(
          """
          SELECT id, title, starts_at, ends_at, location, is_important, notes
          FROM calendar_events
          ORDER BY starts_at ASC
          """,
          logger: logger
        )
      }

      var events: [CalendarEventRecord] = []
      for try await (id, title, startsAt, endsAt, location, isImportant, notes) in rows.decode(
        (String, String, Date, Date, String, Bool, String?).self
      ) {
        events.append(
          CalendarEventRecord(
            id: id,
            title: title,
            startsAt: startsAt,
            endsAt: endsAt,
            location: location,
            isImportant: isImportant,
            notes: notes
          )
        )
      }
      return events
    }
  }

  public func event(id: String) async throws -> CalendarEventRecord {
    try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        SELECT id, title, starts_at, ends_at, location, is_important, notes
        FROM calendar_events
        WHERE id = \(id)
        LIMIT 1
        """,
        logger: logger
      )
      for try await record in rows.decode((String, String, Date, Date, String, Bool, String?).self) {
        let (id, title, startsAt, endsAt, location, isImportant, notes) = record
        return CalendarEventRecord(
          id: id,
          title: title,
          startsAt: startsAt,
          endsAt: endsAt,
          location: location,
          isImportant: isImportant,
          notes: notes
        )
      }
      throw CalendarRepositoryError.notFound(id)
    }
  }

  public func createEvent(
    title: String,
    startsAt: Date,
    endsAt: Date,
    location: String,
    isImportant: Bool,
    notes: String?
  ) async throws -> CalendarEventRecord {
    guard endsAt > startsAt else { throw CalendarRepositoryError.invalidRange }
    let id = Self.makeEventID()
    return try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        INSERT INTO calendar_events (id, title, starts_at, ends_at, location, is_important, notes)
        VALUES (\(id), \(title), \(startsAt), \(endsAt), \(location), \(isImportant), \(notes))
        RETURNING id, title, starts_at, ends_at, location, is_important, notes
        """,
        logger: logger
      )
      for try await record in rows.decode((String, String, Date, Date, String, Bool, String?).self) {
        let (id, title, startsAt, endsAt, location, isImportant, notes) = record
        return CalendarEventRecord(
          id: id,
          title: title,
          startsAt: startsAt,
          endsAt: endsAt,
          location: location,
          isImportant: isImportant,
          notes: notes
        )
      }
      throw CalendarRepositoryError.notFound(id)
    }
  }

  public func deleteEvent(id: String) async throws {
    try await database.withConnection { connection in
      _ = try await connection.query(
        "DELETE FROM calendar_events WHERE id = \(id)",
        logger: logger
      )
    }
  }

  private static func makeEventID() -> String {
    let suffix = UUID().uuidString
      .replacingOccurrences(of: "-", with: "")
      .lowercased()
      .prefix(12)
    return "evt_\(suffix)"
  }
}
