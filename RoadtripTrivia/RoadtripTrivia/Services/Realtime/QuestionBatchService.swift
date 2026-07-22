import Foundation

// MARK: - Batch Data Models

struct BatchQuestion: Codable {
    let questionText: String
    let options: [String]?
    let correctAnswer: String
}

struct BatchRound: Codable {
    let roundNumber: Int
    let category: String
    let isLightning: Bool
    let questions: [BatchQuestion]
}

struct QuestionBatch: Codable {
    let rounds: [BatchRound]
}

// MARK: - Service

final class QuestionBatchService {

    static let shared = QuestionBatchService()

    private let supabaseURL = "https://kakhzbcuudkrrktkobjs.supabase.co/functions/v1"
    /// Gemini 3.1 Flash Lite — GA id (`gemini-3.1-flash-lite`).
    /// The `-preview` suffix was discontinued 2026-05-25 per Google;
    /// architecture matches preview, only the identifier changes.
    private let restModel = "gemini-3.1-flash-lite"
    private let restBase = "https://generativelanguage.googleapis.com/v1beta"

    private(set) var currentBatch: QuestionBatch?
    private var roundCursor = 0
    private var questionCursor = 0

    // #region agent log
    private static let _batchLogPath: String = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("debug-f3b222.log").path
    }()
    static func _batchLog(_ hyp: String, _ loc: String, _ msg: String, _ data: [String: Any]) {
        let entry: [String: Any] = ["sessionId":"f3b222","hypothesisId":hyp,"location":loc,"message":msg,"data":data,"timestamp":Date().timeIntervalSince1970 * 1000]
        if let json = try? JSONSerialization.data(withJSONObject: entry), var line = String(data: json, encoding: .utf8) {
            line += "\n"
            if let fh = FileHandle(forWritingAtPath: _batchLogPath) {
                fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); fh.closeFile()
            } else {
                FileManager.default.createFile(atPath: _batchLogPath, contents: line.data(using: .utf8))
            }
        }
    }
    // #endregion

    // MARK: - Public API

    /// Generate a batch of 5 rounds (4 standard + 1 lightning) via Gemini REST.
    /// Retries once on JSON parse failure.
    func generateBatch(
        apiKey: String,
        location: String,
        difficulty: String,
        ageBands: [String],
        questionHistory: [String],
        usedCategories: [String],
        startingRound: Int = 1
    ) async throws -> QuestionBatch {
        let prompt = buildPrompt(
            location: location,
            difficulty: difficulty,
            ageBands: ageBands,
            questionHistory: questionHistory,
            usedCategories: usedCategories,
            startingRound: startingRound
        )

        var lastError: Error?
        for attempt in 1...2 {
            do {
                let batch = try await callRESTAndParse(prompt: prompt, apiKey: apiKey,
                                                        startingRound: startingRound,
                                                        historyCount: questionHistory.count,
                                                        attempt: attempt)
                let shuffled = Self.shuffleAnswerPositions(batch)
                currentBatch = shuffled
                roundCursor = 0
                questionCursor = 0
                return shuffled
            } catch {
                lastError = error
                if attempt == 1 {
                    print("[QuestionBatch] Attempt 1 failed (\(error.localizedDescription)), retrying…")
                }
            }
        }
        throw lastError!
    }

    private func callRESTAndParse(prompt: String, apiKey: String,
                                   startingRound: Int, historyCount: Int,
                                   attempt: Int) async throws -> QuestionBatch {
        guard let url = URL(string: "\(restBase)/models/\(restModel):generateContent?key=\(apiKey)") else {
            throw BatchError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "temperature": 1.0
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[QuestionBatch] Generating batch attempt \(attempt) (rounds \(startingRound)-\(startingRound + 4), history: \(historyCount))…")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let respBody = String(data: data, encoding: .utf8) ?? ""
            print("[QuestionBatch] API failed: HTTP \(code) — \(respBody.prefix(200))")
            throw BatchError.apiFailure(code)
        }

        struct Part: Codable { let text: String }
        struct Content: Codable { let parts: [Part] }
        struct Candidate: Codable { let content: Content }
        struct GeminiResp: Codable { let candidates: [Candidate] }

        let gemini = try JSONDecoder().decode(GeminiResp.self, from: data)
        guard let jsonText = gemini.candidates.first?.content.parts.first?.text else {
            throw BatchError.emptyResponse
        }

        // #region agent log
        Self._batchLog("H3_PARSE","QuestionBatchService.swift:\(#line)","raw JSON from Gemini",["rawLen":jsonText.count,"first50":String(jsonText.prefix(50)),"last50":String(jsonText.suffix(50)),"attempt":attempt])
        // #endregion
        let batch = try Self.parseBatchJSON(jsonText)
        // #region agent log
        Self._batchLog("H3_PARSE","QuestionBatchService.swift:\(#line)","parseBatchJSON succeeded",["rounds":batch.rounds.count,"totalQ":batch.rounds.map { $0.questions.count }.reduce(0, +),"attempt":attempt])
        // #endregion
        print("[QuestionBatch] Generated \(batch.rounds.count) rounds, \(batch.rounds.map { $0.questions.count }.reduce(0, +)) total questions")
        return batch
    }

    /// Fetch the Gemini API key from the Supabase edge function.
    func fetchAPIKey() async throws -> String {
        guard let url = URL(string: "\(supabaseURL)/gemini-token") else {
            throw BatchError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BatchError.apiFailure((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(GeminiTokenResponse.self, from: data).apiKey
    }

    /// Return the next question from the current batch, or nil if exhausted.
    func nextQuestion() -> (round: BatchRound, question: BatchQuestion, questionIndex: Int)? {
        guard let batch = currentBatch else { return nil }
        guard roundCursor < batch.rounds.count else { return nil }

        let round = batch.rounds[roundCursor]
        guard questionCursor < round.questions.count else {
            roundCursor += 1
            questionCursor = 0
            return nextQuestion()
        }

        let q = round.questions[questionCursor]
        let idx = questionCursor + 1
        questionCursor += 1
        return (round, q, idx)
    }

    var hasMoreQuestions: Bool {
        guard let batch = currentBatch else { return false }
        if roundCursor >= batch.rounds.count { return false }
        if roundCursor == batch.rounds.count - 1 {
            return questionCursor < batch.rounds[roundCursor].questions.count
        }
        return true
    }

    /// Categories used by the current batch (for tracking).
    var batchCategories: [String] {
        currentBatch?.rounds.map { $0.category } ?? []
    }

    /// Rewind one question so the same question is served again on the next call to `nextQuestion()`.
    func rewindLastQuestion() {
        if questionCursor > 0 {
            questionCursor -= 1
        } else if roundCursor > 0 {
            roundCursor -= 1
            if let batch = currentBatch, roundCursor < batch.rounds.count {
                questionCursor = max(0, batch.rounds[roundCursor].questions.count - 1)
            }
        }
    }

    func reset() {
        currentBatch = nil
        roundCursor = 0
        questionCursor = 0
    }

    // MARK: - Prompt

    private func buildPrompt(
        location: String,
        difficulty: String,
        ageBands: [String],
        questionHistory: [String],
        usedCategories: [String],
        startingRound: Int
    ) -> String {
        let diffRules: String
        switch difficulty.lowercased() {
        case "simple":
            diffRules = """
            Multiple choice with 4 options. Family-friendly, lenient. \
            Include options as ["A: ...", "B: ...", "C: ...", "D: ..."]. \
            correctAnswer is just the letter (e.g. "A").
            """
        case "tricky":
            diffRules = """
            Multiple choice with 4 options. Include wordplay and misdirection. \
            Include options as ["A: ...", "B: ...", "C: ...", "D: ..."]. \
            correctAnswer is just the letter (e.g. "B").
            """
        case "wicked_hard":
            diffRules = "Free response only. Genuinely challenging. Set options to null. correctAnswer is the answer text."
        case "einstein":
            diffRules = "Free response only. Expert-level. Set options to null. correctAnswer is the answer text."
        default:
            diffRules = """
            Multiple choice with 4 options. \
            Include options as ["A: ...", "B: ...", "C: ...", "D: ..."]. \
            correctAnswer is just the letter.
            """
        }

        // Lightning rounds are anchored to ABSOLUTE round numbers — every 5th round
        // (5, 10, 15, …) is a lightning round. Within any 5 consecutive rounds there is
        // exactly one multiple of 5. This keeps lightning alignment consistent even
        // when a batch is regenerated mid-game after a resume.
        let lightningRound = ((startingRound + 4) / 5) * 5
        var roundDesc = ""
        for r in startingRound...(startingRound + 4) {
            if r == lightningRound {
                roundDesc += "  Round \(r): 10 questions (LIGHTNING — shorter, faster pacing, isLightning=true)\n"
            } else {
                roundDesc += "  Round \(r): 5 questions (standard, isLightning=false)\n"
            }
        }

        let avoidCats = usedCategories.isEmpty ? "None" : usedCategories.joined(separator: ", ")

        let historyBlock: String
        if questionHistory.isEmpty {
            historyBlock = "None — first game."
        } else {
            historyBlock = "- " + questionHistory.joined(separator: "\n- ")
        }

        return """
        Generate trivia questions for a voice-based road trip game.

        LOCATION: \(location)
        DIFFICULTY: \(difficulty)
        PLAYER AGES: \(ageBands.joined(separator: ", "))

        Generate exactly 5 rounds:
        \(roundDesc)

        CATEGORY RULES:
        - Choose 5 DIFFERENT broad categories from: Science & Nature, History, Geography, \
        Sports, Entertainment, Food & Drink, Art & Literature, Music, Pop Culture, \
        Animals & Wildlife, Movies & TV, World Cultures, Technology, Mythology & Legends.
        - Every question in a round MUST be from that round's single category.
        - Do NOT reuse these already-used categories: \(avoidCats)

        LOCATION RULES (IMPORTANT):
        - The player is currently near: \(location).
        - At least 1 question in EACH standard round MUST relate to or reference the \
        player's location, state, or region. For example, a local landmark, a famous \
        person from the area, a regional food, a sports team, a historical event, etc.
        - The remaining questions in the round can be from anywhere.
        - For the lightning round, at least 2 of the 10 questions should be location-related.

        DIFFICULTY RULES:
        \(diffRules)
        For multiple choice, randomize which letter (A-D) is correct for each question.

        BANNED TOPICS — do NOT generate questions covering ANY of these subjects:
        \(historyBlock)
        Every question must be on a completely different topic from the banned list.

        Return ONLY valid JSON in this exact format (no markdown, no explanation):
        {
          "rounds": [
            {
              "roundNumber": \(startingRound),
              "category": "Category Name",
              "isLightning": false,
              "questions": [
                {
                  "questionText": "Full question text here?",
                  "options": ["A: First option", "B: Second option", "C: Third option", "D: Fourth option"],
                  "correctAnswer": "B"
                }
              ]
            }
          ]
        }
        """
    }

    // MARK: - JSON Cleanup

    /// Attempt to decode batch JSON, cleaning up common LLM formatting issues.
    private static func parseBatchJSON(_ raw: String) throws -> QuestionBatch {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code fences if present
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if text.hasSuffix("```") {
                text = String(text.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Find the outermost { … } respecting quoted strings and escape chars.
        if let openBrace = text.firstIndex(of: "{") {
            var depth = 0
            var inString = false
            var escaped = false
            var closeIdx = text.startIndex
            for i in text.indices[openBrace...] {
                let c = text[i]
                if escaped { escaped = false; continue }
                if c == "\\" && inString { escaped = true; continue }
                if c == "\"" { inString = !inString; continue }
                if inString { continue }
                if c == "{" { depth += 1 }
                else if c == "}" { depth -= 1 }
                if depth == 0 { closeIdx = i; break }
            }
            if closeIdx > openBrace {
                text = String(text[openBrace...closeIdx])
            }
        }

        guard let data = text.data(using: .utf8) else {
            throw BatchError.invalidJSON
        }
        return try JSONDecoder().decode(QuestionBatch.self, from: data)
    }

    // MARK: - Answer Position Shuffling

    /// Redistribute correct answer positions to avoid A/B bias from the LLM.
    private static func shuffleAnswerPositions(_ batch: QuestionBatch) -> QuestionBatch {
        let newRounds = batch.rounds.map { round -> BatchRound in
            let newQuestions = round.questions.map { q -> BatchQuestion in
                guard let options = q.options, options.count == 4 else { return q }
                guard let correctLetter = q.correctAnswer.first,
                      let correctIdx = letterToIndex(correctLetter) else { return q }
                guard correctIdx < options.count else { return q }

                let targetIdx = Int.random(in: 0..<4)
                if targetIdx == correctIdx { return q }

                var shuffled = options
                shuffled.swapAt(correctIdx, targetIdx)

                // Relabel A/B/C/D prefixes
                let labels = ["A", "B", "C", "D"]
                let relabeled = shuffled.enumerated().map { i, opt -> String in
                    let stripped = stripLetterPrefix(opt)
                    return "\(labels[i]): \(stripped)"
                }

                let newAnswer = labels[targetIdx]
                return BatchQuestion(questionText: q.questionText, options: relabeled, correctAnswer: newAnswer)
            }
            return BatchRound(roundNumber: round.roundNumber, category: round.category,
                              isLightning: round.isLightning, questions: newQuestions)
        }
        return QuestionBatch(rounds: newRounds)
    }

    private static func letterToIndex(_ c: Character) -> Int? {
        switch c.uppercased() {
        case "A": return 0; case "B": return 1; case "C": return 2; case "D": return 3
        default: return nil
        }
    }

    private static func stripLetterPrefix(_ option: String) -> String {
        let trimmed = option.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 3 && trimmed[trimmed.index(trimmed.startIndex, offsetBy: 1)] == ":" {
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        if trimmed.count >= 4 && trimmed[trimmed.index(trimmed.startIndex, offsetBy: 1)] == "." {
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    // MARK: - Errors

    enum BatchError: LocalizedError {
        case invalidURL
        case apiFailure(Int)
        case emptyResponse
        case invalidJSON

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid batch generation URL"
            case .apiFailure(let c): return "Batch API failed (HTTP \(c))"
            case .emptyResponse: return "Empty batch response"
            case .invalidJSON: return "Invalid JSON in batch response"
            }
        }
    }
}
