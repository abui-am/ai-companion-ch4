import CompanionDatabase
import Foundation
import Logging

/// Sub-agent backend for the Realtime orchestrator's `tasks` function tool.
struct TaskAgent: SubAgent, Sendable {
    let name = "tasks"

    private let tasks: TaskRepository
    private let timeZone: TimeZone
    private let logger: Logger

    init(tasks: TaskRepository, timeZoneIdentifier: String, logger: Logger) {
        self.tasks = tasks
        self.timeZone = CompanionTimezone.resolve(identifier: timeZoneIdentifier)
        self.logger = logger
    }

    var toolDefinition: [String: Any] {
        let offset = CompanionTimezone.iso8601Offset(for: timeZone)
        let example = "2026-07-08T20:00:00\(offset)"
        return [
            "type": "function",
            "name": name,
            "description": """
            Manage the user's task list: list, add, update, complete, or delete tasks.

            Use when the user asks about their to-do list, reminders, or things they need to do.
            Confirm what you changed in a short spoken reply after the tool returns.

            Times are in the user's local timezone (\(timeZone.identifier), offset \(offset)).
            If the user says "8pm", pass 20:00 local — e.g. dueAt \(example) or bare `2026-07-08T20:00:00`.
            Do not use `Z` for local times like 8pm.

            Actions:
            - list: optional completed (default false = incomplete only)
            - create: title required; optional dueAt (ISO 8601 with offset), notes
            - update: id required; optional title, completed, dueAt (ISO 8601 with offset, or null to clear), notes (string or null to clear)
            - delete: id required
            """,
            "parameters": [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": ["list", "create", "update", "delete"],
                        "description": "What to do with tasks.",
                    ] as [String: Any],
                    "id": [
                        "type": "string",
                        "description": "Task ID (task_...) for update or delete.",
                    ] as [String: Any],
                    "title": [
                        "type": "string",
                        "description": "Task title for create or update.",
                    ] as [String: Any],
                    "completed": [
                        "type": "boolean",
                        "description": "Completion status for list filter or update.",
                    ] as [String: Any],
                    "dueAt": [
                        "type": ["string", "null"],
                        "description": "Due date/time in ISO 8601 with timezone offset, e.g. \(example). Pass null on update to clear.",
                    ] as [String: Any],
                    "notes": [
                        "type": ["string", "null"],
                        "description": "Optional notes. Pass null on update to clear.",
                    ] as [String: Any],
                ],
                "required": ["action"],
            ] as [String: Any],
        ]
    }

    func execute(argumentsJSON: String) async -> String {
        guard let args = SubAgentJSON.parseArguments(argumentsJSON) else {
            logger.error("tasks invalid arguments", metadata: ["args": .string(argumentsJSON)])
            return SubAgentJSON.encodeError("invalid arguments JSON")
        }
        guard let action = args["action"] as? String else {
            return SubAgentJSON.encodeError("missing action")
        }

        do {
            switch action {
            case "list":
                let completed = args["completed"] as? Bool ?? false
                let records = try await tasks.listTasks(completed: completed)
                let items = records.map(taskJSON)
                return SubAgentJSON.encode([
                    "summary": completed ? "Found \(items.count) completed task(s)." : "Found \(items.count) open task(s).",
                    "tasks": items,
                ])
            case "create":
                guard let title = args["title"] as? String else {
                    return SubAgentJSON.encodeError("create requires title")
                }
                let dueAt: Date?
                if let dueAtString = args["dueAt"] as? String {
                    switch SubAgentJSON.parseZonedDate(dueAtString, defaultTimeZone: timeZone, field: "dueAt") {
                    case .success(let date):
                        dueAt = date
                    case .failure(let error):
                        return SubAgentJSON.encodeError(error.description)
                    }
                } else {
                    dueAt = nil
                }
                let notes = args["notes"] as? String
                let record = try await tasks.createTask(title: title, dueAt: dueAt, notes: notes)
                return SubAgentJSON.encode([
                    "summary": "Created task \"\(record.title)\".",
                    "task": taskJSON(record),
                ])
            case "update":
                guard let id = args["id"] as? String else {
                    return SubAgentJSON.encodeError("update requires id")
                }
                var patch = TaskPatch()
                if let title = args["title"] as? String {
                    patch.title = title
                }
                if let completed = args["completed"] as? Bool {
                    patch.completed = completed
                }
                if args.keys.contains("dueAt") {
                    patch.updateDueAt = true
                    if let dueAtString = args["dueAt"] as? String {
                        switch SubAgentJSON.parseZonedDate(dueAtString, defaultTimeZone: timeZone, field: "dueAt") {
                        case .success(let date):
                            patch.dueAt = date
                        case .failure(let error):
                            return SubAgentJSON.encodeError(error.description)
                        }
                    } else {
                        patch.dueAt = nil
                    }
                }
                if args.keys.contains("notes") {
                    patch.updateNotes = true
                    patch.notes = args["notes"] as? String
                }
                let record = try await tasks.updateTask(id: id, patch: patch)
                return SubAgentJSON.encode([
                    "summary": "Updated task \"\(record.title)\".",
                    "task": taskJSON(record),
                ])
            case "delete":
                guard let id = args["id"] as? String else {
                    return SubAgentJSON.encodeError("delete requires id")
                }
                try await tasks.deleteTask(id: id)
                return SubAgentJSON.encode(["summary": "Deleted task \(id)."])
            default:
                return SubAgentJSON.encodeError("unknown action: \(action)")
            }
        } catch let error as TaskRepositoryError {
            logger.warning("tasks repository error", metadata: ["error": .string(error.description)])
            return SubAgentJSON.encodeError(error.description)
        } catch {
            logger.error("tasks failed", metadata: ["error": .string("\(error)")])
            return SubAgentJSON.encodeError("\(error)")
        }
    }

    private func taskJSON(_ record: TaskRecord) -> [String: Any] {
        var json: [String: Any] = [
            "id": record.id,
            "title": record.title,
            "completed": record.completed,
        ]
        if let dueAt = record.dueAt {
            json["dueAt"] = SubAgentJSON.formatDate(dueAt, in: timeZone)
        } else {
            json["dueAt"] = NSNull()
        }
        if let notes = record.notes {
            json["notes"] = notes
        } else {
            json["notes"] = NSNull()
        }
        return json
    }
}
