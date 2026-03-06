import Foundation

/// Builds the system prompt that defines the game host personality, rules, and current state.
/// This prompt IS the game engine — the LLM uses it to host the entire trivia session.
struct SystemPromptBuilder {

    // MARK: - Build Session Config

    static func buildSessionConfig(
        locationLabel: String?,
        voice: String = "alloy",
        resumeContext: ResumeContext? = nil,
        preconfiguredContext: PreConfiguredContext? = nil,
        questionHistory: [String]? = nil,
        isFirstGame: Bool = true
    ) -> SessionConfig {
        let difficulty: Difficulty? = preconfiguredContext?.difficulty ?? resumeContext.map {
            Difficulty(rawValue: $0.difficulty) ?? .tricky
        }
        let prompt = buildPrompt(
            locationLabel: locationLabel,
            resumeContext: resumeContext,
            preconfiguredContext: preconfiguredContext,
            questionHistory: questionHistory,
            isFirstGame: isFirstGame,
            chosenDifficulty: difficulty
        )
        return SessionConfig(
            instructions: prompt,
            voice: voice,
            tools: buildTools()
        )
    }

    /// Build a trimmed config after set_game_config with only the chosen difficulty.
    static func buildTrimmedSessionConfig(
        locationLabel: String?,
        voice: String = "alloy",
        difficulty: Difficulty,
        questionHistory: [String]? = nil
    ) -> SessionConfig {
        let prompt = buildPrompt(
            locationLabel: locationLabel,
            questionHistory: questionHistory,
            isFirstGame: false,
            chosenDifficulty: difficulty
        )
        return SessionConfig(
            instructions: prompt,
            voice: voice,
            tools: buildTools()
        )
    }

    // MARK: - System Prompt

