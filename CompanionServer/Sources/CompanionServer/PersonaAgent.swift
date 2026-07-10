import Foundation
import Logging

/// Sub-agent that switches the active character persona by voice command
/// ("change persona to grumpy", "be the pirate", "jadi minion", "stop the
/// act"). Changes go through PersonaStore, which persists the choice and
/// pushes the new instruction into every attached realtime session — the new
/// character takes over from the robot's next spoken turn.
struct PersonaAgent: SubAgent, Sendable {
    let name = "persona"

    private let personas: PersonaStore
    private let logger: Logger

    init(personas: PersonaStore, logger: Logger) {
        self.personas = personas
        self.logger = logger
    }

    var toolDefinition: [String: Any] {
        [
            "type": "function",
            "name": name,
            "description": """
            Switch which character persona this robot plays, list the available characters, \
            or clear the persona back to the default personality.

            **Required** whenever the user asks to change/switch the persona, character, or \
            personality by name, or to become some character: "change persona to grumpy", \
            "switch to the pirate", "be the minion", "jadi vampire", "ganti karakter ke chef", \
            "talk like the wizard again". Also for "what characters do you have?" (action=list) \
            and "stop the act" / "back to normal" / "clear the persona" (action=clear).

            Speech-to-text often mangles "persona" (persoso, persina, personal) — if the user \
            says something like "change persoso to X", treat it as a persona switch to X.

            The switch takes effect on your NEXT reply, so finish the current turn in your \
            current voice with a short in-character handover ("The captain sails off — a new \
            face takes the helm!"). Never announce tool mechanics.
            """,
            "parameters": [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": ["set", "clear", "list"],
                        "description": "set = activate the named persona; clear = back to default personality; list = names of available personas.",
                    ] as [String: Any],
                    "name": [
                        "type": "string",
                        "description": "Persona to activate (required for action=set). Use the name the user said; close matches are resolved automatically.",
                    ] as [String: Any],
                ],
                "required": ["action"],
            ] as [String: Any],
        ]
    }

    func execute(argumentsJSON: String) async -> String {
        guard let args = SubAgentJSON.parseArguments(argumentsJSON) else {
            return SubAgentJSON.encodeError("invalid arguments JSON")
        }
        guard let action = args["action"] as? String else {
            return SubAgentJSON.encodeError("missing action")
        }

        switch action {
        case "list":
            let available = await personas.available()
            let active = await personas.activeName()
            logger.info("persona tool list", metadata: ["count": .string("\(available.count)")])
            return SubAgentJSON.encode([
                "summary": available.isEmpty
                    ? "No personas installed."
                    : "Available personas: \(available.joined(separator: ", ")). Active: \(active ?? "none (default personality)").",
            ])

        case "clear":
            do {
                try await personas.setActive(nil)
            } catch {
                logger.warning("persona tool clear failed", metadata: ["error": .string("\(error)")])
                return SubAgentJSON.encodeError("could not clear persona: \(error)")
            }
            logger.info("persona tool cleared")
            return SubAgentJSON.encode([
                "summary": "Persona cleared — the default personality returns from the next reply.",
            ])

        case "set":
            guard let requested = args["name"] as? String, !requested.isEmpty else {
                return SubAgentJSON.encodeError("missing name for action=set")
            }
            let available = await personas.available()
            guard let resolved = Self.resolve(requested, in: available) else {
                return SubAgentJSON.encodeError(
                    "unknown persona \"\(requested)\" — available: \(available.joined(separator: ", "))"
                )
            }
            do {
                try await personas.setActive(resolved)
            } catch {
                logger.warning(
                    "persona tool set failed",
                    metadata: ["persona": .string(resolved), "error": .string("\(error)")]
                )
                return SubAgentJSON.encodeError("could not activate \(resolved): \(error)")
            }
            logger.info("persona tool set", metadata: ["persona": .string(resolved)])
            return SubAgentJSON.encode([
                "summary": "Persona switched to \(resolved) — the new character takes over from your next reply. Close this turn with a short in-character handover.",
            ])

        default:
            return SubAgentJSON.encodeError("unknown action: \(action)")
        }
    }

    /// Case-insensitive match tolerant of STT noise: exact name first, then
    /// separator-stripped equality, then unique prefix/substring match
    /// ("grump" → grumpy, "the pirate" → pirate).
    static func resolve(_ requested: String, in available: [String]) -> String? {
        func normalize(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let wanted = normalize(requested)
        guard !wanted.isEmpty else { return nil }

        if let exact = available.first(where: { normalize($0) == wanted }) {
            return exact
        }
        let partial = available.filter {
            normalize($0).hasPrefix(wanted) || wanted.contains(normalize($0))
        }
        return partial.count == 1 ? partial[0] : nil
    }
}
