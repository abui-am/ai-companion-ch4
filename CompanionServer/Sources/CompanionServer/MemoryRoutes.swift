import CompanionDatabase
import Foundation
import Hummingbird
import HTTPTypes
import Logging

struct MemoryItem: ResponseCodable, Sendable {
  let id: String
  let content: String
  let source: String
  let createdAt: Date

  init(record: MemoryRecord) {
    id = record.id
    content = record.content
    source = record.source
    createdAt = record.createdAt
  }
}

struct MemoriesResponse: ResponseCodable, Sendable {
  let memories: [MemoryItem]
}

/// Read/delete REST API for stored memories — writes happen only through the voice `memory`
/// tool, see `MemoryAgent`. Gated by `privacy.personalizationData`: returns an empty list when
/// personalization is off, mirroring how `ConversationRoutes` treats that same flag.
enum MemoryRoutes {
  static func register(
    on router: Router<BasicRequestContext>,
    memories: MemoryRepository,
    config: ConfigRepository,
    deviceToken: String,
    logger: Logger
  ) {
    let memoriesRouter = router.group("/api/v1/memories")

    memoriesRouter.get { request, _ in
      try requireDeviceToken(from: request, expected: deviceToken)
      guard await isPersonalizationEnabled(config: config, logger: logger) else {
        logger.debug("GET /api/v1/memories — personalization disabled, returning empty list")
        return MemoriesResponse(memories: [])
      }
      let limit = parseLimit(request.uri.queryParameters.get("limit"), default: 100)
      let records = try await memories.list(limit: limit)
      logger.debug("GET /api/v1/memories", metadata: ["count": "\(records.count)"])
      return MemoriesResponse(memories: records.map(MemoryItem.init(record:)))
    }

    memoriesRouter.delete("/{id}") { request, context -> HTTPResponse.Status in
      try requireDeviceToken(from: request, expected: deviceToken)
      let id = try context.parameters.require("id")
      do {
        try await memories.delete(id: id)
        logger.info("DELETE /api/v1/memories/{id}", metadata: ["id": .string(id)])
        return .noContent
      } catch let error as MemoryRepositoryError {
        switch error {
        case .notFound:
          throw HTTPError(.notFound, message: error.description)
        case .invalidInput:
          throw HTTPError(.badRequest, message: error.description)
        }
      }
    }
  }

  private static func isPersonalizationEnabled(config: ConfigRepository, logger: Logger) async -> Bool {
    do {
      return try await config.get().personalizationData
    } catch {
      logger.warning("failed to load config for memory privacy check", metadata: ["error": "\(error)"])
      return false
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

  private static func parseLimit(_ value: String?, default defaultLimit: Int) -> Int {
    guard let value, let parsed = Int(value), parsed > 0 else { return defaultLimit }
    return parsed
  }
}
