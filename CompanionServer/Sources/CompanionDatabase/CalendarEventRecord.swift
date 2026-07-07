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

/// Partial update for `CalendarEventRecord` — only fields marked for update are applied.
public struct CalendarPatch: Sendable {
  public var title: String?
  public var startsAt: Date?
  public var endsAt: Date?
  public var location: String?
  public var isImportant: Bool?
  public var notes: String?
  public var updateNotes: Bool

  public init(
    title: String? = nil,
    startsAt: Date? = nil,
    endsAt: Date? = nil,
    location: String? = nil,
    isImportant: Bool? = nil,
    notes: String? = nil,
    updateNotes: Bool = false
  ) {
    self.title = title
    self.startsAt = startsAt
    self.endsAt = endsAt
    self.location = location
    self.isImportant = isImportant
    self.notes = notes
    self.updateNotes = updateNotes
  }

  func applied(to record: CalendarEventRecord) throws -> CalendarEventRecord {
    if let title {
      guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CalendarRepositoryError.invalidInput("title cannot be empty")
      }
    }
    let mergedStartsAt = startsAt ?? record.startsAt
    let mergedEndsAt = endsAt ?? record.endsAt
    guard mergedEndsAt > mergedStartsAt else {
      throw CalendarRepositoryError.invalidRange
    }
    return CalendarEventRecord(
      id: record.id,
      title: title ?? record.title,
      startsAt: mergedStartsAt,
      endsAt: mergedEndsAt,
      location: location ?? record.location,
      isImportant: isImportant ?? record.isImportant,
      notes: updateNotes ? notes : record.notes
    )
  }
}
