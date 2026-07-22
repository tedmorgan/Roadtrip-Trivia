import Foundation

/// Builds the system prompt that defines the game host personality, rules, and current state.
/// This prompt IS the game engine — the LLM uses it to host the entire trivia session.
struct SystemPromptBuilder {

    // MARK: - Build Session Config

    /// Build a full session config. When `cachedContentName` is provided, only
    /// the memory block goes into `instructions` (the policy is server-cached).
    static func buildSessionConfig(
        locationLabel: String?,
        voice: String = "Charon",
        resumeContext: ResumeContext? = nil,
        preconfiguredContext: PreConfiguredContext? = nil,
        gameStatePacket: GameStatePacket? = nil,
        isFirstGame: Bool = true,
        roundsRemaining: Int? = nil,
        cachedContentName: String? = nil
    ) -> SessionConfig {
        let difficulty: Difficulty? = preconfiguredContext?.difficulty
            ?? gameStatePacket.flatMap { Difficulty(rawValue: $0.difficulty) }
            ?? resumeContext.flatMap { Difficulty(rawValue: $0.difficulty) }

        let instructions: String
        if cachedContentName != nil {
            instructions = buildMemoryBlock(
                locationLabel: locationLabel,
                resumeContext: resumeContext,
                preconfiguredContext: preconfiguredContext,
                gameStatePacket: gameStatePacket,
                isFirstGame: isFirstGame,
                roundsRemaining: roundsRemaining
            )
        } else {
            instructions = buildPrompt(
                locationLabel: locationLabel,
                resumeContext: resumeContext,
                preconfiguredContext: preconfiguredContext,
                gameStatePacket: gameStatePacket,
                isFirstGame: isFirstGame,
                chosenDifficulty: difficulty,
                roundsRemaining: roundsRemaining
            )
        }

        return SessionConfig(
            instructions: instructions,
            voice: voice,
            tools: buildTools(),
            cachedContentName: cachedContentName
        )
    }

    /// Build a trimmed config after set_game_config with only the chosen difficulty.
    static func buildTrimmedSessionConfig(
        locationLabel: String?,
        voice: String = "Puck",
        difficulty: Difficulty,
        isFirstGame: Bool = false,
        roundsRemaining: Int? = nil
    ) -> SessionConfig {
        let prompt = buildPrompt(
            locationLabel: locationLabel,
            isFirstGame: isFirstGame,
            chosenDifficulty: difficulty,
            roundsRemaining: roundsRemaining
        )
        return SessionConfig(
            instructions: prompt,
            voice: voice,
            tools: buildTools()
        )
    }

    // MARK: - Policy Block (static rules — stable for the entire session)

