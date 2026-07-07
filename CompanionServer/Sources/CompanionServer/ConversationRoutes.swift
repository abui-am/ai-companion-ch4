import CompanionDatabase
import Foundation
import Hummingbird
import Logging
import NIOCore

struct ConversationSession: ResponseCodable, Sendable {
  let id: String
  let startedAt: Date
  let endedAt: Date?

  init(record: ConversationSessionRecord) {
    id = record.id
    startedAt = record.startedAt
    endedAt = record.endedAt
  }
}

struct ConversationSessionsResponse: ResponseCodable, Sendable {
  let sessions: [ConversationSession]
}

struct ConversationMessage: ResponseCodable, Sendable {
  let id: String
  let sessionId: String
  let turnId: String
  let role: String
  let content: String
  let audioUrl: String?
  let createdAt: Date

  init(record: ConversationMessageRecord) {
    id = record.id
    sessionId = record.sessionId
    turnId = record.turnId
    role = record.role
    content = record.content
    audioUrl = record.audioPath.map { _ in
      "/api/v1/conversations/\(record.sessionId)/messages/\(record.id)/audio"
    }
    createdAt = record.createdAt
  }
}

struct ConversationMessagesResponse: ResponseCodable, Sendable {
  let messages: [ConversationMessage]
}

/// Read-only browsing of persisted conversation history — see `ConversationRepository`
/// and `VoiceSession` (the only writer). Gated upstream by `privacy.personalizationData`.
enum ConversationRoutes {
  static func register(
    on router: Router<BasicRequestContext>,
    conversations: ConversationRepository,
    audioStore: ConversationAudioStore,
    deviceToken: String,
    logger: Logger
  ) {
    let conversationRouter = router.group("/api/v1/conversations")

    conversationRouter.get { request, _ in
      try requireDeviceToken(from: request, expected: deviceToken)
      let from = parseISO8601(request.uri.queryParameters.get("from"))
      let to = parseISO8601(request.uri.queryParameters.get("to"))
      let limit = parseLimit(request.uri.queryParameters.get("limit"), default: 50)
      let records = try await conversations.listSessions(from: from, to: to, limit: limit)
      logger.debug("GET /api/v1/conversations", metadata: ["count": "\(records.count)"])
      return ConversationSessionsResponse(sessions: records.map(ConversationSession.init(record:)))
    }

    conversationRouter.get("/{id}") { request, context in
      try requireDeviceToken(from: request, expected: deviceToken)
      let id = try context.parameters.require("id")
      do {
        let record = try await conversations.session(id: id)
        logger.debug("GET /api/v1/conversations/{id}", metadata: ["id": .string(id)])
        return ConversationSession(record: record)
      } catch let error as ConversationRepositoryError {
        throw error.httpError
      }
    }

    conversationRouter.get("/{id}/messages") { request, context in
      try requireDeviceToken(from: request, expected: deviceToken)
      let id = try context.parameters.require("id")
      do {
        _ = try await conversations.session(id: id)
      } catch let error as ConversationRepositoryError {
        throw error.httpError
      }
      let limit = parseLimit(request.uri.queryParameters.get("limit"), default: 100)
      let offset = request.uri.queryParameters.get("offset").flatMap(Int.init) ?? 0
      let records = try await conversations.listMessages(sessionId: id, limit: limit, offset: offset)
      logger.debug(
        "GET /api/v1/conversations/{id}/messages",
        metadata: ["id": .string(id), "count": "\(records.count)"]
      )
      return ConversationMessagesResponse(messages: records.map(ConversationMessage.init(record:)))
    }

    conversationRouter.get("/{id}/messages/{messageId}/audio") { request, context in
      try requireDeviceToken(from: request, expected: deviceToken)
      let sessionId = try context.parameters.require("id")
      let messageId = try context.parameters.require("messageId")
      let message: ConversationMessageRecord
      do {
        message = try await conversations.message(id: messageId)
      } catch let error as ConversationRepositoryError {
        throw error.httpError
      }
      guard message.sessionId == sessionId else {
        throw HTTPError(.notFound, message: "Message not found in this conversation")
      }
      guard let audioPath = message.audioPath else {
        throw HTTPError(.notFound, message: "Message has no audio")
      }
      let fileURL = audioStore.fileURL(forRelativePath: audioPath)
      guard let data = FileManager.default.contents(atPath: fileURL.path) else {
        throw HTTPError(.notFound, message: "Audio file not found on disk")
      }
      logger.debug(
        "GET /api/v1/conversations/{id}/messages/{messageId}/audio",
        metadata: ["message_id": .string(messageId), "bytes": "\(data.count)"]
      )
      return Response(
        status: .ok,
        headers: [
          .contentType: "audio/wav",
          .contentLength: "\(data.count)"
        ],
        body: .init(byteBuffer: ByteBuffer(data: data))
      )
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

  private static func parseLimit(_ value: String?, default defaultLimit: Int) -> Int {
    guard let value, let parsed = Int(value), parsed > 0 else { return defaultLimit }
    return parsed
  }
}

extension ConversationRepositoryError {
  fileprivate var httpError: HTTPError {
    switch self {
    case .sessionNotFound, .messageNotFound:
      HTTPError(.notFound, message: description)
    }
  }
}
