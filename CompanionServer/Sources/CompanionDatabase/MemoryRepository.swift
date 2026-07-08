import Foundation
import Logging
import PostgresNIO

public enum MemoryRepositoryError: Error, CustomStringConvertible, Sendable {
  case notFound(String)
  case invalidInput(String)

  public var description: String {
    switch self {
    case .notFound(let id):
      "Memory not found: \(id)"
    case .invalidInput(let message):
      message
    }
  }
}

/// Stores durable user facts as OpenAI embeddings for semantic recall — the pgvector-backed
/// long-term memory for the voice companion. Writes happen only through `MemoryAgent` (the
/// `memory` function tool); this actor is the storage layer, agnostic of embedding generation.
/// Gated upstream by `ConfigRecord.personalizationData`, same privacy flag as conversation
/// history — see `MemoryAgent` and `MemoryRoutes`.
public actor MemoryRepository {
  private let database: DatabaseService
  private let logger: Logger

  public init(database: DatabaseService, logger: Logger) {
    self.database = database
    self.logger = logger
  }

  /// Assumes the `vector` extension is already enabled — see `DatabaseService.enableVectorExtension()`.
  /// `vector(1536)` must match `MemoryVector.dimensions`.
  public func migrate() async throws {
    try await database.withConnection { connection in
      try await connection.query(
        """
        CREATE TABLE IF NOT EXISTS memories (
          id TEXT PRIMARY KEY,
          content TEXT NOT NULL CHECK (char_length(content) <= 500),
          embedding vector(1536) NOT NULL,
          source TEXT NOT NULL DEFAULT 'tool',
          created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        CREATE INDEX IF NOT EXISTS memories_created_at_idx
          ON memories (created_at DESC)
        """,
        logger: logger
      )
      try await connection.query(
        """
        CREATE INDEX IF NOT EXISTS memories_embedding_hnsw_idx
          ON memories USING hnsw (embedding vector_cosine_ops)
        """,
        logger: logger
      )
    }
    logger.info("memory migrations applied")
  }

  @discardableResult
  public func insert(content: String, embedding: [Float], source: String = "tool") async throws -> MemoryRecord {
    let id = Self.makeMemoryID()
    let vectorLiteral = MemoryVector.encode(embedding)
    return try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        INSERT INTO memories (id, content, embedding, source)
        VALUES (\(id), \(content), \(vectorLiteral)::vector, \(source))
        RETURNING id, content, source, created_at, updated_at
        """,
        logger: logger
      )
      for try await record in rows.decode((String, String, String, Date, Date).self) {
        let (id, content, source, createdAt, updatedAt) = record
        return MemoryRecord(id: id, content: content, source: source, createdAt: createdAt, updatedAt: updatedAt)
      }
      throw MemoryRepositoryError.notFound(id)
    }
  }

  @discardableResult
  public func update(id: String, content: String, embedding: [Float]) async throws -> MemoryRecord {
    let vectorLiteral = MemoryVector.encode(embedding)
    return try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        UPDATE memories
        SET content = \(content),
            embedding = \(vectorLiteral)::vector,
            updated_at = NOW()
        WHERE id = \(id)
        RETURNING id, content, source, created_at, updated_at
        """,
        logger: logger
      )
      for try await record in rows.decode((String, String, String, Date, Date).self) {
        let (id, content, source, createdAt, updatedAt) = record
        return MemoryRecord(id: id, content: content, source: source, createdAt: createdAt, updatedAt: updatedAt)
      }
      throw MemoryRepositoryError.notFound(id)
    }
  }

  /// Finds the closest existing memory within `maxDistance`, used by `MemoryAgent.remember`
  /// to update a near-duplicate fact instead of inserting a new row.
  public func findDuplicate(embedding: [Float], maxDistance: Double) async throws -> MemoryRecord? {
    let vectorLiteral = MemoryVector.encode(embedding)
    return try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        SELECT id, content, source, created_at, updated_at
        FROM memories
        WHERE embedding <=> \(vectorLiteral)::vector < \(maxDistance)
        ORDER BY embedding <=> \(vectorLiteral)::vector
        LIMIT 1
        """,
        logger: logger
      )
      for try await record in rows.decode((String, String, String, Date, Date).self) {
        let (id, content, source, createdAt, updatedAt) = record
        return MemoryRecord(id: id, content: content, source: source, createdAt: createdAt, updatedAt: updatedAt)
      }
      return nil
    }
  }

  /// Semantic search ordered by cosine distance, dropping matches beyond `maxDistance` so
  /// unrelated memories are never surfaced — see `MemoryAgent.search`.
  public func search(embedding: [Float], limit: Int, maxDistance: Double) async throws -> [MemoryRecord] {
    let vectorLiteral = MemoryVector.encode(embedding)
    return try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        SELECT id, content, source, created_at, updated_at
        FROM memories
        WHERE embedding <=> \(vectorLiteral)::vector < \(maxDistance)
        ORDER BY embedding <=> \(vectorLiteral)::vector
        LIMIT \(limit)
        """,
        logger: logger
      )
      var results: [MemoryRecord] = []
      for try await record in rows.decode((String, String, String, Date, Date).self) {
        let (id, content, source, createdAt, updatedAt) = record
        results.append(MemoryRecord(id: id, content: content, source: source, createdAt: createdAt, updatedAt: updatedAt))
      }
      return results
    }
  }

  /// Deletes the closest match within `maxDistance`, used by `MemoryAgent.forget` when the
  /// caller supplies a natural-language `query` rather than an exact `id`.
  @discardableResult
  public func deleteBestMatch(embedding: [Float], maxDistance: Double) async throws -> MemoryRecord? {
    guard let match = try await search(embedding: embedding, limit: 1, maxDistance: maxDistance).first else {
      return nil
    }
    try await delete(id: match.id)
    return match
  }

  public func delete(id: String) async throws {
    try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        DELETE FROM memories
        WHERE id = \(id)
        RETURNING id
        """,
        logger: logger
      )
      for try await _ in rows.decode((String,).self) {
        return
      }
      throw MemoryRepositoryError.notFound(id)
    }
  }

  public func list(limit: Int) async throws -> [MemoryRecord] {
    try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        SELECT id, content, source, created_at, updated_at
        FROM memories
        ORDER BY created_at DESC
        LIMIT \(limit)
        """,
        logger: logger
      )
      var results: [MemoryRecord] = []
      for try await record in rows.decode((String, String, String, Date, Date).self) {
        let (id, content, source, createdAt, updatedAt) = record
        results.append(MemoryRecord(id: id, content: content, source: source, createdAt: createdAt, updatedAt: updatedAt))
      }
      return results
    }
  }

  private static func makeMemoryID() -> String {
    let suffix = UUID().uuidString
      .replacingOccurrences(of: "-", with: "")
      .lowercased()
      .prefix(12)
    return "mem_\(suffix)"
  }
}
