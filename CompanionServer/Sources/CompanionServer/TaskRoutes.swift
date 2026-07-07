import CompanionDatabase
import Foundation
import Hummingbird
import HTTPTypes
import Logging

struct TaskItem: ResponseCodable, Sendable {
  let id: String
  let title: String
  let completed: Bool
  let dueAt: Date?
  let notes: String?

  init(record: TaskRecord) {
    id = record.id
    title = record.title
    completed = record.completed
    dueAt = record.dueAt
    notes = record.notes
  }

  enum CodingKeys: String, CodingKey {
    case id, title, completed, dueAt, notes
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(title, forKey: .title)
    try container.encode(completed, forKey: .completed)
    if let dueAt {
      try container.encode(dueAt, forKey: .dueAt)
    } else {
      try container.encodeNil(forKey: .dueAt)
    }
    if let notes {
      try container.encode(notes, forKey: .notes)
    } else {
      try container.encodeNil(forKey: .notes)
    }
  }
}

struct TasksResponse: ResponseCodable, Sendable {
  let tasks: [TaskItem]
}

struct CreateTaskRequest: Decodable, Sendable {
  let title: String
  let dueAt: Date?
  let notes: String?
}

private struct PatchTaskRequest: Decodable, Sendable {
  let title: String?
  let dueAt: Date?
  let notes: String?
  let completed: Bool?
  let updateDueAt: Bool
  let updateNotes: Bool

  enum CodingKeys: String, CodingKey {
    case title, dueAt, notes, completed
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    title = try container.decodeIfPresent(String.self, forKey: .title)
    completed = try container.decodeIfPresent(Bool.self, forKey: .completed)
    if container.contains(.dueAt) {
      updateDueAt = true
      if try container.decodeNil(forKey: .dueAt) {
        dueAt = nil
      } else {
        dueAt = try container.decode(Date.self, forKey: .dueAt)
      }
    } else {
      updateDueAt = false
      dueAt = nil
    }
    if container.contains(.notes) {
      updateNotes = true
      if try container.decodeNil(forKey: .notes) {
        notes = nil
      } else {
        notes = try container.decode(String.self, forKey: .notes)
      }
    } else {
      updateNotes = false
      notes = nil
    }
  }

  var patch: TaskPatch {
    TaskPatch(
      title: title,
      dueAt: dueAt,
      notes: notes,
      completed: completed,
      updateDueAt: updateDueAt,
      updateNotes: updateNotes
    )
  }
}

enum TaskRoutes {
  static func register(
    on router: Router<BasicRequestContext>,
    tasks: TaskRepository,
    deviceToken: String,
    logger: Logger
  ) {
    let tasksRouter = router.group("/api/v1/tasks")

    tasksRouter.get { request, _ in
      try requireDeviceToken(from: request, expected: deviceToken)
      let completed = try parseCompletedFilter(request.uri.queryParameters.get("completed"))
      let records = try await tasks.listTasks(completed: completed)
      logger.debug(
        "GET /api/v1/tasks",
        metadata: ["count": "\(records.count)", "completed": "\(completed)"]
      )
      return TasksResponse(tasks: records.map(TaskItem.init(record:)))
    }

    tasksRouter.get("/{id}") { request, context in
      try requireDeviceToken(from: request, expected: deviceToken)
      let id = try context.parameters.require("id")
      do {
        let record = try await tasks.task(id: id)
        logger.debug("GET /api/v1/tasks/{id}", metadata: ["id": .string(id)])
        return TaskItem(record: record)
      } catch let error as TaskRepositoryError {
        switch error {
        case .notFound:
          throw HTTPError(.notFound, message: error.description)
        case .invalidInput:
          throw HTTPError(.badRequest, message: error.description)
        }
      }
    }

    tasksRouter.post { request, context in
      try requireDeviceToken(from: request, expected: deviceToken)
      let body = try await request.decode(as: CreateTaskRequest.self, context: context)
      do {
        let record = try await tasks.createTask(
          title: body.title,
          dueAt: body.dueAt,
          notes: body.notes
        )
        logger.info("POST /api/v1/tasks", metadata: ["id": .string(record.id)])
        return TaskItem(record: record)
      } catch let error as TaskRepositoryError {
        switch error {
        case .notFound:
          throw HTTPError(.internalServerError, message: error.description)
        case .invalidInput:
          throw HTTPError(.badRequest, message: error.description)
        }
      }
    }

    tasksRouter.patch("/{id}") { request, context in
      try requireDeviceToken(from: request, expected: deviceToken)
      let id = try context.parameters.require("id")
      let body = try await request.decode(as: PatchTaskRequest.self, context: context)
      do {
        let record = try await tasks.updateTask(id: id, patch: body.patch)
        logger.info("PATCH /api/v1/tasks/{id}", metadata: ["id": .string(id)])
        return TaskItem(record: record)
      } catch let error as TaskRepositoryError {
        switch error {
        case .notFound:
          throw HTTPError(.notFound, message: error.description)
        case .invalidInput:
          throw HTTPError(.badRequest, message: error.description)
        }
      }
    }

    tasksRouter.delete("/{id}") { request, context -> HTTPResponse.Status in
      try requireDeviceToken(from: request, expected: deviceToken)
      let id = try context.parameters.require("id")
      do {
        try await tasks.deleteTask(id: id)
        logger.info("DELETE /api/v1/tasks/{id}", metadata: ["id": .string(id)])
        return .noContent
      } catch let error as TaskRepositoryError {
        switch error {
        case .notFound:
          throw HTTPError(.notFound, message: error.description)
        case .invalidInput:
          throw HTTPError(.badRequest, message: error.description)
        }
      }
    }
  }

  private static func requireDeviceToken(from request: Request, expected: String) throws {
    guard let header = request.headers[.authorization] else {
      throw HTTPError(.unauthorized, message: "Missing Authorization header")
    }
    guard let token = header.split(separator: " ").last.map(String.init), token == expected else {
      throw HTTPError(.unauthorized, message: "Invalid bearer token")
    }
  }

  private static func parseCompletedFilter(_ value: String?) throws -> Bool {
    guard let value, !value.isEmpty else { return false }
    switch value.lowercased() {
    case "true", "1":
      return true
    case "false", "0":
      return false
    default:
      throw HTTPError(.badRequest, message: "completed must be true or false")
    }
  }
}
