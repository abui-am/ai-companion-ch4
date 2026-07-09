import Foundation

public enum PushPlatform: String, Sendable, Equatable, Codable {
  case macos
}

public enum PushEnvironment: String, Sendable, Equatable, Codable {
  case sandbox
  case production
}

public struct PushDeviceRecord: Sendable, Equatable {
  public let id: String
  public let platform: PushPlatform
  public let deviceToken: String
  public let bundleId: String
  public let environment: PushEnvironment
  public let updatedAt: Date

  public init(
    id: String,
    platform: PushPlatform,
    deviceToken: String,
    bundleId: String,
    environment: PushEnvironment,
    updatedAt: Date
  ) {
    self.id = id
    self.platform = platform
    self.deviceToken = deviceToken
    self.bundleId = bundleId
    self.environment = environment
    self.updatedAt = updatedAt
  }
}
