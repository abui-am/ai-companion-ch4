import Configuration
import Foundation
import SystemPackage

public enum TTSProvider: String, Sendable {
  case openai
  case cartesia
}

public enum AppConfigError: Error, CustomStringConvertible {
  case missingDeviceToken
  case missingOpenAIAPIKey
  case missingCartesiaAPIKey

  public var description: String {
    switch self {
    case .missingDeviceToken:
      "DEVICE_TOKEN env var not set — showcase auth requires a shared bearer token"
    case .missingOpenAIAPIKey:
      "OPENAI_API_KEY env var not set"
    case .missingCartesiaAPIKey:
      "CARTESIA_API_KEY env var not set — required when TTS_PROVIDER=cartesia"
    }
  }
}

public struct AppConfig: Sendable {
  public let deviceToken: String
  public let openAIAPIKey: String
  public let openAIRealtimeModel: String
  public let openAIRealtimeVoice: String
  public let ttsProvider: TTSProvider
  public let cartesiaAPIKey: String?
  public let cartesiaVoiceId: String
  public let cartesiaModelId: String
  public let companionHost: String
  public let webSearchEnabled: Bool
  public let openAISearchModel: String
  public let responseLanguage: String

  public var usesCartesiaTTS: Bool { ttsProvider == .cartesia }

  public static func load() async throws -> AppConfig {
    let secrets: SecretsSpecifier<String, String> = .specific(["DEVICE_TOKEN", "OPENAI_API_KEY", "CARTESIA_API_KEY"])
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
    let openAIRealtimeModel = reader.string(forKey: "openai.realtime.model", default: "gpt-realtime-mini")
    let openAIRealtimeVoice = reader.string(forKey: "openai.realtime.voice", default: "verse")
    let ttsProviderRaw = reader.string(forKey: "tts.provider", default: "openai")
    let ttsProvider = TTSProvider(rawValue: ttsProviderRaw) ?? .openai
    let cartesiaAPIKey = reader.string(forKey: "cartesia.api.key", isSecret: true)
    let cartesiaVoiceId = reader.string(forKey: "cartesia.voice.id", default: "f786b574-daa5-4673-aa0c-cbe3e8534c02")
    let cartesiaModelId = reader.string(forKey: "cartesia.model.id", default: "sonic-3.5")
    let webSearchEnabled = reader.bool(forKey: "web.search.enabled", default: true)
    let openAISearchModel = reader.string(forKey: "openai.search.model", default: "gpt-4o-mini")
    let responseLanguage = reader.string(forKey: "companion.response.language", default: "English")

    if ttsProvider == .cartesia, cartesiaAPIKey?.isEmpty != false {
      throw AppConfigError.missingCartesiaAPIKey
    }

    return AppConfig(
      deviceToken: deviceToken,
      openAIAPIKey: openAIAPIKey,
      openAIRealtimeModel: openAIRealtimeModel,
      openAIRealtimeVoice: openAIRealtimeVoice,
      ttsProvider: ttsProvider,
      cartesiaAPIKey: cartesiaAPIKey,
      cartesiaVoiceId: cartesiaVoiceId,
      cartesiaModelId: cartesiaModelId,
      companionHost: companionHost,
      webSearchEnabled: webSearchEnabled,
      openAISearchModel: openAISearchModel,
      responseLanguage: responseLanguage
    )
  }
}
