import Foundation

/// Builds the single line the host reads when a question is served.
///
/// The host used to be told "say Question N, then read questionText
/// verbatim." Generated question text sometimes already begins with
/// "Question N", so the number was spoken twice. The number now lives
/// only in `readLine`, and `body` is the question with that prefix removed.
public enum QuestionReadComposer {

    /// Question text with a leading "Question 3", "Question 3:", or "Q3." removed.
    public static func body(from questionText: String) -> String {
        let trimmed = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(
            pattern: #"^(?:question|q)\s*\d+\s*[:.\-–—]?\s*"#,
            options: [.caseInsensitive]
        ) else {
            return trimmed
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let stripped = regex.stringByReplacingMatches(
            in: trimmed,
            range: range,
            withTemplate: ""
        )
        let result = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? trimmed : result
    }

    /// The one sentence the host speaks before the options.
    /// "Question 2. Which cape is the oldest?" — the number appears once.
    public static func readLine(questionIndex: Int, questionText: String) -> String {
        let questionBody = body(from: questionText)
        return "Question \(questionIndex). \(questionBody)"
    }

    /// Tool-result instruction. The host says `read` once and does not
    /// also read `questionText`, which is kept only as the unnumbered body.
    public static func toolInstruction(hasAnnounce: Bool) -> String {
        let lead = hasAnnounce
            ? "Say the announce field VERBATIM, then say the read field VERBATIM exactly once."
            : "Say the read field VERBATIM exactly once."
        return """
        \(lead) Do not say the question number again and do not also read questionText. \
        Then read every option. Do NOT paraphrase or reveal the answer. \
        After the player answers, call report_score.
        """
    }
}
