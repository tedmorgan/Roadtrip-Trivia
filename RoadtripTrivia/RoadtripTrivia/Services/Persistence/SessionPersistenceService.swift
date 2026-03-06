import Foundation

/// Manages session state persistence for resume-last-game functionality.
/// Per PRD RESUME-01: save state after every question and scoring event.
/// Per PRD RESUME-02: checkpoint schema includes session id, round, question index,
/// score, hints, challenges, category, location label, lightning time, phase.
///
/// Uses local storage for MVP (UserDefaults + file). CloudKit sync for production.
class SessionPersistenceService: ObservableObject {

    static let shared = SessionPersistenceService()

    private let checkpointKey = "sessionCheckpoint"
    private let sessionHistoryKey = "sessionHistory"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    // MARK: - Checkpoint (Resume Last Game)

    /// Save checkpoint after every question/scoring event.
    /// Must be efficient and non-blocking per PRD CPUI-004.
    func saveCheckpoint(_ checkpoint: SessionCheckpoint) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let data = try? self?.encoder.encode(checkpoint) else { return }
            UserDefaults.standard.set(data, forKey: self?.checkpointKey ?? "")
        }
    }

    /// Load the most recent checkpoint for "Resume Last Game".
    func loadCheckpoint() -> SessionCheckpoint? {
        guard let data = UserDefaults.standard.data(forKey: checkpointKey) else { return nil }
        return try? decoder.decode(SessionCheckpoint.self, from: data)
    }

    /// Clear checkpoint when game completes normally.
    func clearCheckpoint() {
        UserDefaults.standard.removeObject(forKey: checkpointKey)
    }

    /// Returns true if there's a resumable session.
    var hasResumableSession: Bool {
        return loadCheckpoint() != nil
    }

    // MARK: - Full Session Persistence

    /// Save a completed session for history/analytics.
    /// Deduplicates by session ID to prevent the same game appearing multiple times.
    func saveCompletedSession(_ session: TriviaSession) {
        var history = loadSessionHistory()
        if history.contains(where: { $0.id == session.id }) {
            return
        }
        history.append(session)
        if history.count > 50 {
            history = Array(history.suffix(50))
        }
        if let data = try? encoder.encode(history) {
            UserDefaults.standard.set(data, forKey: sessionHistoryKey)
        }
    }

    func loadSessionHistory() -> [TriviaSession] {
        guard let data = UserDefaults.standard.data(forKey: sessionHistoryKey) else { return [] }
        return (try? decoder.decode([TriviaSession].self, from: data)) ?? []
    }

    // MARK: - Account Deletion (AUTH-006)

    func clearAllData() {
        clearCheckpoint()
        UserDefaults.standard.removeObject(forKey: sessionHistoryKey)
    }
}
