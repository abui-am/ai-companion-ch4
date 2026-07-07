import Foundation

public struct ConversationSessionRecord: Sendable, Equatable {
  public let id: String
  public let startedAt: Date
  public let endedAt: Date?

  public init(id: String, startedAt: Date, endedAt: Date?) {
    self.id = id
    self.startedAt = startedAt
    self.endedAt = endedAt
  }
}
