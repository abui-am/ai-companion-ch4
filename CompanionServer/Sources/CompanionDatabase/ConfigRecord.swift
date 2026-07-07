import Foundation

public enum ConfigPersonality: String, Codable, Sendable, CaseIterable {
  case calm
  case energetic
  case professional
}

public enum ConfigAppearance: String, Codable, Sendable, CaseIterable {
  case system
  case light
  case dark
}

public enum ConfigLanguage: String, Codable, Sendable, CaseIterable {
  case english
  case spanish
  case french

  /// Language name understood by `CompanionPrompt.system(responseLanguage:)`.
  public var promptLabel: String {
    switch self {
    case .english: "English"
    case .spanish: "Spanish"
    case .french: "French"
    }
  }
}

public struct ConfigRecord: Sendable, Equatable {
  public static let allowedRemindBeforeMinutes: Set<Int> = [5, 10, 15, 30]

  public let personality: ConfigPersonality
  public let appearance: ConfigAppearance
  public let taskReminders: Bool
  public let calendarAlerts: Bool
  public let remindBeforeMinutes: Int
  public let cameraAccess: Bool
  public let personalizationData: Bool
  public let language: ConfigLanguage

  public init(
    personality: ConfigPersonality,
    appearance: ConfigAppearance,
    taskReminders: Bool,
    calendarAlerts: Bool,
    remindBeforeMinutes: Int,
    cameraAccess: Bool,
    personalizationData: Bool,
    language: ConfigLanguage
  ) {
    self.personality = personality
    self.appearance = appearance
    self.taskReminders = taskReminders
    self.calendarAlerts = calendarAlerts
    self.remindBeforeMinutes = remindBeforeMinutes
    self.cameraAccess = cameraAccess
    self.personalizationData = personalizationData
    self.language = language
  }
}

/// Partial update for `ConfigRecord` — only non-nil fields are applied.
public struct ConfigPatch: Sendable {
  public var personality: ConfigPersonality?
  public var appearance: ConfigAppearance?
  public var taskReminders: Bool?
  public var calendarAlerts: Bool?
  public var remindBeforeMinutes: Int?
  public var cameraAccess: Bool?
  public var personalizationData: Bool?
  public var language: ConfigLanguage?

  public init(
    personality: ConfigPersonality? = nil,
    appearance: ConfigAppearance? = nil,
    taskReminders: Bool? = nil,
    calendarAlerts: Bool? = nil,
    remindBeforeMinutes: Int? = nil,
    cameraAccess: Bool? = nil,
    personalizationData: Bool? = nil,
    language: ConfigLanguage? = nil
  ) {
    self.personality = personality
    self.appearance = appearance
    self.taskReminders = taskReminders
    self.calendarAlerts = calendarAlerts
    self.remindBeforeMinutes = remindBeforeMinutes
    self.cameraAccess = cameraAccess
    self.personalizationData = personalizationData
    self.language = language
  }

  func applied(to record: ConfigRecord) throws -> ConfigRecord {
    var remindBeforeMinutes = record.remindBeforeMinutes
    if let value = self.remindBeforeMinutes {
      guard ConfigRecord.allowedRemindBeforeMinutes.contains(value) else {
        throw ConfigRepositoryError.invalidRemindBeforeMinutes(value)
      }
      remindBeforeMinutes = value
    }
    return ConfigRecord(
      personality: personality ?? record.personality,
      appearance: appearance ?? record.appearance,
      taskReminders: taskReminders ?? record.taskReminders,
      calendarAlerts: calendarAlerts ?? record.calendarAlerts,
      remindBeforeMinutes: remindBeforeMinutes,
      cameraAccess: cameraAccess ?? record.cameraAccess,
      personalizationData: personalizationData ?? record.personalizationData,
      language: language ?? record.language
    )
  }
}
