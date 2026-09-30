import Foundation

/// Moves each multiple-choice key off the slot the generator picked.
///
/// The batch model almost always parks the correct choice on D. A per-question
/// coin flip still leaves that slot in place whenever it "randomly" picks D
/// again, and it bails out entirely when `correctAnswer` is the words rather
/// than a letter. This assigns letters from a balanced deck (each of A–D used
/// as evenly as the question count allows) and rewrites the option labels to
/// match.
public enum AnswerPositionPolicy {

    public struct Question: Equatable {
        public var questionText: String
        public var options: [String]?
        public var correctAnswer: String

        public init(questionText: String, options: [String]?, correctAnswer: String) {
            self.questionText = questionText
            self.options = options
            self.correctAnswer = correctAnswer
        }
    }

    /// Target slots for `count` questions. A full set of A–D is dealt before
    /// any letter is repeated, then the deck is shuffled.
    public static func balancedTargets<R: RandomNumberGenerator>(
        count: Int,
        random: inout R
    ) -> [Int] {
        guard count > 0 else { return [] }
        var deck: [Int] = []
        var remaining = count
        while remaining > 0 {
            var cycle = [0, 1, 2, 3]
            cycle.shuffle(using: &random)
            let take = min(4, remaining)
            deck.append(contentsOf: cycle.prefix(take))
            remaining -= take
        }
        return deck
    }

    public static func redistribute<R: RandomNumberGenerator>(
        _ questions: [Question],
        random: inout R
    ) -> [Question] {
        redistribute(questions, targets: balancedTargets(count: questions.count, random: &random))
    }

    /// `targets` are indexes 0...3, one per question (cycled if shorter).
    public static func redistribute(_ questions: [Question], targets: [Int]) -> [Question] {
        questions.enumerated().map { offset, question in
            guard let options = question.options, options.count == 4,
                  let correctIndex = correctOptionIndex(
                    correctAnswer: question.correctAnswer,
                    options: options
                  )
            else { return question }
            let rawTarget = targets.isEmpty ? correctIndex : targets[offset % targets.count]
            let targetIndex = min(max(rawTarget, 0), 3)
            return placing(question, options: options, correctIndex: correctIndex, targetIndex: targetIndex)
        }
    }

    /// Index of the correct option, or nil when this is not a 4-choice question
    /// we can safely relabel.
    public static func correctOptionIndex(correctAnswer: String, options: [String]) -> Int? {
        guard options.count == 4 else { return nil }
        let trimmed = correctAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.count == 1, let index = letterIndex(trimmed) {
            return index
        }

        let body = optionBody(trimmed)
        if let match = options.firstIndex(where: {
            optionBody($0).caseInsensitiveCompare(body) == .orderedSame
        }) {
            return match
        }
        if isLabeled(trimmed), let index = letterIndex(String(trimmed.prefix(1))) {
            return index
        }
        return nil
    }

    /// Strips a leading "D:", "D)", "D.", or "(D)" label. Plain words that
    /// happen to start with A–D ("Canada") are left alone.
    public static func optionBody(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("(") {
            trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard trimmed.count >= 2, let index = letterIndex(String(trimmed.prefix(1))) else {
            return trimmed
        }
        _ = index
        let scalars = Array(trimmed)
        let mark = scalars[1]
        guard mark == ":" || mark == ")" || mark == "." || mark == "-" else {
            return trimmed
        }
        let rest = String(scalars.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? trimmed : rest
    }

    // MARK: - Private

    private static func placing(
        _ question: Question,
        options: [String],
        correctIndex: Int,
        targetIndex: Int
    ) -> Question {
        var bodies = options.map(optionBody)
        bodies.swapAt(correctIndex, targetIndex)
        let labels = ["A", "B", "C", "D"]
        let relabeled = bodies.enumerated().map { offset, body in
            "\(labels[offset]): \(body)"
        }
        var updated = question
        updated.options = relabeled
        updated.correctAnswer = labels[targetIndex]
        return updated
    }

    private static func isLabeled(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return optionBody(trimmed).caseInsensitiveCompare(trimmed) != .orderedSame
    }

    private static func letterIndex(_ raw: String) -> Int? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "A": return 0
        case "B": return 1
        case "C": return 2
        case "D": return 3
        default: return nil
        }
    }
}
