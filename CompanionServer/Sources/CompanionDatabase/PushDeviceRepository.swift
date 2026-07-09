import Foundation
import Logging
import PostgresNIO

public enum PushDeviceRepositoryError: Error, CustomStringConvertible, Sendable {
  case notFound(String)
  case invalidInput(String)

  public var description: String {
    switch self {
    case .notFound(let id):
      "Push device not found: \(id)"
    case .invalidInput(let message):
      message
    }
  }
}

public actor PushDeviceRepository {
  private let database: DatabaseService
  private let logger: Logger

  public init(database: DatabaseService, logger: Logger) {
    self.database = database
    self.logger = logger
  }

  public func migrate() async throws {
    try await database.withConnection { connection in
      try await connection.query(
        """
        CREATE TABLE IF NOT EXISTS push_devices (
          id TEXT PRIMARY KEY,
          platform TEXT NOT NULL,
          device_token TEXT NOT NULL,
          bundle_id TEXT NOT NULL,
          environment TEXT NOT NULL,
          created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          UNIQUE (platform, device_token)
        )
        """,
        logger: logger
      )
    }
    logger.info("push device migrations applied")
  }

  public func upsert(
    platform: PushPlatform,
    deviceToken: String,
    bundleId: String,
    environment: PushEnvironment
  ) async throws -> PushDeviceRecord {
    guard !deviceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PushDeviceRepositoryError.invalidInput("deviceToken cannot be empty")
    }
    guard !bundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PushDeviceRepositoryError.invalidInput("bundleId cannot be empty")
    }
    let id = Self.makeDeviceID(platform: platform, deviceToken: deviceToken)
    return try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        INSERT INTO push_devices (id, platform, device_token, bundle_id, environment)
        VALUES (\(id), \(platform.rawValue), \(deviceToken), \(bundleId), \(environment.rawValue))
        ON CONFLICT (platform, device_token) DO UPDATE SET
          bundle_id = EXCLUDED.bundle_id,
          environment = EXCLUDED.environment,
          updated_at = NOW()
        RETURNING id, platform, device_token, bundle_id, environment, updated_at
        """,
        logger: logger
      )
      for try await row in rows.decode((String, String, String, String, String, Date).self) {
        let (id, platformRaw, token, bundleId, environmentRaw, updatedAt) = row
        guard let platform = PushPlatform(rawValue: platformRaw),
              let environment = PushEnvironment(rawValue: environmentRaw)
        else {
          throw PushDeviceRepositoryError.invalidInput("invalid stored push device row")
        }
        return PushDeviceRecord(
          id: id,
          platform: platform,
          deviceToken: token,
          bundleId: bundleId,
          environment: environment,
          updatedAt: updatedAt
        )
      }
      throw PushDeviceRepositoryError.notFound(id)
    }
  }

  public func delete(deviceToken: String) async throws {
    guard !deviceToken.isEmpty else {
      throw PushDeviceRepositoryError.invalidInput("deviceToken cannot be empty")
    }
    try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        DELETE FROM push_devices
        WHERE device_token = \(deviceToken)
        RETURNING id
        """,
        logger: logger
      )
      for try await _ in rows.decode((String,).self) {
        return
      }
      throw PushDeviceRepositoryError.notFound(deviceToken)
    }
  }

  public func list() async throws -> [PushDeviceRecord] {
    try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        SELECT id, platform, device_token, bundle_id, environment, updated_at
        FROM push_devices
        ORDER BY updated_at DESC
        """,
        logger: logger
      )
      var devices: [PushDeviceRecord] = []
      for try await row in rows.decode((String, String, String, String, String, Date).self) {
        let (id, platformRaw, token, bundleId, environmentRaw, updatedAt) = row
        guard let platform = PushPlatform(rawValue: platformRaw),
              let environment = PushEnvironment(rawValue: environmentRaw)
        else { continue }
        devices.append(
          PushDeviceRecord(
            id: id,
            platform: platform,
            deviceToken: token,
            bundleId: bundleId,
            environment: environment,
            updatedAt: updatedAt
          )
        )
      }
      return devices
    }
  }

  private static func makeDeviceID(platform: PushPlatform, deviceToken: String) -> String {
    let suffix = deviceToken
      .replacingOccurrences(of: " ", with: "")
      .lowercased()
      .prefix(16)
    return "push_\(platform.rawValue)_\(suffix)"
  }
}
