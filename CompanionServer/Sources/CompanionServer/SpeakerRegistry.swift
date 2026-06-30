import Foundation
import HummingbirdWebSocket
import Logging
import NIOCore

/// Fan-out target for TTS audio destined for ESP speaker clients on `/speaker`.
actor SpeakerRegistry {
    private var speakers: [UUID: WebSocketOutboundWriter] = [:]
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func register(id: UUID, outbound: WebSocketOutboundWriter) {
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
            try? await outbound.write(.text(text))
        }
    }

    func broadcastBinary(_ data: Data) async {
        guard !speakers.isEmpty else { return }
        let buffer = ByteBuffer(bytes: data)
        for (_, outbound) in speakers {
            try? await outbound.write(.binary(buffer))
        }
    }

    var hasSpeakers: Bool {
        !speakers.isEmpty
    }
}
