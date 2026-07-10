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

struct PersonaDetailResponse: ResponseEncodable, Sendable {
    let name: String
    let content: String
    let active: Bool
}

/// Body for creating/updating a persona file: the full markdown instruction.
struct PutPersonaContentRequest: Decodable, Sendable {
    let content: String
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

        group.get("/{name}") { request, context in
            try requireDeviceToken(from: request, expected: deviceToken)
            let name = try context.parameters.require("name")
            guard let content = await personas.instruction(for: name) else {
                throw HTTPError(.notFound, message: PersonaError.unknownPersona(name).description)
            }
            logger.debug("GET /api/v1/personas/{name}", metadata: ["persona": .string(name)])
            return PersonaDetailResponse(
                name: name,
                content: content,
                active: await personas.activeName() == name
            )
        }

        group.put("/{name}") { request, context in
            try requireDeviceToken(from: request, expected: deviceToken)
            let name = try context.parameters.require("name")
            let body: PutPersonaContentRequest
            do {
                body = try await request.decode(as: PutPersonaContentRequest.self, context: context)
            } catch {
                throw HTTPError(.badRequest, message: "Invalid persona body: \(error)")
            }
            do {
                try await personas.save(name: name, content: body.content)
            } catch let error as PersonaError {
                throw HTTPError(.badRequest, message: error.description)
            }
            logger.info("PUT /api/v1/personas/{name}", metadata: ["persona": .string(name)])
            return PersonaDetailResponse(
                name: name,
                content: body.content,
                active: await personas.activeName() == name
            )
        }

        group.delete("/{name}") { request, context -> HTTPResponse.Status in
            try requireDeviceToken(from: request, expected: deviceToken)
            let name = try context.parameters.require("name")
            do {
                try await personas.delete(name: name)
            } catch let error as PersonaError {
                throw HTTPError(.notFound, message: error.description)
            }
            logger.info("DELETE /api/v1/personas/{name}", metadata: ["persona": .string(name)])
            return .noContent
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
