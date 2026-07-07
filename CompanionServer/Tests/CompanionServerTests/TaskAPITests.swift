import CompanionDatabase
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdCore
import HummingbirdTesting
import Logging
import NIOCore
import XCTest

@testable import CompanionServer

private struct APITask: Decodable, Equatable {
  let id: String
  let title: String
  let completed: Bool
  let dueAt: Date?
  let notes: String?
}

private struct APITasksResponse: Decodable {
  let tasks: [APITask]
}

private final class TaskAPITestHarness {
  let database: DatabaseService
  let tasks: TaskRepository
  let deviceToken = "task-test-token"
  let logger: Logger
  var createdTaskIDs: [String] = []

  init(database: DatabaseService, tasks: TaskRepository, logger: Logger) {
    self.database = database
    self.tasks = tasks
    self.logger = logger
  }

  static func make() async throws -> TaskAPITestHarness? {
    let logger = Logger(label: "TaskAPITests")
    let databaseURL = ProcessInfo.processInfo.environment["DATABASE_URL"]
      ?? "postgres://postgres:postgres@localhost:5432/companion"
    let settings = try DatabaseSettings(urlString: databaseURL)
    let database = DatabaseService(settings: settings, logger: logger)
    await database.start()
    do {
      try await database.ping()
    } catch {
      await database.shutdown()
      return nil
    }
    let tasks = TaskRepository(database: database, logger: logger)
    try await tasks.migrate()
    return TaskAPITestHarness(database: database, tasks: tasks, logger: logger)
  }

  func makeApp() -> Application<RouterResponder<BasicRequestContext>> {
    let router = Router()
    TaskRoutes.register(
      on: router,
      tasks: tasks,
      deviceToken: deviceToken,
      logger: logger
    )
    return Application(responder: router.buildResponder())
  }

  func authHeaders() -> HTTPFields {
    [.authorization: bearerValue()]
  }

  func wrongAuthHeaders() -> HTTPFields {
    [.authorization: "Bearer wrong-token"]
  }

  func bearerValue() -> String {
    "Bearer \(deviceToken)"
  }

  func jsonHeaders() -> HTTPFields {
    [
      .authorization: bearerValue(),
      .contentType: "application/json",
    ]
  }

  func trackCreatedTask(id: String) {
    createdTaskIDs.append(id)
  }

  func cleanup() async {
    for id in createdTaskIDs {
      try? await tasks.deleteTask(id: id)
    }
    createdTaskIDs.removeAll()
    await database.shutdown()
  }

  static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

final class TaskAPITests: XCTestCase {
  private var harness: TaskAPITestHarness!

  override func setUp() async throws {
    guard let harness = try await TaskAPITestHarness.make() else {
      throw XCTSkip("Postgres not available — start with docker-compose up -d")
    }
    self.harness = harness
  }

  override func tearDown() async throws {
    await harness?.cleanup()
    harness = nil
  }

  func testListTasksRequiresAuth() async throws {
    let app = harness.makeApp()
    try await app.test(.router) { client in
      try await client.execute(uri: "/api/v1/tasks", method: .get) { response in
        XCTAssertEqual(response.status, .unauthorized)
      }
    }
  }

