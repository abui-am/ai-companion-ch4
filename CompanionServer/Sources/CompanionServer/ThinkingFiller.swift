import Foundation

/// Short spoken phrases while the pipeline is working (web search, LLM latency).
enum ThinkingFiller {
    enum Kind: Sendable {
        case processing
        case webSearch
    }

    private static let processingPhrases = [
        "Hmm, one sec...",
        "Let me think...",
        "Just a moment...",
    ]

    private static let webSearchPhrases = [
        "Let me look that up...",
        "One sec, checking online...",
        "Hmm, let me see what's out there...",
    ]

    static func fallbackPhrase(for kind: Kind) -> String {
        switch kind {
        case .processing:
            processingPhrases.randomElement() ?? processingPhrases[0]
        case .webSearch:
            webSearchPhrases.randomElement() ?? webSearchPhrases[0]
        }
    }

    /// Contextual phrase from the user's question (no extra LLM call).
    static func phrase(for kind: Kind, userQuestion: String, searchQuery: String) -> String {
        let question = userQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let search = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if question.isEmpty, search.isEmpty {
            return fallbackPhrase(for: kind)
        }
        return heuristicPhrase(for: kind, userQuestion: question, searchQuery: search)
    }

    /// Fast local fallback when the LLM filler call is unavailable.
    static func heuristicPhrase(for kind: Kind, userQuestion: String, searchQuery: String) -> String {
        let topic = speakableSnippet(from: searchQuery.isEmpty ? userQuestion : searchQuery)
        guard !topic.isEmpty else { return fallbackPhrase(for: kind) }

        switch kind {
        case .webSearch:
            let openers = ["Let me look up", "Let me check on", "One sec, I'll check"]
            return "\(openers.randomElement() ?? openers[0]) \(topic)..."
        case .processing:
            let openers = ["Hmm,", "Okay,", "Right,"]
            return "\(openers.randomElement() ?? openers[0]) about \(topic) — one sec..."
        }
    }

    private static func speakableSnippet(from text: String, maxWords: Int = 8) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("?") || t.hasSuffix(".") { t.removeLast() }

        let lowered = t.lowercased()
        let prefixes = [
            "can you tell me ",
            "could you tell me ",
            "tell me about ",
            "tell me ",
            "what's the ",
            "what is the ",
            "what's ",
            "what is ",
            "who won the ",
            "who won ",
            "who is the ",
            "who is ",
            "who's the ",
            "who's ",
            "when did the ",
            "when did ",
            "when was the ",
            "when was ",
            "how much is ",
            "how much ",
            "how many ",
            "where is the ",
            "where is ",
            "is there ",
        ]
        for prefix in prefixes {
            if lowered.hasPrefix(prefix) {
                t = String(t.dropFirst(prefix.count))
                break
            }
        }

        let words = t.split(separator: " ").prefix(maxWords)
        return words.joined(separator: " ")
    }
}
