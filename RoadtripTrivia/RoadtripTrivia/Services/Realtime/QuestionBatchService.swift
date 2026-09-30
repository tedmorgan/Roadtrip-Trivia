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

    private(set) var currentBatch: QuestionBatch?
    private var roundCursor = 0
    private var questionCursor = 0

    // #region agent log
    private static let _batchLogPath: String = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("debug-f3b222.log").path
    }()
    static func _batchLog(_ hyp: String, _ loc: String, _ msg: String, _ data: [String: Any]) {
        guard DiagnosticLog.isEnabled else { return }
        let entry: [String: Any] = ["sessionId":"f3b222","hypothesisId":hyp,"location":loc,"message":msg,"data":DiagnosticLog.redactingSensitiveKeys(data),"timestamp":Date().timeIntervalSince1970 * 1000]
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
        location: String,
        difficulty: String,
        ageBands: [String],
        questionHistory: [String],
        usedCategories: [String],
        startingRound: Int = 1
    ) async throws -> QuestionBatch {
        var lastError: Error?
        for attempt in 1...2 {
            do {
                let batch = try await callEdgeAndParse(
                    location: location,
                    difficulty: difficulty,
                    ageBands: ageBands,
                    questionHistory: questionHistory,
                    usedCategories: usedCategories,
                    startingRound: startingRound,
                    attempt: attempt
                )
                let shuffled = Self.shuffleAnswerPositions(batch)
                let filtered = Self.droppingHistoryDuplicates(shuffled, history: questionHistory)
                currentBatch = filtered
                roundCursor = 0
                questionCursor = 0
                return filtered
            } catch {
                lastError = error
                if attempt == 1 {
                    print("[QuestionBatch] Attempt 1 failed (\(error.localizedDescription)), retrying…")
                }
            }
        }
        throw lastError!
    }

    private func callEdgeAndParse(
        location: String,
        difficulty: String,
        ageBands: [String],
        questionHistory: [String],
        usedCategories: [String],
        startingRound: Int,
        attempt: Int
    ) async throws -> QuestionBatch {
        guard let url = URL(string: "\(supabaseURL)/gemini-question-batch") else {
            throw BatchError.invalidURL
        }
        guard let accessToken = await AuthService.shared.accessTokenForRequests(), !accessToken.isEmpty else {
            throw BatchError.authenticationRequired
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AuthService.shared.supabaseApiKey, forHTTPHeaderField: "apikey")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "location": location,
            "difficulty": difficulty,
            "ageBands": ageBands,
            "questionHistory": questionHistory,
            "usedCategories": usedCategories,
            "startingRound": startingRound,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[QuestionBatch] Generating secure server-side batch attempt \(attempt) (rounds \(startingRound)-\(startingRound + 4), history: \(questionHistory.count))…")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let respBody = String(data: data, encoding: .utf8) ?? ""
            print("[QuestionBatch] API failed: HTTP \(code) — \(respBody.prefix(200))")
            throw BatchError.apiFailure(code)
        }

        let batch = try JSONDecoder().decode(QuestionBatch.self, from: data)
        // #region agent log
        Self._batchLog("H3_PARSE","QuestionBatchService.swift:\(#line)","secure batch decode succeeded",["rounds":batch.rounds.count,"totalQ":batch.rounds.map { $0.questions.count }.reduce(0, +),"attempt":attempt])
        // #endregion
        print("[QuestionBatch] Generated \(batch.rounds.count) rounds, \(batch.rounds.map { $0.questions.count }.reduce(0, +)) total questions")
        return batch
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

    /// Look at the next question without advancing the cursor.
    func peekNextQuestion() -> (round: BatchRound, question: BatchQuestion, questionIndex: Int)? {
        guard let batch = currentBatch else { return nil }
        var roundIndex = roundCursor
        var questionIndex = questionCursor
        while roundIndex < batch.rounds.count {
            let round = batch.rounds[roundIndex]
            if questionIndex < round.questions.count {
                return (round, round.questions[questionIndex], questionIndex + 1)
            }
            roundIndex += 1
            questionIndex = 0
        }
        return nil
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

    /// Skip leftover questions in the current round (lightning TIME IS UP)
    /// so the next `get_next_question` peeks at the following round.
    func skipRemainingQuestionsInCurrentRound() {
        guard let batch = currentBatch, roundCursor < batch.rounds.count else { return }
        let round = batch.rounds[roundCursor]
        if questionCursor >= round.questions.count { return }
        roundCursor += 1
        questionCursor = 0
    }

    func reset() {
        currentBatch = nil
        roundCursor = 0
        questionCursor = 0
    }

    // MARK: - History Dedup

    static func droppingHistoryDuplicates(_ batch: QuestionBatch, history: [String]) -> QuestionBatch {
        var seen = history
        let newRounds = batch.rounds.map { round -> BatchRound in
            let keepAtLeast = round.isLightning ? 6 : 5
            let kept = QuestionDedupPolicy.filterQuestions(
                round.questions,
                text: { $0.questionText },
                history: seen,
                keepAtLeast: keepAtLeast
            )
            seen.append(contentsOf: kept.map(\.questionText))
            return BatchRound(
                roundNumber: round.roundNumber,
                category: round.category,
                isLightning: round.isLightning,
                questions: kept
            )
        }
        return QuestionBatch(rounds: newRounds)
    }

    // MARK: - Answer Position Shuffling

    /// Spread correct-answer letters across A–D. The generator parks the key
    /// on D; a balanced deck is applied per round so a round cannot come out
    /// all D.
    private static func shuffleAnswerPositions(_ batch: QuestionBatch) -> QuestionBatch {
        var rng = SystemRandomNumberGenerator()
        let newRounds = batch.rounds.map { round -> BatchRound in
            let input = round.questions.map {
                AnswerPositionPolicy.Question(
                    questionText: $0.questionText,
                    options: $0.options,
                    correctAnswer: $0.correctAnswer
                )
            }
            let shuffled = AnswerPositionPolicy.redistribute(input, random: &rng)
            let questions = shuffled.map {
                BatchQuestion(
                    questionText: $0.questionText,
                    options: $0.options,
                    correctAnswer: $0.correctAnswer
                )
            }
            return BatchRound(
                roundNumber: round.roundNumber,
                category: round.category,
                isLightning: round.isLightning,
                questions: questions
            )
        }
        return QuestionBatch(rounds: newRounds)
    }

    // MARK: - Errors

    enum BatchError: LocalizedError {
        case invalidURL
        case apiFailure(Int)
        case emptyResponse
        case invalidJSON
        case authenticationRequired

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid batch generation URL"
            case .apiFailure(let c): return "Batch API failed (HTTP \(c))"
            case .emptyResponse: return "Empty batch response"
            case .invalidJSON: return "Invalid JSON in batch response"
            case .authenticationRequired: return "Sign in is required to generate questions"
            }
        }
    }
}
