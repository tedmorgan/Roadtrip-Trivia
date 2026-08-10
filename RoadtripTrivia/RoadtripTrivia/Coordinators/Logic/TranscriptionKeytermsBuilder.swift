import Foundation

/// Builds ASR keyterms for the current trivia question so Grok's
/// `audio.input.transcription.keyterms` bias improves answer recognition
/// (option letters, option text, and the correct answer).
enum TranscriptionKeytermsBuilder {

    /// xAI caps: max 100 terms, each ≤ 50 characters.
    static let maxTerms = 100
    static let maxTermLength = 50

    static func build(
        questionText: String?,
        options: [String]?,
        correctAnswer: String?,
        category: String? = nil
    ) -> [String] {
        var terms: [String] = []
        var seen = Set<String>()

        func append(_ raw: String?) {
            guard let raw else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let clipped = String(trimmed.prefix(maxTermLength))
            let key = clipped.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            terms.append(clipped)
        }

        append(correctAnswer)
        append(category)

        if let options {
            for (index, option) in options.enumerated() where index < 4 {
                let letter = String(Character(UnicodeScalar(65 + index)!)) // A-D
                append(letter)
                append(option)
                append("\(letter): \(option)")
            }
        }

        // Pull capitalized / multi-word phrases from the question stem.
        if let questionText {
            for token in questionText
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter({ $0.count >= 3 })
            {
                append(token)
            }
        }

        if terms.count > maxTerms {
            return Array(terms.prefix(maxTerms))
        }
        return terms
    }
}
