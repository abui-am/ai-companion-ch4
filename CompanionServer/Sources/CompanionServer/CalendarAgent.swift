import CompanionDatabase
import Foundation
import Logging

/// Sub-agent backend for the Realtime orchestrator's `calendar` function tool.
struct CalendarAgent: SubAgent, Sendable {
    let name = "calendar"

    private let calendar: CalendarRepository
    private let reminderScheduler: ReminderScheduler
    private let timeZone: TimeZone
    private let logger: Logger

    init(
        calendar: CalendarRepository,
        reminderScheduler: ReminderScheduler,
        timeZoneIdentifier: String,
        logger: Logger
    ) {
        self.calendar = calendar
        self.reminderScheduler = reminderScheduler
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
            Manage the user's calendar: list, add, update, or delete events.

            Use when the user asks what's on their schedule, wants to book something, reschedule, or cancel an event.
            Confirm what you changed in a short spoken reply after the tool returns.

            Times are in the user's local timezone (\(timeZone.identifier), offset \(offset)).
            If the user says "8pm", pass 20:00 local — e.g. \(example) or bare `2026-07-08T20:00:00`.
            Do not use `Z` for local times like 8pm.

            Actions:
            - list: optional from and to (ISO 8601 with offset) to filter overlapping events
            - create: title, startsAt, endsAt required; optional location, isImportant, notes
            - update: id required; optional title, startsAt, endsAt, location, isImportant, notes (string or null to clear)
            - delete: id required
            """,
            "parameters": [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": ["list", "create", "update", "delete"],
                        "description": "What to do with calendar events.",
                    ] as [String: Any],
                    "id": [
                        "type": "string",
                        "description": "Event ID (evt_...) for update or delete.",
                    ] as [String: Any],
                    "title": [
                        "type": "string",
                        "description": "Event title for create.",
                    ] as [String: Any],
                    "startsAt": [
                        "type": "string",
                        "description": "Start time in ISO 8601 with timezone offset, e.g. \(example).",
                    ] as [String: Any],
                    "endsAt": [
                        "type": "string",
                        "description": "End time in ISO 8601 with timezone offset, e.g. \(example).",
                    ] as [String: Any],
                    "from": [
                        "type": "string",
                        "description": "List filter start in ISO 8601 with timezone offset.",
                    ] as [String: Any],
                    "to": [
                        "type": "string",
                        "description": "List filter end in ISO 8601 with timezone offset.",
                    ] as [String: Any],
                    "location": [
                        "type": "string",
                        "description": "Location label for create.",
                    ] as [String: Any],
                    "isImportant": [
                        "type": "boolean",
                        "description": "Whether the event is important for create.",
                    ] as [String: Any],
                    "notes": [
                        "type": "string",
                        "description": "Optional notes for create.",
                    ] as [String: Any],
                ],
                "required": ["action"],
            ] as [String: Any],
        ]
    }

    func execute(argumentsJSON: String) async -> String {
        guard let args = SubAgentJSON.parseArguments(argumentsJSON) else {
            logger.error("calendar invalid arguments", metadata: ["args": .string(argumentsJSON)])
            return SubAgentJSON.encodeError("invalid arguments JSON")
        }
        guard let action = args["action"] as? String else {
            return SubAgentJSON.encodeError("missing action")
        }

        do {
            switch action {
            case "list":
                var fromDate: Date?
                if let fromString = args["from"] as? String {
                    switch SubAgentJSON.parseZonedDate(fromString, defaultTimeZone: timeZone, field: "from") {
                    case .success(let date):
                        fromDate = date
                    case .failure(let error):
                        return SubAgentJSON.encodeError(error.description)
                    }
                }
                var toDate: Date?
                if let toString = args["to"] as? String {
                    switch SubAgentJSON.parseZonedDate(toString, defaultTimeZone: timeZone, field: "to") {
                    case .success(let date):
                        toDate = date
                    case .failure(let error):
                        return SubAgentJSON.encodeError(error.description)
                    }
                }
                let records = try await calendar.listEvents(from: fromDate, to: toDate)
                let items = records.map(eventJSON)
                return SubAgentJSON.encode([
                    "summary": "Found \(items.count) event(s).",
                    "events": items,
                ])
            case "create":
                guard let title = args["title"] as? String,
                      let startsAtString = args["startsAt"] as? String,
                      let endsAtString = args["endsAt"] as? String
                else {
                    return SubAgentJSON.encodeError("create requires title, startsAt, and endsAt")
                }
                let startsAtResult = SubAgentJSON.parseZonedDate(
                    startsAtString,
                    defaultTimeZone: timeZone,
                    field: "startsAt"
                )
                if case .failure(let error) = startsAtResult {
                    return SubAgentJSON.encodeError(error.description)
                }
                let endsAtResult = SubAgentJSON.parseZonedDate(
                    endsAtString,
                    defaultTimeZone: timeZone,
                    field: "endsAt"
                )
                if case .failure(let error) = endsAtResult {
                    return SubAgentJSON.encodeError(error.description)
                }
                guard case .success(let startsAt) = startsAtResult,
                      case .success(let endsAt) = endsAtResult
                else {
                    return SubAgentJSON.encodeError("invalid startsAt or endsAt")
                }
                let location = args["location"] as? String ?? ""
                let isImportant = args["isImportant"] as? Bool ?? false
                let notes = args["notes"] as? String
                let record = try await calendar.createEvent(
                    title: title,
                    startsAt: startsAt,
                    endsAt: endsAt,
                    location: location,
                    isImportant: isImportant,
                    notes: notes
                )
                await reminderScheduler.scheduleEvent(record)
                return SubAgentJSON.encode([
                    "summary": "Created event \"\(record.title)\".",
                    "event": eventJSON(record),
                ])
            case "update":
                guard let id = args["id"] as? String else {
                    return SubAgentJSON.encodeError("update requires id")
                }
                var patch = CalendarPatch()
                if let title = args["title"] as? String {
                    patch.title = title
                }
                if let startsAtString = args["startsAt"] as? String {
                    switch SubAgentJSON.parseZonedDate(
                        startsAtString,
                        defaultTimeZone: timeZone,
                        field: "startsAt"
                    ) {
                    case .success(let date):
                        patch.startsAt = date
                    case .failure(let error):
                        return SubAgentJSON.encodeError(error.description)
                    }
                }
                if let endsAtString = args["endsAt"] as? String {
                    switch SubAgentJSON.parseZonedDate(
                        endsAtString,
                        defaultTimeZone: timeZone,
                        field: "endsAt"
                    ) {
                    case .success(let date):
                        patch.endsAt = date
                    case .failure(let error):
                        return SubAgentJSON.encodeError(error.description)
                    }
                }
                if let location = args["location"] as? String {
                    patch.location = location
                }
                if let isImportant = args["isImportant"] as? Bool {
                    patch.isImportant = isImportant
                }
                if args.keys.contains("notes") {
                    patch.updateNotes = true
                    patch.notes = args["notes"] as? String
                }
                let record = try await calendar.updateEvent(id: id, patch: patch)
                await reminderScheduler.scheduleEvent(record)
                return SubAgentJSON.encode([
                    "summary": "Updated event \"\(record.title)\".",
                    "event": eventJSON(record),
                ])
            case "delete":
                guard let id = args["id"] as? String else {
                    return SubAgentJSON.encodeError("delete requires id")
                }
                try await calendar.deleteEvent(id: id)
                await reminderScheduler.cancelEvent(id: id)
                return SubAgentJSON.encode(["summary": "Deleted event \(id)."])
            default:
                return SubAgentJSON.encodeError("unknown action: \(action)")
            }
        } catch let error as CalendarRepositoryError {
            logger.warning("calendar repository error", metadata: ["error": .string(error.description)])
            return SubAgentJSON.encodeError(error.description)
        } catch {
            logger.error("calendar failed", metadata: ["error": .string("\(error)")])
            return SubAgentJSON.encodeError("\(error)")
        }
    }

    private func eventJSON(_ record: CalendarEventRecord) -> [String: Any] {
        var json: [String: Any] = [
            "id": record.id,
            "title": record.title,
            "startsAt": SubAgentJSON.formatDate(record.startsAt, in: timeZone),
            "endsAt": SubAgentJSON.formatDate(record.endsAt, in: timeZone),
            "location": record.location,
            "isImportant": record.isImportant,
        ]
        if let notes = record.notes {
            json["notes"] = notes
        } else {
            json["notes"] = NSNull()
        }
        return json
    }
}
