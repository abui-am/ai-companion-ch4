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

  /// Enables the pgvector extension once at boot, before any repository migrates a table
  /// that depends on the `vector` type — see `MemoryRepository`. Kept here rather than in
  /// one repository since other features may need vector columns later.
  public func enableVectorExtension() async throws {
    _ = try await withConnection { connection in
      try await connection.query("CREATE EXTENSION IF NOT EXISTS vector", logger: logger)
    }
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
