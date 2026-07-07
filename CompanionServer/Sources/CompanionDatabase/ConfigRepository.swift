import Foundation
import Logging
import PostgresNIO

public enum ConfigRepositoryError: Error, CustomStringConvertible, Sendable {
  case notFound
  case corruptData(String)
  case invalidRemindBeforeMinutes(Int)

  public var description: String {
    switch self {
    case .notFound:
      "Config row not found — migration may not have run"
    case .corruptData(let field):
      "Config row has invalid stored value for \(field)"
    case .invalidRemindBeforeMinutes(let value):
      "remindBeforeMinutes must be one of 5, 10, 15, 30 (got \(value))"
    }
  }
}

/// Backs the Settings page. Stores a single row of user-editable preferences —
/// device connection is intentionally not persisted here (see `ConfigRoutes`).
public actor ConfigRepository {
  private static let rowID = "default"

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
        CREATE TABLE IF NOT EXISTS companion_config (
          id TEXT PRIMARY KEY DEFAULT 'default',
          personality TEXT NOT NULL DEFAULT 'calm',
          appearance TEXT NOT NULL DEFAULT 'light',
          task_reminders BOOLEAN NOT NULL DEFAULT TRUE,
          calendar_alerts BOOLEAN NOT NULL DEFAULT TRUE,
          remind_before_minutes INT NOT NULL DEFAULT 10,
          camera_access BOOLEAN NOT NULL DEFAULT TRUE,
          personalization_data BOOLEAN NOT NULL DEFAULT TRUE,
          language TEXT NOT NULL DEFAULT 'english',
          updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        INSERT INTO companion_config (id)
        VALUES ('default')
        ON CONFLICT (id) DO NOTHING
        """,
        logger: logger
      )
    }
    logger.info("config migrations applied")
  }

  public func get() async throws -> ConfigRecord {
    try await database.withConnection { connection in
      // Split across two queries — a single 8-column tuple decode is unwieldy to read.
      let firstHalf = try await connection.query(
        """
        SELECT personality, appearance, task_reminders, calendar_alerts
        FROM companion_config
        WHERE id = \(Self.rowID)
        LIMIT 1
        """,
        logger: logger
      )
      var personality: String?
      var appearance: String?
      var taskReminders: Bool?
      var calendarAlerts: Bool?
      for try await row in firstHalf.decode((String, String, Bool, Bool).self) {
        (personality, appearance, taskReminders, calendarAlerts) = row
      }
      guard let personality, let appearance, let taskReminders, let calendarAlerts else {
        throw ConfigRepositoryError.notFound
      }

      let secondHalf = try await connection.query(
        """
        SELECT remind_before_minutes, camera_access, personalization_data, language
        FROM companion_config
        WHERE id = \(Self.rowID)
        LIMIT 1
        """,
        logger: logger
      )
      var remindBeforeMinutes: Int?
      var cameraAccess: Bool?
      var personalizationData: Bool?
      var language: String?
      for try await row in secondHalf.decode((Int, Bool, Bool, String).self) {
        (remindBeforeMinutes, cameraAccess, personalizationData, language) = row
      }
      guard let remindBeforeMinutes, let cameraAccess, let personalizationData, let language else {
        throw ConfigRepositoryError.notFound
      }

      return try Self.makeRecord(
        personality: personality,
        appearance: appearance,
        taskReminders: taskReminders,
        calendarAlerts: calendarAlerts,
        remindBeforeMinutes: remindBeforeMinutes,
        cameraAccess: cameraAccess,
        personalizationData: personalizationData,
        language: language
      )
    }
  }

  public func update(_ patch: ConfigPatch) async throws -> ConfigRecord {
    let current = try await get()
    let merged = try patch.applied(to: current)
    try await database.withConnection { connection in
      _ = try await connection.query(
        """
        UPDATE companion_config
        SET personality = \(merged.personality.rawValue),
            appearance = \(merged.appearance.rawValue),
            task_reminders = \(merged.taskReminders),
            calendar_alerts = \(merged.calendarAlerts),
            remind_before_minutes = \(merged.remindBeforeMinutes),
            camera_access = \(merged.cameraAccess),
            personalization_data = \(merged.personalizationData),
            language = \(merged.language.rawValue),
            updated_at = NOW()
        WHERE id = \(Self.rowID)
        """,
        logger: logger
      )
    }
    return merged
  }

  private static func makeRecord(
    personality: String,
    appearance: String,
    taskReminders: Bool,
    calendarAlerts: Bool,
    remindBeforeMinutes: Int,
    cameraAccess: Bool,
    personalizationData: Bool,
    language: String
  ) throws -> ConfigRecord {
    guard let personality = ConfigPersonality(rawValue: personality) else {
      throw ConfigRepositoryError.corruptData("personality")
    }
    guard let appearance = ConfigAppearance(rawValue: appearance) else {
      throw ConfigRepositoryError.corruptData("appearance")
    }
    guard let language = ConfigLanguage(rawValue: language) else {
      throw ConfigRepositoryError.corruptData("language")
    }
    return ConfigRecord(
      personality: personality,
      appearance: appearance,
      taskReminders: taskReminders,
      calendarAlerts: calendarAlerts,
      remindBeforeMinutes: remindBeforeMinutes,
      cameraAccess: cameraAccess,
      personalizationData: personalizationData,
      language: language
    )
  }
}
