import Foundation

/// Global rate-limiter for AI recovery actions (nudges / cancel+nudge).
///
/// Why this exists: the coordinator has several watchdogs that send
/// `responseCreate` nudges or `responseCancel` when the AI stalls. Each fires
/// independently; in the bad builds they fired repeatedly per question
/// ("nudge storms"), each one costing input tokens AND often interrupting a
/// healthy-but-slow turn — converting a 3s pause into a cut-off + restart.
/// Every recovery action must now be approved here, which enforces:
///
///   • minimum spacing between ANY two recovery actions
///   • a per-question nudge budget
///   • a per-question cancel budget (cancels are the destructive ones —
///     `responseCancel` is delivered as a literal "[stop]" user turn)
///
/// Reconnect escalations are always permitted: by that point the session is
/// wedged and recovery outranks politeness.
struct TurnRecoveryGovernor {

    enum ActionKind: Equatable {
        /// A plain `responseCreate` re-prompt.
        case softNudge
        /// `responseCancel` followed by `responseCreate` — interrupts the model.
        case cancelAndNudge
        /// Full session reconnect — always allowed.
        case reconnectEscalation
    }

    enum Verdict: Equatable {
        case allow
        case denySpacing(secondsSinceLast: Double)
        case denyNudgeBudget(used: Int)
        case denyCancelBudget(used: Int)
    }

    struct State: Equatable {
        var lastActionAt: Double?
        var nudgeCount: Int = 0
        var cancelCount: Int = 0

        /// Reset when a new question is served or a score is accepted —
        /// the budgets are per-question.
        mutating func resetForNewQuestion() {
            nudgeCount = 0
            cancelCount = 0
            // lastActionAt intentionally survives: spacing is global so two
            // different watchdogs can't fire back-to-back across a boundary.
        }
    }

    static let defaultMinSpacingSeconds: Double = 4.0
    static let defaultMaxNudgesPerQuestion: Int = 3
    static let defaultMaxCancelsPerQuestion: Int = 1

    static func decide(
        kind: ActionKind,
        now: Double,
        state: State,
        minSpacingSeconds: Double = defaultMinSpacingSeconds,
        maxNudgesPerQuestion: Int = defaultMaxNudgesPerQuestion,
        maxCancelsPerQuestion: Int = defaultMaxCancelsPerQuestion
    ) -> Verdict {
        if kind == .reconnectEscalation { return .allow }

        if let last = state.lastActionAt {
            let gap = now - last
            if gap < minSpacingSeconds {
                return .denySpacing(secondsSinceLast: gap)
            }
        }
        if state.nudgeCount >= maxNudgesPerQuestion {
            return .denyNudgeBudget(used: state.nudgeCount)
        }
        if kind == .cancelAndNudge && state.cancelCount >= maxCancelsPerQuestion {
            return .denyCancelBudget(used: state.cancelCount)
        }
        return .allow
    }

    /// Record an executed action. Call only after `decide` returned `.allow`
    /// (or for reconnect escalations, unconditionally).
    static func record(kind: ActionKind, now: Double, state: inout State) {
        state.lastActionAt = now
        switch kind {
        case .softNudge:
            state.nudgeCount += 1
        case .cancelAndNudge:
            state.nudgeCount += 1
            state.cancelCount += 1
        case .reconnectEscalation:
            break
        }
    }
}
