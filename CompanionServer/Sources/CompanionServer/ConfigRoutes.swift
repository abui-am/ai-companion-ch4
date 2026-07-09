import CompanionDatabase
import Foundation
import Hummingbird
import Logging

struct ConnectionResponse: Encodable, Sendable {
  let deviceName: String
  let status: String
}

struct NotificationsResponse: Encodable, Sendable {
  let taskReminders: Bool
  let calendarAlerts: Bool
  let remindBeforeMinutes: Int
}

struct PrivacyResponse: Encodable, Sendable {
  let cameraAccess: Bool
  let personalizationData: Bool
}

struct PersonaStateResponse: ResponseEncodable, Sendable {
  let active: String?
  let available: [String]
}

struct ConfigResponse: ResponseEncodable, Sendable {
  let personality: ConfigPersonality
  let persona: PersonaStateResponse
  let connection: ConnectionResponse
  let appearance: ConfigAppearance
  let notifications: NotificationsResponse
  let privacy: PrivacyResponse
  let language: ConfigLanguage

  init(record: ConfigRecord, persona: PersonaStateResponse) {
    personality = record.personality
    self.persona = persona
    connection = ConfigRoutes.mockConnection
    appearance = record.appearance
    notifications = NotificationsResponse(
      taskReminders: record.taskReminders,
      calendarAlerts: record.calendarAlerts,
      remindBeforeMinutes: record.remindBeforeMinutes
    )
    privacy = PrivacyResponse(
      cameraAccess: record.cameraAccess,
      personalizationData: record.personalizationData
    )
    language = record.language
  }
}

struct PatchNotificationsRequest: Decodable, Sendable {
  let taskReminders: Bool?
  let calendarAlerts: Bool?
  let remindBeforeMinutes: Int?
}

struct PatchPrivacyRequest: Decodable, Sendable {
  let cameraAccess: Bool?
  let personalizationData: Bool?
}

/// `connection` is deliberately not a stored property — see `ConfigRoutes.mockConnection`.
/// If a caller sends it in the PATCH body, `JSONDecoder` silently ignores the unknown key.
struct PatchConfigRequest: Decodable, Sendable {
  let personality: ConfigPersonality?
  let appearance: ConfigAppearance?
  let notifications: PatchNotificationsRequest?
  let privacy: PatchPrivacyRequest?
  let language: ConfigLanguage?

  var patch: ConfigPatch {
    ConfigPatch(
      personality: personality,
      appearance: appearance,
      taskReminders: notifications?.taskReminders,
      calendarAlerts: notifications?.calendarAlerts,
      remindBeforeMinutes: notifications?.remindBeforeMinutes,
      cameraAccess: privacy?.cameraAccess,
      personalizationData: privacy?.personalizationData,
      language: language
    )
  }
}

struct PersonalityResponse: ResponseEncodable, Sendable {
  let personality: ConfigPersonality
}

struct PutPersonalityRequest: Decodable, Sendable {
  let personality: ConfigPersonality
}

struct PutConfigPersonaRequest: Decodable, Sendable {
  let name: String?
}

enum ConfigRoutes {
  /// Device pairing is not implemented — the Settings page always shows this
  /// hardcoded connection. Never persisted, never mutated by PATCH.
  static let mockConnection = ConnectionResponse(deviceName: "Bocil-Desk-01", status: "paired")

  static func register(
    on router: Router<BasicRequestContext>,
    config: ConfigRepository,
    reminderScheduler: ReminderScheduler,
    personas: PersonaStore? = nil,
    sessionRegistry: ActiveVoiceSessionRegistry? = nil,
    deviceToken: String,
    logger: Logger
  ) {
    let configRouter = router.group("/api/v1/config")

    configRouter.get { request, _ in
      try requireDeviceToken(from: request, expected: deviceToken)
      let record = try await config.get()
      logger.debug("GET /api/v1/config")
      return ConfigResponse(record: record, persona: await personaState(from: personas))
    }

    configRouter.put("/personality") { request, context in
      try requireDeviceToken(from: request, expected: deviceToken)
      let body: PutPersonalityRequest
      do {
        body = try await request.decode(as: PutPersonalityRequest.self, context: context)
      } catch {
        throw HTTPError(.badRequest, message: "Invalid personality body: \(error)")
      }
      do {
        let record = try await config.update(ConfigPatch(personality: body.personality))
        await pushPersonalityToActiveSession(body.personality, sessionRegistry: sessionRegistry)
        logger.info(
          "PUT /api/v1/config/personality",
          metadata: ["personality": .string(body.personality.rawValue)]
        )
        return PersonalityResponse(personality: record.personality)
      } catch let error as ConfigRepositoryError {
        switch error {
        case .invalidRemindBeforeMinutes:
          throw HTTPError(.badRequest, message: error.description)
        case .notFound, .corruptData:
          throw HTTPError(.internalServerError, message: error.description)
        }
      }
    }

    configRouter.put("/persona") { request, context in
      try requireDeviceToken(from: request, expected: deviceToken)
      guard let personas else {
        throw HTTPError(.serviceUnavailable, message: "Personas are not configured")
      }
      let body: PutConfigPersonaRequest
      do {
        body = try await request.decode(as: PutConfigPersonaRequest.self, context: context)
      } catch {
        throw HTTPError(.badRequest, message: "Invalid persona body: \(error)")
      }
      do {
        try await personas.setActive(body.name)
        logger.info(
          "PUT /api/v1/config/persona",
          metadata: ["persona": .string(body.name ?? "none")]
        )
        return await personaState(from: personas)
      } catch let error as PersonaError {
        throw HTTPError(.badRequest, message: error.description)
      }
    }

    configRouter.patch { request, context in
      try requireDeviceToken(from: request, expected: deviceToken)
      let body: PatchConfigRequest
      do {
        body = try await request.decode(as: PatchConfigRequest.self, context: context)
      } catch let error as DecodingError {
        throw HTTPError(.badRequest, message: "Invalid config body: \(error)")
      }
      do {
        let previous = try await config.get()
        let record = try await config.update(body.patch)
        if body.patch.remindBeforeMinutes != nil {
          await reminderScheduler.recomputeAfterConfigChange(
            previousMinutes: previous.remindBeforeMinutes,
            newMinutes: record.remindBeforeMinutes
          )
        }
        if let personality = body.patch.personality {
          await pushPersonalityToActiveSession(personality, sessionRegistry: sessionRegistry)
        }
        logger.info("PATCH /api/v1/config")
        return ConfigResponse(record: record, persona: await personaState(from: personas))
      } catch let error as ConfigRepositoryError {
        switch error {
        case .invalidRemindBeforeMinutes:
          throw HTTPError(.badRequest, message: error.description)
        case .notFound, .corruptData:
          throw HTTPError(.internalServerError, message: error.description)
        }
      }
    }
  }

  private static func personaState(from personas: PersonaStore?) async -> PersonaStateResponse {
    guard let personas else {
      return PersonaStateResponse(active: nil, available: [])
    }
    return PersonaStateResponse(
      active: await personas.activeName(),
      available: await personas.available()
    )
  }

  private static func pushPersonalityToActiveSession(
    _ personality: ConfigPersonality,
    sessionRegistry: ActiveVoiceSessionRegistry?
  ) async {
    guard let active = await sessionRegistry?.currentSession() else { return }
    await active.session.applyPersonality(personality)
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
