import Foundation
import Logging

/// Fan-out target for TTS audio destined for ESP speaker clients on `/speaker`.
actor SpeakerRegistry {
    private var speakers: [UUID: SessionOutboundWriter] = [:]
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func register(id: UUID, outbound: SessionOutboundWriter) {
        speakers[id] = outbound
        logger.info("speaker registered", metadata: ["id": .string(id.uuidString), "count": "\(speakers.count)"])
    }

    func unregister(id: UUID) {
        speakers.removeValue(forKey: id)
        logger.info("speaker unregistered", metadata: ["id": .string(id.uuidString), "count": "\(speakers.count)"])
    }

    func broadcastText(_ text: String) async {
        guard !speakers.isEmpty else { return }
        logger.debug("speaker broadcast text", metadata: ["json": .string(text), "count": "\(speakers.count)"])
        for (_, outbound) in speakers {
            try? await outbound.writeText(text)
        }
    }

    func broadcastBinary(_ data: Data) async {
        guard !speakers.isEmpty else { return }
        for (_, outbound) in speakers {
            try? await outbound.writeBinary(data)
        }
    }

    var hasSpeakers: Bool {
        !speakers.isEmpty
    }
}
