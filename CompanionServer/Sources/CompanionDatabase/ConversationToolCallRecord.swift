import Foundation

public struct ConversationToolCallRecord: Sendable, Equatable {
  public let id: String
  public let sessionId: String
  public let turnId: String
  public let name: String
  public let detail: String
  public let arguments: String
  public let output: String
  public let createdAt: Date

  public init(
    id: String,
    sessionId: String,
    turnId: String,
    name: String,
    detail: String,
    arguments: String,
    output: String,
    createdAt: Date
  ) {
    self.id = id
    self.sessionId = sessionId
    self.turnId = turnId
    self.name = name
    self.detail = detail
    self.arguments = arguments
    self.output = output
    self.createdAt = createdAt
  }
}
