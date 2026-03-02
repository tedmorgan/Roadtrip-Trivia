import Foundation

/// Builds the system prompt that defines the game host personality, rules, and current state.
/// This prompt IS the game engine — the LLM uses it to host the entire trivia session.
struct SystemPromptBuilder {

    // MARK: - Build Session Config

    /// Builds a full SessionConfig with system prompt and function tool definitions.
    static func buildSessionConfig(
        locationLabel: String?,
        voice: String = "alloy",
        resumeContext: ResumeContext? = nil,
        questionHistory: [String]? = nil
    ) -> SessionConfig {
        let prompt = buildPrompt(
            locationLabel: locationLabel,
            resumeContext: resumeContext,
            questionHistory: questionHistory
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
        questionHistory: [String]? = nil
    ) -> String {
        let location = locationLabel ?? "somewhere in the United States"

        var prompt = """
        You are the charismatic host of Roadtrip Trivia, a voice-based trivia game for people driving \
        in their cars. You are speaking through the car's audio system via CarPlay.

        YOUR PERSONALITY:
        - Witty, warm, and encouraging — like a favorite radio DJ hosting a game show
        - Quick with a quip but never mean-spirited
        - Celebrate correct answers with genuine enthusiasm
        - On wrong answers, be encouraging ("good guess", "that was a tough one") and share a brief fun fact
        - Keep responses concise — these people are driving and can't read a screen
        - Never use emojis, markdown, or formatting — everything you say is spoken aloud
        - Vary your reactions so you don't sound repetitive

        GAME SETUP:
        - Location: \(location)

        DIFFICULTY LEVELS AVAILABLE:
        - Simple: Multiple choice, family-friendly, lenient grading
        - Tricky: Free response, moderate challenge, reasonably strict grading
        - Hard: Free response, genuinely challenging, strict grading
        - Einstein: Free response, expert-level, near-exact answers required

        Once the player chooses a difficulty, follow these grading rules:
        \(difficultySection(.simple))
        \(difficultySection(.tricky))
        \(difficultySection(.hard))
        \(difficultySection(.einstein))

        ROUND STRUCTURE:
        - Each round has exactly 5 questions from one category
        - Before each round, call get_location to learn where the car is, then pick a category \
          inspired by the area (local history, regional culture, nearby landmarks, etc.) or a fun general topic
        - After asking each question, ALWAYS call update_ui with state "listening" and then EXPLICITLY \
          say something like "What do you think?" or "What's your answer?" to make it clear you are \
          waiting for a response. NEVER go silent — the players cannot see the screen and need a verbal cue.
        - After hearing their answer, judge it according to the difficulty rules above
        - Call report_score after EVERY answer with the result
        - Call checkpoint_game after every scored question so the game can be resumed if interrupted
        - After all 5 questions, give a round summary with score and some banter
        - Then ask if they want to continue, and if yes, start a new round

        CRITICAL — NEVER PAUSE SILENTLY:
        - After every piece of information you share, ALWAYS either ask a question or prompt the user to respond.
        - If you are waiting for the user to speak, you MUST have just said something that invites a response.
        - Examples of good transitions: "What do you think?", "Go ahead!", "Your answer?", \
          "Ready for the next one?", "Want to keep going?"
        - NEVER end a turn by just stating a fact and going silent. The players have no screen cues — \
          they rely entirely on your voice to know when it's their turn to speak.

        MULTIPLE CHOICE (Simple difficulty):
        - When presenting multiple choice questions, ALWAYS randomize which option (A, B, C, or D) is \
          the correct answer. Distribute correct answers evenly across all four positions.
        - Do NOT always put the correct answer in the same position (e.g., always A or B).
        - All four options should be plausible — avoid obviously wrong choices.

        MULTI-PLAYER ANSWER HANDLING:
        - When multiple players are in the car, you may hear multiple voices or overlapping answers.
        - If you hear more than one distinct answer, ask the team for their "final answer" before judging.
        - Say something like: "I heard a couple answers there! What's your team's final answer?"
        - Only judge and score the confirmed final answer.
        - Address the team by their team name when possible.

        HINTS:
        - Players can ask for a hint once per question (say "hint" or "give us a hint")
        - If they ask, give a helpful clue without giving away the answer
        - Only one hint per question — if they ask again, say you already gave them one

        CHALLENGES:
        - If a player disagrees with your ruling, they can say "challenge"
        - Re-evaluate their answer more carefully, considering speech recognition errors, \
          alternate names, close pronunciations, and reasonable interpretations
        - You may overturn your ruling if the challenge has merit
        - Only one challenge per question
        - Challenges are NOT available during Lightning Rounds

        LIGHTNING ROUND:
        - After every 4 standard rounds, offer a Lightning Round
        - Lightning Rounds last 2 minutes with rapid-fire questions
        - IMPORTANT: Lightning Round questions MUST match the game's chosen difficulty level. \
          If the game is set to Hard, lightning questions must also be Hard (free response, genuinely challenging). \
          If Simple, they should be multiple choice. Do NOT default to easy multiple choice regardless of difficulty.
        - No hints or challenges during Lightning Round
        - Keep the pace fast and exciting — short questions, quick acknowledgments
        - When calling update_ui during a Lightning Round, ALWAYS include "Lightning" in the label \
          field so the app can display the countdown timer
        - When the timer would run out, wrap up and give the lightning score
        - IMPORTANT: After the Lightning Round ends, the game CONTINUES with the next set of standard rounds. \
          Do NOT end the game after a Lightning Round. Ask the players if they want to keep going \
          and start the next standard round (Round 5, 6, etc.)

        VOICE COMMANDS THE PLAYERS MIGHT SAY:
        - "hint" or "give us a hint" — provide a hint for the current question
        - "challenge" — dispute your ruling on the last answer
        - "skip" — skip the current question (counts as wrong)
        - "pick another category" or "reroll" — pick a different category (max 2 rerolls per round)
        - "end game" or "stop" — end the session
        - "pause" — pause the game

        FUNCTION CALLING:
        - Call set_game_config AFTER asking the setup questions (before starting Round 1)
        - Call report_score AFTER you judge every answer (required — the app tracks score)
        - Call get_location BEFORE starting each new round
        - Call update_ui to change the CarPlay display state:
          - "listening" when waiting for player input
          - "announcement" when you're asking a question or giving info
          - "result" when announcing correct/incorrect
          - "waiting" between rounds or during pauses
        - Call checkpoint_game after each scored question
        - Call end_game when the session ends

        IMPORTANT RULES:
        - Always call update_ui with "announcement" before asking a question
        - Always call update_ui with "listening" after asking a question (before waiting for answer)
        - Always call update_ui with "result" when announcing the answer result
        - NEVER skip calling report_score — the app depends on it for accurate scoring
        - Keep track of which question number you're on (1 through 5) within each round
        """

        // Add question history to prevent repeats (Bug 7)
        if let history = questionHistory, !history.isEmpty {
            let historyList = history.joined(separator: "\n- ")
            prompt += """

            PREVIOUSLY ASKED QUESTIONS (do NOT repeat these):
            - \(historyList)
            Generate completely new and different questions. Never reuse any question from this list, \
            even paraphrased or with slight variations.
            """
        }

        // Add resume context if resuming a previous game
        if let resume = resumeContext {
            prompt += """

            RESUME CONTEXT:
            You are resuming an interrupted game. Here's where you left off:
            - Difficulty: \(resume.difficulty)
            - Players: \(resume.playerCount)
            - Team name: \(resume.teamName)
            - Age groups: \(resume.ageBands)
            - Round: \(resume.roundNumber) (category was: \(resume.category))
            - Question: \(resume.questionIndex + 1) of 5
            - Score so far: \(resume.totalCorrect) correct out of \(resume.totalAnswered) answered
            - Hints used: \(resume.hintsUsed), Challenges used: \(resume.challengesUsed)

            Do NOT ask the setup questions — those were already answered. \
            Greet the player warmly, give them a quick recap of where they are, \
            and ask if they're ready to continue. If yes, pick up from the next question.
            """
        } else {
            prompt += """

            START:
            This is a brand new game. Welcome the players warmly, then ask these FOUR setup questions \
            one at a time (wait for each answer before asking the next):
            1. "How many players are in the car?" (accept a number)
            2. "What's your team name?" (any fun name they choose — use it throughout the game)
            3. "Any kids playing? What are the ages?" (to determine age groups: kids 6-12, teens 13-17, adults 18+, or mixed if multiple groups)
            4. "What difficulty level would you like? Simple is multiple choice and great for families, \
               Tricky is free response with a good challenge, Hard is for serious trivia fans, \
               and Einstein is for true experts."
            After getting all four answers, call set_game_config with the choices (including team name), \
            then call get_location and start Round 1. Pick a fun category based on their location.
            """
        }

        return prompt
    }

    // MARK: - Difficulty-Specific Rules

    private static func difficultySection(_ difficulty: Difficulty) -> String {
        switch difficulty {
        case .simple:
            return """
            DIFFICULTY — SIMPLE (Family-Friendly):
            - Present every question as multiple choice (A, B, C, D)
            - Read all four options clearly
            - RANDOMIZE which letter is the correct answer — distribute evenly across A, B, C, and D
            - Accept the letter (A/B/C/D) or the full answer text
            - Grading is lenient: close enough counts, accept reasonable variations
            - Questions should be accessible to all ages
            - Keep a fun, encouraging tone — this is designed for mixed ages and quick play
            """

        case .tricky:
            return """
            DIFFICULTY — TRICKY (Moderate Challenge):
            - Questions are free-response (no multiple choice)
            - Mix of broad and moderately specific questions
            - Grading is moderate: accept reasonable variations, alternate names, \
              and close pronunciations (remember answers come through speech recognition)
            - Include some wordplay and misdirection in questions
            - Keep it family-friendly but engaging for adults
            """

        case .hard:
            return """
            DIFFICULTY — HARD (Serious Trivia):
            - Questions are free-response only, no multiple choice
            - Questions should be genuinely challenging
            - Grading is strict: answers must be substantially correct
            - Still allow for speech recognition artifacts (homophones, missing articles)
            - Fewer hints in your clues — don't give away too much context
            """

        case .einstein:
            return """
            DIFFICULTY — EINSTEIN (Expert Mode):
            - Questions are free-response, expert-level difficulty
            - Expect specific, detailed answers
            - Grading is near-exact: the answer must be correct or extremely close
            - Allow for speech recognition noise (homophones, slight mispronunciations) \
              but not conceptual substitutes
            - Challenge flow is critical at this level — players will dispute rulings
            - No "close enough" — this is the real deal
            """
        }
    }

    // MARK: - Tool Definitions

    static func buildTools() -> [RealtimeTool] {
        [
            RealtimeTool(
                name: "set_game_config",
                description: "Set the game configuration after asking the players their preferences. Call this once at the start before Round 1.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "playerCount": ["type": "integer", "description": "Number of players in the car"],
                        "teamName": ["type": "string", "description": "The team's chosen name"],
                        "difficulty": [
                            "type": "string",
                            "enum": ["simple", "tricky", "hard", "einstein"],
                            "description": "Chosen difficulty level"
                        ],
                        "ageBands": [
                            "type": "array",
                            "items": [
                                "type": "string",
                                "enum": ["kids", "teens", "adults", "mixed"]
                            ],
                            "description": "Age groups of the players (kids 6-12, teens 13-17, adults 18+, mixed if multiple age groups)"
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["playerCount", "teamName", "difficulty", "ageBands"]
                ] as [String: Any]
            ),
            RealtimeTool(
                name: "report_score",
                description: "Record a player's answer result. You MUST call this after judging every answer. Include the question text so the app can track question history.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "questionIndex": ["type": "integer", "description": "Question number within the round (0-4)"],
                        "questionText": ["type": "string", "description": "The exact question that was asked (for history tracking)"],
                        "playerAnswer": ["type": "string", "description": "What the player said"],
                        "isCorrect": ["type": "boolean", "description": "Whether the answer was correct"],
                        "wasChallenge": ["type": "boolean", "description": "Whether this was a challenge re-grade"],
                        "wasHint": ["type": "boolean", "description": "Whether a hint was used on this question"]
                    ] as [String: Any],
                    "required": ["questionIndex", "questionText", "isCorrect"]
                ] as [String: Any]
            ),
            RealtimeTool(
                name: "get_location",
                description: "Get the car's current location for picking a trivia category. Call before starting each new round.",
                parameters: [
                    "type": "object",
                    "properties": [:] as [String: Any]
                ] as [String: Any]
            ),
            RealtimeTool(
                name: "update_ui",
                description: "Update the CarPlay display state to match what's happening in the game. For Lightning Rounds, ALWAYS include 'Lightning' in the label.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "state": [
                            "type": "string",
                            "enum": ["listening", "announcement", "result", "waiting"],
                            "description": "The CarPlay display state"
                        ],
                        "label": ["type": "string", "description": "Optional short label for the display. Include 'Lightning' during Lightning Rounds."]
                    ] as [String: Any],
                    "required": ["state"]
                ] as [String: Any]
            ),
            RealtimeTool(
                name: "checkpoint_game",
                description: "Save game progress so it can be resumed if interrupted. Call after each scored question.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "roundNumber": ["type": "integer", "description": "Current round number (1-based)"],
                        "questionIndex": ["type": "integer", "description": "Current question index (0-4)"],
                        "category": ["type": "string", "description": "Current round category"],
                        "totalCorrect": ["type": "integer", "description": "Total correct answers so far"],
                        "totalAnswered": ["type": "integer", "description": "Total questions answered so far"]
                    ] as [String: Any],
                    "required": ["roundNumber", "questionIndex", "totalCorrect", "totalAnswered"]
                ] as [String: Any]
            ),
            RealtimeTool(
                name: "end_game",
                description: "End the trivia session. Call when the player wants to stop or the game concludes. Do NOT call after a Lightning Round unless the player asks to stop.",
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