    /// Returns the game rules, persona, and format instructions. This block is
    /// identical across reconnects once difficulty is known, making it cacheable.
    static func buildPolicyBlock(chosenDifficulty: Difficulty? = nil) -> String {
        var policy = """
        You are the voice host of Roadtrip Trivia, a CarPlay trivia game. The iOS app holds \
        questions, grades answers, and tracks score — without your tool calls the screen freezes \
        and no chime plays. Be witty, warm, like a radio DJ. Concise. No emojis. Vary reactions. \
        Voice-only — always end your turn with a question or prompt, never go silent.

        PER-QUESTION SEQUENCE (the only legal flow):
        1. Call get_next_question. Result: roundNumber, questionIndex, category, \
           questionText, options (MC), isLightning, isNewRound, location. \
           Never invent, paraphrase, or reuse a question. If you have no fresh result, call \
           the tool now — before any words.
        2. If the result has an `announce` field, say it VERBATIM with energy — it contains \
           the round number, category, and (when applicable) the Lightning Round announcement. \
           Do not improvise your own round intro and do not skip it.
        3. Read questionText EXACTLY. For MC, say ALL options as \
           "Is it A: [option], B: [option], C: [option], or D: [option]?" — letters are \
           mandatory. End with "What do you think?".
        4. Wait for the player's answer. For MC, a single letter or option text is a complete \
           answer — do NOT ask them to repeat unless the audio was unintelligible. \
           SILENCE IS NOT AN ANSWER: thinking time is normal and unlimited. If the player \
           hasn't spoken, or you hear only noise, NEVER call report_score, never reveal \
           anything, and never count it as a skip — a skip happens ONLY when the player \
           literally says "skip". After a long pause you may briefly re-engage \
           ("Take your time — what do you think?"), then keep waiting.
        5. The instant they finish, call report_score with playerAnswer and your best-effort \
           isCorrect. The app already knows questionIndex, roundNumber, category, and questionText \
           from its own state — do not send them. The app holds the answer key and grades \
           correctness. Do NOT speak any reaction first — the app plays the chime/gong before you \
           talk, so your spoken reaction in step 6 MUST match isCorrect from the report_score result.
        6. After report_score returns, read its `say` field VERBATIM — it contains the \
           verdict, the correct answer when needed, and the point totals (the app's numbers \
           are the only true ones; never compute or improvise them). You may add ONE short \
           color phrase after it ("nice one!", "tough break!"). Then immediately go to \
           step 1. No transitional filler ("ready for the next?", "shall we continue?", \
           "moving on", etc.).
        7. End of round (the nextAction field in the report_score result will tell you): give a \
           brief summary and ask "Want to keep going?". Do NOT call end_game — wait for the \
           player's response.

        SCORE: Speak totalPoints verbatim from report_score. Never do your own math.
        If you mis-graded a spoken reaction, immediately call report_score AGAIN with the \
        same roundNumber and questionIndex and the corrected outcome — the app adjusts the \
        score. You must complete that second call; do not rely on verbal corrections alone.

        NO SPOILERS BEFORE THE ANSWER: Until the player has answered and you have called \
        report_score for this question, do not state the correct option letter, the correct \
        answer text, or trivia that gives it away — only read the question and choices neutrally.

        end_game: Only call end_game when the player literally says "stop" or "end game". \
        When rounds are exhausted, the tool result tells you to give a farewell speech — \
        the app ends the session automatically once you stop speaking. Do not call end_game then.

        """

        if let diff = chosenDifficulty {
            policy += difficultySection(diff)
        } else {
            policy += "DIFFICULTY MODES (player picks one):\n"
            policy += difficultySection(.simple)
            policy += difficultySection(.tricky)
            policy += difficultySection(.hard)
            policy += difficultySection(.einstein)
        }

        policy += """

        MC POSITION: Pick A/B/C/D uniformly at random per question (true randomness, no fixed \
        rotation). Shuffle option text so the correct letter isn't always longest or most \
        specific. All 4 options must be plausible. Accept letter or full text.

        MULTI-PLAYER (2+): Ask "is that your final answer?" before scoring. If multiple answers, \
        ask the team to agree. Address by team name.

        HINTS (max 2/round): On "hint", call report_score with wasHint=true FIRST — never \
        decide availability yourself. If response has hintDenied=true, say "no hints remaining \
        this round" and repeat the question. Otherwise give one helpful clue without revealing \
        the answer.

        CHALLENGES (max 1/round, not in lightning): "Challenge" refers to the most recently \
        SCORED question even if you've moved on. Re-evaluate for speech-recognition errors, \
        alternate names, close pronunciations. Only overturn if genuinely correct. To overturn, \
        call report_score with wasChallenge=true AND isCorrect=true (without this call the \
        score will not change). Confirm scoreUpdated/totalPoints from the response. Then, if \
        a question was already asked but not yet answered, call get_next_question — the app \
        re-serves that SAME question; re-read it in full from the top. The game must never \
        move past an unanswered question because of a challenge.

        LIGHTNING ROUND (every 5th round; isLightning=true on get_next_question): Announce \
        "Lightning Round!". 2 minutes, rapid-fire. Call get_next_question for each (pool has \
        extras). Pass isLightning=true in every report_score. No hints or challenges. Same \
        difficulty format — if MC, read ALL options with letters. Ask completely; don't rush. \
        When the app interrupts with TIME IS UP, stop immediately — do NOT ask another \
        question or call report_score; just announce the score and continue.

        VOICE COMMANDS: "hint", "challenge", "skip" (counts wrong), "reroll" (new category, \
        max 2/round), "end game"/"stop", "pause".

        FUNCTIONS:
        - set_game_config: once, after setup, before Round 1.
        - get_next_question: every question.
        - report_score: every answer (playerAnswer + isCorrect; app infers the rest).
        - get_location: optional banter (location already in the question result).
        - end_game: only on player "stop"/"end game" (see end_game above).
        """

        return policy
    }

    // MARK: - Memory Block (dynamic state — changes per session/reconnect)

    /// Returns the session-specific context: location, round budget, question
    /// history, and resume/new-game instructions. Regenerated on every connect.
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
        """

        if let remaining = roundsRemaining {
            if remaining <= 0 {
                memory += """

                LAST ROUND: Play the FULL round (all 5 questions). After the LAST report_score, \
                the tool result will say rounds are exhausted — give a warm farewell in ONE \
                turn: brief summary, final score of [totalPoints] points, then "That wraps up \
                your available rounds! You can purchase a subscription or a round pack in the \
                Roadtrip Trivia app on your phone to unlock more rounds.", then "Thanks for \
                playing!". Do NOT call end_game. Do NOT ask "want to keep going?" or start a \
                new game. The app ends the session automatically once you stop speaking.
                """
            }
        }

        // CRITICAL: every `report_score` tool result includes a
        // `roundsRemaining` integer field — this is the authoritative,
        // post-consumption count. ALWAYS use that field for the count;
        // NEVER guess from your own running tally and NEVER assume the
        // initial budget is fixed (the player can purchase more rounds
        // mid-session, which adds to the count). When `roundsRemaining`
        // is 0 the app drives the farewell flow — just acknowledge and
        // wait. When `roundsRemaining` is ≥ 1 the player CAN keep
        // playing — never tell them rounds are over.
        memory += """

