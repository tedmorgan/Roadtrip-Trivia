import Foundation

/// Logs GPT-realtime API usage (calls sent, responses received, token counts)
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

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        logFileURL = docs.appendingPathComponent("api_usage.log")

        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }

        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()

        writeEntry("=== API Usage Logger started ===")
    }

    deinit {
        fileHandle?.closeFile()
    }

    /// The path to the log file on disk.
    var logFilePath: String { logFileURL.path }

    // MARK: - Logging Methods

    /// Log an outgoing API call (client → server).
    func logOutgoingEvent(type: String, payloadBytes: Int) {
        let estimatedTokens = max(1, payloadBytes / 4)
        writeEntry("[SEND] type=\(type) | payload_bytes=\(payloadBytes) | est_input_tokens=\(estimatedTokens)")
    }

    /// Log a session.update which contains the system prompt (major token cost).
    func logSessionUpdate(promptLength: Int, toolCount: Int) {
        let estimatedTokens = max(1, promptLength / 4)
        writeEntry("[SEND] type=session.update | prompt_chars=\(promptLength) | est_prompt_tokens=\(estimatedTokens) | tools=\(toolCount)")
    }

    /// Log an incoming API event (server → client).
    func logIncomingEvent(type: String, payloadBytes: Int) {
        writeEntry("[RECV] type=\(type) | payload_bytes=\(payloadBytes)")
    }

    /// Log a response.done event with usage/token data if available.
    func logResponseDone(status: String, usage: ResponseUsage?) {
        if let usage = usage {
            writeEntry("[RECV] type=response.done | status=\(status) | input_tokens=\(usage.inputTokens) | output_tokens=\(usage.outputTokens) | total_tokens=\(usage.totalTokens)")
        } else {
            writeEntry("[RECV] type=response.done | status=\(status) | tokens=unavailable")
        }
    }

    /// Log an audio chunk (aggregated, not per-chunk).
    func logAudioSent(chunkCount: Int, totalBytes: Int) {
        writeEntry("[SEND] type=audio_chunks | chunks=\(chunkCount) | total_bytes=\(totalBytes)")
    }

    /// Log a connection event.
    func logConnection(event: String) {
        writeEntry("[CONN] \(event)")
    }

    // MARK: - Private

    private func writeEntry(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async { [weak self] in
            self?.fileHandle?.write(data)
        }
    }
}

/// Token usage data extracted from response.done events.
struct ResponseUsage {
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
}
