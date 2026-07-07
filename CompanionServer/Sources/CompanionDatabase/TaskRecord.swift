import Foundation

public struct TaskRecord: Sendable, Equatable {
  public let id: String
  public let title: String
  public let completed: Bool
  public let dueAt: Date?
  public let notes: String?

  public init(
    id: String,
    title: String,
    completed: Bool,
    dueAt: Date?,
    notes: String?
  ) {
    self.id = id
    self.title = title
    self.completed = completed
    self.dueAt = dueAt
    self.notes = notes
  }
}

/// Partial update for `TaskRecord` — only fields marked for update are applied.
public struct TaskPatch: Sendable {
  public var title: String?
  public var dueAt: Date?
  public var notes: String?
  public var completed: Bool?
  public var updateDueAt: Bool
  public var updateNotes: Bool

  public init(
    title: String? = nil,
    dueAt: Date? = nil,
    notes: String? = nil,
    completed: Bool? = nil,
    updateDueAt: Bool = false,
    updateNotes: Bool = false
  ) {
    self.title = title
    self.dueAt = dueAt
    self.notes = notes
    self.completed = completed
    self.updateDueAt = updateDueAt
    self.updateNotes = updateNotes
  }

  func applied(to record: TaskRecord) throws -> TaskRecord {
    if let title {
      guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw TaskRepositoryError.invalidInput("title cannot be empty")
      }
    }
    return TaskRecord(
      id: record.id,
      title: title ?? record.title,
      completed: completed ?? record.completed,
      dueAt: updateDueAt ? dueAt : record.dueAt,
      notes: updateNotes ? notes : record.notes
    )
  }
}
