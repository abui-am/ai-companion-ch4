import Foundation
import Logging

/// Leaky-bucket downlink sender: accepts PCM bursts from TTS/Realtime and
/// transmits WS binary frames at real-time rate on a dedicated task so
/// `VoiceSession` stays responsive for uplink and control messages.
actor DownlinkPacer {
    private let outbound: SessionOutboundWriter
    private let speakers: SpeakerRegistry
    private let sampleRate: Int
    private let logger: Logger
    private let maxQueuedFrames: Int

    private var frameQueue: [Data] = []
    private var pacingTask: Task<Void, Never>?
    private var turnActive = false
    private var enqueueFinished = false

    private var spaceWaiters: [CheckedContinuation<Void, Error>] = []

    private static let speakerInitialBurstFrames = 12

    init(
        outbound: SessionOutboundWriter,
        speakers: SpeakerRegistry,
        sampleRate: Int,
        logger: Logger,
        maxQueuedFrames: Int = 48
    ) {
        self.outbound = outbound
        self.speakers = speakers
        self.sampleRate = sampleRate
        self.logger = logger
        self.maxQueuedFrames = maxQueuedFrames
    }

    func beginTurn() {
        turnActive = true
        enqueueFinished = false
        frameQueue.removeAll(keepingCapacity: true)
        pacingTask?.cancel()
        pacingTask = Task { [weak self] in
            guard let self else { return }
            let burst = await speakers.hasSpeakers ? Self.speakerInitialBurstFrames : 0
            await self.runPacingLoop(speakerBurstRemaining: burst)
        }
    }

    func enqueue(pcm: Data) async throws -> Int {
        guard turnActive else { return 0 }
        let chunks = try OpusCodec.encodeFromPCM(pcm, sampleRate: sampleRate)
        for chunk in chunks {
            try Task.checkCancellation()
            while frameQueue.count >= maxQueuedFrames {
                try await waitForQueueSpace()
            }
            frameQueue.append(chunk)
        }
        return chunks.count
    }

    /// Waits until all enqueued frames have been sent at real-time pace.
    func endTurn() async {
        guard turnActive else { return }
        enqueueFinished = true
        if let pacingTask {
            await pacingTask.value
        }
        turnActive = false
        pacingTask = nil
    }

    func cancel() {
        turnActive = false
        enqueueFinished = true
        frameQueue.removeAll()
        pacingTask?.cancel()
        pacingTask = nil
        let space = spaceWaiters
        spaceWaiters.removeAll(keepingCapacity: true)
        for waiter in space {
            waiter.resume(throwing: CancellationError())
        }
    }

    // MARK: - Pacing loop

    private func runPacingLoop(speakerBurstRemaining initialBurst: Int) async {
        var nextSend = ContinuousClock.now
        var speakerBurstRemaining = initialBurst

        while turnActive {
            if frameQueue.isEmpty {
                if enqueueFinished {
                    return
                }
                try? await Task.sleep(for: .milliseconds(2))
                continue
            }

            let frame = frameQueue.removeFirst()
            resumeSpaceWaiters()

            if speakerBurstRemaining > 0 {
                speakerBurstRemaining -= 1
            } else {
                let now = ContinuousClock.now
                if now < nextSend {
                    try? await Task.sleep(until: nextSend, clock: .continuous)
                }
            }

            guard turnActive else { return }

            do {
                try await outbound.writeBinary(frame)
                await speakers.broadcastBinary(frame)
            } catch {
                logger.warning("downlink pacer send failed", metadata: ["error": "\(error)"])
            }

            let frameMs = max(1, (frame.count / 2) * 1000 / sampleRate)
            nextSend += .milliseconds(frameMs)
            let nowAfterSend = ContinuousClock.now
            if nextSend < nowAfterSend {
                nextSend = nowAfterSend
            }
        }
    }

    private func waitForQueueSpace() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            spaceWaiters.append(continuation)
        }
    }

    private func resumeSpaceWaiters() {
        let waiters = spaceWaiters
        spaceWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }
}
