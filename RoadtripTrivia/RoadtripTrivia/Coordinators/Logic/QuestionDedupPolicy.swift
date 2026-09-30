import Foundation

/// Near-duplicate detection for trivia prompts so paraphrases of the same
/// fact ("largest hot desert in the world" vs "largest hot desert on Earth")
/// are treated as the same banned topic.
public enum QuestionDedupPolicy {

    private static let stopWords: Set<String> = [
        "a", "an", "the", "of", "in", "on", "to", "for", "and", "or", "is", "are",
        "was", "were", "what", "which", "who", "where", "when", "how", "does",
        "do", "did", "you", "find", "these", "those", "this", "that", "with",
        "from", "by", "as", "at", "it", "its", "be", "been", "being", "than",
        "their", "there", "would", "could", "should", "your", "our", "his",
        "her", "not", "also", "only", "just", "about", "into", "over", "under",
        "among", "between", "known", "called", "name", "term", "following",
    ]

    private static let synonyms: [String: String] = [
        "earth": "world",
        "planet": "world",
        "biggest": "largest",
        "greatest": "largest",
        "whats": "what",
    ]

    /// Compact topic key for the batch prompt, e.g. "largest hot desert".
    public static func topicKey(from raw: String) -> String {
        contentTokens(from: raw).prefix(6).joined(separator: " ")
    }

    /// History lines plus derived topic keys so the generator sees paraphrases.
    public static func historyWithTopicKeys(_ history: [String]) -> [String] {
        var out = history
        var seen = Set(history.map { $0.lowercased() })
        for line in history {
            let key = topicKey(from: line)
            guard key.split(separator: " ").count >= 2 else { continue }
            let labeled = "TOPIC: \(key)"
            if seen.insert(labeled.lowercased()).inserted {
                out.append(labeled)
            }
        }
        return out
    }

    public static func isNearDuplicate(questionText: String, history: [String]) -> Bool {
        let incoming = contentTokens(from: questionText)
        guard incoming.count >= 2 else { return false }
        let incomingSet = Set(incoming)
        let incomingGrams = ngrams(incoming, n: 3)
        let incomingPairs = ngrams(incoming, n: 2)

        for prior in history {
            let priorTokens = contentTokens(from: prior)
            guard priorTokens.count >= 2 else { continue }
            let priorSet = Set(priorTokens)
            let intersection = incomingSet.intersection(priorSet)
            let union = incomingSet.union(priorSet)
            let jaccard = union.isEmpty ? 0 : Double(intersection.count) / Double(union.count)
            if jaccard >= 0.5 && intersection.count >= 3 {
                return true
            }
            if !incomingGrams.isEmpty && !incomingGrams.isDisjoint(with: ngrams(priorTokens, n: 3)) {
                return true
            }
            let sharedPairs = incomingPairs.intersection(ngrams(priorTokens, n: 2))
            if sharedPairs.contains(where: { $0.hasPrefix("largest ") || $0.hasPrefix("biggest ") }) {
                return true
            }
        }
        return false
    }

    /// Drop near-duplicates, but never shrink a round below `keepAtLeast`.
    public static func filterQuestions<T>(
        _ questions: [T],
        text: (T) -> String,
        history: [String],
        keepAtLeast: Int
    ) -> [T] {
        var kept: [T] = []
        var dropped: [T] = []
        var seen = history
        for question in questions {
            let questionText = text(question)
            if isNearDuplicate(questionText: questionText, history: seen) {
                dropped.append(question)
            } else {
                kept.append(question)
                seen.append(questionText)
            }
        }
        if kept.count >= keepAtLeast { return kept }
        for question in dropped {
            if kept.count >= keepAtLeast { break }
            kept.append(question)
        }
        return kept
    }

    // MARK: - Tokenization

    static func contentTokens(from raw: String) -> [String] {
        let topic = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? raw
        let folded = topic
            .lowercased()
            .replacingOccurrences(of: "'s", with: "")
            .replacingOccurrences(of: "’s", with: "")
        let scalars = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        let words = String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .map { synonyms[String($0)] ?? String($0) }
            .filter { $0.count >= 3 && !stopWords.contains($0) }
        return words
    }

    private static func ngrams(_ tokens: [String], n: Int) -> Set<String> {
        guard tokens.count >= n else { return [] }
        var grams: Set<String> = []
        for i in 0...(tokens.count - n) {
            grams.insert(tokens[i..<(i + n)].joined(separator: " "))
        }
        return grams
    }
}
