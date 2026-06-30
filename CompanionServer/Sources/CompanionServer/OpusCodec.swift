import Foundation

/// Placeholder Opus<->PCM bridging. Real Opus encode/decode requires linking
/// libopus (e.g. via a SwiftPM Opus binding) — not wired up yet. For now this
/// wraps/unwraps raw 16-bit PCM in a minimal WAV container so the rest of the
/// pipeline (ASR/TTS HTTP calls, which accept WAV/MP3) can be exercised end to
/// end with TestClient before the real codec is dropped in.
enum OpusCodec {
    static func decodeToWAV(_ frames: [Data], sampleRate: Int) throws -> Data {
        let pcm = frames.reduce(into: Data()) { $0.append($1) }
        return wrapWAV(pcm: pcm, sampleRate: sampleRate)
    }

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

    private static func wrapWAV(pcm: Data, sampleRate: Int) -> Data {
        var header = Data()
        let byteRate = sampleRate * 2
        let blockAlign = 2
        let dataSize = UInt32(pcm.count)
        let chunkSize = 36 + dataSize

        header.append(contentsOf: "RIFF".utf8)
        header.append(littleEndian: chunkSize)
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(littleEndian: UInt32(16))
        header.append(littleEndian: UInt16(1)) // PCM
        header.append(littleEndian: UInt16(1)) // mono
        header.append(littleEndian: UInt32(sampleRate))
        header.append(littleEndian: UInt32(byteRate))
        header.append(littleEndian: UInt16(blockAlign))
        header.append(littleEndian: UInt16(16)) // bits per sample
        header.append(contentsOf: "data".utf8)
        header.append(littleEndian: dataSize)
        header.append(pcm)
        return header
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func append(littleEndian value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
