import Foundation

/// Builds the system prompt that defines the game host personality, rules, and current state.
/// Tuned for Grok Voice Think Fast 2.0 — keep this short; the app owns game state via tools.
struct SystemPromptBuilder {

    // MARK: - Build Session Config

    static func buildSessionConfig(
        locationLabel: String?,
        voice: String = "eve",
        resumeContext: ResumeContext? = nil,
        preconfiguredContext: PreConfiguredContext? = nil,
        gameStatePacket: GameStatePacket? = nil,
        isFirstGame: Bool = true,
        roundsRemaining: Int? = nil
    ) -> SessionConfig {
        let difficulty: Difficulty? = preconfiguredContext?.difficulty
            ?? gameStatePacket.flatMap { Difficulty(rawValue: $0.difficulty) }
            ?? resumeContext.flatMap { Difficulty(rawValue: $0.difficulty) }

        let instructions = buildPrompt(
            locationLabel: locationLabel,
            resumeContext: resumeContext,
            preconfiguredContext: preconfiguredContext,
            gameStatePacket: gameStatePacket,
            isFirstGame: isFirstGame,
            chosenDifficulty: difficulty,
            roundsRemaining: roundsRemaining
        )

        return SessionConfig(
            instructions: instructions,
            voice: voice,
            tools: buildTools()
        )
    }

    // MARK: - Policy Block

    static func buildPolicyBlock(chosenDifficulty: Difficulty? = nil) -> String {
        var policy = """
        You are Roadtrip Trivia's CarPlay voice host. Witty, warm, concise. No emojis. \
        The iOS app owns questions, grading, score UI, and end-of-game farewell. Always \
        use tools — without them the screen freezes. Never invent or reuse questions.

        FLOW:
        1. Call get_next_question. If result has `announce`, say it VERBATIM, then read \
           questionText VERBATIM. For MC say ALL options as \
           "Is it A: …, B: …, C: …, or D: …?" then "What do you think?".
        2. Wait for a real answer. Silence is not a skip — skip only if they say "skip". \
           A letter or option text is enough for MC.
        3. Call report_score({playerAnswer, isCorrect}) immediately — no spoken reaction first \
           (app plays chime/gong). App grades against its answer key.
        4. Say report_score.say VERBATIM (+ one short color phrase). Then go to step 1. \
           No filler ("ready?", "shall we continue?").
        5. End of round: follow nextAction — brief summary, ask "Want to keep going?". \
           Call end_game only if they say stop/end game. When roundsRemaining is 0, \
           acknowledge and wait — the app drives the farewell.

        SCORE: Speak totalPoints from tool results only. To fix a mis-grade, call \
        report_score again with the corrected outcome.
        NO SPOILERS before report_score for the current question.
        HINTS (max 2/round): call report_score(wasHint=true) first; honor hintDenied.
        CHALLENGES (max 1/round, not lightning): call report_score(wasChallenge=true, isCorrect=true) \
        to overturn; then re-serve via get_next_question if needed.
        LIGHTNING (isLightning=true): announce it, rapid-fire, pass isLightning in report_score, \
        no hints/challenges. On TIME IS UP, stop and announce the score.
        VOICE: hint, challenge, skip, reroll, end game/stop, pause.

        """

        if let diff = chosenDifficulty {
            policy += difficultySection(diff)
        } else {
            policy += "DIFFICULTY (player picks one):\n"
            policy += difficultySection(.simple)
            policy += difficultySection(.tricky)
            policy += difficultySection(.hard)
            policy += difficultySection(.einstein)
        }

        policy += """

        TOOLS: set_game_config (once before Round 1); get_next_question (every Q); \
        report_score (every answer); get_location (optional); end_game (player stop only).
        """

        return policy
    }

    // MARK: - Memory Block

    static func buildMemoryBlock(
        locationLabel: String?,
        resumeContext: ResumeContext? = nil,
        preconfiguredContext: PreConfiguredContext? = nil,
        gameStatePacket: GameStatePacket? = nil,
        isFirstGame: Bool = true,
        roundsRemaining: Int? = nil
    ) -> String {
        let location = locationLabel ?? "somewhere in the United States"
        var memory = """

        LOCATION: \(location)
        ROUND COUNT: Use roundsRemaining from each report_score result. Never say rounds \
        are over unless that field is 0. Purchases can increase the count mid-session.
        """

        if let remaining = roundsRemaining, remaining <= 0 {
            memory += """

            LAST AVAILABLE ROUND: Play all 5 questions. After the final report_score, \
            acknowledge briefly and wait — the app speaks the farewell. Do not call end_game \
            and do not ask to keep going.
            """
        }

        if let packet = gameStatePacket {
            memory += """

            GAME STATE (authoritative):
            \(packet.toJSON())
            Resume at Round \(packet.roundNumber), Question \(packet.questionIndex + 1)/5. \
            Skip setup. Greet warmly, brief score recap, continue with get_next_question.
            """
        } else if let resume = resumeContext {
            let answeredInRound = max(0, min(5, resume.questionIndex))
            let advancesToNextRound = answeredInRound >= 5
            let resumeRoundNumber = advancesToNextRound ? (resume.roundNumber + 1) : resume.roundNumber
            let nextQuestionInRound = advancesToNextRound ? 1 : (answeredInRound + 1)
            memory += """

            RESUME: Difficulty=\(resume.difficulty), \(resume.playerCount) players, \
            team=\(resume.teamName), ages=\(resume.ageBands). \
            Score: \(resume.totalCorrect)/\(resume.totalAnswered). Skip setup. Continue at \
            Round \(resumeRoundNumber), Question \(nextQuestionInRound) via get_next_question.
            """
        } else if let preconfig = preconfiguredContext {
            let pts = preconfig.previousTotalCorrect * preconfig.difficulty.pointsPerCorrect
            let nextRound = preconfig.previousRoundCount + 1
            memory += """

            PRE-CONFIGURED: Difficulty=\(preconfig.difficulty.rawValue), \
            \(preconfig.playerCount) players, team=\(preconfig.teamName ?? "Team"), \
            ages=\(preconfig.ageBands.map { $0.rawValue }.joined(separator: ", ")), \
            previous=\(pts) pts from \(preconfig.previousRoundCount) rounds. \
            Call set_game_config immediately, greet by team name, start Round \(nextRound).
            """
        } else {
            let rulesNote = isFirstGame
                ? "After config, briefly mention: 2 hints/round, 1 challenge/round, lightning every 5 rounds. Say once: \"Keep the app open on your iPhone while you play to follow your score.\""
                : "After config, skip rules."

            memory += """

            NEW GAME SETUP — one question per turn, wait for each answer:
            1) team name  2) ages (kids/teens/adults/mix)  3) difficulty \
            (Simple/Tricky/Wicked Hard/Einstein). Then call set_game_config once \
            (playerCount=1). \(rulesNote) Then call get_next_question immediately.
            """
        }

        return memory
    }

