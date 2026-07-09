import Foundation
import Hummingbird
import Logging

struct PersonaResponse: ResponseEncodable, Sendable {
    let active: String?
    let available: [String]
}

/// `{"name": "minion"}` activates; `{"name": null}` (or omitting it) clears.
struct PutPersonaRequest: Decodable, Sendable {
    let name: String?
}

enum PersonaRoutes {
    static func register(
        on router: Router<BasicRequestContext>,
        personas: PersonaStore,
        deviceToken: String,
        logger: Logger
    ) {
        let group = router.group("/api/v1/personas")

        group.get { request, _ in
            try requireDeviceToken(from: request, expected: deviceToken)
            logger.debug("GET /api/v1/personas")
            return PersonaResponse(
                active: await personas.activeName(),
                available: await personas.available()
            )
        }

        group.put { request, context in
            try requireDeviceToken(from: request, expected: deviceToken)
            let body: PutPersonaRequest
            do {
                body = try await request.decode(as: PutPersonaRequest.self, context: context)
            } catch {
                throw HTTPError(.badRequest, message: "Invalid persona body: \(error)")
            }
            do {
                try await personas.setActive(body.name)
            } catch let error as PersonaError {
                throw HTTPError(.badRequest, message: error.description)
            }
            logger.info("PUT /api/v1/personas", metadata: ["persona": .string(body.name ?? "none")])
            return PersonaResponse(
                active: await personas.activeName(),
                available: await personas.available()
            )
        }
    }

    private static func requireDeviceToken(from request: Request, expected: String) throws {
        guard let header = request.headers[.authorization] else {
            throw HTTPError(.unauthorized, message: "Missing Authorization header")
        }
        guard let token = header.split(separator: " ").last.map(String.init), token == expected else {
            throw HTTPError(.unauthorized, message: "Invalid bearer token")
        }
    }
}
