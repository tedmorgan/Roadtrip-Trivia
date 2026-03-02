import Foundation
import Combine

/// Manages the voice wizard flow for new session setup.
/// Tracks which setup step we're on and validates voice input.
class SessionSetupViewModel: ObservableObject {

    @Published var playerCount: Int?
    @Published var ageBands: [AgeBand] = []
    @Published var difficulty: Difficulty = .tricky
    @Published var isSetupComplete = false

    /// Last-used difficulty persisted across sessions
    private let lastDifficultyKey = "lastUsedDifficulty"

    init() {
        if let saved = UserDefaults.standard.string(forKey: lastDifficultyKey),
           let restored = Difficulty(rawValue: saved) {
            difficulty = restored
        }
    }

    func confirmSetup() {
        UserDefaults.standard.set(difficulty.rawValue, forKey: lastDifficultyKey)
        isSetupComplete = true
    }

    func reset() {
        playerCount = nil
        ageBands = []
        isSetupComplete = false
        // Keep difficulty — defaults to last used per PRD SETUP-03
    }
}
