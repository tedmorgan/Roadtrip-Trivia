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
        guard let accessToken = AuthService.shared.currentToken, !accessToken.isEmpty else {
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
