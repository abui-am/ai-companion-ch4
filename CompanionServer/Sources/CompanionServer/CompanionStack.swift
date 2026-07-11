import Foundation

/// Canonical version identifiers for the stable showcase stack.
/// See `docs/STABLE_V1.md` for the full specification.
enum CompanionStack {
    /// Human-facing server release version, surfaced by `GET /version`.
    static let serverVersion = "0.1.2-beta"

    /// Wire protocol version: JSON control events + raw PCM binary frames.
    static let protocolVersion = "v1"

    /// Server pipeline profile (OpenAI Realtime only).
    static let pipelineProfile = "v1"
}
