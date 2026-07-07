import Foundation

public struct CalendarEventRecord: Sendable, Equatable {
  public let id: String
  public let title: String
  public let startsAt: Date
  public let endsAt: Date
  public let location: String
  public let isImportant: Bool
  public let notes: String?

  public init(
    id: String,
    title: String,
    startsAt: Date,
    endsAt: Date,
    location: String,
    isImportant: Bool,
    notes: String?
  ) {
    self.id = id
    self.title = title
    self.startsAt = startsAt
    self.endsAt = endsAt
    self.location = location
    self.isImportant = isImportant
    self.notes = notes
  }
}
