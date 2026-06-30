import Configuration
import Foundation
import SystemPackage

public enum AppConfigError: Error, CustomStringConvertible {
  case missingDeviceToken
  case missingOpenAIAPIKey

  public var description: String {
    switch self {
    case .missingDeviceToken:
      "DEVICE_TOKEN env var not set — showcase auth requires a shared bearer token"
    case .missingOpenAIAPIKey:
      "OPENAI_API_KEY env var not set"
    }
  }
}

public struct AppConfig: Sendable {
  public let deviceToken: String
  public let openAIAPIKey: String
  public let companionHost: String

  public static func load() async throws -> AppConfig {
    let secrets: SecretsSpecifier<String, String> = .specific(["DEVICE_TOKEN", "OPENAI_API_KEY"])
    var providers: [any ConfigProvider] = [
      EnvironmentVariablesProvider(secretsSpecifier: secrets),
    ]
    if let envPath = PackagePaths.dotEnvFile() {
      providers.append(
        try await EnvironmentVariablesProvider(
          environmentFilePath: FilePath(envPath),
          secretsSpecifier: secrets
        )
      )
    }

    let reader = ConfigReader(providers: providers)

    guard let deviceToken = reader.string(forKey: "device.token", isSecret: true), !deviceToken.isEmpty else {
      throw AppConfigError.missingDeviceToken
    }
    guard let openAIAPIKey = reader.string(forKey: "openai.api.key", isSecret: true), !openAIAPIKey.isEmpty else {
      throw AppConfigError.missingOpenAIAPIKey
    }
    let companionHost = reader.string(forKey: "companion.host", default: "ws://127.0.0.1:8080/ws")

    return AppConfig(
      deviceToken: deviceToken,
      openAIAPIKey: openAIAPIKey,
      companionHost: companionHost
    )
  }
}
