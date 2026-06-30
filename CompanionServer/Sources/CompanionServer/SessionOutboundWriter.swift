import Foundation
import HummingbirdWebSocket
import NIOCore

protocol SessionOutboundWriter: Sendable {
    func writeText(_ text: String) async throws
    func writeBinary(_ data: Data) async throws
}

struct WebSocketSessionOutboundWriter: SessionOutboundWriter {
    let base: WebSocketOutboundWriter

    func writeText(_ text: String) async throws {
        try await base.write(.text(text))
    }

    func writeBinary(_ data: Data) async throws {
        try await base.write(.binary(ByteBuffer(bytes: data)))
    }
}