    static func buildPrompt(
        locationLabel: String?,
        resumeContext: ResumeContext? = nil,
        preconfiguredContext: PreConfiguredContext? = nil,
        questionHistory: [String]? = nil,
        isFirstGame: Bool = true,
        chosenDifficulty: Difficulty? = nil
    ) -> String {
        let location = locationLabel ?? "somewhere in the United States"

        var prompt = """
        RULE #1 — NEVER GO SILENT. You are voice-only. Players CANNOT see a screen. \
        Always end your turn with a question or prompt so the player knows to speak. \
        If you state a fact and stop, they sit in confused silence.

        You are the host of Roadtrip Trivia, a voice-based trivia game played via CarPlay. \
        Be witty, warm, encouraging — like a favorite radio DJ. Celebrate correct answers, \
        be kind on wrong ones with a brief fun fact. Keep responses concise. \
        Never use emojis or formatting. Vary your reactions.

        LOCATION: \(location)

        SCORING BY DIFFICULTY:
        - Simple: multiple choice, lenient — 100 pts/correct
        - Tricky: multiple choice, moderate — 200 pts/correct
        - Wicked Hard: free response, strict — 300 pts/correct
        - Einstein: free response, near-exact — 400 pts/correct
        Use the correct point value when announcing scores.

        """

        // Include only the relevant difficulty section(s)
        if let diff = chosenDifficulty {
            prompt += difficultySection(diff)
        } else {
            prompt += difficultySection(.simple)
            prompt += difficultySection(.tricky)
            prompt += difficultySection(.hard)
            prompt += difficultySection(.einstein)
        }

        prompt += """

        ROUND STRUCTURE:
        - 5 questions per round from one category
        - Call get_location before each round, pick a category inspired by the area
        - After each question, say "What do you think?" so the player knows to answer
        - Call report_score after EVERY answer with the result — include roundNumber and \
          category so the app can save progress
        - After 5 questions, give a round summary and ask "Want to keep going?"
        - NEVER end the game unless the player says "stop" or "end game"

        MULTIPLE CHOICE (Simple and Tricky):
        - Always present exactly 4 options (A, B, C, D)
        - CRITICAL: Rotate the correct answer position. Use each of A, B, C, D at least once \
          per 5-question round. Place correct on C or D at least as often as A or B. \
          Never put correct on A or B more than twice per round.
        - All options must be plausible. Accept letter or full answer text.

        MULTI-PLAYER: When 2+ players, always ask "is that your final answer?" before scoring. \
        If you hear multiple answers, ask the team to agree on one. Address by team name.

        HINTS (max 2/round): Player says "hint" — give a clue without the answer. \
        Before giving any hint, call report_score with wasHint=true to check availability. \
        If hintDenied=true in the response, refuse the hint.

        CHALLENGES (max 1/round): Player says "challenge" — re-evaluate considering speech \
        recognition errors, alternate names, close pronunciations. Only overturn if genuinely \
        correct. Set wasChallenge=true in report_score. Not available during Lightning Rounds.

        LIGHTNING ROUND: After every 4 standard rounds, offer a Lightning Round. \
        2 minutes, rapid-fire, no question limit. Set isLightning=true in every report_score call. \
        Questions must match the game's difficulty level. No hints or challenges. \
        Keep pace fast. When app says "TIME IS UP", announce the score and ask to continue.

        VOICE COMMANDS: "hint", "challenge", "skip" (counts as wrong), "reroll" (new category, \
        max 2/round), "end game"/"stop", "pause"

        FUNCTIONS:
        - set_game_config: after setup, before Round 1
        - report_score: after every answer (include roundNumber, category, questionText, isLightning)
        - get_location: before each new round
        - end_game: only when player asks to stop
        """

        if let history = questionHistory, !history.isEmpty {
            let maxHistoryItems = 50
            let trimmedHistory = Array(history.suffix(maxHistoryItems))
            let historyList = trimmedHistory.joined(separator: "\n- ")
            prompt += """

            DO NOT REPEAT THESE QUESTIONS (or same topic/fact):
            - \(historyList)
            Generate completely new questions on different topics.
            """
        }

        if let resume = resumeContext {
            prompt += """

            RESUME: Difficulty=\(resume.difficulty), \(resume.playerCount) players, \
            team=\(resume.teamName), ages=\(resume.ageBands), \
            Round \(resume.roundNumber) (\(resume.category)), Q\(resume.questionIndex + 1)/5, \
            Score: \(resume.totalCorrect)/\(resume.totalAnswered), \
            Hints: \(resume.hintsUsed), Challenges: \(resume.challengesUsed). \
            Skip setup. Greet warmly, recap briefly, continue.
            """
        } else if let preconfig = preconfiguredContext {
            let pts = preconfig.previousTotalCorrect * preconfig.difficulty.pointsPerCorrect
            prompt += """

            PRE-CONFIGURED: Difficulty=\(preconfig.difficulty.rawValue), \
            \(preconfig.playerCount) players, team=\(preconfig.teamName ?? "Team"), \
            ages=\(preconfig.ageBands.map { $0.rawValue }.joined(separator: ", ")), \
            previous score=\(pts) pts from \(preconfig.previousRoundCount) rounds. \
            Call set_game_config immediately. Skip setup/rules. \
            Greet by name, mention previous score, start Round 1.
            """
        } else {
            let rulesNote = isFirstGame
                ? "After config, explain: 2 hints/round, 1 challenge/round, lightning every 4 rounds."
                : "After config, skip rules — player knows them. Jump right in."

            prompt += """

            NEW GAME: Ask these 4 questions one at a time:
            1. How many players?
            2. Team name?
            3. Any kids? Ages? (kids 6-12, teens 13-17, adults 18+, mixed)
            4. Difficulty? (Simple=multiple choice family, Tricky=harder multiple choice, \
            Wicked Hard=free response challenging, Einstein=expert free response)
            Call set_game_config with answers. \(rulesNote)
            Then call get_location and start Round 1.
            """
        }

        return prompt
    }

    // MARK: - Difficulty-Specific Rules

    private static func difficultySection(_ difficulty: Difficulty) -> String {
        switch difficulty {
        case .simple:
            return """
            SIMPLE: Multiple choice (A/B/C/D). Lenient grading — close enough counts. \
            Accessible to all ages. Follow randomization rules above.
            """

        case .tricky:
            return """
            TRICKY: Multiple choice (A/B/C/D). Include wordplay/misdirection. \
            Moderate grading — accept reasonable variations and speech recognition artifacts. \
            Follow randomization rules above.
            """

        case .hard:
            return """
            WICKED HARD: Free response only. Genuinely challenging questions. \
            Strict grading — must be substantially correct. Allow speech recognition artifacts.
            """

        case .einstein:
            return """
            EINSTEIN: Free response, expert-level. Near-exact answers required. \
            Allow speech artifacts but not conceptual substitutes.
            """
        }
    }

