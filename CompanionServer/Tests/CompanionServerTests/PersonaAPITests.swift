import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import XCTest

@testable import CompanionServer

private struct APIPersonaList: Decodable {
    let active: String?
    let available: [String]
}

private struct APIPersonaDetail: Decodable {
    let name: String
    let content: String
    let active: Bool
}

/// Route-level tests for the persona CRUD API — no database needed; the
/// store is pointed at a per-test temp directory.
final class PersonaAPITests: XCTestCase {
    private let deviceToken = "persona-test-token"
    private var tempDir: URL!
    private var store: PersonaStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("persona-api-tests-\(UUID().uuidString)", isDirectory: true)
        store = PersonaStore(directory: tempDir, logger: Logger(label: "PersonaAPITests"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeApp() -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        PersonaRoutes.register(
            on: router,
            personas: store,
            deviceToken: deviceToken,
            logger: Logger(label: "PersonaAPITests")
        )
        return Application(responder: router.buildResponder())
    }

    private func authHeaders() -> HTTPFields {
        [.authorization: "Bearer \(deviceToken)", .contentType: "application/json"]
    }

    func testListRequiresAuth() async throws {
        let app = makeApp()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/personas", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            try await client.execute(
                uri: "/api/v1/personas",
                method: .get,
                headers: [.authorization: "Bearer wrong-token"]
            ) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testCreateReadListDeleteRoundTrip() async throws {
        let app = makeApp()
        let headers = authHeaders()
        try await app.test(.router) { client in
            // Create.
            try await client.execute(
                uri: "/api/v1/personas/ninja",
                method: .put,
                headers: headers,
                body: ByteBuffer(string: ##"{"content":"# Ninja\nBe silent."}"##)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let detail = try JSONDecoder().decode(APIPersonaDetail.self, from: response.body)
                XCTAssertEqual(detail.name, "ninja")
                XCTAssertFalse(detail.active)
            }

            // Read back.
            try await client.execute(
                uri: "/api/v1/personas/ninja", method: .get, headers: headers
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let detail = try JSONDecoder().decode(APIPersonaDetail.self, from: response.body)
                XCTAssertEqual(detail.content, "# Ninja\nBe silent.")
            }

            // Shows up in the list.
            try await client.execute(
                uri: "/api/v1/personas", method: .get, headers: headers
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let list = try JSONDecoder().decode(APIPersonaList.self, from: response.body)
                XCTAssertEqual(list.available, ["ninja"])
                XCTAssertNil(list.active)
            }

            // Delete.
            try await client.execute(
                uri: "/api/v1/personas/ninja", method: .delete, headers: headers
            ) { response in
                XCTAssertEqual(response.status, .noContent)
            }
            try await client.execute(
                uri: "/api/v1/personas/ninja", method: .get, headers: headers
            ) { response in
                XCTAssertEqual(response.status, .notFound)
            }
        }
    }

    func testActivateAndClearViaBaseRoute() async throws {
        try await store.save(name: "pirate", content: "# Pirate\nArrr.")
        let app = makeApp()
        let headers = authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/personas",
                method: .put,
                headers: headers,
                body: ByteBuffer(string: #"{"name":"pirate"}"#)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let list = try JSONDecoder().decode(APIPersonaList.self, from: response.body)
                XCTAssertEqual(list.active, "pirate")
            }

            // Detail reports active=true while activated.
            try await client.execute(
                uri: "/api/v1/personas/pirate", method: .get, headers: headers
            ) { response in
                let detail = try JSONDecoder().decode(APIPersonaDetail.self, from: response.body)
                XCTAssertTrue(detail.active)
            }

            try await client.execute(
                uri: "/api/v1/personas",
                method: .put,
                headers: headers,
                body: ByteBuffer(string: #"{"name":null}"#)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let list = try JSONDecoder().decode(APIPersonaList.self, from: response.body)
                XCTAssertNil(list.active)
            }
        }
    }

    func testActivateUnknownPersonaReturnsBadRequest() async throws {
        let app = makeApp()
        let headers = authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/personas",
                method: .put,
                headers: headers,
                body: ByteBuffer(string: #"{"name":"ghost"}"#)
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
    }

    func testSaveRejectsBadNameAndEmptyContent() async throws {
        let app = makeApp()
        let headers = authHeaders()
        try await app.test(.router) { client in
            // Invalid characters in the name (dots blocked → no traversal).
            try await client.execute(
                uri: "/api/v1/personas/bad.name",
                method: .put,
                headers: headers,
                body: ByteBuffer(string: #"{"content":"x"}"#)
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
            }

            // Whitespace-only content.
            try await client.execute(
                uri: "/api/v1/personas/ok-name",
                method: .put,
                headers: headers,
                body: ByteBuffer(string: #"{"content":"   \n "}"#)
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
    }

    func testDeleteActivePersonaClearsActive() async throws {
        try await store.save(name: "pirate", content: "# Pirate\nArrr.")
        try await store.setActive("pirate")
        let app = makeApp()
        let headers = authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/personas/pirate", method: .delete, headers: headers
            ) { response in
                XCTAssertEqual(response.status, .noContent)
            }
            try await client.execute(
                uri: "/api/v1/personas", method: .get, headers: headers
            ) { response in
                let list = try JSONDecoder().decode(APIPersonaList.self, from: response.body)
                XCTAssertNil(list.active)
                XCTAssertTrue(list.available.isEmpty)
            }
        }
    }

    func testDeleteUnknownReturnsNotFound() async throws {
        let app = makeApp()
        let headers = authHeaders()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/personas/ghost", method: .delete, headers: headers
            ) { response in
                XCTAssertEqual(response.status, .notFound)
            }
        }
    }
}
