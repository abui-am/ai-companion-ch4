import Foundation
import Logging
import PostgresNIO

public enum TaskRepositoryError: Error, CustomStringConvertible, Sendable {
  case notFound(String)
  case invalidInput(String)

  public var description: String {
    switch self {
    case .notFound(let id):
      "Task not found: \(id)"
    case .invalidInput(let message):
      message
    }
  }
}

public actor TaskRepository {
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
        CREATE TABLE IF NOT EXISTS tasks (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          completed BOOLEAN NOT NULL DEFAULT FALSE,
          due_at TIMESTAMPTZ,
          notes TEXT,
          created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        CREATE INDEX IF NOT EXISTS tasks_completed_due_at_idx
          ON tasks (completed, due_at NULLS LAST)
        """,
        logger: logger
      )
      try await connection.query(
        """
        INSERT INTO tasks (id, title, completed, due_at, notes)
        VALUES (
          'task_xyz',
          'Finish report',
          FALSE,
          TIMESTAMPTZ '2026-07-08 17:00:00+00',
          NULL
        )
        ON CONFLICT (id) DO UPDATE SET
          title = EXCLUDED.title,
          completed = EXCLUDED.completed,
          due_at = EXCLUDED.due_at,
          notes = EXCLUDED.notes
        """,
        logger: logger
      )
    }
    logger.info("task migrations applied")
  }

  public func listTasks(completed: Bool) async throws -> [TaskRecord] {
    try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        SELECT id, title, completed, due_at, notes
        FROM tasks
        WHERE completed = \(completed)
        ORDER BY due_at ASC NULLS LAST, created_at ASC
        """,
        logger: logger
      )
      var tasks: [TaskRecord] = []
      for try await (id, title, completed, dueAt, notes) in rows.decode(
        (String, String, Bool, Date?, String?).self
      ) {
        tasks.append(
          TaskRecord(
            id: id,
            title: title,
            completed: completed,
            dueAt: dueAt,
            notes: notes
          )
        )
      }
      return tasks
    }
  }

  public func task(id: String) async throws -> TaskRecord {
    try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        SELECT id, title, completed, due_at, notes
        FROM tasks
        WHERE id = \(id)
        LIMIT 1
        """,
        logger: logger
      )
      for try await record in rows.decode((String, String, Bool, Date?, String?).self) {
        let (id, title, completed, dueAt, notes) = record
        return TaskRecord(
          id: id,
          title: title,
          completed: completed,
          dueAt: dueAt,
          notes: notes
        )
      }
      throw TaskRepositoryError.notFound(id)
    }
  }

  public func createTask(title: String, dueAt: Date?, notes: String?) async throws -> TaskRecord {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TaskRepositoryError.invalidInput("title cannot be empty")
    }
    let id = Self.makeTaskID()
    return try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        INSERT INTO tasks (id, title, completed, due_at, notes)
        VALUES (\(id), \(title), FALSE, \(dueAt), \(notes))
        RETURNING id, title, completed, due_at, notes
        """,
        logger: logger
      )
      for try await record in rows.decode((String, String, Bool, Date?, String?).self) {
        let (id, title, completed, dueAt, notes) = record
        return TaskRecord(
          id: id,
          title: title,
          completed: completed,
          dueAt: dueAt,
          notes: notes
        )
      }
      throw TaskRepositoryError.notFound(id)
    }
  }

  public func updateTask(id: String, patch: TaskPatch) async throws -> TaskRecord {
    let current = try await task(id: id)
    let merged = try patch.applied(to: current)
    return try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        UPDATE tasks
        SET title = \(merged.title),
            completed = \(merged.completed),
            due_at = \(merged.dueAt),
            notes = \(merged.notes)
        WHERE id = \(id)
        RETURNING id, title, completed, due_at, notes
        """,
        logger: logger
      )
      for try await record in rows.decode((String, String, Bool, Date?, String?).self) {
        let (id, title, completed, dueAt, notes) = record
        return TaskRecord(
          id: id,
          title: title,
          completed: completed,
          dueAt: dueAt,
          notes: notes
        )
      }
      throw TaskRepositoryError.notFound(id)
    }
  }

  public func deleteTask(id: String) async throws {
    try await database.withConnection { connection in
      let rows = try await connection.query(
        """
        DELETE FROM tasks
        WHERE id = \(id)
        RETURNING id
        """,
        logger: logger
      )
      for try await _ in rows.decode((String,).self) {
        return
      }
      throw TaskRepositoryError.notFound(id)
    }
  }

  private static func makeTaskID() -> String {
    let suffix = UUID().uuidString
      .replacingOccurrences(of: "-", with: "")
      .lowercased()
      .prefix(12)
    return "task_\(suffix)"
  }
}
