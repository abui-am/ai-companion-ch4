import Foundation

public struct ProfileRecord: Sendable, Equatable {
  public let name: String?
  public let role: String?
  public let focusSecondsToday: Int
  public let date: String
  public let updatedAt: Date

  public init(
    name: String?,
    role: String?,
    focusSecondsToday: Int,
    date: String,
    updatedAt: Date
  ) {
    self.name = name
    self.role = role
    self.focusSecondsToday = focusSecondsToday
    self.date = date
    self.updatedAt = updatedAt
  }
}

/// Partial update for `ProfileRecord` where omitted fields are left unchanged.
public struct ProfilePatch: Sendable {
  public var name: String?
  public var role: String?
  public var updateName: Bool
  public var updateRole: Bool

  public init(
    name: String? = nil,
    role: String? = nil,
    updateName: Bool = false,
    updateRole: Bool = false
  ) {
    self.name = name
    self.role = role
    self.updateName = updateName
    self.updateRole = updateRole
  }

  func applied(to record: ProfileRecord) -> ProfileRecord {
    ProfileRecord(
      name: updateName ? name : record.name,
      role: updateRole ? role : record.role,
      focusSecondsToday: record.focusSecondsToday,
      date: record.date,
      updatedAt: record.updatedAt
    )
  }
}
