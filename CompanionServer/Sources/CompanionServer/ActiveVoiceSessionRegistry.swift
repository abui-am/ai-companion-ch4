import Foundation
import Logging

struct ActiveVoiceSession: Sendable {
  let sessionId: String
  let session: VoiceSession
  let gateway: DeviceCommandGateway
}

/// Tracks the active ESP32 voice session for proactive reminders.
actor ActiveVoiceSessionRegistry {
  private var active: ActiveVoiceSession?
  private let logger: Logger

  init(logger: Logger) {
    self.logger = logger
  }

  func register(sessionId: String, session: VoiceSession, gateway: DeviceCommandGateway) {
    active = ActiveVoiceSession(sessionId: sessionId, session: session, gateway: gateway)
    logger.info("voice session registered for reminders", metadata: ["session_id": .string(sessionId)])
  }

  func unregister(sessionId: String) {
    guard active?.sessionId == sessionId else { return }
    active = nil
    logger.info("voice session unregistered for reminders", metadata: ["session_id": .string(sessionId)])
  }

  func currentSession() -> ActiveVoiceSession? {
    active
  }
}
