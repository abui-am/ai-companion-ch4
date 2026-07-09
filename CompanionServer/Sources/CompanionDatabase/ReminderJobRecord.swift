import Foundation

public enum ReminderKind: String, Sendable, Equatable {
  case task
  case event
}

public enum ReminderJobStatus: String, Sendable, Equatable {
  case pending
  case claimed
  case fired
  case cancelled
  case skipped
}

public struct ReminderJobRecord: Sendable, Equatable {
  public let id: String
  public let kind: ReminderKind
  public let sourceId: String
  public let title: String
  public let fireAt: Date
  public let targetAt: Date
  public let status: ReminderJobStatus
  public let skipReason: String?

  public init(
    id: String,
    kind: ReminderKind,
    sourceId: String,
    title: String,
    fireAt: Date,
    targetAt: Date,
    status: ReminderJobStatus,
    skipReason: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.sourceId = sourceId
    self.title = title
    self.fireAt = fireAt
    self.targetAt = targetAt
    self.status = status
    self.skipReason = skipReason
  }
}
