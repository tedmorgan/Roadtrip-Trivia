import Foundation

// MARK: - Session

struct TriviaSession: Codable, Identifiable {
    let id: UUID
    var rounds: [TriviaRound]
    var currentRoundIndex: Int
    var currentQuestionIndex: Int
    var difficulty: Difficulty
    var playerCount: Int
    var ageBands: [AgeBand]
    var teamName: String?
    var locationLabel: String?
    var createdAt: Date
    var lastPlayedAt: Date
    var isComplete: Bool

    var totalScore: Int {
        rounds.reduce(0) { $0 + $1.score }
    }

    var totalQuestionsAnswered: Int {
        rounds.reduce(0) { $0 + $1.questionsAnswered }
    }

    var totalQuestionsCorrect: Int {
        rounds.reduce(0) { $0 + $1.questionsCorrect }
    }

    var hintsUsed: Int {
        rounds.reduce(0) { $0 + $1.hintsUsed }
    }

    var challengesUsed: Int {
        rounds.reduce(0) { $0 + $1.challengesUsed }
    }

    var completedStandardRounds: Int {
        rounds.filter { $0.type == .standard && $0.isComplete }.count
    }

    var isLightningRoundEligible: Bool {
        completedStandardRounds > 0 && completedStandardRounds % 4 == 0
    }

    init(difficulty: Difficulty, playerCount: Int, ageBands: [AgeBand], teamName: String? = nil) {
        self.id = UUID()
        self.rounds = []
        self.currentRoundIndex = 0
        self.currentQuestionIndex = 0
        self.difficulty = difficulty
        self.playerCount = playerCount
        self.ageBands = ageBands
        self.teamName = teamName
        self.locationLabel = nil
        self.createdAt = Date()
        self.lastPlayedAt = Date()
        self.isComplete = false
    }
}

// MARK: - Round

struct TriviaRound: Codable, Identifiable {
    let id: UUID
    let type: RoundType
    var category: String
    var questions: [TriviaQuestion]
    var score: Int
    var questionsAnswered: Int
    var questionsCorrect: Int
    var hintsUsed: Int
    var challengesUsed: Int
    var challengesOverturned: Int
    var rerollsUsed: Int
    var isComplete: Bool
    var lightningTimeRemaining: TimeInterval?

    init(type: RoundType, category: String, questions: [TriviaQuestion]) {
        self.id = UUID()
        self.type = type
        self.category = category
        self.questions = questions
        self.score = 0
        self.questionsAnswered = 0
        self.questionsCorrect = 0
        self.hintsUsed = 0
        self.challengesUsed = 0
        self.challengesOverturned = 0
        self.rerollsUsed = 0
        self.isComplete = false
        self.lightningTimeRemaining = type == .lightning ? 120.0 : nil
    }
}

enum RoundType: String, Codable {
    case standard
    case lightning
}

// MARK: - Question

struct TriviaQuestion: Codable, Identifiable {
    let id: UUID
    let text: String
    let correctAnswer: String
    let hint: String
    let gradingRubric: String
    let multipleChoiceOptions: [String]?
    var playerAnswer: String?
    var isCorrect: Bool?
    var hintUsed: Bool
    var challenged: Bool
    var challengeOverturned: Bool?
    var clarificationAttempted: Bool

    init(
        text: String,
        correctAnswer: String,
        hint: String,
        gradingRubric: String,
        multipleChoiceOptions: [String]? = nil
    ) {
        self.id = UUID()
        self.text = text
        self.correctAnswer = correctAnswer
        self.hint = hint
        self.gradingRubric = gradingRubric
        self.multipleChoiceOptions = multipleChoiceOptions
        self.playerAnswer = nil
        self.isCorrect = nil
        self.hintUsed = false
        self.challenged = false
        self.challengeOverturned = nil
        self.clarificationAttempted = false
    }
}

// MARK: - Enums

enum Difficulty: String, CaseIterable {
    case simple = "Simple"
    case tricky = "Tricky"
    case hard = "Wicked Hard"
    case einstein = "Einstein"

    var pointsPerCorrect: Int {
        switch self {
        case .simple: return 100
        case .tricky: return 200
        case .hard: return 300
        case .einstein: return 400
        }
    }

    var usesMultipleChoice: Bool {
        self == .simple || self == .tricky
    }

    var gradingStrictness: String {
        switch self {
        case .simple: return "lenient"
        case .tricky: return "moderate"
        case .hard: return "strict"
        case .einstein: return "near-exact"
        }
    }
}

// Custom Codable to handle migration from old "Hard" raw value
extension Difficulty: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        // Accept both old "Hard" and new "Wicked Hard"
        if value == "Hard" || value == "Wicked Hard" {
            self = .hard
        } else if let matched = Difficulty(rawValue: value) {
            self = matched
        } else {
            self = .tricky // safe fallback
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
}

enum AgeBand: String, Codable, CaseIterable {
    case kids = "Kids (6-12)"
    case teens = "Teens (13-17)"
    case adults = "Adults (18+)"
    case mixed = "Mixed ages"
}

// MARK: - GPT Payloads

struct QuestionGenerationRequest: Codable {
    let locationLabel: String
    let difficulty: String
    let ageBands: [String]
    let roundNumber: Int
    let excludeCategories: [String]
}

struct QuestionGenerationResponse: Codable {
    let category: String
    let questions: [GeneratedQuestion]
}

struct GeneratedQuestion: Codable {
    let text: String
    let correctAnswer: String
    let hint: String
    let gradingRubric: String
    let multipleChoiceOptions: [String]?
}

struct GradingRequest: Codable {
    let question: String
    let correctAnswer: String
    let playerAnswer: String
    let gradingRubric: String
    let difficulty: String
}

struct GradingResponse: Codable {
    let isCorrect: Bool
    let isUncertain: Bool
    let explanation: String
}

struct ChallengeRequest: Codable {
    let question: String
    let correctAnswer: String
    let playerAnswer: String
    let gradingRubric: String
    let difficulty: String
    let originalGrading: String
}

struct ChallengeResponse: Codable {
    let overturned: Bool
    let explanation: String
}
