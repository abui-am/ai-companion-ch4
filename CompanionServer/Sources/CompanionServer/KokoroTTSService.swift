import Foundation
import Kokoro
import Logging

/// Local, on-device TTS via kokoro-swift (Kokoro-82M, MLX backend on Apple Silicon)
/// — an alternative to CartesiaService for side-by-side comparison. Conforms to the
/// same `TTSStreamingService` protocol as Cartesia so VoiceSession is agnostic to
/// which engine is selected.
///
/// Kokoro's `synthesize` call is not incremental like Cartesia's WebSocket stream —
/// each call blocks until that call's full text is rendered. To still get some
/// overlap with the LLM, text is synthesized sentence-by-sentence as complete
/// sentences accumulate in the buffer (instead of waiting for the whole reply),
/// emitting one `.audio` event per sentence rather than one for the entire turn.
///
/// Requires the MLX Metal shader library, which `swift build`/`swift run` cannot
/// produce (see kokoro-swift's README) — run via `xcodebuild` or Xcode, not `swift run`.
actor KokoroTTSService: TTSStreamingService {
    private let weightsDir: URL
    private let voice: String
    private let logger: Logger

    private var pipeline: KPipeline?
    private var bufferedText: [String: String] = [:]
    private var continuations: [String: AsyncStream<TTSStreamEvent>.Continuation] = [:]

    init(weightsDir: URL, voice: String, logger: Logger) {
        self.weightsDir = weightsDir
        self.voice = voice
        self.logger = logger
    }

    func beginTurn(contextId: String) -> AsyncStream<TTSStreamEvent> {
        bufferedText[contextId] = ""
        return AsyncStream { continuation in
            continuations[contextId] = continuation
        }
    }

    func sendTranscriptChunk(_ text: String, contextId: String, isFinal: Bool) async {
        bufferedText[contextId, default: ""] += text

        while let sentence = extractNextSentence(contextId: contextId) {
            let synthesized = await synthesizeAndEmit(sentence, contextId: contextId)
            guard synthesized else { return } // .error event already finished the turn
        }

        guard isFinal else { return }

        let remainder = (bufferedText[contextId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        bufferedText.removeValue(forKey: contextId)
        if !remainder.isEmpty {
            guard await synthesizeAndEmit(remainder, contextId: contextId) else { return }
        }
        finishTurn(contextId: contextId, event: .done)
    }

    func cancelTurn(contextId: String) {
        bufferedText.removeValue(forKey: contextId)
        finishTurn(contextId: contextId, event: nil)
    }

    /// Pulls the first complete sentence (ending in `.`, `!`, or `?`) off the
    /// front of the buffer for `contextId`, if one exists yet.
    private func extractNextSentence(contextId: String) -> String? {
        guard let buffer = bufferedText[contextId],
              let terminatorIndex = buffer.firstIndex(where: { ".!?".contains($0) })
        else { return nil }

        let sentenceEnd = buffer.index(after: terminatorIndex)
        let sentence = String(buffer[..<sentenceEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        bufferedText[contextId] = String(buffer[sentenceEnd...])
        return sentence.isEmpty ? nil : sentence
    }

    /// Synthesizes one chunk of text and emits it as an `.audio` event. Returns
    /// `false` (after emitting `.error` and finishing the turn) on failure.
    @discardableResult
    private func synthesizeAndEmit(_ text: String, contextId: String) async -> Bool {
        do {
            let pipeline = try loadPipelineIfNeeded()
            // KPipeline.synthesize is a synchronous, CPU/GPU-bound call (no async
            // entry point); turns are processed sequentially per session, so running
            // it directly on this actor is acceptable rather than fighting Swift 6
            // strict concurrency over a non-Sendable KPipeline capture.
            let result = try pipeline.synthesize(text: text, voice: voice)
            let pcm = Self.pcmData(from: result.audio, sampleRate: result.sampleRate)
            finishTurn(contextId: contextId, event: .audio(pcm))
            return true
        } catch {
            logger.error("kokoro synthesis failed", metadata: ["context_id": .string(contextId), "error": "\(error)"])
            finishTurn(contextId: contextId, event: .error("\(error)"))
            return false
        }
    }

    private func loadPipelineIfNeeded() throws -> KPipeline {
        if let pipeline { return pipeline }
        let configURL = weightsDir.appendingPathComponent("config.json")
        let weightsURL = weightsDir.appendingPathComponent("kokoro-v1_0.safetensors")
        let voicesDir = weightsDir.appendingPathComponent("voices", isDirectory: true)
        logger.info("kokoro loading model", metadata: ["weights_dir": .string(weightsDir.path)])
        let model = try KModel(configURL: configURL, weightsURL: weightsURL)
        let voices = VoiceLoader(baseDirectory: voicesDir, enableDownload: true)
        let loaded = KPipeline(model: model, voices: voices)
        pipeline = loaded
        return loaded
    }

    private func finishTurn(contextId: String, event: TTSStreamEvent?) {
        guard let continuation = continuations[contextId] else { return }
        if let event {
            continuation.yield(event)
        }
        if event == nil || isTerminal(event) {
            continuation.finish()
            continuations.removeValue(forKey: contextId)
        }
    }

    private func isTerminal(_ event: TTSStreamEvent?) -> Bool {
        switch event {
        case .done, .error: true
        default: false
        }
    }

    /// Strips the 44-byte WAV header AudioWriter.wavData produces, reusing its
    /// exact Float -> clamped Int16LE conversion to match the PCM format the rest
    /// of the downlink pipeline expects. Wrapped in `Data(...)` because
    /// `Data.dropFirst` keeps the original buffer's index range (startIndex 44,
    /// not 0) — passing that slice straight to `subdata(in: 0..<n)` downstream
    /// traps instead of throwing.
    private static func pcmData(from samples: [Float], sampleRate: Int) -> Data {
        Data(AudioWriter.wavData(samples: samples, sampleRate: sampleRate).dropFirst(44))
    }
}
