import CompanionDatabase
import Foundation
import Hummingbird
import Logging
import NIOCore

struct ConversationSession: ResponseCodable, Sendable {
  let id: String
  let startedAt: Date
  let endedAt: Date?
  let voiceCount: Int

  init(record: ConversationSessionRecord) {
    id = record.id
    startedAt = record.startedAt
    endedAt = record.endedAt
    voiceCount = record.voiceCount
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

/// One side of a turn (`user` or `assistant`) inside `ConversationTurn`. A slimmer sibling of
/// `ConversationMessage` — omits `sessionId`/`turnId`/`role` since those are implied by nesting.
struct ConversationTurnMessage: ResponseCodable, Sendable {
  let id: String
  let content: String
  let audioUrl: String?
  let createdAt: Date

  init(record: ConversationMessageRecord) {
    id = record.id
    content = record.content
    audioUrl = record.audioPath.map { _ in
      "/api/v1/conversations/\(record.sessionId)/messages/\(record.id)/audio"
    }
    createdAt = record.createdAt
  }
}

/// One turn of a conversation, grouping the user's speech, any tool calls the model made
/// while forming its reply, and the assistant's response — the frontend-first shape for
/// `GET /conversations/{id}/history`, so clients render `turns.map(...)` with no client-side
/// merging of separate messages/tool-calls lists.
struct ConversationTurn: ResponseCodable, Sendable {
  let turnId: String
  let user: ConversationTurnMessage?
  let toolCalls: [StructuredToolCall]
  let assistant: ConversationTurnMessage?
}

struct ConversationHistoryResponse: ResponseCodable, Sendable {
  let sessionId: String
  let turns: [ConversationTurn]
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

    conversationRouter.get("/{id}/history") { request, context in
      try requireDeviceToken(from: request, expected: deviceToken)
      let id = try context.parameters.require("id")
      do {
        _ = try await conversations.session(id: id)
      } catch let error as ConversationRepositoryError {
        throw error.httpError
      }
      let limit = parseLimit(request.uri.queryParameters.get("limit"), default: 50)
      let offset = request.uri.queryParameters.get("offset").flatMap(Int.init) ?? 0
      let messages = try await conversations.listMessages(sessionId: id, limit: historyFetchLimit, offset: 0)
      let toolCalls = try await conversations.listToolCalls(sessionId: id, limit: historyFetchLimit, offset: 0)
      let turns = buildTurns(messages: messages, toolCalls: toolCalls, limit: limit, offset: offset)
      logger.debug(
        "GET /api/v1/conversations/{id}/history",
        metadata: ["id": .string(id), "turns": "\(turns.count)"]
      )
      return ConversationHistoryResponse(sessionId: id, turns: turns)
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

  /// Upper bound when fetching a session's full message/tool-call history for grouping —
  /// pagination for `/history` happens on the resulting turn list, not these queries.
  private static let historyFetchLimit = 10_000

  /// Groups messages and tool calls by `turnId`, sorts turns chronologically, and paginates
  /// on the resulting turn list.
  private static func buildTurns(
    messages: [ConversationMessageRecord],
    toolCalls: [ConversationToolCallRecord],
    limit: Int,
    offset: Int
  ) -> [ConversationTurn] {
    var userByTurn: [String: ConversationMessageRecord] = [:]
    var assistantByTurn: [String: ConversationMessageRecord] = [:]
    for message in messages {
      if message.role == "user" {
        userByTurn[message.turnId] = message
      } else if message.role == "assistant" {
        assistantByTurn[message.turnId] = message
      }
    }

    var toolCallsByTurn: [String: [ConversationToolCallRecord]] = [:]
    for call in toolCalls {
      toolCallsByTurn[call.turnId, default: []].append(call)
    }

    let turnIds = Set(userByTurn.keys).union(assistantByTurn.keys).union(toolCallsByTurn.keys)
    let sortedTurnIds = turnIds.sorted { turnOrder($0) < turnOrder($1) }
    let page = sortedTurnIds.dropFirst(offset).prefix(limit)

    return page.map { turnId in
      ConversationTurn(
        turnId: turnId,
        user: userByTurn[turnId].map(ConversationTurnMessage.init(record:)),
        toolCalls: (toolCallsByTurn[turnId] ?? []).map { record in
          ConversationToolCallBuilder.build(
            id: record.id,
            name: record.name,
            detail: record.detail,
            argumentsJSON: record.arguments,
            outputJSON: record.output,
            createdAt: record.createdAt
          )
        },
        assistant: assistantByTurn[turnId].map(ConversationTurnMessage.init(record:))
      )
    }
  }

  /// Extracts the numeric suffix from `"turn-<n>"` (see `VoiceSession.handleAudioStop`) for
  /// chronological sorting; falls back to `Int.max` for unrecognized formats so they sort
  /// last rather than crash.
  private static func turnOrder(_ turnId: String) -> Int {
    guard let dashIndex = turnId.lastIndex(of: "-"),
      let number = Int(turnId[turnId.index(after: dashIndex)...])
    else { return Int.max }
    return number
  }
}

extension ConversationRepositoryError {
  fileprivate var httpError: HTTPError {
    switch self {
    case .sessionNotFound, .messageNotFound, .toolCallNotFound:
      HTTPError(.notFound, message: description)
    }
  }
}
