import CompanionDatabase
import Foundation
import Hummingbird
import Logging

struct ProfileResponse: ResponseCodable, Sendable {
  let name: String?
  let role: String?
  let focusSecondsToday: Int
  let date: String
  let updatedAt: Date

  init(record: ProfileRecord) {
    name = record.name
    role = record.role
    focusSecondsToday = record.focusSecondsToday
    date = record.date
    updatedAt = record.updatedAt
  }
}

private struct PatchProfileRequest: Decodable, Sendable {
  let name: String?
  let role: String?
  let updateName: Bool
  let updateRole: Bool

  enum CodingKeys: String, CodingKey {
    case name
    case role
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if container.contains(.name) {
      updateName = true
      name = try container.decode(String.self, forKey: .name)
    } else {
      updateName = false
      name = nil
    }
    if container.contains(.role) {
      updateRole = true
      role = try container.decode(String.self, forKey: .role)
    } else {
      updateRole = false
      role = nil
    }
  }

  var patch: ProfilePatch {
    ProfilePatch(
      name: name,
      role: role,
      updateName: updateName,
      updateRole: updateRole
    )
  }
}

private struct AddFocusRequest: Decodable, Sendable {
  let seconds: Int
}

enum ProfileRoutes {
  static func register(
    on router: Router<BasicRequestContext>,
    profile: ProfileRepository,
    deviceToken: String,
    logger: Logger
  ) {
    let profileRouter = router.group("/api/v1/profile")

    profileRouter.get { request, _ in
      try requireDeviceToken(from: request, expected: deviceToken)
      let record = try await profile.getProfile()
      logger.debug("GET /api/v1/profile")
      return ProfileResponse(record: record)
    }

    profileRouter.patch { request, context in
      try requireDeviceToken(from: request, expected: deviceToken)
      let body: PatchProfileRequest
      do {
        body = try await request.decode(as: PatchProfileRequest.self, context: context)
      } catch let error as DecodingError {
        throw HTTPError(.badRequest, message: "Invalid profile body: \(error)")
      }
      do {
        let record = try await profile.updateProfile(body.patch)
        logger.info("PATCH /api/v1/profile")
        return ProfileResponse(record: record)
      } catch let error as ProfileRepositoryError {
        switch error {
        case .invalidInput:
          throw HTTPError(.badRequest, message: error.description)
        case .notFound:
          throw HTTPError(.internalServerError, message: error.description)
        }
      }
    }

    profileRouter.post("/focus") { request, context in
      try requireDeviceToken(from: request, expected: deviceToken)
      let body: AddFocusRequest
      do {
        body = try await request.decode(as: AddFocusRequest.self, context: context)
      } catch let error as DecodingError {
        throw HTTPError(.badRequest, message: "Invalid focus body: \(error)")
      }
      do {
        let record = try await profile.addFocus(seconds: body.seconds)
        logger.info("POST /api/v1/profile/focus")
        return ProfileResponse(record: record)
      } catch let error as ProfileRepositoryError {
        switch error {
        case .invalidInput:
          throw HTTPError(.badRequest, message: error.description)
        case .notFound:
          throw HTTPError(.internalServerError, message: error.description)
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