  func testListTasksRejectsInvalidToken() async throws {
    let app = harness.makeApp()
    let headers = harness.wrongAuthHeaders()
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/tasks",
        method: .get,
        headers: headers
      ) { response in
        XCTAssertEqual(response.status, .unauthorized)
      }
    }
  }

  func testListTasksDefaultReturnsIncompleteOnly() async throws {
    let completed = try await harness.tasks.createTask(
      title: "Done item",
      dueAt: nil,
      notes: nil
    )
    harness.trackCreatedTask(id: completed.id)
    _ = try await harness.tasks.updateTask(
      id: completed.id,
      patch: TaskPatch(completed: true)
    )

    let app = harness.makeApp()
    let headers = harness.authHeaders()
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/tasks",
        method: .get,
        headers: headers
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let body = try TaskAPITestHarness.makeDecoder().decode(
          APITasksResponse.self,
          from: response.body
        )
        XCTAssertTrue(body.tasks.contains(where: { $0.id == "task_xyz" }))
        XCTAssertFalse(body.tasks.contains(where: { $0.id == completed.id }))
        XCTAssertTrue(body.tasks.allSatisfy { !$0.completed })
      }
    }
  }

  func testListTasksExplicitCompletedFalse() async throws {
    let app = harness.makeApp()
    let headers = harness.authHeaders()
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/tasks?completed=false",
        method: .get,
        headers: headers
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let body = try TaskAPITestHarness.makeDecoder().decode(
          APITasksResponse.self,
          from: response.body
        )
        XCTAssertTrue(body.tasks.contains(where: { $0.id == "task_xyz" }))
        XCTAssertTrue(body.tasks.allSatisfy { !$0.completed })
      }
    }
  }

  func testListTasksCompletedTrue() async throws {
    let completed = try await harness.tasks.createTask(
      title: "Completed task",
      dueAt: nil,
      notes: nil
    )
    harness.trackCreatedTask(id: completed.id)
    _ = try await harness.tasks.updateTask(
      id: completed.id,
      patch: TaskPatch(completed: true)
    )

    let app = harness.makeApp()
    let headers = harness.authHeaders()
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/tasks?completed=true",
        method: .get,
        headers: headers
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let body = try TaskAPITestHarness.makeDecoder().decode(
          APITasksResponse.self,
          from: response.body
        )
        XCTAssertTrue(body.tasks.contains(where: { $0.id == completed.id }))
        XCTAssertFalse(body.tasks.contains(where: { $0.id == "task_xyz" }))
        XCTAssertTrue(body.tasks.allSatisfy(\.completed))
      }
    }
  }

  func testListTasksRejectsInvalidCompletedFilter() async throws {
    let app = harness.makeApp()
    let headers = harness.authHeaders()
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/tasks?completed=maybe",
        method: .get,
        headers: headers
      ) { response in
        XCTAssertEqual(response.status, .badRequest)
      }
    }
  }

  func testGetTaskByID() async throws {
    let app = harness.makeApp()
    let headers = harness.authHeaders()
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/tasks/task_xyz",
        method: .get,
        headers: headers
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let task = try TaskAPITestHarness.makeDecoder().decode(
          APITask.self,
          from: response.body
        )
        XCTAssertEqual(task.id, "task_xyz")
        XCTAssertEqual(task.title, "Finish report")
        XCTAssertEqual(task.completed, false)
        XCTAssertNil(task.notes)
      }
    }
  }

  func testGetTaskNotFound() async throws {
    let app = harness.makeApp()
    let headers = harness.authHeaders()
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/tasks/task_missing",
        method: .get,
        headers: headers
      ) { response in
        XCTAssertEqual(response.status, .notFound)
      }
    }
  }

  func testCreateTask() async throws {
    let body = """
    {
      "title": "Buy groceries",
      "dueAt": "2026-07-09T12:00:00Z",
      "notes": "Milk and eggs"
    }
    """
    let app = harness.makeApp()
    let headers = harness.jsonHeaders()
    let createdID = try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/tasks",
        method: .post,
        headers: headers,
        body: ByteBufferAllocator().buffer(string: body)
      ) { response -> String in
        XCTAssertEqual(response.status, .ok)
        let task = try TaskAPITestHarness.makeDecoder().decode(
          APITask.self,
          from: response.body
        )
        XCTAssertTrue(task.id.hasPrefix("task_"))
        XCTAssertEqual(task.title, "Buy groceries")
        XCTAssertEqual(task.completed, false)
        XCTAssertEqual(task.notes, "Milk and eggs")
        XCTAssertNotNil(task.dueAt)
        return task.id
      }
    }
    harness.trackCreatedTask(id: createdID)
  }

  func testCreateTaskRejectsEmptyTitle() async throws {
    let body = """
    {
      "title": "   ",
      "dueAt": null,
      "notes": null
    }
    """
    let app = harness.makeApp()
    let headers = harness.jsonHeaders()
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/tasks",
        method: .post,
        headers: headers,
        body: ByteBufferAllocator().buffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .badRequest)
      }
    }
  }

  func testPatchTaskUpdatesTitleAndClearsDueAt() async throws {
    let created = try await harness.tasks.createTask(
      title: "Original",
      dueAt: ISO8601DateFormatter().date(from: "2026-07-10T12:00:00Z"),
      notes: "Keep"
    )
    harness.trackCreatedTask(id: created.id)

    let body = """
    {
      "title": "Renamed",
      "dueAt": null,
      "notes": "Updated"
    }
    """
    let app = harness.makeApp()
    let headers = harness.jsonHeaders()
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/tasks/\(created.id)",
        method: .patch,
        headers: headers,
        body: ByteBufferAllocator().buffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let task = try TaskAPITestHarness.makeDecoder().decode(
          APITask.self,
          from: response.body
        )
        XCTAssertEqual(task.title, "Renamed")
        XCTAssertNil(task.dueAt)
        XCTAssertEqual(task.notes, "Updated")
      }
    }
  }

  func testPatchTaskMarksCompleted() async throws {
    let created = try await harness.tasks.createTask(
      title: "Toggle me",
      dueAt: nil,
      notes: nil
    )
    harness.trackCreatedTask(id: created.id)

    let body = #"{"completed": true}"#
    let app = harness.makeApp()
    let headers = harness.jsonHeaders()
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/tasks/\(created.id)",
        method: .patch,
        headers: headers,
        body: ByteBufferAllocator().buffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let task = try TaskAPITestHarness.makeDecoder().decode(
          APITask.self,
          from: response.body
        )
        XCTAssertEqual(task.id, created.id)
        XCTAssertEqual(task.completed, true)
      }

      try await client.execute(
        uri: "/api/v1/tasks",
        method: .get,
        headers: headers
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let body = try TaskAPITestHarness.makeDecoder().decode(
          APITasksResponse.self,
          from: response.body
        )
        XCTAssertFalse(body.tasks.contains(where: { $0.id == created.id }))
      }

      try await client.execute(
        uri: "/api/v1/tasks?completed=true",
        method: .get,
        headers: headers
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let body = try TaskAPITestHarness.makeDecoder().decode(
          APITasksResponse.self,
          from: response.body
        )
        XCTAssertTrue(body.tasks.contains(where: { $0.id == created.id }))
      }
    }
  }

  func testDeleteTask() async throws {
    let created = try await harness.tasks.createTask(
      title: "Delete me",
      dueAt: nil,
      notes: nil
    )
    let createdID = created.id

    let app = harness.makeApp()
    let headers = harness.authHeaders()
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/tasks/\(createdID)",
        method: .delete,
        headers: headers
      ) { response in
        XCTAssertEqual(response.status, .noContent)
      }

      try await client.execute(
        uri: "/api/v1/tasks/\(createdID)",
        method: .get,
        headers: headers
      ) { response in
        XCTAssertEqual(response.status, .notFound)
      }
    }
  }

  func testDeleteTaskNotFound() async throws {
    let app = harness.makeApp()
    let headers = harness.authHeaders()
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/api/v1/tasks/task_missing",
        method: .delete,
        headers: headers
      ) { response in
        XCTAssertEqual(response.status, .notFound)
      }
    }
  }
}
