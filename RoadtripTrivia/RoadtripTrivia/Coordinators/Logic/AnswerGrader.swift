import Foundation

/// Pure, dependency-free grader that decides whether a player's spoken
/// answer matches the question's correct answer.
///
/// Extracted from `RealtimeGameCoordinator` so it can be unit-tested
/// without bringing up the WebSocket session, audio service, or any
/// other coordinator dependency. The coordinator delegates here via
/// `appGradedCorrectness(for:)`.
///
/// Behavior must remain identical to the previous inline implementation
/// — these tests are the regression contract for it.
enum AnswerGrader {

    /// Returns `true` if `playerAnswer` is judged correct against
    /// `correctAnswer` (with optional `options` for MC matching).
    ///
    /// - Parameters:
    ///   - playerAnswer: Raw player answer text (transcribed speech).
    ///   - correctAnswer: Correct answer string. May be a letter ("C"),
    ///     a labeled MC option ("C: Rugby"), or a free-response answer.
    ///   - options: Full MC option strings ("A: ...", "B: ...", etc.),
    ///     used so the player can give either the letter or the option text.
    ///   - playerQuestionIndex / currentQuestionIndex: Used as a guard.
    ///     If the report is for a stale question, we fall through to
    ///     `fallbackIsCorrect` rather than risk misgrading.
    ///   - playerRoundNumber / currentRoundNumber: Same guard for round.
    ///   - fallbackIsCorrect: AI's own `isCorrect` value, used only when
    ///     we lack the data to grade ourselves.
    static func isCorrect(
        playerAnswer: String?,
        correctAnswer: String?,
        options: [String]?,
        playerQuestionIndex: Int,
        currentQuestionIndex: Int,
        playerRoundNumber: Int?,
        currentRoundNumber: Int,
        fallbackIsCorrect: Bool
    ) -> Bool {
        // Stale-question / cross-round guard. If the AI is reporting a
        // score whose context doesn't match the active question, we must
        // not grade with the active question's answer key.
        guard playerQuestionIndex == currentQuestionIndex,
              playerRoundNumber == nil || playerRoundNumber == currentRoundNumber else {
            return fallbackIsCorrect
        }

        // Need both player answer and correct answer to grade ourselves.
        guard let trimmedCorrect = correctAnswer?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedCorrect.isEmpty,
              let trimmedPlayer = playerAnswer?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedPlayer.isEmpty else {
            return fallbackIsCorrect
        }

        let player = normalizedToken(trimmedPlayer)
        let correct = normalizedToken(trimmedCorrect)

        // Direct normalized match.
        if player == correct {
            return true
        }

        // Spoken-letter match: "the answer is bee" -> "b", and correct
        // happens to also normalize to a single letter.
        if let playerLetter = answerLetter(from: player),
           let correctLetter = answerLetter(from: correct),
           playerLetter == correctLetter {
            return true
        }

        // Player gave option text, correct is just a letter (or vice
        // versa) — look the letter up in the options list.
        if let options = options, let correctLetter = correct.first {
            let correctPrefix = "\(correctLetter):"
            if let optionText = options.first(where: {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
                    .hasPrefix(correctPrefix.uppercased())
            }) {
                let optionWithoutLetter = optionText
                    .replacingOccurrences(of: #"^[A-Da-d]\s*[:.)-]\s*"#, with: "", options: [.regularExpression])
                let normalizedOption = normalizedToken(optionWithoutLetter)
                if player == normalizedOption
                    || normalizedOption.contains(player)
                    || player.contains(normalizedOption) {
                    return true
                }
            }
        }

        // Free-response tolerance for speech artifacts. Only when both
        // sides have at least 4 chars so we don't false-accept short
        // unrelated tokens.
        if correct.count >= 4 && (player.contains(correct) || correct.contains(player)) {
            return true
        }

        return false
    }

    /// Resolves the stored correct answer into the FULL spoken answer the
    /// host should say out loud — never a bare letter.
    ///
    /// The batch stores `correctAnswer` as a letter ("B") while the options
    /// carry the text ("B: Oslo"). Reading "the answer was B" is useless to a
    /// player who can't see the screen (2026-07-21 drive test: "host should
    /// state the full correct answer not just the letter"). This maps the
    /// letter back to its option text so the verdict line and the tool result
    /// both carry a human answer.
    ///
    /// - "B" + ["A: Berlin", "B: Oslo"]  → "Oslo"
    /// - "B: Oslo"                        → "Oslo"
    /// - "Oslo" (free response, no opts)  → "Oslo"
    /// - unknown / empty                  → "unknown"
    static func spokenCorrectAnswer(correctAnswer: String?, options: [String]?) -> String {
        let trimmed = (correctAnswer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }

        // Strip any leading "B:" / "B)" / "B." / "B-" label from the stored answer.
        let stripped = trimmed
            .replacingOccurrences(of: #"^[A-Da-d]\s*[:.)-]\s*"#, with: "", options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // If stripping removed a real label ("B: Oslo" → "Oslo"), we already
        // have the text.
        if !stripped.isEmpty && stripped.count != trimmed.count {
            return stripped
        }

        // Bare single-letter answer — look the text up in the options list.
        if trimmed.count == 1,
           let letter = trimmed.first,
           let options = options {
            let prefix = "\(letter):".uppercased()
            if let opt = options.first(where: {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix(prefix)
            }) {
                let text = opt
                    .replacingOccurrences(of: #"^[A-Da-d]\s*[:.)-]\s*"#, with: "", options: [.regularExpression])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }

        // Already plain text (free response) or no matching option — return as-is.
        return stripped.isEmpty ? trimmed : stripped
    }

    /// Lowercase + collapse non-alphanumerics to single spaces + trim.
    /// Used to normalize spoken player answers before comparison.
    static func normalizedToken(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// If the value (already normalized) is just a short spoken letter
    /// like "a", "be", "see", or "dee", return the canonical "a".."d".
    /// Otherwise nil so we don't misinterpret long phrases.
    static func answerLetter(from value: String) -> String? {
        let words = value.split(separator: " ").map(String.init)
        guard words.count <= 4 else { return nil }

        for word in words {
            switch word {
            case "a", "ay", "eh": return "a"
            case "b", "be", "bee": return "b"
            case "c", "see", "sea": return "c"
            case "d", "dee": return "d"
            default: continue
            }
        }

        return nil
    }
}
