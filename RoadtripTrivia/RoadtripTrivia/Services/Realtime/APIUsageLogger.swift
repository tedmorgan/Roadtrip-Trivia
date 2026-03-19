import Foundation

/// Logs only Realtime `response.done` token usage (including text/audio/cached breakdown when present)
/// to a file in the app's Documents directory for cost review.
///
/// Log file location: Documents/api_usage.log
/// Access via: Files.app → On My iPhone → Roadtrip Trivia, or Xcode → Devices → Download Container
class APIUsageLogger {

    static let shared = APIUsageLogger()

    private let fileHandle: FileHandle?
    private let logFileURL: URL
    private let queue = DispatchQueue(label: "com.nagrom.roadtrip.apilog", qos: .utility)
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // Per-session context for cost analysis
    private var contextUserId: String?
    private var contextTeamName: String?
    private var contextRound: Int?
    private var contextQuestion: Int?
    private var contextCategory: String?
    private var contextDifficulty: String?
    private var contextPhase: String?   // e.g. "intro" vs "trivia"

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        logFileURL = docs.appendingPathComponent("api_usage.log")

        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }

        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()
    }

    deinit {
        fileHandle?.closeFile()
    }

    /// The path to the log file on disk.
    var logFilePath: String { logFileURL.path }

    // MARK: - Logging Methods

    /// Update contextual fields that will be appended to subsequent log entries.
    /// This lets us attribute token usage to a specific user, team, round, and question.
    func setContext(userId: String?,
                    teamName: String?,
                    round: Int?,
                    question: Int?,
                    category: String?,
                    difficulty: String?,
                    phase: String? = nil) {
        contextUserId = userId
        contextTeamName = teamName
        contextRound = round
        contextQuestion = question
        contextCategory = category
        contextDifficulty = difficulty
        if let phase { contextPhase = phase }
    }

    /// Log a `response.done` event when the API includes a `usage` object (real token counts + modality breakdown).
    func logResponseDone(status: String, usage: ResponseUsage) {
        writeEntry("[RECV] type=response.done | status=\(status) | input_tokens=\(usage.inputTokens) | output_tokens=\(usage.outputTokens) | total_tokens=\(usage.totalTokens)\(usage.detailLogSuffix())")
    }

    // MARK: - Private

    private func writeEntry(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let context = contextSuffix()
        let line = "[\(timestamp)] \(message)\(context)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async { [weak self] in
            self?.fileHandle?.write(data)
        }
    }

    private func contextSuffix() -> String {
        var parts: [String] = []
        if let user = contextUserId { parts.append("user=\(user)") }
        if let team = contextTeamName { parts.append("team=\"\(team)\"") }
        if let round = contextRound { parts.append("round=\(round)") }
        if let q = contextQuestion { parts.append("question=\(q)") }
        if let cat = contextCategory { parts.append("category=\"\(cat)\"") }
        if let diff = contextDifficulty { parts.append("difficulty=\(diff)") }
        if let phase = contextPhase { parts.append("phase=\(phase)") }
        guard !parts.isEmpty else { return "" }
        return " | " + parts.joined(separator: " | ")
    }
}

/// Token usage extracted from Realtime `response.done` → `response.usage`.
/// See OpenAI Realtime cost docs: `input_token_details`, `output_token_details`, cached input breakdown.
struct ResponseUsage {
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int

    /// `input_token_details.text_tokens`
    let inputTextTokens: Int?
    /// `input_token_details.audio_tokens`
    let inputAudioTokens: Int?
    /// `input_token_details.image_tokens`
    let inputImageTokens: Int?

    /// `input_token_details.cached_tokens`
    let cachedInputTokens: Int?
    /// `input_token_details.cached_tokens_details.text_tokens`
    let cachedInputTextTokens: Int?
    /// `input_token_details.cached_tokens_details.audio_tokens`
    let cachedInputAudioTokens: Int?
    /// `input_token_details.cached_tokens_details.image_tokens`
    let cachedInputImageTokens: Int?

    /// `output_token_details.text_tokens`
    let outputTextTokens: Int?
    /// `output_token_details.audio_tokens`
    let outputAudioTokens: Int?
    /// `output_token_details.image_tokens`
    let outputImageTokens: Int?

    /// Build from JSON `usage` object on `response.done`.
    static func from(usageDictionary d: [String: Any]) -> ResponseUsage {
        let input = intFromJSON(d["input_tokens"]) ?? intFromJSON(d["total_tokens"]) ?? 0
        let output = intFromJSON(d["output_tokens"]) ?? 0
        let total = intFromJSON(d["total_tokens"]) ?? (input + output)

        var inText: Int?
        var inAudio: Int?
        var inImage: Int?
        var cached: Int?
        var cachedText: Int?
        var cachedAudio: Int?
        var cachedImage: Int?

        if let inDet = d["input_token_details"] as? [String: Any] {
            inText = intFromJSON(inDet["text_tokens"])
            inAudio = intFromJSON(inDet["audio_tokens"])
            inImage = intFromJSON(inDet["image_tokens"])
            cached = intFromJSON(inDet["cached_tokens"])
            if let ctd = inDet["cached_tokens_details"] as? [String: Any] {
                cachedText = intFromJSON(ctd["text_tokens"])
                cachedAudio = intFromJSON(ctd["audio_tokens"])
                cachedImage = intFromJSON(ctd["image_tokens"])
            }
        }

        var outText: Int?
        var outAudio: Int?
        var outImage: Int?
        if let outDet = d["output_token_details"] as? [String: Any] {
            outText = intFromJSON(outDet["text_tokens"])
            outAudio = intFromJSON(outDet["audio_tokens"])
            outImage = intFromJSON(outDet["image_tokens"])
        }

        return ResponseUsage(
            inputTokens: input,
            outputTokens: output,
            totalTokens: total,
            inputTextTokens: inText,
            inputAudioTokens: inAudio,
            inputImageTokens: inImage,
            cachedInputTokens: cached,
            cachedInputTextTokens: cachedText,
            cachedInputAudioTokens: cachedAudio,
            cachedInputImageTokens: cachedImage,
            outputTextTokens: outText,
            outputAudioTokens: outAudio,
            outputImageTokens: outImage
        )
    }

    /// Appends `| in_text=… | in_audio=…` etc. only for fields the API provided.
    func detailLogSuffix() -> String {
        var parts: [String] = []
        if let v = inputTextTokens { parts.append("in_text=\(v)") }
        if let v = inputAudioTokens { parts.append("in_audio=\(v)") }
        if let v = inputImageTokens { parts.append("in_image=\(v)") }
        if let v = cachedInputTokens { parts.append("cached_in=\(v)") }
        if let v = cachedInputTextTokens { parts.append("cached_in_text=\(v)") }
        if let v = cachedInputAudioTokens { parts.append("cached_in_audio=\(v)") }
        if let v = cachedInputImageTokens { parts.append("cached_in_image=\(v)") }
        if let v = outputTextTokens { parts.append("out_text=\(v)") }
        if let v = outputAudioTokens { parts.append("out_audio=\(v)") }
        if let v = outputImageTokens { parts.append("out_image=\(v)") }
        guard !parts.isEmpty else { return "" }
        return " | " + parts.joined(separator: " | ")
    }

    private static func intFromJSON(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}
