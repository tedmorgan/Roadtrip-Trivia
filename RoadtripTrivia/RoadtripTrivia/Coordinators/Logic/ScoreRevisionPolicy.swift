import Foundation

/// Handles a second `report_score` for the same (round, questionIndex) when
/// the host verbally corrects grading — without double-counting questions
/// answered and with a delta applied to correctness tallies.
public enum ScoreRevisionPolicy {

    public static func scoreKey(roundNumber: Int, questionIndex: Int) -> String {
        "\(roundNumber)-\(questionIndex)"
    }

    /// When non-nil, this `report_score` is a revision; the value is the
    /// app-graded correctness from the prior report (for delta math).
    public static func previousCorrectIfRevision(
        existingGraded: Bool?,
        isHint: Bool,
        isChallenge: Bool
    ) -> Bool? {
        guard !isHint, !isChallenge, let prev = existingGraded else { return nil }
        return prev
    }

    public static func correctnessDelta(previous: Bool, newGraded: Bool) -> Int {
        (newGraded ? 1 : 0) - (previous ? 1 : 0)
    }
}
