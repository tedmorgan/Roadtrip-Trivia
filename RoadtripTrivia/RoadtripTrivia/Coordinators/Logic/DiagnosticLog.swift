import Foundation

/// Master switch for the app's on-device diagnostic log files.
///
/// The app writes several plaintext JSONL files into its Documents
/// directory (`debug-f3b222.log`, `debug-30dda1.log`, `mic_gating.log`,
/// `api_usage.log`). They carry spoken transcripts, player answers, team
/// names, and Supabase user ids, so shipping them enabled would put that
/// content on the device in the clear for every player.
///
/// Debug builds log by default. Release builds do not, unless a tester
/// flips the switch in Settings (`setEnabled(true)`), which is how a
/// TestFlight or App Store build can be put back into diagnostic mode
/// without a new binary. Turning the switch off deletes whatever the
/// files already captured.
public enum DiagnosticLog {

    /// `UserDefaults` key holding the tester override. Absent means
    /// "use the build default".
    public static let defaultsKey = "rt_diagnosticLoggingEnabled"

    /// Every file this app may write. Used for the purge.
    public static let fileNames = [
        "debug-f3b222.log",
        "debug-30dda1.log",
        "mic_gating.log",
        "api_usage.log",
    ]

    /// Whether diagnostic files should be written right now.
    ///
    /// Cached rather than re-read from `UserDefaults` on every call: the
    /// mic logger runs on the audio path and is hit per capture buffer.
    /// `setEnabled` refreshes the cache, so the switch still takes effect
    /// immediately.
    public static var isEnabled: Bool {
        if let cachedEnabled { return cachedEnabled }
        let resolved = resolveEnabled()
        cachedEnabled = resolved
        return resolved
    }

    private static var cachedEnabled: Bool?

    private static func resolveEnabled(defaults: UserDefaults = .standard) -> Bool {
        #if DEBUG
        let debugBuild = true
        #else
        let debugBuild = false
        #endif
        return shouldLog(
            isDebugBuild: debugBuild,
            testerOverride: storedOverride(in: defaults)
        )
    }

    /// Turn diagnostic logging on or off and persist the choice.
    ///
    /// Switching off purges the existing files so a device that logged
    /// during testing does not keep the transcripts around afterwards.
    public static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
        cachedEnabled = enabled
        if !enabled {
            purgeLogFiles()
        }
    }

    /// Clear any files left behind by a previous build that logged
    /// unconditionally. Called once at launch.
    public static func applyAtLaunch() {
        if !isEnabled {
            purgeLogFiles()
        }
    }

    /// Delete every diagnostic file from the Documents directory.
    public static func purgeLogFiles() {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return }
        for name in fileNames {
            try? FileManager.default.removeItem(at: documents.appendingPathComponent(name))
        }
    }

    // MARK: - Pure logic (unit tested)

    /// The switch decision.
    ///
    /// - Parameters:
    ///   - isDebugBuild: true for a developer build.
    ///   - testerOverride: the stored setting, or nil when the tester has
    ///     never touched it.
    /// - Returns: true when diagnostic files may be written. A Release
    ///   build with no stored setting logs nothing.
    public static func shouldLog(isDebugBuild: Bool, testerOverride: Bool?) -> Bool {
        testerOverride ?? isDebugBuild
    }

    /// Replace free-form player content with its length.
    ///
    /// Spoken transcripts and typed answers are the most revealing thing
    /// in these files, and the character count is enough to debug the
    /// turn-taking bugs they were added for.
    public static func redact(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "<empty>" }
        return "<redacted \(value.count) chars>"
    }

    /// Shorten an account identifier so cost and session reports can still
    /// group by player without writing the full id.
    public static func pseudonymize(_ identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        return String(identifier.prefix(8))
    }

    /// Payload keys that carry what a player said, what a question asked,
    /// or who the player is. Replaced with a length before anything is
    /// written, so even a tester-enabled log holds no readable content.
    public static let sensitiveKeys: Set<String> = [
        "transcript", "playerAnswer", "answer", "correctAnswer",
        "questionText", "compressed", "first3", "last3",
        "team", "teamName", "email", "username", "raw", "spoken",
    ]

    /// Redact the sensitive entries of a log payload, recursing into
    /// nested dictionaries. Numbers and booleans are left alone: the
    /// round, question index, and timing values are the diagnostic value.
    public static func redactingSensitiveKeys(_ data: [String: Any]) -> [String: Any] {
        var output: [String: Any] = [:]
        for (key, value) in data {
            if sensitiveKeys.contains(key) {
                output[key] = redact(describe(value))
            } else if let nested = value as? [String: Any] {
                output[key] = redactingSensitiveKeys(nested)
            } else {
                output[key] = value
            }
        }
        return output
    }

    private static func describe(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let array = value as? [Any] { return array.map(describe).joined(separator: " ") }
        return String(describing: value)
    }

    static func storedOverride(in defaults: UserDefaults) -> Bool? {
        guard defaults.object(forKey: defaultsKey) != nil else { return nil }
        return defaults.bool(forKey: defaultsKey)
    }
}
