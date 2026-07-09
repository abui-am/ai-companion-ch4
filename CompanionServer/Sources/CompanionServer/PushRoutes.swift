import CompanionDatabase
import Foundation
import Hummingbird
import Logging

struct PushDeviceResponse: ResponseEncodable, Sendable {
  let id: String
  let platform: PushPlatform
  let deviceToken: String
  let bundleId: String
  let environment: PushEnvironment
  let updatedAt: Date

  init(record: PushDeviceRecord) {
    id = record.id
    platform = record.platform
    deviceToken = record.deviceToken
    bundleId = record.bundleId
    environment = record.environment
    updatedAt = record.updatedAt
  }
}

struct RegisterPushDeviceRequest: Decodable, Sendable {
  let platform: PushPlatform
  let deviceToken: String
  let bundleId: String
  let environment: PushEnvironment
}

struct DeletePushDeviceRequest: Decodable, Sendable {
  let deviceToken: String
}

enum PushRoutes {
  static func register(
    on router: Router<BasicRequestContext>,
    pushDevices: PushDeviceRepository,
    deviceToken: String,
    logger: Logger
  ) {
    let pushRouter = router.group("/api/v1/push")

    pushRouter.put("/device") { request, context in
      try requireDeviceToken(from: request, expected: deviceToken)
      let body = try await request.decode(as: RegisterPushDeviceRequest.self, context: context)
      guard body.platform == .macos else {
        throw HTTPError(.badRequest, message: "Only platform macos is supported")
      }
      do {
        let record = try await pushDevices.upsert(
          platform: body.platform,
          deviceToken: body.deviceToken,
          bundleId: body.bundleId,
          environment: body.environment
        )
        logger.info("PUT /api/v1/push/device", metadata: ["id": .string(record.id)])
        return PushDeviceResponse(record: record)
      } catch let error as PushDeviceRepositoryError {
        switch error {
        case .invalidInput:
          throw HTTPError(.badRequest, message: error.description)
        case .notFound:
          throw HTTPError(.internalServerError, message: error.description)
        }
      }
    }

    pushRouter.delete("/device") { request, context -> HTTPResponse.Status in
      try requireDeviceToken(from: request, expected: deviceToken)
      let body = try await request.decode(as: DeletePushDeviceRequest.self, context: context)
      do {
        try await pushDevices.delete(deviceToken: body.deviceToken)
        logger.info("DELETE /api/v1/push/device")
        return .noContent
      } catch let error as PushDeviceRepositoryError {
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
}
