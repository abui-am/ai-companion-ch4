import Foundation

public struct ConversationMessageRecord: Sendable, Equatable {
  public let id: String
  public let sessionId: String
  public let turnId: String
  public let role: String
  public let content: String
  public let audioPath: String?
  public let createdAt: Date

  public init(
    id: String,
    sessionId: String,
    turnId: String,
    role: String,
    content: String,
    audioPath: String?,
    createdAt: Date
  ) {
    self.id = id
    self.sessionId = sessionId
    self.turnId = turnId
    self.role = role
    self.content = content
    self.audioPath = audioPath
    self.createdAt = createdAt
  }
}
