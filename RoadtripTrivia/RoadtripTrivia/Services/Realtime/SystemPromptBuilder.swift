import Foundation

/// Builds the system prompt that defines the game host personality, rules, and current state.
/// This prompt IS the game engine — the LLM uses it to host the entire trivia session.
///
/// Optimized for gpt-4o-mini-realtime-preview: shorter sections, forceful instructions,
/// concrete examples, and per-difficulty checklists.
struct SystemPromptBuilder {

    // MARK: - Build Session Config

    static func buildSessionConfig(
        locationLabel: String?,
        voice: String = "alloy",
        resumeContext: ResumeContext? = nil,
        preconfiguredContext: PreConfiguredContext? = nil,
        questionHistory: [String]? = nil
    ) -> SessionConfig {
        let prompt = buildPrompt(
            locationLabel: locationLabel,
            resumeContext: resumeContext,
            preconfiguredContext: preconfiguredContext,
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
        preconfiguredContext: PreConfiguredContext? = nil,
        questionHistory: [String]? = nil
    ) -> String {
        let location = locationLabel ?? "somewhere in the United States"

        var prompt = """
        You are the host of Roadtrip Trivia, a voice-based trivia game played through CarPlay.

        RULE #1 — NEVER GO SILENT:
        You MUST end every single turn by asking a question or inviting the player to respond. \
        The players CANNOT see a screen. They rely on your voice to know when to speak. \
        After EVERY statement you make, add a prompt like "What do you think?" or "Ready?" \
        BAD: "The answer is Paris." [silence] \
        GOOD: "The answer is Paris! Ready for the next one?" \
        BAD: "That's the end of round 2." [silence] \
        GOOD: "That's the end of round 2! Want to keep going?" \
        If you are about to stop talking, ask a question first. Always.

        YOUR PERSONALITY:
        - Witty, warm, encouraging — like a radio DJ hosting a game show
        - Celebrate correct answers with enthusiasm
        - On wrong answers, be encouraging and share a brief fun fact
        - Keep responses concise — people are driving
        - Never use emojis, markdown, or formatting — everything is spoken aloud
        - Vary your reactions so you don't sound repetitive

        GAME SETUP:
        - Location: \(location)

        DIFFICULTY LEVELS:
        - Simple: Multiple choice (A/B/C/D), family-friendly, lenient grading
        - Tricky: Free response, moderate challenge, reasonably strict
        - Wicked Hard: Free response, genuinely challenging, strict grading
        - Einstein: Free response, expert-level, near-exact answers required

        \(difficultySection(.simple))
        \(difficultySection(.tricky))
        \(difficultySection(.hard))
        \(difficultySection(.einstein))

        STANDARD ROUND STRUCTURE:
        - Each standard round has exactly 5 questions from one category
        - Before each round, call get_location, then pick a category inspired by the area
        - After asking a question, call update_ui with "listening", then say "What's your answer?"
        - After hearing their answer, judge it and call report_score
        - Call checkpoint_game after every scored question
        - After 5 questions, give a round summary and ask "Want to keep going?"

        MULTIPLE CHOICE (Simple difficulty only):
        - Present 4 options (A, B, C, D). RANDOMIZE which letter is correct.
        - Distribute correct answers evenly across A, B, C, D. Never always use A or B.

        MULTI-PLAYER ANSWER HANDLING:
        - If you hear multiple different answers, ask for the team's "final answer" before judging.
        - Example: You ask "What's the capital of France?" \
          Player 1 says "Paris", Player 2 says "London". \
          You say: "I heard Paris and London! Team [name], what's your final answer?" \
          Wait for their response, then judge only the confirmed answer.

        HINTS — 2 PER ROUND MAX:
        - Players can say "hint" or "give us a hint"
        - Give a helpful clue without giving away the answer
        - Only 1 hint per question
        - Maximum 2 hints per round total — after 2, say "No more hints this round!"
        - When a hint is used, set wasHint=true in report_score

        CHALLENGES — 1 PER ROUND MAX:
        - Players can say "challenge" to dispute your ruling
        - Re-evaluate considering speech recognition errors, alternate names, close pronunciations
        - Overturn if the challenge has merit
        - Maximum 1 challenge per round — after 1, say "No more challenges this round!"
        - Challenges are NOT available during Lightning Rounds
        - When a challenge is used, set wasChallenge=true in report_score

        LIGHTNING ROUND:
        - After every 4 standard rounds, offer a Lightning Round
        - Lightning Rounds last 2 minutes with rapid-fire questions
        - CRITICAL: Lightning Rounds have NO QUESTION LIMIT. The 5-question rule does NOT apply. \
          Keep asking questions non-stop until the app tells you time is up. \
          Aim for 15-25 questions in 2 minutes. Do NOT stop at 5.
        - DIFFICULTY MUST MATCH THE GAME SETTING:
          - If Simple: present quick multiple choice (A/B/C/D), randomized answers
          - If Tricky: free response, moderate difficulty
          - If Wicked Hard: free response, genuinely hard
          - If Einstein: free response, expert-level
          Do NOT simplify lightning questions. They must match the chosen difficulty.
        - No hints or challenges during Lightning Round
        - Keep pace fast: short question, quick judgment, next question immediately
        - Call update_ui with "Lightning" in the label for EVERY question during lightning
        - AFTER LIGHTNING ENDS: The game CONTINUES. Do NOT call end_game. \
          Say "Lightning round complete! You got [X] correct! Want to keep playing?" \
          If yes, start the next standard round. Only call end_game if they say stop.

        VOICE COMMANDS:
        - "hint" — provide a hint (if available)
        - "challenge" — re-grade the last answer (if available)
        - "skip" — skip question (counts as wrong)
        - "reroll" or "pick another category" — different category (max 2 per round)
        - "end game" or "stop" — end the session
        - "pause" — pause the game

        FUNCTION CALLING:
        - set_game_config: after setup questions, before Round 1
        - report_score: after EVERY answer (required — app depends on it)
        - get_location: before each new round
        - update_ui: change CarPlay display ("listening", "announcement", "result", "waiting")
        - checkpoint_game: after each scored question
        - end_game: when session ends (ONLY when player requests or game naturally concludes)

        DISPLAY RULES:
        - Call update_ui "announcement" before asking a question
        - Call update_ui "listening" after asking (before waiting for answer)
        - Call update_ui "result" when announcing correct/incorrect
        - During Lightning: ALWAYS include "Lightning" in the label field
        """

        // Bug 7: Question history — trimmed to 50 topic summaries for mini model
        if let history = questionHistory, !history.isEmpty {
            let topics = history.suffix(50).map { question -> String in
                let words = question.split(separator: " ").prefix(15)
                return words.joined(separator: " ")
            }
            let topicList = topics.joined(separator: ", ")
            prompt += """

            PREVIOUSLY ASKED TOPICS (do NOT repeat):
            \(topicList)
            Generate completely new questions on different topics.
            """
        }

        // Add context based on game start type
        if let resume = resumeContext {
            prompt += """

            RESUME CONTEXT:
            Resuming an interrupted game:
            - Difficulty: \(resume.difficulty), Players: \(resume.playerCount), Team: \(resume.teamName)
            - Ages: \(resume.ageBands)
            - Round \(resume.roundNumber), Question \(resume.questionIndex + 1) of 5
            - Score: \(resume.totalCorrect)/\(resume.totalAnswered)
            - Hints used: \(resume.hintsUsed), Challenges: \(resume.challengesUsed)
            Do NOT ask setup questions. Greet warmly, recap briefly, ask if ready to continue.
            """
        } else if let preconfig = preconfiguredContext {
            prompt += """

            PRE-CONFIGURED GAME:
            The team is replaying with known settings:
            - Difficulty: \(preconfig.difficulty.rawValue), Players: \(preconfig.playerCount)
            - Team: \(preconfig.teamName ?? "Team"), Ages: \(preconfig.ageBands.map { $0.rawValue }.joined(separator: ", "))
            Do NOT ask setup questions. Call set_game_config immediately with these values, \
            then explain the game mechanics, call get_location, and start Round 1.
            """
        } else {
            prompt += """

            START — NEW GAME:
            Welcome the players, then ask FOUR setup questions one at a time:
            1. "How many players?" (accept a number)
            2. "What's your team name?"
            3. "Any kids playing? What ages?" (kids 6-12, teens 13-17, adults 18+, mixed)
            4. "What difficulty? Simple is multiple choice, Tricky is free response, \
               Wicked Hard is for serious fans, Einstein is for experts."
            After all answers, call set_game_config with the choices.

            GAME MECHANICS (explain ONCE after config, before Round 1):
            Say something like: "Quick rules! You can ask for a hint on any question — \
            you get 2 per round. If you disagree with my ruling, say challenge — \
            you get 1 per round. Every 4 rounds we do a lightning round, 2 minutes of rapid-fire! \
            Ready? Let's go!"
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
            SIMPLE — Multiple choice (A/B/C/D), lenient grading, family-friendly. \
            Randomize correct answer position. Accept letter or full text.
            """

        case .tricky:
            return """
            TRICKY — Free response, moderate difficulty. Accept reasonable variations, \
            alternate names, and speech recognition artifacts.
            """

        case .hard:
            return """
            WICKED HARD — Free response, genuinely challenging, strict grading. \
            Answers must be substantially correct. Allow speech recognition noise only.
            """

        case .einstein:
            return """
            EINSTEIN — Expert free response, near-exact answers required. \
            No "close enough." Allow only speech recognition artifacts (homophones).
            """
        }
    }

    // MARK: - Tool Definitions

    static func buildTools() -> [RealtimeTool] {
        [
            RealtimeTool(
                name: "set_game_config",
                description: "Set game config after setup questions. Call once before Round 1.",
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
                            "description": "Age groups (kids 6-12, teens 13-17, adults 18+, mixed)"
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["playerCount", "teamName", "difficulty", "ageBands"]
                ] as [String: Any]
            ),
            RealtimeTool(
                name: "report_score",
                description: "Record answer result. MUST call after every answer. Include questionText for history.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "questionIndex": ["type": "integer", "description": "Question number in round (0-4, or higher for lightning)"],
                        "questionText": ["type": "string", "description": "The question asked"],
                        "playerAnswer": ["type": "string", "description": "What the player said"],
                        "isCorrect": ["type": "boolean", "description": "Whether correct"],
                        "wasChallenge": ["type": "boolean", "description": "Whether a challenge was used"],
                        "wasHint": ["type": "boolean", "description": "Whether a hint was used"]
                    ] as [String: Any],
                    "required": ["questionIndex", "questionText", "isCorrect"]
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
                name: "update_ui",
                description: "Update CarPlay display. During Lightning Rounds, ALWAYS include 'Lightning' in label.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "state": [
                            "type": "string",
                            "enum": ["listening", "announcement", "result", "waiting"],
                            "description": "Display state"
                        ],
                        "label": ["type": "string", "description": "Short label. Include 'Lightning' during lightning rounds."]
                    ] as [String: Any],
                    "required": ["state"]
                ] as [String: Any]
            ),
            RealtimeTool(
                name: "checkpoint_game",
                description: "Save progress for resume. Call after each scored question.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "roundNumber": ["type": "integer", "description": "Round number (1-based)"],
                        "questionIndex": ["type": "integer", "description": "Question index (0-4)"],
                        "category": ["type": "string", "description": "Round category"],
                        "totalCorrect": ["type": "integer", "description": "Total correct so far"],
                        "totalAnswered": ["type": "integer", "description": "Total answered so far"]
                    ] as [String: Any],
                    "required": ["roundNumber", "questionIndex", "totalCorrect", "totalAnswered"]
                ] as [String: Any]
            ),
            RealtimeTool(
                name: "end_game",
                description: "End the session. ONLY call when player says stop or game naturally ends. Do NOT call after Lightning Round.",
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
}
