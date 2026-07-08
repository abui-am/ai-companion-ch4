import Foundation
import Logging
import PostgresNIO

public enum ConversationRepositoryError: Error, CustomStringConvertible, Sendable {
  case sessionNotFound(String)
  case messageNotFound(String)
  case toolCallNotFound(String)

  public var description: String {
    switch self {
    case .sessionNotFound(let id):
      "Conversation session not found: \(id)"
    case .messageNotFound(let id):
      "Conversation message not found: \(id)"
    case .toolCallNotFound(let id):
      "Conversation tool call not found: \(id)"
    }
  }
}

/// Persists voice-turn transcripts (and references to their WAV audio on disk) so past
/// conversations survive a WebSocket disconnect. Gated by `ConfigRecord.personalizationData` —
/// see `VoiceSession`.
public actor ConversationRepository {
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
        CREATE TABLE IF NOT EXISTS conversation_sessions (
          id TEXT PRIMARY KEY,
          started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          ended_at TIMESTAMPTZ
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        CREATE TABLE IF NOT EXISTS conversation_messages (
          id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL REFERENCES conversation_sessions(id) ON DELETE CASCADE,
          turn_id TEXT NOT NULL,
          role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
          content TEXT NOT NULL DEFAULT '',
          audio_path TEXT,
          created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        CREATE INDEX IF NOT EXISTS conversation_messages_session_created_idx
          ON conversation_messages (session_id, created_at)
        """,
        logger: logger
      )
      try await connection.query(
        """
        CREATE INDEX IF NOT EXISTS conversation_sessions_started_at_idx
          ON conversation_sessions (started_at DESC)
        """,
        logger: logger
      )
      try await connection.query(
        """
        CREATE TABLE IF NOT EXISTS conversation_tool_calls (
          id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL REFERENCES conversation_sessions(id) ON DELETE CASCADE,
          turn_id TEXT NOT NULL,
          name TEXT NOT NULL,
          detail TEXT NOT NULL DEFAULT '',
          arguments TEXT NOT NULL DEFAULT '{}',
          output TEXT NOT NULL DEFAULT '',
          created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        CREATE INDEX IF NOT EXISTS conversation_tool_calls_session_created_idx
          ON conversation_tool_calls (session_id, created_at)
        """,
        logger: logger
      )
    }
    logger.info("conversation migrations applied")
  }

  /// Inserts the session row if it doesn't already exist. Safe to call before every turn.
  public func ensureSession(id: String) async throws {
    try await database.withConnection { connection in
      _ = try await connection.query(
        """
        INSERT INTO conversation_sessions (id)
        VALUES (\(id))
        ON CONFLICT (id) DO NOTHING
        """,
        logger: logger
      )
    }
  }

  /// Marks a session as ended. Idempotent — only the first call sets `ended_at`.
  public func endSession(id: String) async throws {
    try await database.withConnection { connection in
      _ = try await connection.query(
        """
        UPDATE conversation_sessions
        SET ended_at = NOW()
        WHERE id = \(id) AND ended_at IS NULL
        """,
        logger: logger
      )
    }
  }

  public func listSessions(from: Date?, to: Date?, limit: Int) async throws -> [ConversationSessionRecord] {
    try await database.withConnection { connection in
      let rows: PostgresRowSequence
      if let from, let to {
        rows = try await connection.query(
          """
          SELECT s.id, s.started_at, s.ended_at,
            COALESCE(
              (SELECT COUNT(DISTINCT m.turn_id)::INT
               FROM conversation_messages m
               WHERE m.session_id = s.id),
              0
            ) AS voice_count
          FROM conversation_sessions s
          WHERE s.started_at >= \(from) AND s.started_at <= \(to)
          ORDER BY s.started_at DESC
          LIMIT \(limit)
          """,
          logger: logger
        )
      } else if let from {
        rows = try await connection.query(
          """
          SELECT s.id, s.started_at, s.ended_at,
            COALESCE(
              (SELECT COUNT(DISTINCT m.turn_id)::INT
               FROM conversation_messages m
               WHERE m.session_id = s.id),
              0
            ) AS voice_count
          FROM conversation_sessions s
          WHERE s.started_at >= \(from)
          ORDER BY s.started_at DESC
          LIMIT \(limit)
          """,
          logger: logger
        )
      } else if let to {
        rows = try await connection.query(
          """
          SELECT s.id, s.started_at, s.ended_at,
            COALESCE(
              (SELECT COUNT(DISTINCT m.turn_id)::INT
               FROM conversation_messages m
               WHERE m.session_id = s.id),
              0
            ) AS voice_count
          FROM conversation_sessions s
          WHERE s.started_at <= \(to)
          ORDER BY s.started_at DESC
          LIMIT \(limit)
          """,
          logger: logger
        )
      } else {
        rows = try await connection.query(
          """
          SELECT s.id, s.started_at, s.ended_at,
            COALESCE(
              (SELECT COUNT(DISTINCT m.turn_id)::INT
               FROM conversation_messages m
               WHERE m.session_id = s.id),
              0
            ) AS voice_count
          FROM conversation_sessions s
          ORDER BY s.started_at DESC
          LIMIT \(limit)
          """,
          logger: logger
        )
      }

      var sessions: [ConversationSessionRecord] = []
      for try await (id, startedAt, endedAt, voiceCount) in rows.decode((String, Date, Date?, Int).self) {
        sessions.append(
          ConversationSessionRecord(id: id, startedAt: startedAt, endedAt: endedAt, voiceCount: voiceCount)
        )
      }
      return sessions
    }
  }

  /// Deletes a session and its messages (cascades via `ON DELETE CASCADE`). No HTTP route
  /// exposes this — it exists for test cleanup, mirroring `CalendarRepository.deleteEvent`.
  public func deleteSession(id: String) async throws {
    try await database.withConnection { connection in
      _ = try await connection.query(
        "DELETE FROM conversation_sessions WHERE id = \(id)",
        logger: logger
      )
    }
  }

  public func session(id: String) async throws -> ConversationSessionRecord {
    try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        SELECT s.id, s.started_at, s.ended_at,
          COALESCE(
            (SELECT COUNT(DISTINCT m.turn_id)::INT
             FROM conversation_messages m
             WHERE m.session_id = s.id),
            0
          ) AS voice_count
        FROM conversation_sessions s
        WHERE s.id = \(id)
        LIMIT 1
        """,
        logger: logger
      )
      for try await (id, startedAt, endedAt, voiceCount) in rows.decode((String, Date, Date?, Int).self) {
        return ConversationSessionRecord(id: id, startedAt: startedAt, endedAt: endedAt, voiceCount: voiceCount)
      }
      throw ConversationRepositoryError.sessionNotFound(id)
    }
  }

  @discardableResult
  public func appendMessage(
    sessionId: String,
    turnId: String,
    role: String,
    content: String,
    audioPath: String?
  ) async throws -> ConversationMessageRecord {
    let id = Self.makeMessageID()
    return try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        INSERT INTO conversation_messages (id, session_id, turn_id, role, content, audio_path)
        VALUES (\(id), \(sessionId), \(turnId), \(role), \(content), \(audioPath))
        RETURNING id, session_id, turn_id, role, content, audio_path, created_at
        """,
        logger: logger
      )
      for try await record in rows.decode((String, String, String, String, String, String?, Date).self) {
        let (id, sessionId, turnId, role, content, audioPath, createdAt) = record
        return ConversationMessageRecord(
          id: id,
          sessionId: sessionId,
          turnId: turnId,
          role: role,
          content: content,
          audioPath: audioPath,
          createdAt: createdAt
        )
      }
      throw ConversationRepositoryError.messageNotFound(id)
    }
  }

  public func listMessages(sessionId: String, limit: Int, offset: Int) async throws -> [ConversationMessageRecord] {
    try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        SELECT id, session_id, turn_id, role, content, audio_path, created_at
        FROM conversation_messages
        WHERE session_id = \(sessionId)
        ORDER BY created_at ASC
        LIMIT \(limit) OFFSET \(offset)
        """,
        logger: logger
      )
      var messages: [ConversationMessageRecord] = []
      for try await record in rows.decode((String, String, String, String, String, String?, Date).self) {
        let (id, sessionId, turnId, role, content, audioPath, createdAt) = record
        messages.append(
          ConversationMessageRecord(
            id: id,
            sessionId: sessionId,
            turnId: turnId,
            role: role,
            content: content,
            audioPath: audioPath,
            createdAt: createdAt
          )
        )
      }
      return messages
    }
  }

  public func message(id: String) async throws -> ConversationMessageRecord {
    try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        SELECT id, session_id, turn_id, role, content, audio_path, created_at
        FROM conversation_messages
        WHERE id = \(id)
        LIMIT 1
        """,
        logger: logger
      )
      for try await record in rows.decode((String, String, String, String, String, String?, Date).self) {
        let (id, sessionId, turnId, role, content, audioPath, createdAt) = record
        return ConversationMessageRecord(
          id: id,
          sessionId: sessionId,
          turnId: turnId,
          role: role,
          content: content,
          audioPath: audioPath,
          createdAt: createdAt
        )
      }
      throw ConversationRepositoryError.messageNotFound(id)
    }
  }

  private static func makeMessageID() -> String {
    let suffix = UUID().uuidString
      .replacingOccurrences(of: "-", with: "")
      .lowercased()
      .prefix(12)
    return "cmsg_\(suffix)"
  }

  /// Persists one completed tool call. `id` and `createdAt` are passed in (rather than
  /// generated here) so the same values used for the live `tool.done` WebSocket event —
  /// see `VoiceSession` — are the ones written to disk.
  @discardableResult
  public func appendToolCall(
    id: String,
    sessionId: String,
    turnId: String,
    name: String,
    detail: String,
    arguments: String,
    output: String,
    createdAt: Date
  ) async throws -> ConversationToolCallRecord {
    try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        INSERT INTO conversation_tool_calls (id, session_id, turn_id, name, detail, arguments, output, created_at)
        VALUES (\(id), \(sessionId), \(turnId), \(name), \(detail), \(arguments), \(output), \(createdAt))
        RETURNING id, session_id, turn_id, name, detail, arguments, output, created_at
        """,
        logger: logger
      )
      for try await record in rows.decode((String, String, String, String, String, String, String, Date).self) {
        let (id, sessionId, turnId, name, detail, arguments, output, createdAt) = record
        return ConversationToolCallRecord(
          id: id,
          sessionId: sessionId,
          turnId: turnId,
          name: name,
          detail: detail,
          arguments: arguments,
          output: output,
          createdAt: createdAt
        )
      }
      throw ConversationRepositoryError.toolCallNotFound(id)
    }
  }

  public func listToolCalls(sessionId: String, limit: Int, offset: Int) async throws -> [ConversationToolCallRecord] {
    try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        SELECT id, session_id, turn_id, name, detail, arguments, output, created_at
        FROM conversation_tool_calls
        WHERE session_id = \(sessionId)
        ORDER BY created_at ASC
        LIMIT \(limit) OFFSET \(offset)
        """,
        logger: logger
      )
      var toolCalls: [ConversationToolCallRecord] = []
      for try await record in rows.decode((String, String, String, String, String, String, String, Date).self) {
        let (id, sessionId, turnId, name, detail, arguments, output, createdAt) = record
        toolCalls.append(
          ConversationToolCallRecord(
            id: id,
            sessionId: sessionId,
            turnId: turnId,
            name: name,
            detail: detail,
            arguments: arguments,
            output: output,
            createdAt: createdAt
          )
        )
      }
      return toolCalls
    }
  }
}
