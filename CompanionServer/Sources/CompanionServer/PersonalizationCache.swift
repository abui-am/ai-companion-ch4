import CompanionDatabase
import Foundation
import Logging

/// Short-TTL cache for `ConfigRecord.personalizationData`, avoiding a Postgres round trip on
/// every `memory` tool call — see `MemoryAgent.isPersonalizationEnabled()`. A few seconds of
/// staleness is an acceptable trade-off on a single-user companion device: toggling the setting
/// takes effect within `ttl` seconds rather than the very next tool call.
actor PersonalizationCache {
    private static let defaultTTL: TimeInterval = 5

    private let config: ConfigRepository
    private let ttl: TimeInterval
    private let logger: Logger
    private var cached: (value: Bool, fetchedAt: Date)?

    init(config: ConfigRepository, ttl: TimeInterval = PersonalizationCache.defaultTTL, logger: Logger) {
        self.config = config
        self.ttl = ttl
        self.logger = logger
    }

    func isEnabled() async -> Bool {
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < ttl {
            return cached.value
        }
        do {
            let value = try await config.get().personalizationData
            cached = (value, Date())
            return value
        } catch {
            logger.warning(
                "personalization cache refresh failed — using stale/default value",
                metadata: ["error": "\(error)", "had_cached_value": "\(cached != nil)"]
            )
            return cached?.value ?? false
        }
    }
}