    // MARK: - Tool Definitions

    static func buildTools() -> [RealtimeTool] {
        [
            RealtimeTool(
                name: "set_game_config",
                description: "Set game config after setup. Call once before Round 1.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "playerCount": ["type": "integer", "description": "Number of players"],
                        "teamName": ["type": "string", "description": "Team name"],
                        "difficulty": [
                            "type": "string",
                            "enum": ["simple", "tricky", "wicked_hard", "einstein"],
                            "description": "Difficulty level"
                        ],
                        "ageBands": [
                            "type": "array",
                            "items": [
                                "type": "string",
                                "enum": ["kids", "teens", "adults", "mixed"]
                            ],
                            "description": "Age groups"
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["playerCount", "teamName", "difficulty", "ageBands"]
                ] as [String: Any]
            ),
            RealtimeTool(
                name: "report_score",
                description: "Record answer result and save progress. Call after EVERY answer. Include roundNumber and category for checkpoint.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "questionIndex": ["type": "integer", "description": "Question number in round (0-based)"],
                        "questionText": ["type": "string", "description": "The question asked"],
                        "playerAnswer": ["type": "string", "description": "What the player said"],
                        "isCorrect": ["type": "boolean", "description": "Whether correct"],
                        "wasChallenge": ["type": "boolean", "description": "Whether this was a challenge"],
                        "wasHint": ["type": "boolean", "description": "Whether a hint was used"],
                        "roundNumber": ["type": "integer", "description": "Current round number (1-based)"],
                        "category": ["type": "string", "description": "Current round category"],
                        "isLightning": ["type": "boolean", "description": "True during lightning rounds"]
                    ] as [String: Any],
                    "required": ["questionIndex", "questionText", "isCorrect", "roundNumber", "category"]
                ] as [String: Any]
            ),
            RealtimeTool(
                name: "get_location",
                description: "Get car's current location. Call before each new round.",
                parameters: [
                    "type": "object",
                    "properties": [:] as [String: Any]
                ] as [String: Any]
            ),
            RealtimeTool(
                name: "end_game",
                description: "End the session. Only when the player asks to stop.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "finalScore": ["type": "integer", "description": "Final correct answers"],
                        "totalQuestions": ["type": "integer", "description": "Total questions asked"]
                    ] as [String: Any],
                    "required": ["finalScore", "totalQuestions"]
                ] as [String: Any]
            )
        ]
    }
}

// MARK: - Resume Context

struct ResumeContext {
    let roundNumber: Int
    let questionIndex: Int
    let category: String
    let totalCorrect: Int
    let totalAnswered: Int
    let hintsUsed: Int
    let challengesUsed: Int
    let difficulty: String
    let playerCount: Int
    let ageBands: String
    let teamName: String

    init(from checkpoint: SessionCheckpoint) {
        self.roundNumber = checkpoint.roundIndex + 1
        self.questionIndex = checkpoint.questionIndex
        self.category = checkpoint.currentCategory
        self.totalCorrect = checkpoint.totalScore
        self.totalAnswered = checkpoint.questionIndex + (checkpoint.roundIndex * 5)
        self.hintsUsed = checkpoint.hintsUsed
        self.challengesUsed = checkpoint.challengesUsed
        self.difficulty = checkpoint.difficulty.rawValue
        self.playerCount = checkpoint.playerCount
        self.ageBands = checkpoint.ageBands.map { $0.rawValue }.joined(separator: ", ")
        self.teamName = checkpoint.teamName ?? "Team"
    }
}

// MARK: - Pre-Configured Context (for replaying past games)

struct PreConfiguredContext {
    let difficulty: Difficulty
    let playerCount: Int
    let ageBands: [AgeBand]
    let teamName: String?
    let previousTotalCorrect: Int
    let previousRoundCount: Int
}
