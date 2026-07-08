import Foundation
import Logging
import PostgresNIO

public enum ProfileRepositoryError: Error, CustomStringConvertible, Sendable {
  case notFound
  case invalidInput(String)

  public var description: String {
    switch self {
    case .notFound:
      "Profile row not found — migration may not have run"
    case .invalidInput(let message):
      message
    }
  }
}

public actor ProfileRepository {
  private static let rowID = "default"

  private let database: DatabaseService
  private let logger: Logger

  public init(database: DatabaseService, logger: Logger) {
    self.database = database
    self.logger = logger
  }

  public func migrate() async throws {
    let today = Self.localDateString(for: Date(), timeZone: .current)
    try await database.withConnection { connection in
      try await connection.query(
        """
        CREATE TABLE IF NOT EXISTS companion_profile (
          id TEXT PRIMARY KEY DEFAULT 'default',
          name TEXT,
          role TEXT,
          focus_seconds_today INT NOT NULL DEFAULT 0,
          focus_date TEXT NOT NULL,
          updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          CHECK (focus_seconds_today >= 0)
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        INSERT INTO companion_profile (id, name, role, focus_seconds_today, focus_date)
        VALUES (\(Self.rowID), NULL, NULL, 0, \(today))
        ON CONFLICT (id) DO NOTHING
        """,
        logger: logger
      )
    }
    logger.info("profile migrations applied")
  }

  public func getProfile(now: Date = Date()) async throws -> ProfileRecord {
    try await database.withConnection { connection in
      try await currentWithRollover(on: connection, now: now)
    }
  }

  public func updateProfile(_ patch: ProfilePatch, now: Date = Date()) async throws -> ProfileRecord {
    var mutablePatch = patch
    if patch.updateName {
      mutablePatch.name = try Self.sanitizeTextField(patch.name, field: "name")
    }
    if patch.updateRole {
      mutablePatch.role = try Self.sanitizeTextField(patch.role, field: "role")
    }
    let sanitizedPatch = mutablePatch
    return try await database.withConnection { connection in
      let current = try await currentWithRollover(on: connection, now: now)
      let merged = sanitizedPatch.applied(to: current)
      return try await updateProfileRow(
        on: connection,
        name: merged.name,
        role: merged.role,
        focusSecondsToday: merged.focusSecondsToday,
        focusDate: merged.date
      )
    }
  }

  public func addFocus(seconds: Int, now: Date = Date()) async throws -> ProfileRecord {
    guard seconds >= 0 else {
      throw ProfileRepositoryError.invalidInput("seconds must be a non-negative integer")
    }
    return try await database.withConnection { connection in
      let current = try await currentWithRollover(on: connection, now: now)
      let (newTotal, overflowed) = current.focusSecondsToday.addingReportingOverflow(seconds)
      guard !overflowed else {
        throw ProfileRepositoryError.invalidInput("focusSecondsToday overflowed")
      }
      return try await updateProfileRow(
        on: connection,
        name: current.name,
        role: current.role,
        focusSecondsToday: newTotal,
        focusDate: current.date
      )
    }
  }

  private func currentWithRollover(on connection: PostgresConnection, now: Date) async throws -> ProfileRecord {
    let current = try await fetchCurrentProfile(on: connection)
    let today = Self.localDateString(for: now, timeZone: .current)
    guard Self.shouldResetFocus(storedDate: current.date, today: today) else {
      return current
    }
    return try await updateProfileRow(
      on: connection,
      name: current.name,
      role: current.role,
      focusSecondsToday: 0,
      focusDate: today
    )
  }

  private func fetchCurrentProfile(on connection: PostgresConnection) async throws -> ProfileRecord {
    let rows = try await connection.query(
      """
      SELECT name, role, focus_seconds_today, focus_date, updated_at
      FROM companion_profile
      WHERE id = \(Self.rowID)
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows.decode((String?, String?, Int, String, Date).self) {
      let (name, role, focusSecondsToday, date, updatedAt) = row
      return ProfileRecord(
        name: name,
        role: role,
        focusSecondsToday: focusSecondsToday,
        date: date,
        updatedAt: updatedAt
      )
    }
    throw ProfileRepositoryError.notFound
  }

  private func updateProfileRow(
    on connection: PostgresConnection,
    name: String?,
    role: String?,
    focusSecondsToday: Int,
    focusDate: String
  ) async throws -> ProfileRecord {
    let rows = try await connection.query(
      """
      UPDATE companion_profile
      SET name = \(name),
          role = \(role),
          focus_seconds_today = \(focusSecondsToday),
          focus_date = \(focusDate),
          updated_at = NOW()
      WHERE id = \(Self.rowID)
      RETURNING name, role, focus_seconds_today, focus_date, updated_at
      """,
      logger: logger
    )
    for try await row in rows.decode((String?, String?, Int, String, Date).self) {
      let (name, role, focusSecondsToday, date, updatedAt) = row
      return ProfileRecord(
        name: name,
        role: role,
        focusSecondsToday: focusSecondsToday,
        date: date,
        updatedAt: updatedAt
      )
    }
    throw ProfileRepositoryError.notFound
  }

  private static func sanitizeTextField(_ value: String?, field: String) throws -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count <= 100 else {
      throw ProfileRepositoryError.invalidInput("\(field) must be at most 100 characters")
    }
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func shouldResetFocus(storedDate: String, today: String) -> Bool {
    let formatter = makeLocalDateFormatter()
    guard let stored = formatter.date(from: storedDate),
          let current = formatter.date(from: today)
    else {
      return storedDate != today
    }
    return current > stored
  }

  private static func localDateString(for date: Date, timeZone: TimeZone) -> String {
    let formatter = makeLocalDateFormatter()
    formatter.timeZone = timeZone
    return formatter.string(from: date)
  }

  private static func makeLocalDateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }
}
