import CompanionDatabase
import CompanionEnv
import CryptoKit
import Foundation
import Logging

enum APNsError: Error, CustomStringConvertible, Sendable {
  case notConfigured
  case invalidPrivateKey
  case requestFailed(Int, String)

  var description: String {
    switch self {
    case .notConfigured:
      "APNs is not configured"
    case .invalidPrivateKey:
      "Invalid APNs private key"
    case .requestFailed(let status, let body):
      "APNs request failed (\(status)): \(body)"
    }
  }
}

protocol APNsSending: Sendable {
  func sendReminder(
    to device: PushDeviceRecord,
    job: ReminderJobRecord,
    remindBeforeMinutes: Int
  ) async throws
}

struct APNsConfiguration: Sendable {
  let keyID: String
  let teamID: String
  let privateKeyPEM: String
  let defaultBundleID: String?

  static func load(from config: AppConfig) -> APNsConfiguration? {
    guard let keyID = config.apnsKeyID,
          let teamID = config.apnsTeamID,
          let pem = resolvePrivateKeyPEM(from: config),
          !keyID.isEmpty, !teamID.isEmpty, !pem.isEmpty
    else { return nil }
    return APNsConfiguration(
      keyID: keyID,
      teamID: teamID,
      privateKeyPEM: pem,
      defaultBundleID: config.apnsBundleID
    )
  }

  private static func resolvePrivateKeyPEM(from config: AppConfig) -> String? {
    if let inline = config.apnsPrivateKey?.trimmingCharacters(in: .whitespacesAndNewlines),
       !inline.isEmpty {
      return inline.replacingOccurrences(of: "\\n", with: "\n")
    }
    if let path = config.apnsPrivateKeyPath?.trimmingCharacters(in: .whitespacesAndNewlines),
       !path.isEmpty,
       let pem = try? String(contentsOfFile: path, encoding: .utf8) {
      return pem.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return nil
  }
}

struct APNsService: APNsSending {
  private let configuration: APNsConfiguration
  private let logger: Logger
  private let session: URLSession

  init(configuration: APNsConfiguration, logger: Logger, session: URLSession = .shared) {
    self.configuration = configuration
    self.logger = logger
    self.session = session
  }

  func sendReminder(
    to device: PushDeviceRecord,
    job: ReminderJobRecord,
    remindBeforeMinutes: Int
  ) async throws {
    let topic = device.bundleId.isEmpty
      ? (configuration.defaultBundleID ?? device.bundleId)
      : device.bundleId
    guard !topic.isEmpty else {
      throw APNsError.notConfigured
    }

    let title = job.kind == .task ? "Task reminder" : "Calendar reminder"
    let body = "\(job.title) is due in \(remindBeforeMinutes) minutes"
    var companion: [String: Any] = [
      "type": "reminder",
      "kind": job.kind.rawValue,
      "id": job.sourceId,
      "title": job.title,
      "fireAt": iso8601(job.fireAt),
      "remindBeforeMinutes": remindBeforeMinutes,
    ]
    if job.kind == .task {
      companion["dueAt"] = iso8601(job.targetAt)
    } else {
      companion["startsAt"] = iso8601(job.targetAt)
    }

    let payload: [String: Any] = [
      "aps": [
        "alert": ["title": title, "body": body],
        "sound": "default",
      ],
      "companion": companion,
    ]
    let payloadData = try JSONSerialization.data(withJSONObject: payload)

    let host = device.environment == .production
      ? "api.push.apple.com"
      : "api.sandbox.push.apple.com"
    let url = URL(string: "https://\(host)/3/device/\(device.deviceToken)")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = payloadData
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue(topic, forHTTPHeaderField: "apns-topic")
    request.setValue("alert", forHTTPHeaderField: "apns-push-type")
    request.setValue("10", forHTTPHeaderField: "apns-priority")
    request.setValue(try makeBearerToken(), forHTTPHeaderField: "authorization")

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw APNsError.requestFailed(-1, "no HTTP response")
    }
    guard (200...299).contains(http.statusCode) else {
      let responseBody = String(data: data, encoding: .utf8) ?? ""
      logger.warning(
        "apns request rejected",
        metadata: [
          "status": .stringConvertible(http.statusCode),
          "device_id": .string(device.id),
          "topic": .string(topic),
          "environment": .string(device.environment.rawValue),
          "body": .string(responseBody),
        ]
      )
      throw APNsError.requestFailed(http.statusCode, responseBody)
    }
    logger.info(
      "apns reminder sent",
      metadata: ["device_id": .string(device.id), "job_id": .string(job.id)]
    )
  }

  private func makeBearerToken() throws -> String {
    let header = base64URL(["alg": "ES256", "kid": configuration.keyID])
    let issuedAt = Int(Date().timeIntervalSince1970)
    let payload = base64URL(["iss": configuration.teamID, "iat": issuedAt])
    let signingInput = "\(header).\(payload)"
    let signature = try signES256(signingInput)
    return "bearer \(header).\(payload).\(signature)"
  }

  private func signES256(_ input: String) throws -> String {
    let key = try parsePrivateKey(configuration.privateKeyPEM)
    let signature = try key.signature(for: Data(input.utf8))
    return base64URLEncode(signature.rawRepresentation)
  }

  private func parsePrivateKey(_ pem: String) throws -> P256.Signing.PrivateKey {
    var normalized = pem
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if (normalized.hasPrefix("\"") && normalized.hasSuffix("\""))
      || (normalized.hasPrefix("'") && normalized.hasSuffix("'"))
    {
      normalized = String(normalized.dropFirst().dropLast())
    }
    normalized = normalized.replacingOccurrences(of: "\\n", with: "\n")
    do {
      return try P256.Signing.PrivateKey(pemRepresentation: normalized)
    } catch {
      throw APNsError.invalidPrivateKey
    }
  }

  private func base64URL(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "" }
    return base64URLEncode(data)
  }

  private func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private func iso8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}
