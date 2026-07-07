import CompanionDatabase
import Foundation
import Hummingbird
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

enum CalendarRoutes {
  static func register(
    on router: Router<BasicRequestContext>,
    calendar: CalendarRepository,
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
        logger.info("POST /api/v1/calendar/events", metadata: ["id": .string(record.id)])
        return CalendarEvent(record: record)
      } catch let error as CalendarRepositoryError {
        switch error {
        case .notFound:
          throw HTTPError(.internalServerError, message: error.description)
        case .invalidRange:
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
