import CarPlay
import UIKit

/// Manages the CPVoiceControlState objects for the game's Playing template.
/// iOS 26.4 allows up to 5 states per CPVoiceControlTemplate.
///
/// Since CPVoiceControlState.titleVariants is read-only after init,
/// we rebuild the entire set of states each time score data changes.
/// The CarPlayCoordinator swaps the CPVoiceControlTemplate to show updates.
class VoiceControlStateManager {

    // MARK: - Refresh Callback

    /// Called when score data changes and the template needs rebuilding.
    /// Set by CarPlayCoordinator to trigger a template swap.
    var onNeedsRefresh: (() -> Void)?

    // MARK: - Score Tracking

    private(set) var totalCorrect = 0
    private(set) var totalAnswered = 0
    private(set) var questionInRound = 0
    private(set) var totalInRound = 5
    private(set) var currentRoundNumber = 0
    private(set) var currentCategory = ""
    private(set) var roundCorrect = 0
    private(set) var roundAnswered = 0
    private(set) var lightningSecondsRemaining = 120
    private(set) var lightningCorrect = 0
    private(set) var isLightningActive = false

    /// Team name set during game config (Bug 9)
    private(set) var teamName: String?

    // Round summary (shown briefly between rounds)
    private(set) var isShowingRoundSummary = false
    private(set) var summaryRoundScore = 0
    private(set) var summaryRoundTotal = 0
    private(set) var summaryHints = 0
    private(set) var summaryChallenges = 0

    // MARK: - Build Fresh States

    /// Creates a new set of 5 CPVoiceControlState objects with current score
    /// data baked into the titleVariants. Call this each time you need to
    /// rebuild the CPVoiceControlTemplate.
    func buildStates() -> [CPVoiceControlState] {
        return [
            buildListeningState(),
            buildProcessingState(),
            buildResultState(),
            buildAnnouncementState(),
            buildWaitingState()
        ]
    }

    // MARK: - Score Updates

    func updateScore(correct: Int, answered: Int, questionInRound: Int, totalInRound: Int = 5) {
        totalCorrect = correct
        totalAnswered = answered
        self.questionInRound = questionInRound
        self.totalInRound = totalInRound
        isShowingRoundSummary = false
        // No longer trigger template refresh on score changes — iPhone UI shows scores instead
    }

    func updateRound(number: Int, category: String) {
        currentRoundNumber = number
        currentCategory = category
        isShowingRoundSummary = false
        onNeedsRefresh?()
    }

    func setTeamName(_ name: String?) {
        self.teamName = name
    }

    func updateLightningTimer(secondsRemaining: Int, lightningCorrect: Int) {
        let oldSeconds = self.lightningSecondsRemaining
        self.lightningSecondsRemaining = secondsRemaining
        self.lightningCorrect = lightningCorrect
        self.isLightningActive = true
        // Bug 15: Only trigger refresh every 5 seconds during lightning to avoid flicker.
        // Always refresh on first tick (oldSeconds == 120) and at key thresholds.
        let shouldRefresh = (oldSeconds == 120)
            || (secondsRemaining % 5 == 0)
            || (secondsRemaining <= 10)
            || (secondsRemaining <= 0)
        if shouldRefresh {
            onNeedsRefresh?()
        }
    }

    func clearLightning() {
        isLightningActive = false
        onNeedsRefresh?()
    }

    // MARK: - Round Summary (GAME-02, CP-SCORE-05)

    func showRoundSummary(roundScore: Int, roundTotal: Int, cumCorrect: Int, cumAnswered: Int, hints: Int, challenges: Int) {
        roundCorrect = roundScore
        roundAnswered = roundTotal
        totalCorrect = cumCorrect
        totalAnswered = cumAnswered
        summaryRoundScore = roundScore
        summaryRoundTotal = roundTotal
        summaryHints = hints
        summaryChallenges = challenges
        isShowingRoundSummary = true
        onNeedsRefresh?()

        // Auto-clear round summary after 6 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            guard let self, self.isShowingRoundSummary else { return }
            self.isShowingRoundSummary = false
            self.onNeedsRefresh?()
        }
    }

    /// Reset all tracking (new game or return to home).
    func reset() {
        totalCorrect = 0
        totalAnswered = 0
        questionInRound = 0
        totalInRound = 5
        currentRoundNumber = 0
        currentCategory = ""
        roundCorrect = 0
        roundAnswered = 0
        lightningSecondsRemaining = 120
        lightningCorrect = 0
        isLightningActive = false
        isShowingRoundSummary = false
        teamName = nil
    }

    // MARK: - Private State Builders

    private var hasScore: Bool { totalAnswered > 0 }

    /// Short team prefix like "Quizzards: " or empty
    private var teamPrefix: String {
        guard let name = teamName, !name.isEmpty else { return "" }
        return "\(name): "
    }

    private var scoreLabel: String {
        "\(totalCorrect)/\(totalAnswered)"
    }

    /// "Rd 2 Q3/5" — compact round + question progress
    private var progressLabel: String {
        if currentRoundNumber > 0 {
            return "Rd \(currentRoundNumber) Q\(questionInRound)/\(totalInRound)"
        }
        return "Q\(questionInRound)/\(totalInRound)"
    }

    private var lightningTimerLabel: String {
        let mins = lightningSecondsRemaining / 60
        let secs = lightningSecondsRemaining % 60
        return String(format: "%d:%02d", mins, secs)
    }

    // ── Listening ──────────────────────────────────────────

    // Bug 33: CarPlay should only show current category — no "Speak your answer" text
    private func buildListeningState() -> CPVoiceControlState {
        let title = currentCategory.isEmpty ? "Roadtrip Trivia" : currentCategory
        return CPVoiceControlState(
            identifier: VoiceControlStateID.listening.rawValue,
            titleVariants: [title],
            image: UIImage(systemName: "mic.fill"),
            repeats: false
        )
    }

    // ── Processing ─────────────────────────────────────────

    private func buildProcessingState() -> CPVoiceControlState {
        let titles: [String] = [currentCategory, "Thinking..."]
        return CPVoiceControlState(
            identifier: VoiceControlStateID.processing.rawValue,
            titleVariants: titles,
            image: UIImage(systemName: "brain.head.profile"),
            repeats: false
        )
    }

    // ── Result ─────────────────────────────────────────────

    private func buildResultState() -> CPVoiceControlState {
        let titles: [String] = [currentCategory, "Result"]
        return CPVoiceControlState(
            identifier: VoiceControlStateID.result.rawValue,
            titleVariants: titles,
            image: UIImage(systemName: "checkmark.circle"),
            repeats: false
        )
    }

    // ── Announcement (question / round intro) ──────────────

    private func buildAnnouncementState() -> CPVoiceControlState {
        let titles: [String]
        if isLightningActive {
            titles = ["⚡ Lightning Round", "Lightning"]
        } else {
            titles = [currentCategory, "Roadtrip Trivia"]
        }
        return CPVoiceControlState(
            identifier: VoiceControlStateID.announcement.rawValue,
            titleVariants: titles,
            image: UIImage(systemName: "speaker.wave.2.fill"),
            repeats: false
        )
    }

    // ── Waiting (between rounds, round summary, idle) ──────

    private func buildWaitingState() -> CPVoiceControlState {
        let titles: [String] = [currentCategory, "Roadtrip Trivia"]
        return CPVoiceControlState(
            identifier: VoiceControlStateID.waiting.rawValue,
            titleVariants: titles,
            image: UIImage(systemName: "car.fill"),
            repeats: false
        )
    }
}