    // MARK: - Combined Prompt

    static func buildPrompt(
        locationLabel: String?,
        resumeContext: ResumeContext? = nil,
        preconfiguredContext: PreConfiguredContext? = nil,
        gameStatePacket: GameStatePacket? = nil,
        isFirstGame: Bool = true,
        chosenDifficulty: Difficulty? = nil,
        roundsRemaining: Int? = nil
    ) -> String {
        let policy = buildPolicyBlock(chosenDifficulty: chosenDifficulty)
        let memory = buildMemoryBlock(
            locationLabel: locationLabel,
            resumeContext: resumeContext,
            preconfiguredContext: preconfiguredContext,
            gameStatePacket: gameStatePacket,
            isFirstGame: isFirstGame,
            roundsRemaining: roundsRemaining
        )
        return policy + memory
    }

    // MARK: - Difficulty

    private static func difficultySection(_ difficulty: Difficulty) -> String {
        switch difficulty {
        case .simple:
            return "SIMPLE: MC A/B/C/D, 100 pts. Lenient.\n"
        case .tricky:
            return "TRICKY: MC A/B/C/D, 200 pts. Wordplay; accept reasonable variations.\n"
        case .hard:
            return "WICKED HARD: Free response, 300 pts. Strict; allow speech artifacts.\n"
        case .einstein:
            return "EINSTEIN: Free response, 400 pts. Near-exact; allow speech artifacts.\n"
        }
    }

    // MARK: - Tool Definitions

    static func buildTools() -> [RealtimeTool] {
        [
            RealtimeTool(
                name: "set_game_config",
                description: "Set config once before Round 1.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "playerCount": ["type": "integer"],
                        "teamName": ["type": "string"],
                        "difficulty": [
                            "type": "string",
                            "enum": ["simple", "tricky", "wicked_hard", "einstein"]
                        ],
                        "ageBands": [
                            "type": "array",
                            "items": [
                                "type": "string",
                                "enum": ["kids", "teens", "adults", "mixed"]
                            ]
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["playerCount", "teamName", "difficulty", "ageBands"]
                ] as [String: Any]
            ),
            RealtimeTool(
                name: "report_score",
                description: "Record answer after EVERY answer. Only playerAnswer and isCorrect are required; the app derives questionIndex, roundNumber, category, questionText, and isLightning from its own state.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "playerAnswer": ["type": "string"],
                        "isCorrect": ["type": "boolean", "description": "Best effort only; app verifies against its answer key."],
                        "wasChallenge": ["type": "boolean"],
                        "wasHint": ["type": "boolean"],
                        "questionIndex": ["type": "integer", "description": "Optional; app infers from last served question."],
                        "roundNumber": ["type": "integer", "description": "Optional; app infers from current round."],
                        "category": ["type": "string"],
                        "questionText": ["type": "string"],
                        "isLightning": ["type": "boolean"]
                    ] as [String: Any],
                    "required": ["playerAnswer", "isCorrect"]
                ] as [String: Any]
            ),
            RealtimeTool(
                name: "get_next_question",
                description: "Get the next trivia question. Call before every question.",
                parameters: [
                    "type": "object",
                    "properties": [:] as [String: Any]
                ] as [String: Any]
            ),
            RealtimeTool(
                name: "get_location",
                description: "Get current location. Optional.",
                parameters: [
                    "type": "object",
                    "properties": [:] as [String: Any]
                ] as [String: Any]
            ),
            RealtimeTool(
                name: "end_game",
                description: "End session only when player says stop/end game.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "finalScore": ["type": "integer"],
                        "totalQuestions": ["type": "integer"]
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

// MARK: - Pre-Configured Context

struct PreConfiguredContext {
    let difficulty: Difficulty
    let playerCount: Int
    let ageBands: [AgeBand]
    let teamName: String?
    let previousTotalCorrect: Int
    let previousRoundCount: Int
}
