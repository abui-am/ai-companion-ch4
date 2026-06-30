import Foundation

/// Placeholder Opus<->PCM bridging for the downlink. Real Opus encode requires
/// linking libopus (e.g. via a SwiftPM Opus binding) — not wired up yet. For now
/// this just chunks raw 16-bit PCM into frame-sized pieces so the rest of the
/// downlink pipeline can be exercised end to end with TestClient before the real
/// codec is dropped in.
enum OpusCodec {
    static func encodeFromPCM(_ pcm: Data, sampleRate: Int) throws -> [Data] {
        let frameBytes = sampleRate / 1000 * 60 * 2 // 60ms frames, 16-bit mono
        var frames: [Data] = []
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + frameBytes, pcm.count)
            frames.append(pcm.subdata(in: offset..<end))
            offset = end
        }
        return frames
    }
}
