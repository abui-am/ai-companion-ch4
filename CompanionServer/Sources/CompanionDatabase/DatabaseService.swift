import Logging
import PostgresNIO

public actor DatabaseService {
  private let client: PostgresClient
  private var runTask: Task<Void, Never>?
  private let logger: Logger

  public init(settings: DatabaseSettings, logger: Logger) {
    self.logger = logger
    self.client = PostgresClient(
      configuration: settings.postgresConfiguration,
      backgroundLogger: logger
    )
  }

  public func start() {
    guard runTask == nil else { return }
    runTask = Task {
      await client.run()
    }
  }

  public func ping() async throws {
    let rows = try await client.query("SELECT 1 AS ok", logger: logger)
    for try await (ok,) in rows.decode((Int,).self) {
      guard ok == 1 else {
        throw DatabaseError.pingFailed
      }
      return
    }
    throw DatabaseError.pingFailed
  }

  public func withConnection<T: Sendable>(
    _ operation: @Sendable (PostgresConnection) async throws -> T
  ) async throws -> T {
    try await client.withConnection { connection in
      try await operation(connection)
    }
  }

  public func shutdown() {
    runTask?.cancel()
    runTask = nil
  }
}
