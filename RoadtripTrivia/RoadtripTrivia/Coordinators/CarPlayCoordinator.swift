import CarPlay
import Combine

private extension DateFormatter {
    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()
}

/// Owns the CarPlay template stack (max depth 3 per iOS 26.4 conversational app rules).
///
/// Depth 1: CPListTemplate (Home) — "Start New Game" / "Resume Last Game"
/// Depth 2: CPVoiceControlTemplate (Playing) — all gameplay states
/// Depth 3: CPListTemplate (Score Summary) — optional tap target
class CarPlayCoordinator: NSObject {

    private let interfaceController: CPInterfaceController
    private var realtimeCoordinator: RealtimeGameCoordinator?
    private var playingTemplate: CPVoiceControlTemplate?
    private var stateManager: VoiceControlStateManager?
    private var cancellables = Set<AnyCancellable>()

    /// Track which voice control state is currently active so we can
    /// re-activate it after rebuilding the template.
    private var activeStateID: String = VoiceControlStateID.waiting.rawValue

    /// Debounce timer for template refreshes to avoid overwhelming CarPlay.
    private var refreshWorkItem: DispatchWorkItem?
    private let refreshDebounceInterval: TimeInterval = 0.5

    // MARK: - Services
    private let persistenceService = SessionPersistenceService.shared
    private let gameViewModel = GameViewModel()

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        super.init()
        // Bug 24: Detect when templates are popped (back/cancel button)
        interfaceController.delegate = self
    }

    // MARK: - Start

    func start() {
        let homeTemplate = buildHomeTemplate()
        interfaceController.setRootTemplate(homeTemplate, animated: true, completion: nil)
        observeGameState()
    }

    // MARK: - Home Template (Depth 1)

    private func buildHomeTemplate() -> CPListTemplate {
        var mainItems: [CPListItem] = []

        // Start New Game — always visible
        let startItem = CPListItem(
            text: "Start New Game",
            detailText: "Voice-guided trivia powered by AI"
        )
        startItem.handler = { [weak self] _, completion in
            self?.startNewGame()
            completion()
        }
        mainItems.append(startItem)

        // Resume Last Game — only if a checkpoint exists
        if let checkpoint = persistenceService.loadCheckpoint() {
            let teamLabel = checkpoint.teamName.map { " (\($0))" } ?? ""
            let resumeItem = CPListItem(
                text: "Resume Last Game",
                detailText: "Round \(checkpoint.roundIndex + 1), Q\(checkpoint.questionIndex + 1) — Score: \(checkpoint.totalScore)\(teamLabel)"
            )
            resumeItem.handler = { [weak self] _, completion in
                self?.resumeGame(from: checkpoint)
                completion()
            }
            mainItems.append(resumeItem)
        }

        let mainSection = CPListSection(items: mainItems, header: nil, sectionIndexTitle: nil)

        // Game History section (Bug 8) — show recent completed games
        var sections: [CPListSection] = [mainSection]
        let history = persistenceService.loadSessionHistory()
        if !history.isEmpty {
            let recentGames = Array(history.suffix(5).reversed())
            let historyItems: [CPListItem] = recentGames.map { session in
                let team = session.teamName ?? "Game"
                let date = DateFormatter.shortDate.string(from: session.lastPlayedAt)
                // Bug 16: Use totalQuestionsAnswered to derive round count more accurately.
                // Each standard round has ~5 questions; this avoids depending on rounds array.
                let roundCount = max(session.rounds.count, (session.totalQuestionsAnswered + 4) / 5)
                let roundLabel = roundCount == 1 ? "1 round" : "\(roundCount) rounds"
                let item = CPListItem(
                    text: "\(team) — \(session.totalQuestionsCorrect)/\(session.totalQuestionsAnswered)",
                    detailText: "\(roundLabel) • \(session.difficulty.rawValue) • \(date)"
                )
                // Bug 8/18/22: Tapping a past game starts a new game with the same config
                item.handler = { [weak self] _, completion in
                    self?.startNewGameWithConfig(
                        difficulty: session.difficulty,
                        playerCount: session.playerCount,
                        ageBands: session.ageBands,
                        teamName: session.teamName
                    )
                    completion()
                }
                return item
            }
            let historySection = CPListSection(items: historyItems, header: "Recent Games", sectionIndexTitle: nil)
            sections.append(historySection)
        }

        let template = CPListTemplate(title: "Roadtrip Trivia", sections: sections)
        return template
    }

    // MARK: - Playing Template (Depth 2)

    private func pushPlayingTemplate() {
        let manager = VoiceControlStateManager()
        self.stateManager = manager

        // Wire up the refresh callback — when score data changes,
        // rebuild the template with fresh states.
        manager.onNeedsRefresh = { [weak self] in
            self?.scheduleTemplateRefresh()
        }

        let states = manager.buildStates()
        let template = CPVoiceControlTemplate(voiceControlStates: states)
        self.playingTemplate = template
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    /// Debounced template rebuild. Prevents rapid-fire refreshes (e.g., lightning timer
    /// ticking every second) from overwhelming CarPlay's template rate limits.
    private func scheduleTemplateRefresh() {
        refreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.rebuildPlayingTemplate()
        }
        refreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + refreshDebounceInterval, execute: work)
    }

    /// Pop the current voice control template and push a new one with updated
    /// score data baked into the titleVariants. Uses non-animated transitions
    /// to minimize visual disruption.
    private func rebuildPlayingTemplate() {
        guard let manager = stateManager, playingTemplate != nil else { return }

        let savedStateID = activeStateID
        let newStates = manager.buildStates()
        let newTemplate = CPVoiceControlTemplate(voiceControlStates: newStates)

        // Pop old template (non-animated) and push new one (non-animated)
        interfaceController.popTemplate(animated: false) { [weak self] _, _ in
            guard let self else { return }
            self.playingTemplate = newTemplate
            self.interfaceController.pushTemplate(newTemplate, animated: false) { [weak self] _, _ in
                // Re-activate the state that was showing before the swap
                self?.playingTemplate?.activateVoiceControlState(withIdentifier: savedStateID)
            }
        }
        print("[CarPlay] Template rebuilt with updated score display")
    }

    // MARK: - Score Summary (Depth 3) — CP-SCORE-04/05

    func pushScoreSummary() {
        let session = gameViewModel.currentSession
        guard let session else { return }

        let items = [
            CPListItem(text: "Total Score", detailText: "\(session.totalQuestionsCorrect)/\(session.totalQuestionsAnswered)"),
            CPListItem(text: "Rounds Played", detailText: "\(session.rounds.count)"),
            CPListItem(text: "Hints Used", detailText: "\(session.hintsUsed)"),
            CPListItem(text: "Challenges", detailText: "\(session.challengesUsed)")
        ]

        let section = CPListSection(items: items)
        let template = CPListTemplate(title: "Score Summary", sections: [section])
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Game Flow

    private func startNewGame() {
        pushPlayingTemplate()

        // Create the Realtime coordinator with the state manager for score display updates.
        realtimeCoordinator = RealtimeGameCoordinator(
            gameViewModel: gameViewModel,
            stateManager: stateManager!
        )
        realtimeCoordinator?.startNewGame()
    }

    /// Start a new game with pre-configured settings from a past game (Bugs 8, 18, 22).
    /// The LLM skips setup questions and goes straight to Round 1.
    private func startNewGameWithConfig(
        difficulty: Difficulty,
        playerCount: Int,
        ageBands: [AgeBand],
        teamName: String?
    ) {
        pushPlayingTemplate()
        realtimeCoordinator = RealtimeGameCoordinator(
            gameViewModel: gameViewModel,
            stateManager: stateManager!
        )
        realtimeCoordinator?.startNewGameWithConfig(
            difficulty: difficulty,
            playerCount: playerCount,
            ageBands: ageBands,
            teamName: teamName
        )
    }

    private func resumeGame(from checkpoint: SessionCheckpoint) {
        pushPlayingTemplate()
        realtimeCoordinator = RealtimeGameCoordinator(
            gameViewModel: gameViewModel,
            stateManager: stateManager!
        )
        realtimeCoordinator?.resumeGame(from: checkpoint)
    }

    // MARK: - Observe State Changes

    private func observeGameState() {
        gameViewModel.$currentPhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self else { return }
                self.updateVoiceControlState(for: phase)

                // When the game ends, show score summary briefly then return home
                if phase == .gameOver {
                    self.pushScoreSummary()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
                        self?.returnToHome()
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func updateVoiceControlState(for phase: GamePhase) {
        let stateID = phase.voiceControlStateID.rawValue
        activeStateID = stateID
        playingTemplate?.activateVoiceControlState(withIdentifier: stateID)
    }

    /// Pop back to the root and rebuild the home template with fresh checkpoint state.
    private func returnToHome() {
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        realtimeCoordinator?.disconnect()
        realtimeCoordinator = nil
        playingTemplate = nil
        stateManager?.onNeedsRefresh = nil
        stateManager?.reset()
        stateManager = nil

        let freshHome = buildHomeTemplate()
        interfaceController.popToRootTemplate(animated: true) { [weak self] _, _ in
            self?.interfaceController.setRootTemplate(freshHome, animated: false, completion: nil)
        }
    }

    // MARK: - Disconnect

    func handleDisconnect() {
        refreshWorkItem?.cancel()
        refreshWorkItem = nil

        // Bug 22: Save the in-progress session to history so it shows in Recent Games
        if let session = gameViewModel.currentSession, session.totalQuestionsAnswered > 0 {
            persistenceService.saveCompletedSession(session)
        }

        realtimeCoordinator?.disconnect()
        realtimeCoordinator = nil
        playingTemplate = nil
        stateManager?.onNeedsRefresh = nil
        stateManager?.reset()
        stateManager = nil
    }
}

// MARK: - CPInterfaceControllerDelegate (Bug 24)

extension CarPlayCoordinator: CPInterfaceControllerDelegate {
    func templateWillDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        // When the playing template (voice control) is popped via back/cancel button,
        // cleanly disconnect the game session so audio stops and resources are freed.
        if aTemplate is CPVoiceControlTemplate && aTemplate === playingTemplate {
            print("[CarPlay] Voice control template popped — disconnecting game session")
            handleDisconnect()
        }
    }
}
