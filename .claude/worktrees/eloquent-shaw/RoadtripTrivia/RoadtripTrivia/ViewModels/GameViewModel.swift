import Foundation
import Combine

/// Central game state owner. Publishes phase changes that the CarPlayCoordinator
/// observes to update CPVoiceControlTemplate states.
///
/// In the Realtime API architecture, this is updated by function calls from the LLM
/// via RealtimeGameCoordinator, rather than by a code-driven state machine.
class GameViewModel: ObservableObject {

    @Published var currentPhase: GamePhase = .idle
    @Published private(set) var currentSession: TriviaSession?

    /// Realtime connection state
    @Published var isConnected = false
    @Published var connectionError: String?

    var currentRound: TriviaRound? {
        guard let session = currentSession,
              !session.rounds.isEmpty else { return nil }
        return session.rounds.last
    }

    // MARK: - Phase Transitions

    func transition(to phase: GamePhase) {
        let oldPhase = currentPhase
        currentPhase = phase
        if oldPhase != phase {
            print("[GameVM] Phase: \(oldPhase) → \(phase)")
        }
    }

    // MARK: - Session Setup

    func createSession(difficulty: Difficulty, playerCount: Int, ageBands: [AgeBand], teamName: String? = nil) {
        currentSession = TriviaSession(difficulty: difficulty, playerCount: playerCount, ageBands: ageBands, teamName: teamName)
    }

    func setPlayerCount(_ count: Int) {
        if currentSession == nil {
            currentSession = TriviaSession(difficulty: .tricky, playerCount: count, ageBands: [.mixed])
        } else {
            currentSession?.playerCount = count
        }
    }

    func setAgeBands(_ bands: [AgeBand]) {
        currentSession?.ageBands = bands
    }

    func setDifficulty(_ difficulty: Difficulty) {
        currentSession?.difficulty = difficulty
    }

    // MARK: - Round Management

    func startNewRound(type: RoundType, category: String, questions: [TriviaQuestion]) {
        let round = TriviaRound(type: type, category: category, questions: questions)
        currentSession?.rounds.append(round)
        currentSession?.currentQuestionIndex = 0
        currentSession?.lastPlayedAt = Date()
    }

    /// Ensures the session has enough rounds for the given round number,
    /// creating placeholder rounds as needed. Called from Realtime function handlers.
    func startNewRoundIfNeeded(roundNumber: Int, category: String, type: RoundType = .standard) {
        guard currentSession != nil else { return }

        while currentSession!.rounds.count < roundNumber {
            // Use the given type only for the target round; earlier gaps are standard
            let isTargetRound = (currentSession!.rounds.count == roundNumber - 1)
            let roundType = isTargetRound ? type : .standard
            let round = TriviaRound(type: roundType, category: category, questions: [])
            currentSession!.rounds.append(round)
        }

        if !currentSession!.rounds.isEmpty {
            currentSession!.rounds[currentSession!.rounds.count - 1].category = category
        }

        currentSession!.currentRoundIndex = roundNumber - 1
    }

    func currentQuestion(at index: Int) -> TriviaQuestion? {
        guard let round = currentRound,
              index < round.questions.count else { return nil }
        return round.questions[index]
    }

    // MARK: - Answer Recording

    func recordAnswer(_ answer: String, isCorrect: Bool, at questionIndex: Int) {
        guard var round = currentRound,
              questionIndex < round.questions.count else { return }

        round.questions[questionIndex].playerAnswer = answer
        round.questions[questionIndex].isCorrect = isCorrect
        round.questionsAnswered += 1
        if isCorrect { round.questionsCorrect += 1 }
        round.score = round.questionsCorrect

        updateCurrentRound(round)
        currentSession?.currentQuestionIndex = questionIndex + 1
    }

    /// Records an answer result reported by the LLM via Realtime function call.
    /// Unlike recordAnswer(), this doesn't require pre-existing question objects.
    func recordAnswerFromRealtime(answer: String, isCorrect: Bool, wasHint: Bool, wasChallenge: Bool) {
        guard currentSession != nil else { return }

        // Ensure we have a round to record into
        if currentSession!.rounds.isEmpty {
            let round = TriviaRound(type: .standard, category: "Trivia", questions: [])
            currentSession!.rounds.append(round)
        }

        let roundIndex = currentSession!.rounds.count - 1

        currentSession!.rounds[roundIndex].questionsAnswered += 1
        if isCorrect {
            currentSession!.rounds[roundIndex].questionsCorrect += 1
            currentSession!.rounds[roundIndex].score += 1
        }
        if wasHint {
            currentSession!.rounds[roundIndex].hintsUsed += 1
        }
        if wasChallenge {
            currentSession!.rounds[roundIndex].challengesUsed += 1
        }

        currentSession!.lastPlayedAt = Date()
    }

    // MARK: - Hints & Challenges

    func useHint(at questionIndex: Int) {
        guard var round = currentRound,
              questionIndex < round.questions.count else { return }
        round.questions[questionIndex].hintUsed = true
        round.hintsUsed += 1
        updateCurrentRound(round)
    }

    func markChallenged(at questionIndex: Int) {
        guard var round = currentRound,
              questionIndex < round.questions.count else { return }
        round.questions[questionIndex].challenged = true
        round.challengesUsed += 1
        updateCurrentRound(round)
    }

    func overturnChallenge(at questionIndex: Int) {
        guard var round = currentRound,
              questionIndex < round.questions.count else { return }
        round.questions[questionIndex].challengeOverturned = true
        round.questions[questionIndex].isCorrect = true
        round.challengesOverturned += 1
        round.questionsCorrect += 1
        round.score = round.questionsCorrect
        updateCurrentRound(round)
    }

    func markClarificationAttempted(at questionIndex: Int) {
        guard var round = currentRound,
              questionIndex < round.questions.count else { return }
        round.questions[questionIndex].clarificationAttempted = true
        updateCurrentRound(round)
    }

    // MARK: - Lightning Round

    func updateLightningTime(_ remaining: TimeInterval) {
        guard var round = currentRound, round.type == .lightning else { return }
        round.lightningTimeRemaining = remaining
        updateCurrentRound(round)
    }

    // MARK: - Round Completion

    func completeCurrentRound() {
        guard var round = currentRound else { return }
        round.isComplete = true
        updateCurrentRound(round)
        currentSession?.currentRoundIndex = (currentSession?.rounds.count ?? 1) - 1
    }

    // MARK: - Session Lifecycle

    func endSession() {
        currentSession?.isComplete = true
        currentSession?.lastPlayedAt = Date()
    }

    func restoreFromCheckpoint(_ checkpoint: SessionCheckpoint) {
        var session = TriviaSession(
            difficulty: checkpoint.difficulty,
            playerCount: checkpoint.playerCount,
            ageBands: checkpoint.ageBands,
            teamName: checkpoint.teamName
        )
        session.currentRoundIndex = checkpoint.roundIndex
        session.currentQuestionIndex = checkpoint.questionIndex
        session.locationLabel = checkpoint.locationLabel
        currentSession = session
    }

    // MARK: - Display Helpers

    var totalScore: Int {
        currentSession?.totalScore ?? 0
    }

    var totalQuestionsAnswered: Int {
        currentSession?.totalQuestionsAnswered ?? 0
    }

    var displayScore: String {
        "\(totalScore)/\(totalQuestionsAnswered)"
    }

    // MARK: - Private

    private func updateCurrentRound(_ round: TriviaRound) {
        guard var session = currentSession,
              !session.rounds.isEmpty else { return }
        session.rounds[session.rounds.count - 1] = round
        currentSession = session
    }
}
