import Foundation

public struct ConversationSessionRecord: Sendable, Equatable {
  public let id: String
  public let startedAt: Date
  public let endedAt: Date?
  /// Distinct voice turns in this session (`turn-1`, `turn-2`, …).
  public let voiceCount: Int

  public init(id: String, startedAt: Date, endedAt: Date?, voiceCount: Int = 0) {
    self.id = id
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.voiceCount = voiceCount
  }
}
