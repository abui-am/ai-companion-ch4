import CompanionDatabase
import Foundation
import Hummingbird
import HTTPTypes
import Logging

struct CalendarEvent: ResponseCodable, Sendable {
  let id: String
  let title: String
  let startsAt: Date
  let endsAt: Date
  let location: String
  let isImportant: Bool
  let notes: String?

  init(record: CalendarEventRecord) {
    id = record.id
    title = record.title
    startsAt = record.startsAt
    endsAt = record.endsAt
    location = record.location
    isImportant = record.isImportant
    notes = record.notes
  }

  enum CodingKeys: String, CodingKey {
    case id, title, startsAt, endsAt, location, isImportant, notes
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(title, forKey: .title)
    try container.encode(startsAt, forKey: .startsAt)
    try container.encode(endsAt, forKey: .endsAt)
    try container.encode(location, forKey: .location)
    try container.encode(isImportant, forKey: .isImportant)
    if let notes {
      try container.encode(notes, forKey: .notes)
    } else {
      try container.encodeNil(forKey: .notes)
    }
  }
}

struct CalendarEventsResponse: ResponseCodable, Sendable {
  let events: [CalendarEvent]
}

struct CreateCalendarEventRequest: Decodable, Sendable {
  let title: String
  let startsAt: Date
  let endsAt: Date
  let location: String
  let isImportant: Bool
  let notes: String?
}

private struct PatchCalendarEventRequest: Decodable, Sendable {
  let title: String?
  let startsAt: Date?
  let endsAt: Date?
  let location: String?
  let isImportant: Bool?
  let notes: String?
  let updateNotes: Bool

  enum CodingKeys: String, CodingKey {
    case title, startsAt, endsAt, location, isImportant, notes
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    title = try container.decodeIfPresent(String.self, forKey: .title)
    startsAt = try container.decodeIfPresent(Date.self, forKey: .startsAt)
    endsAt = try container.decodeIfPresent(Date.self, forKey: .endsAt)
    location = try container.decodeIfPresent(String.self, forKey: .location)
    isImportant = try container.decodeIfPresent(Bool.self, forKey: .isImportant)
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

  var patch: CalendarPatch {
    CalendarPatch(
      title: title,
      startsAt: startsAt,
      endsAt: endsAt,
      location: location,
      isImportant: isImportant,
      notes: notes,
      updateNotes: updateNotes
    )
  }
}

enum CalendarRoutes {
  static func register(
    on router: Router<BasicRequestContext>,
    calendar: CalendarRepository,
    reminderScheduler: ReminderScheduler,
    deviceToken: String,
    logger: Logger
  ) {
    let calendarRouter = router.group("/api/v1/calendar")

    calendarRouter.get("/events") { request, _ in
      try requireDeviceToken(from: request, expected: deviceToken)
      let from = parseISO8601(request.uri.queryParameters.get("from"))
      let to = parseISO8601(request.uri.queryParameters.get("to"))
      let records = try await calendar.listEvents(from: from, to: to)
      logger.debug(
        "GET /api/v1/calendar/events",
        metadata: ["count": "\(records.count)"]
      )
      return CalendarEventsResponse(events: records.map(CalendarEvent.init(record:)))
    }

    calendarRouter.get("/events/{id}") { request, context in
      try requireDeviceToken(from: request, expected: deviceToken)
      let id = try context.parameters.require("id")
      do {
        let record = try await calendar.event(id: id)
        logger.debug("GET /api/v1/calendar/events/{id}", metadata: ["id": .string(id)])
        return CalendarEvent(record: record)
      } catch let error as CalendarRepositoryError {
        switch error {
        case .notFound:
          throw HTTPError(.notFound, message: error.description)
        case .invalidRange:
          throw HTTPError(.badRequest, message: error.description)
        case .invalidInput:
          throw HTTPError(.badRequest, message: error.description)
        }
      }
    }

    calendarRouter.post("/events") { request, context in
      try requireDeviceToken(from: request, expected: deviceToken)
      let body = try await request.decode(as: CreateCalendarEventRequest.self, context: context)
      do {
        let record = try await calendar.createEvent(
          title: body.title,
          startsAt: body.startsAt,
          endsAt: body.endsAt,
          location: body.location,
          isImportant: body.isImportant,
          notes: body.notes
        )
        await reminderScheduler.scheduleEvent(record)
        logger.info("POST /api/v1/calendar/events", metadata: ["id": .string(record.id)])
        return CalendarEvent(record: record)
      } catch let error as CalendarRepositoryError {
        switch error {
        case .notFound:
          throw HTTPError(.internalServerError, message: error.description)
        case .invalidRange:
          throw HTTPError(.badRequest, message: error.description)
        case .invalidInput:
          throw HTTPError(.badRequest, message: error.description)
        }
      }
    }

    calendarRouter.patch("/events/{id}") { request, context in
      try requireDeviceToken(from: request, expected: deviceToken)
      let id = try context.parameters.require("id")
      let body = try await request.decode(as: PatchCalendarEventRequest.self, context: context)
      do {
        let record = try await calendar.updateEvent(id: id, patch: body.patch)
        await reminderScheduler.scheduleEvent(record)
        logger.info("PATCH /api/v1/calendar/events/{id}", metadata: ["id": .string(id)])
        return CalendarEvent(record: record)
      } catch let error as CalendarRepositoryError {
        switch error {
        case .notFound:
          throw HTTPError(.notFound, message: error.description)
        case .invalidRange:
          throw HTTPError(.badRequest, message: error.description)
        case .invalidInput:
          throw HTTPError(.badRequest, message: error.description)
        }
      }
    }

    calendarRouter.delete("/events/{id}") { request, context -> HTTPResponse.Status in
      try requireDeviceToken(from: request, expected: deviceToken)
      let id = try context.parameters.require("id")
      do {
        try await calendar.deleteEvent(id: id)
        await reminderScheduler.cancelEvent(id: id)
        logger.info("DELETE /api/v1/calendar/events/{id}", metadata: ["id": .string(id)])
        return .noContent
      } catch let error as CalendarRepositoryError {
        switch error {
        case .notFound:
          throw HTTPError(.notFound, message: error.description)
        case .invalidRange:
          throw HTTPError(.badRequest, message: error.description)
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

  private static func parseISO8601(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}
