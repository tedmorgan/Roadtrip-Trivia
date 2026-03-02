import Foundation

// MARK: - Game State Machine (Realtime API Architecture)

/// Simplified game phases for the Realtime API-driven architecture.
/// The LLM manages conversation flow; these phases drive CarPlay UI updates.
enum GamePhase: Equatable {
    /// App launched, no game in progress.
    case idle

    /// Connecting to OpenAI Realtime API (fetching token, establishing WebSocket).
    case connecting

    /// Connected and active — the LLM is hosting the game.
    case playing

    /// The LLM is speaking (asking a question, announcing a result, giving a summary).
    case speaking

    /// Waiting for the player to speak.
    case listening

    /// Showing an answer result (correct/incorrect).
    case showingResult

    /// Between rounds or waiting for user decision.
    case waiting

    /// Game paused due to interruption (phone call, Siri, network loss).
    case paused

    /// Asking if the player wants to resume a saved game.
    case resumePrompt

    /// Game session has ended.
    case gameOver
}

// MARK: - Voice Control State Mapping

/// Maps game phases to the 5 CPVoiceControlState slots available.
/// iOS 26.4 limits CPVoiceControlTemplate to max 5 states.
enum VoiceControlStateID: String, CaseIterable {
    case listening = "listening"
    case processing = "processing"
    case result = "result"
    case announcement = "announcement"
    case waiting = "waiting"
}

extension GamePhase {
    /// Which CPVoiceControlState to activate for this game phase.
    var voiceControlStateID: VoiceControlStateID {
        switch self {
        case .listening:
            return .listening
        case .connecting:
            return .processing
        case .showingResult:
            return .result
        case .speaking, .playing:
            return .announcement
        case .idle, .waiting, .paused, .resumePrompt, .gameOver:
            return .waiting
        }
    }
}

// MARK: - Session Checkpoint

/// Minimal data required to resume a session across app kills or CarPlay disconnects.
struct SessionCheckpoint: Codable {
    let sessionID: UUID
    let roundIndex: Int
    let questionIndex: Int
    let totalScore: Int
    let hintsUsed: Int
    let challengesUsed: Int
    let currentCategory: String
    let locationLabel: String?
    let lightningTimeRemaining: TimeInterval?
    let difficulty: Difficulty
    let playerCount: Int
    let ageBands: [AgeBand]
    let teamName: String?
    let savedAt: Date

    init(session: TriviaSession) {
        self.sessionID = session.id
        self.roundIndex = session.currentRoundIndex
        self.questionIndex = session.currentQuestionIndex
        self.totalScore = session.totalScore
        self.hintsUsed = session.hintsUsed
        self.challengesUsed = session.challengesUsed
        self.currentCategory = session.rounds.last?.category ?? ""
        self.locationLabel = session.locationLabel
        self.lightningTimeRemaining = session.rounds.last?.lightningTimeRemaining
        self.difficulty = session.difficulty
        self.playerCount = session.playerCount
        self.ageBands = session.ageBands
        self.teamName = session.teamName
        self.savedAt = Date()
    }

    /// Direct initializer for creating checkpoints from Realtime function calls.
    init(
        sessionID: UUID,
        roundIndex: Int,
        questionIndex: Int,
        totalScore: Int,
        hintsUsed: Int,
        challengesUsed: Int,
        currentCategory: String,
        locationLabel: String?,
        lightningTimeRemaining: TimeInterval?,
        difficulty: Difficulty,
        playerCount: Int,
        ageBands: [AgeBand],
        teamName: String?,
        savedAt: Date
    ) {
        self.sessionID = sessionID
        self.roundIndex = roundIndex
        self.questionIndex = questionIndex
        self.totalScore = totalScore
        self.hintsUsed = hintsUsed
        self.challengesUsed = challengesUsed
        self.currentCategory = currentCategory
        self.locationLabel = locationLabel
        self.lightningTimeRemaining = lightningTimeRemaining
        self.difficulty = difficulty
        self.playerCount = playerCount
        self.ageBands = ageBands
        self.teamName = teamName
        self.savedAt = savedAt
    }
}
