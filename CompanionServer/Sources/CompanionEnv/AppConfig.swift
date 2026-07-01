import Configuration
import Foundation
import SystemPackage

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
      "CARTESIA_API_KEY env var not set"
    }
  }
}

public struct AppConfig: Sendable {
  public let deviceToken: String
  public let openAIAPIKey: String
  public let cartesiaAPIKey: String
  public let cartesiaVoiceId: String
  public let cartesiaModelId: String
  public let companionHost: String
  /// "cartesia" (default, cloud streaming) or "kokoro" (local on-device MLX TTS,
  /// requires running via xcodebuild — see KokoroTTSService.swift).
  public let ttsProvider: String
  public let kokoroWeightsDir: String
  public let kokoroVoice: String
  /// When true, VoiceSession bypasses the STT→LLM→TTS pipeline and uses the
  /// OpenAI Realtime API for a single-roundtrip speech-in/speech-out flow.
  public let openAIRealtimeEnabled: Bool
  public let openAIRealtimeModel: String
  public let openAIRealtimeVoice: String

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
    guard let cartesiaAPIKey = reader.string(forKey: "cartesia.api.key", isSecret: true), !cartesiaAPIKey.isEmpty else {
      throw AppConfigError.missingCartesiaAPIKey
    }
    let cartesiaVoiceId = reader.string(forKey: "cartesia.voice.id", default: "156fb8d2-335b-4950-9cb3-a2d33befec77")
    let cartesiaModelId = reader.string(forKey: "cartesia.model.id", default: "sonic-2")
    let companionHost = reader.string(forKey: "companion.host", default: "ws://127.0.0.1:8080/ws")
    let ttsProvider = reader.string(forKey: "tts.provider", default: "cartesia")
    let kokoroWeightsDir = PackagePaths.resolveRelativeToPackageRoot(
      reader.string(forKey: "kokoro.weights.dir", default: ".kokoro-models/MLX_GPU")
    )
    let kokoroVoice = reader.string(forKey: "kokoro.voice", default: "af_heart")
    let openAIRealtimeEnabled = reader.string(forKey: "openai.use.realtime", default: "false").lowercased() == "true"
    let openAIRealtimeModel = reader.string(forKey: "openai.realtime.model", default: "gpt-4o-mini-realtime-preview")
    let openAIRealtimeVoice = reader.string(forKey: "openai.realtime.voice", default: "verse")

    return AppConfig(
      deviceToken: deviceToken,
      openAIAPIKey: openAIAPIKey,
      cartesiaAPIKey: cartesiaAPIKey,
      cartesiaVoiceId: cartesiaVoiceId,
      cartesiaModelId: cartesiaModelId,
      companionHost: companionHost,
      ttsProvider: ttsProvider,
      kokoroWeightsDir: kokoroWeightsDir,
      kokoroVoice: kokoroVoice,
      openAIRealtimeEnabled: openAIRealtimeEnabled,
      openAIRealtimeModel: openAIRealtimeModel,
      openAIRealtimeVoice: openAIRealtimeVoice
    )
  }
}
