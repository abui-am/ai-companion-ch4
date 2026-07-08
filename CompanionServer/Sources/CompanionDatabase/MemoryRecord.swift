import Foundation

public struct MemoryRecord: Sendable, Equatable {
  public let id: String
  public let content: String
  public let source: String
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    id: String,
    content: String,
    source: String,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.content = content
    self.source = source
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}