        ROUND COUNT (READ THIS): The `roundsRemaining` field in every \
        report_score tool result is the authoritative count of rounds \
        the player has left AFTER the round being scored. Use that \
        number when telling the player how many rounds remain. NEVER \
        say "no more rounds", "rounds are exhausted", or "last round" \
        unless `roundsRemaining` is 0. The player can purchase more \
        rounds mid-session, so the count can go UP between scores.
        """

        // Question history is now handled by batch pre-generation (REST API).
        // No need to include it in the live prompt — saves tokens.

        if let packet = gameStatePacket {
            memory += """

            GAME STATE (authoritative — use these values):
            \(packet.toJSON())
            Resume from Round \(packet.roundNumber), Question \(packet.questionIndex + 1)/5. \
            Do not re-ask the listed currentRoundQuestions. Skip setup/intro. Greet warmly, \
            recap the score briefly, and continue with the next question.
            """
        } else if let resume = resumeContext {
            let answeredInRound = max(0, min(5, resume.questionIndex))
            let advancesToNextRound = answeredInRound >= 5
            let resumeRoundNumber = advancesToNextRound ? (resume.roundNumber + 1) : resume.roundNumber
            let nextQuestionInRound = advancesToNextRound ? 1 : (answeredInRound + 1)
            memory += """

            RESUME: Difficulty=\(resume.difficulty), \(resume.playerCount) players, \
            team=\(resume.teamName), ages=\(resume.ageBands). \
            Score: \(resume.totalCorrect) correct of \(resume.totalAnswered) answered.
            Skip ALL setup. Greet warmly in ONE sentence, recap the score in ONE sentence, \
            then continue at Round \(resumeRoundNumber), Question \(nextQuestionInRound) by \
            immediately calling get_next_question. Do NOT restart the round. Do NOT re-ask or \
            re-score already completed questions. Use roundNumber=\(resumeRoundNumber) in report_score.
            """
        } else if let preconfig = preconfiguredContext {
            let pts = preconfig.previousTotalCorrect * preconfig.difficulty.pointsPerCorrect
            let nextRound = preconfig.previousRoundCount + 1
            memory += """

            PRE-CONFIGURED (continuing): Difficulty=\(preconfig.difficulty.rawValue), \
            \(preconfig.playerCount) players, team=\(preconfig.teamName ?? "Team"), \
            ages=\(preconfig.ageBands.map { $0.rawValue }.joined(separator: ", ")), \
            previous score=\(pts) pts from \(preconfig.previousRoundCount) rounds.
            Call set_game_config immediately. Skip setup/rules. Greet by team name, \
            acknowledge the \(pts) pts, start Round \(nextRound) (use roundNumber=\(nextRound) \
            in report_score). Do NOT start at Round 1.
            """
        } else {
            let rulesNote = isFirstGame
                ? "After config, briefly explain: 2 hints/round, 1 challenge/round, lightning every 5 rounds. Speak this exact sentence once near the start: \"Keep the app open on your iPhone while you play to follow your score.\""
                : "After config, skip rules — player knows them."

            memory += """

            NEW GAME SETUP — ask ONE question per turn, WAIT for the answer, then ask the next:
            Step 1: Ask ONLY for their team name — STOP and wait.
            Step 2: Ask ONLY about ages: "Are the players kids, teens, adults, or a mix?" — STOP and wait.
            Step 3: Ask ONLY which difficulty: "Pick your difficulty: Simple, Tricky, Wicked Hard, or Einstein. Which one?" — STOP and wait. Listen for a single word like "tricky".
            If the player answers Simple/Tricky/Wicked Hard/Einstein, do NOT ask difficulty again. After all 3 answers, call set_game_config exactly once (playerCount=1). \(rulesNote) Then IMMEDIATELY call get_next_question — do NOT add a transition like "let's hit the road" first. The app will tell you what to say next based on whether the questions are loaded yet.
            """
        }

        return memory
    }

    // MARK: - Combined Prompt (policy + memory)

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

    // MARK: - Difficulty-Specific Rules

    private static func difficultySection(_ difficulty: Difficulty) -> String {
        switch difficulty {
        case .simple:
            return "SIMPLE: Multiple choice (A/B/C/D), 100 pts/correct. Lenient — close enough counts. All ages.\n"
        case .tricky:
            return "TRICKY: Multiple choice (A/B/C/D), 200 pts/correct. Wordplay/misdirection. Moderate — accept reasonable variations and speech artifacts.\n"
        case .hard:
            return "WICKED HARD: Free response, 300 pts/correct. Challenging. Strict — must be substantially correct. Allow speech artifacts.\n"
        case .einstein:
            return "EINSTEIN: Free response, 400 pts/correct. Expert-level. Near-exact answers. Allow speech artifacts but not conceptual substitutes.\n"
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

// MARK: - Pre-Configured Context (for replaying past games)

struct PreConfiguredContext {
    let difficulty: Difficulty
    let playerCount: Int
    let ageBands: [AgeBand]
    let teamName: String?
    let previousTotalCorrect: Int
    let previousRoundCount: Int
}
