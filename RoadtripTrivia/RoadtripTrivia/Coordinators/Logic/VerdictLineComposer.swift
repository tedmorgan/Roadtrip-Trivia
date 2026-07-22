import Foundation

/// Composes the exact spoken verdict line the host must read after a score.
///
/// Why this exists: verdicts, correct answers, and point totals are facts the
/// app owns. Letting the model phrase them from prose rules produced "user
/// said D but host said 'correct, the answer is C'", spoken scores that
/// disagreed with the screen, and missing correct-answer reveals. The app now
/// composes the factual sentence; the model reads it verbatim and is free to
/// add personality only AFTER the facts are delivered.
enum VerdictLineComposer {

    /// Standard (non-revision) verdict line.
    static func compose(
        isCorrect: Bool,
        correctAnswer: String,
        pointsPerCorrect: Int,
        totalPoints: Int
    ) -> String {
        if isCorrect {
            return "Correct! That's \(pointsPerCorrect) points — your total is \(totalPoints) points."
        } else {
            return "Not quite — the answer was \(correctAnswer). Your total stays at \(totalPoints) points."
        }
    }

    /// Line for a host correction / re-grade of an already-scored question.
    /// `delta` is +1 (upgraded to correct) or -1 (downgraded to wrong); 0 means
    /// the re-grade didn't change the outcome.
    static func composeRevision(
        delta: Int,
        correctAnswer: String,
        totalPoints: Int
    ) -> String {
        if delta > 0 {
            return "Score corrected — that answer was right after all. Your total is now \(totalPoints) points."
        } else if delta < 0 {
            return "Score corrected — that one was actually \(correctAnswer). Your total is now \(totalPoints) points."
        } else {
            return "No change — your total is \(totalPoints) points."
        }
    }

    /// Line for a successful challenge overturn.
    static func composeChallengeOverturned(totalPoints: Int) -> String {
        return "Good challenge — you get the points. Your total is now \(totalPoints) points."
    }

    /// Line for a rejected challenge (answer stays wrong).
    static func composeChallengeRejected(correctAnswer: String, totalPoints: Int) -> String {
        return "I checked — the answer is still \(correctAnswer). Your total stays at \(totalPoints) points."
    }
}
