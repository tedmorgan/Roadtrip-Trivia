import Foundation
import Combine

// #region agent log helper
private let _debugLogPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first! + "/debug-f3b222.log"
private func _dbg(_ hyp: String, _ loc: String, _ msg: String, _ data: [String: Any]) {
    let entry: [String: Any] = ["sessionId":"f3b222","hypothesisId":hyp,"location":loc,"message":msg,"data":data,"timestamp":Date().timeIntervalSince1970*1000]
    guard let d = try? JSONSerialization.data(withJSONObject: entry), let line = String(data: d, encoding: .utf8) else { return }
    print("[DBG-f3b222] \(hyp) | \(msg) | \(data)")
    if !FileManager.default.fileExists(atPath: _debugLogPath) { FileManager.default.createFile(atPath: _debugLogPath, contents: nil) }
    guard let h = FileHandle(forWritingAtPath: _debugLogPath) else { return }
    h.seekToEndOfFile(); h.write((line+"\n").data(using: .utf8)!); h.closeFile()
}
// #endregion

/// Orchestrates a Realtime API-powered trivia game.
///
/// Unlike the old GameFlowCoordinator (26-phase state machine), this coordinator
/// delegates conversation flow entirely to the LLM. It only handles:
/// - Starting/stopping the Realtime session
/// - Responding to LLM function calls (score tracking, UI updates, persistence)
/// - Enforcing hard game limits the LLM shouldn't violate
/// - Network error recovery
class RealtimeGameCoordinator: ObservableObject {

    // MARK: - Dependencies

    private let gameViewModel: GameViewModel
    private let stateManager: VoiceControlStateManager
    private let sessionManager = RealtimeSessionManager()
    private let audioService = AudioStreamingService()
    private let audioManager = AudioSessionManager.shared
    private let locationService = LocationService.shared
    private let persistence = SessionPersistenceService.shared
    private let connectionMonitor = ConnectionMonitor.shared
    private let apiLogger = APIUsageLogger.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Game Tracking

    /// Current round number (1-based), tracked server-side via function calls.
    private var currentRoundNumber = 0
    private var currentQuestionIndex = 0
    private var totalCorrect = 0
    private var totalAnswered = 0
    private var currentCategory = ""
    private var roundCorrect = 0
    private var roundAnswered = 0
    private var hasSubmittedLeaderboard = false

    // Lightning round timer
    private var lightningTimer: Timer?
    private var lightningCorrect = 0
    private var lightningAnswered = 0
    private var isLightningRound = false
    private var lightningSecondsRemaining = 120
    private var lightningEndCutoffWork: DispatchWorkItem?
    private var lightningAnnouncedButNotStarted = false
    /// Merged into the next `flushPendingResults` `response.create` (avoids duplicate create vs. `response.cancel`).
    private var pendingLightningFlushInstructions: String?
    /// After the 2:00 timer hits zero, block `startLightningTimer` from the B1 path so wrap-up `report_score(isLightning:true)` cannot restart a new lightning round.
    private var suppressLightningToolCallRestart = false

    // Per-round hint/challenge limits (Bug 20)
    private var roundHintsUsed = 0
    private var roundChallengesUsed = 0
    private let maxHintsPerRound = 2
    private let maxChallengesPerRound = 1

    // Question history (Bug 7) — tracks questions asked to avoid repeats
    private var questionHistory: [String] = []
    private let questionHistoryKey = "askedQuestionHistory"

    // Bug 23: Track whether user has played before (for first-time instructions)
    private let hasPlayedBeforeKey = "hasPlayedBefore"
    private var isFirstGameSession = false

    // MARK: - Init

    init(gameViewModel: GameViewModel, stateManager: VoiceControlStateManager) {
        self.gameViewModel = gameViewModel
        self.stateManager = stateManager
        observeRealtimeEvents()
        observeInterruptions()
        observeConnectionQuality()
    }

    deinit {
        disconnect()
    }

    // MARK: - Start New Game

    func startNewGame() {
        // Check round budget BEFORE connecting to OpenAI (saves API costs)
        guard RoundTracker.shared.canPlayRound else {
            print("[RealtimeGame] No rounds available — showing paywall")
            NotificationCenter.default.post(name: RoundTracker.showPaywallNotification, object: nil)
            return
        }

        // Consume the first round upfront
        guard RoundTracker.shared.consumeOneRound() else {
            NotificationCenter.default.post(name: RoundTracker.showPaywallNotification, object: nil)
            return
        }

        gameViewModel.transition(to: .connecting)
        gameViewModel.resetDisplayProperties()

        // Load question history to avoid repeats (Bug 7)
        loadQuestionHistory()

        // Bug 23: Check if this is the user's first game
        let isFirstGame = !UserDefaults.standard.bool(forKey: hasPlayedBeforeKey)
        isFirstGameSession = isFirstGame

        let config = SystemPromptBuilder.buildSessionConfig(
            locationLabel: locationService.currentLocationLabel,
            questionHistory: questionHistory.isEmpty ? nil : questionHistory,
            isFirstGame: isFirstGame,
            roundsRemaining: RoundTracker.shared.totalRoundsAvailable
        )

        Task { @MainActor in
            do {
                audioService.configure(sessionManager: sessionManager)
                sessionManager.autoReconnectDisabled = true
                try await sessionManager.connect(sessionConfig: config)
                try audioService.startStreaming()
                gameViewModel.transition(to: .playing)

                try await sessionManager.send(.responseCreate(instructions: nil))
                print("[RealtimeGame] Game started")
            } catch {
                print("[RealtimeGame] Failed to start: \(error)")
                gameViewModel.transition(to: .idle)
                gameViewModel.connectionError = error.localizedDescription
            }
        }
    }

    // MARK: - Resume Game

    func resumeGame(from checkpoint: SessionCheckpoint) {
        // Check round budget — resuming still costs a round for the current round
        guard RoundTracker.shared.canPlayRound else {
            print("[RealtimeGame] No rounds available — showing paywall")
            NotificationCenter.default.post(name: RoundTracker.showPaywallNotification, object: nil)
            return
        }
        guard RoundTracker.shared.consumeOneRound() else {
            NotificationCenter.default.post(name: RoundTracker.showPaywallNotification, object: nil)
            return
        }

        gameViewModel.transition(to: .connecting)
        gameViewModel.resetDisplayProperties()
        gameViewModel.restoreFromCheckpoint(checkpoint)

        // Restore tracking state
        currentRoundNumber = checkpoint.roundIndex + 1
        currentQuestionIndex = checkpoint.questionIndex
        totalCorrect = checkpoint.totalScore
        totalAnswered = checkpoint.questionIndex + (checkpoint.roundIndex * 5)
        currentCategory = checkpoint.currentCategory

        // Bug 9: Restore team name on CarPlay display
        stateManager.setTeamName(checkpoint.teamName)

        // Bug 32/36: Restore iPhone display properties from checkpoint
        gameViewModel.displayTotalCorrect = checkpoint.totalScore
        gameViewModel.displayRoundCorrect = 0
        gameViewModel.displayRoundNumber = checkpoint.roundIndex + 1
        gameViewModel.displayCategory = checkpoint.currentCategory
        gameViewModel.displayTeamName = checkpoint.teamName ?? ""
        gameViewModel.displayQuestionInRound = checkpoint.questionIndex + 1

        // Load question history to avoid repeats (Bug 7)
        loadQuestionHistory()

        let resumeContext = ResumeContext(from: checkpoint)
        // Resumed games are never first-time
        let config = SystemPromptBuilder.buildSessionConfig(
            locationLabel: checkpoint.locationLabel,
            resumeContext: resumeContext,
            questionHistory: questionHistory.isEmpty ? nil : questionHistory,
            isFirstGame: false,
            roundsRemaining: RoundTracker.shared.totalRoundsAvailable
        )

        Task { @MainActor in
            do {
                audioService.configure(sessionManager: sessionManager)
                sessionManager.autoReconnectDisabled = true
                try await sessionManager.connect(sessionConfig: config)
                try audioService.startStreaming()
                gameViewModel.transition(to: .playing)

                try await sessionManager.send(.responseCreate(instructions: nil))
                print("[RealtimeGame] Game resumed from round \(currentRoundNumber), Q\(currentQuestionIndex + 1)")
            } catch {
                print("[RealtimeGame] Failed to resume: \(error)")
                gameViewModel.transition(to: .idle)
                gameViewModel.connectionError = error.localizedDescription
            }
        }
    }

    // MARK: - Start New Game With Pre-configured Settings (Bugs 8, 18, 22)

    func startNewGameWithConfig(
        difficulty: Difficulty,
        playerCount: Int,
        ageBands: [AgeBand],
        teamName: String?,
        previousTotalCorrect: Int = 0,
        previousRoundCount: Int = 0
    ) {
        // Check round budget before connecting
        guard RoundTracker.shared.canPlayRound else {
            print("[RealtimeGame] No rounds available — showing paywall")
            NotificationCenter.default.post(name: RoundTracker.showPaywallNotification, object: nil)
            return
        }
        guard RoundTracker.shared.consumeOneRound() else {
            NotificationCenter.default.post(name: RoundTracker.showPaywallNotification, object: nil)
            return
        }

        gameViewModel.transition(to: .connecting)
        gameViewModel.resetDisplayProperties()
        gameViewModel.createSession(
            difficulty: difficulty,
            playerCount: playerCount,
            ageBands: ageBands,
            teamName: teamName
        )

        stateManager.setTeamName(teamName)
        gameViewModel.displayTeamName = teamName ?? ""
        if previousTotalCorrect > 0 {
            totalCorrect = previousTotalCorrect
            gameViewModel.displayTotalCorrect = previousTotalCorrect
            currentRoundNumber = previousRoundCount
            gameViewModel.displayRoundNumber = previousRoundCount + 1
        }
        loadQuestionHistory()

        let preconfig = PreConfiguredContext(
            difficulty: difficulty,
            playerCount: playerCount,
            ageBands: ageBands,
            teamName: teamName,
            previousTotalCorrect: previousTotalCorrect,
            previousRoundCount: previousRoundCount
        )

        // Bug 18/23: Pre-configured games are always returning players
        let config = SystemPromptBuilder.buildSessionConfig(
            locationLabel: locationService.currentLocationLabel,
            preconfiguredContext: preconfig,
            questionHistory: questionHistory.isEmpty ? nil : questionHistory,
            isFirstGame: false,
            roundsRemaining: RoundTracker.shared.totalRoundsAvailable
        )

        Task { @MainActor in
            do {
                audioService.configure(sessionManager: sessionManager)
                sessionManager.autoReconnectDisabled = true
                try await sessionManager.connect(sessionConfig: config)
                try audioService.startStreaming()
                gameViewModel.transition(to: .playing)

                try await sessionManager.send(.responseCreate(instructions: nil))
                print("[RealtimeGame] Game started with pre-configured settings: \(difficulty.rawValue), team: \(teamName ?? "")")
            } catch {
                print("[RealtimeGame] Failed to start: \(error)")
                gameViewModel.transition(to: .idle)
                gameViewModel.connectionError = error.localizedDescription
            }
        }
    }

    // MARK: - Disconnect

    func disconnect() {
        stopLightningTimer()
        pendingLightningFlushInstructions = nil
        suppressLightningToolCallRestart = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        pausedByConnectionLoss = false
        cancellables.removeAll()          // Bug 29/31: prevent duplicate subscriptions on resume
        audioService.stopStreaming()
        sessionManager.disconnect()
        audioManager.deactivate()
    }

    // MARK: - Event Handling

    private func observeRealtimeEvents() {
        sessionManager.eventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleEvent(event)
            }
            .store(in: &cancellables)

        // Observe WebSocket connection state — triggers coordinator-managed reconnect
        sessionManager.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self else { return }
                self.gameViewModel.isConnected = connected

                let phase = self.gameViewModel.currentPhase
                guard phase != .idle && phase != .gameOver && phase != .connecting else { return }

                if !connected && !self.pausedByConnectionLoss && phase != .paused {
                    // WebSocket dropped while game is active — pause and schedule context-aware reconnect.
                    // NWPathMonitor may still show .satisfied on degraded cellular, so we handle it here.
                    print("[RealtimeGame] WebSocket disconnected during gameplay — pausing for reconnect")
                    // #region agent log
                    _dbg("E1","RealtimeGameCoordinator.swift:ws_drop","WebSocket isConnected→false during gameplay",["phase":"\(phase)","round":self.currentRoundNumber,"question":self.currentQuestionIndex])
                    // #endregion
                    self.pausedByConnectionLoss = true
                    self.lightningTimer?.invalidate()
                    self.lightningTimer = nil
                    self.audioService.stopStreaming()
                    self.gameViewModel.transition(to: .paused)
                    self.connectionMonitor.speakOffline("Hold on, we lost the connection. Reconnecting now.")
                    self.scheduleReconnect()
                }
            }
            .store(in: &cancellables)
    }

    private func handleEvent(_ event: RealtimeServerEvent) {
        switch event {
        case .responseFunctionCallArgumentsDone(let callId, let name, let arguments):
            handleFunctionCall(callId: callId, name: name, arguments: arguments)

        case .responseDone:
            // Flush any batched function call results so the LLM continues
            flushPendingResults()

        case .inputAudioBufferSpeechStarted:
            gameViewModel.transition(to: .listening)

        case .responseAudioDelta:
            let phase = gameViewModel.currentPhase
            if phase == .listening || phase == .playing || phase == .waiting {
                gameViewModel.transition(to: .speaking)
            }

        case .responseAudioDone:
            if gameViewModel.currentPhase == .speaking {
                gameViewModel.transition(to: .listening)
            }

        case .responseAudioTranscriptDone(let text):
            // Detect lightning round *start* from transcript (not wrap-up: "total up your lightning round score").
            if !isLightningRound && !lightningAnnouncedButNotStarted
                && Self.transcriptSuggestsStartingLightningRound(text) {
                lightningAnnouncedButNotStarted = true
                suppressLightningToolCallRestart = false
                gameViewModel.lightningSecondsRemaining = 120
                print("[RealtimeGame] Lightning round detected from transcript")
                // #region agent log
                _dbg("A1","RealtimeGameCoordinator.swift:298","TRANSCRIPT set announced=true + UI shows 2:00",["transcript":String(text.prefix(200)),"isLightningRound":self.isLightningRound,"secs":self.lightningSecondsRemaining])
                // #endregion
            }

        case .error(let message, let code):
            print("[RealtimeGame] Error [\(code ?? "?")]: \(message)")
            if message.contains("session_expired") || message.contains("invalid_api_key") {
                handleNetworkError()
            } else if code == "reconnect_failed" {
                print("[RealtimeGame] Reconnection exhausted — ending session gracefully")
                handleNetworkError()
            }

        default:
            break
        }
    }

    // MARK: - Function Call Dispatch

    private func handleFunctionCall(callId: String, name: String, arguments: String) {
        print("[RealtimeGame] Function call: \(name)(\(arguments.prefix(100)))")

        guard let data = arguments.data(using: .utf8) else {
            submitResult(callId: callId, result: ["error": "Invalid arguments"])
            return
        }

        switch name {
        case "set_game_config":
            handleSetGameConfig(callId: callId, data: data)

        case "report_score":
            handleReportScore(callId: callId, data: data)

        case "get_location":
            handleGetLocation(callId: callId)

        case "end_game":
            handleEndGame(callId: callId, data: data)

        default:
            print("[RealtimeGame] Unknown function: \(name)")
            submitResult(callId: callId, result: ["error": "Unknown function"])
        }
    }

    // MARK: - Function Handlers

    private func handleSetGameConfig(callId: String, data: Data) {
        guard let args = try? JSONDecoder().decode(SetGameConfigArgs.self, from: data) else {
            submitResult(callId: callId, result: ["error": "Invalid arguments"])
            return
        }

        // Map string difficulty to enum
        let difficulty: Difficulty
        switch args.difficulty.lowercased() {
        case "simple": difficulty = .simple
        case "tricky": difficulty = .tricky
        case "wicked_hard", "hard": difficulty = .hard
        case "einstein": difficulty = .einstein
        default: difficulty = .tricky
        }

        // Map string age bands to enums
        let ageBands: [AgeBand] = args.ageBands.compactMap { band in
            switch band.lowercased() {
            case "kids": return .kids
            case "teens": return .teens
            case "adults": return .adults
            case "mixed": return .mixed
            default: return nil
            }
        }

        // Update the game session with the player's choices
        gameViewModel.createSession(
            difficulty: difficulty,
            playerCount: args.playerCount,
            ageBands: ageBands.isEmpty ? [.adults] : ageBands,
            teamName: args.teamName
        )

        // Bug 9: Pass team name to state manager for CarPlay display + iPhone display
        stateManager.setTeamName(args.teamName)
        gameViewModel.displayTeamName = args.teamName ?? ""

        // Update API usage context for cost analysis — this is still \"intro\" phase
        let userId = AuthService.shared.currentUserID
        apiLogger.setContext(
            userId: userId,
            teamName: args.teamName,
            round: currentRoundNumber,
            question: currentQuestionIndex + 1,
            category: currentCategory,
            difficulty: difficulty.rawValue,
            phase: "intro"
        )

        // Bug 23: Mark that the user has played at least one game
        UserDefaults.standard.set(true, forKey: hasPlayedBeforeKey)

        print("[RealtimeGame] Config set: \(args.playerCount) players, \(args.difficulty), team: \(args.teamName ?? ""), ages: \(args.ageBands)")

        // Send trimmed session config with only the chosen difficulty section
        let trimmedConfig = SystemPromptBuilder.buildTrimmedSessionConfig(
            locationLabel: locationService.currentLocationLabel,
            difficulty: difficulty,
            questionHistory: questionHistory.isEmpty ? nil : questionHistory,
            isFirstGame: isFirstGameSession,
            roundsRemaining: RoundTracker.shared.totalRoundsAvailable
        )
        Task {
            try? await sessionManager.send(.sessionUpdate(trimmedConfig))
            print("[RealtimeGame] Session updated with trimmed prompt for \(difficulty.rawValue)")
        }

        submitResult(callId: callId, result: [
            "acknowledged": true,
            "difficulty": args.difficulty,
            "playerCount": args.playerCount,
            "ageBands": args.ageBands
        ])
    }

    private func handleReportScore(callId: String, data: Data) {
        guard let args = try? JSONDecoder().decode(ReportScoreArgs.self, from: data) else {
            submitResult(callId: callId, result: ["error": "Invalid arguments"])
            return
        }

        // Lightning round detection from isLightning field
        let reportedLightning = args.isLightning ?? false
        // #region agent log
        _dbg("B1_B2_C2","RealtimeGameCoordinator.swift:435","report_score lightning check",["reportedLightning":reportedLightning,"isLightningRound":self.isLightningRound,"announced":self.lightningAnnouncedButNotStarted,"argsIsLightning":String(describing:args.isLightning),"roundNumber":String(describing:args.roundNumber),"questionIndex":args.questionIndex,"category":args.category ?? "nil","secs":self.lightningSecondsRemaining])
        // #endregion
        if args.isLightning == false {
            suppressLightningToolCallRestart = false
        }

        if reportedLightning && !isLightningRound && !lightningAnnouncedButNotStarted && !suppressLightningToolCallRestart {
            lightningAnnouncedButNotStarted = false
            startLightningTimer()
            // #region agent log
            _dbg("B1","RealtimeGameCoordinator.swift:442","startLightningTimer from isLightning=true (no prior announcement)",["roundNumber":String(describing:args.roundNumber)])
            // #endregion
        } else if reportedLightning && lightningAnnouncedButNotStarted {
            lightningAnnouncedButNotStarted = false
            startLightningTimer()
            // #region agent log
            _dbg("A1","RealtimeGameCoordinator.swift:448","startLightningTimer after transcript announcement",["roundNumber":String(describing:args.roundNumber)])
            // #endregion
        } else if args.isLightning == false && isLightningRound {
            // Only explicit false ends lightning — nil means "field omitted" and must NOT stop the timer.
            // #region agent log
            _dbg("C2","RealtimeGameCoordinator.swift:452","STOPPING lightning — isLightning explicitly false while timer active",["roundNumber":String(describing:args.roundNumber),"questionIndex":args.questionIndex,"secs":self.lightningSecondsRemaining])
            // #endregion
            stopLightningTimer()
        }

        totalAnswered += 1
        roundAnswered += 1
        if args.isCorrect {
            totalCorrect += 1
            roundCorrect += 1
        }
        currentQuestionIndex = args.questionIndex

        let isHintOrChallenge = (args.wasHint ?? false) || (args.wasChallenge ?? false)
        if !isHintOrChallenge {
            if args.isCorrect {
                playCorrectSound()
            } else {
                playIncorrectSound()
            }
        }

        if isLightningRound {
            lightningAnswered += 1
            if args.isCorrect {
                lightningCorrect += 1
            }
        }

        var actualHint = args.wasHint ?? false
        var actualChallenge = args.wasChallenge ?? false
        var hintDenied = false
        var challengeDenied = false
        if actualHint {
            if roundHintsUsed >= maxHintsPerRound {
                actualHint = false
                hintDenied = true
                print("[RealtimeGame] Hint DENIED — over limit (\(roundHintsUsed)/\(maxHintsPerRound))")
            } else {
                roundHintsUsed += 1
            }
        }
        if actualChallenge {
            if roundChallengesUsed >= maxChallengesPerRound {
                actualChallenge = false
                challengeDenied = true
                print("[RealtimeGame] Challenge DENIED — over limit (\(roundChallengesUsed)/\(maxChallengesPerRound))")
            } else {
                roundChallengesUsed += 1
            }
        }

        if let questionText = args.questionText, !questionText.isEmpty {
            questionHistory.append(questionText)
            if questionHistory.count > 50 {
                questionHistory = Array(questionHistory.suffix(50))
            }
            saveQuestionHistory()
        }

        gameViewModel.recordAnswerFromRealtime(
            answer: args.playerAnswer ?? "",
            isCorrect: args.isCorrect,
            wasHint: actualHint,
            wasChallenge: actualChallenge
        )

        // Refresh API usage context now that round/question may have advanced.
        // This marks logs as \"trivia\" (actual gameplay questions), distinct from intro/setup.
        let session = gameViewModel.currentSession
        let userId = AuthService.shared.currentUserID
        apiLogger.setContext(
            userId: userId,
            teamName: session?.teamName,
            round: currentRoundNumber,
            question: currentQuestionIndex + 1,
            category: currentCategory,
            difficulty: session?.difficulty.rawValue,
            phase: "trivia"
        )

        // Transition to showingResult (previously done by update_ui)
        gameViewModel.transition(to: .showingResult)

        if isLightningRound {
            stateManager.updateLightningTimer(
                secondsRemaining: lightningSecondsRemaining,
                lightningCorrect: lightningCorrect
            )
        } else {
            stateManager.updateScore(
                correct: totalCorrect,
                answered: totalAnswered,
                questionInRound: args.questionIndex + 1,
                totalInRound: 5
            )
        }
        gameViewModel.displayRoundCorrect = roundCorrect
        gameViewModel.displayTotalCorrect = totalCorrect
        gameViewModel.displayQuestionInRound = args.questionIndex + 1

        // Checkpoint logic (merged from checkpoint_game)
        if let roundNumber = args.roundNumber {
            let reportedCategory = args.category ?? currentCategory

            let isNewRound = roundNumber != currentRoundNumber && currentRoundNumber > 0
            if isNewRound {
                // Consume a round credit for each new round within the session
                if !RoundTracker.shared.consumeOneRound() {
                    // Out of rounds — tell the LLM to end the game
                    print("[RealtimeGame] Round limit reached mid-session — forcing end")
                    submitResult(callId: callId, result: [
                        "error": "ROUND_LIMIT_REACHED",
                        "message": "Player has used all available rounds. You MUST call end_game now. Do NOT ask another question. Tell the player they've used all their rounds and suggest getting more from the app."
                    ])
                    NotificationCenter.default.post(name: RoundTracker.roundLimitReachedNotification, object: nil)
                    return
                }

                gameViewModel.completeCurrentRound()
                stateManager.showRoundSummary(
                    roundScore: roundCorrect,
                    roundTotal: roundAnswered,
                    cumCorrect: totalCorrect,
                    cumAnswered: totalAnswered,
                    hints: gameViewModel.currentSession?.hintsUsed ?? 0,
                    challenges: gameViewModel.currentSession?.challengesUsed ?? 0
                )
                roundCorrect = 0
                roundAnswered = 0
                roundHintsUsed = 0
                roundChallengesUsed = 0
            }

            currentRoundNumber = roundNumber
            currentCategory = reportedCategory

            // Fallback lightning detection from round pattern
            if !isLightningRound && currentRoundNumber > 4 && (currentRoundNumber - 1) % 5 == 0 {
                print("[RealtimeGame] Fallback: detected lightning round from round number \(currentRoundNumber)")
                // #region agent log
                _dbg("A2_B3","RealtimeGameCoordinator.swift:580","FALLBACK startLightningTimer from round pattern",["currentRoundNumber":currentRoundNumber,"reportedLightning":reportedLightning])
                // #endregion
                suppressLightningToolCallRestart = false
                startLightningTimer()
            }

            let roundType: RoundType = isLightningRound ? .lightning : .standard
            gameViewModel.startNewRoundIfNeeded(roundNumber: roundNumber, category: currentCategory, type: roundType)

            stateManager.updateRound(number: currentRoundNumber, category: currentCategory)
            gameViewModel.displayRoundNumber = currentRoundNumber
            gameViewModel.displayCategory = currentCategory

            let checkpoint = SessionCheckpoint(
                sessionID: gameViewModel.currentSession?.id ?? UUID(),
                roundIndex: roundNumber - 1,
                questionIndex: args.questionIndex,
                totalScore: totalCorrect,
                hintsUsed: gameViewModel.currentSession?.hintsUsed ?? 0,
                challengesUsed: gameViewModel.currentSession?.challengesUsed ?? 0,
                currentCategory: currentCategory,
                locationLabel: locationService.currentLocationLabel,
                lightningTimeRemaining: isLightningRound ? TimeInterval(lightningSecondsRemaining) : nil,
                difficulty: gameViewModel.currentSession?.difficulty ?? .tricky,
                playerCount: gameViewModel.currentSession?.playerCount ?? 1,
                ageBands: gameViewModel.currentSession?.ageBands ?? [.adults],
                teamName: gameViewModel.currentSession?.teamName,
                savedAt: Date()
            )
            DispatchQueue.global(qos: .utility).async { [persistence] in
                persistence.saveCheckpoint(checkpoint)
            }
        }

        var result: [String: Any] = [
            "acknowledged": true,
            "totalCorrect": totalCorrect,
            "totalAnswered": totalAnswered,
            "roundQuestionIndex": args.questionIndex,
            "hintsRemainingThisRound": max(0, maxHintsPerRound - roundHintsUsed),
            "challengesRemainingThisRound": max(0, maxChallengesPerRound - roundChallengesUsed)
        ]
        if hintDenied {
            result["hintDenied"] = true
            result["hintDeniedMessage"] = "HINT DENIED: All \(maxHintsPerRound) hints used this round. Tell the player: Sorry, no more hints this round!"
        }
        if challengeDenied {
            result["challengeDenied"] = true
            result["challengeDeniedMessage"] = "CHALLENGE DENIED: The \(maxChallengesPerRound) challenge for this round has been used. Tell the player: No more challenges this round!"
        }
        submitResult(callId: callId, result: result)

        if hintDenied {
            Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                try? await sessionManager.send(.responseCancel)
                try? await sessionManager.send(.responseCreate(
                    instructions: "STOP. The hint was DENIED by the app — the team has already used all \(maxHintsPerRound) hints this round. Do NOT give any clue. Tell them: Sorry, you've used both hints this round! Then continue with the current question."
                ))
            }
        }
        if challengeDenied {
            Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                try? await sessionManager.send(.responseCancel)
                try? await sessionManager.send(.responseCreate(
                    instructions: "STOP. The challenge was DENIED by the app — the team has already used their challenge this round. Tell them: No more challenges this round! Then move on."
                ))
            }
        }
    }

    private func handleGetLocation(callId: String) {
        let location = locationService.currentLocationLabel ?? "somewhere in the United States"
        submitResult(callId: callId, result: ["locationLabel": location])
    }

    private func handleEndGame(callId: String, data: Data) {
        if let args = try? JSONDecoder().decode(EndGameArgs.self, from: data) {
            print("[RealtimeGame] Game over: \(args.finalScore)/\(args.totalQuestions)")
            // #region agent log
            _dbg("C1","RealtimeGameCoordinator.swift:660","end_game called",["finalScore":args.finalScore,"totalQuestions":args.totalQuestions,"isLightningRound":self.isLightningRound,"secs":self.lightningSecondsRemaining,"announced":self.lightningAnnouncedButNotStarted])
            // #endregion
        }

        // Stop lightning timer if running
        stopLightningTimer()

        // Reset CarPlay display
        stateManager.reset()

        // Save completed session to history (Bug 8)
        if let session = gameViewModel.currentSession {
            persistence.saveCompletedSession(session)
            submitScoreToLeaderboard(from: session)
            hasSubmittedLeaderboard = true
        }

        // Clear checkpoint so home screen won't show "Resume"
        persistence.clearCheckpoint()
        gameViewModel.endSession()
        gameViewModel.transition(to: .gameOver)

        // Let the LLM's farewell audio finish playing, then disconnect
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.disconnect()
        }

        submitResultImmediate(callId: callId, result: ["acknowledged": true])
    }

    // MARK: - Leaderboard Submission

    /// Posts the current in-progress score when the player pauses or leaves without `end_game`
    /// (short games otherwise never hit `handleEndGame`).
    func submitLeaderboardFromCurrentSessionIfEligible() {
        guard !hasSubmittedLeaderboard else { return }
        guard let session = gameViewModel.currentSession else { return }
        hasSubmittedLeaderboard = true
        submitScoreToLeaderboard(from: session)
    }

    private func submitScoreToLeaderboard(from session: TriviaSession) {
        guard session.totalQuestionsAnswered > 0 else { return }

        let teamName = session.teamName ?? "Roadtrip Team"
        let points = session.totalQuestionsCorrect * session.difficulty.pointsPerCorrect

        let auth = AuthService.shared
        let baseURL = auth.supabaseApiBaseURL
        let apiKey = auth.supabaseApiKey

        guard let url = URL(string: "/rest/v1/leaderboard_scores", relativeTo: baseURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        let body: [String: Any] = [
            "team_name": teamName,
            "score": points
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request).resume()
    }

    // MARK: - Lightning Round Timer (LTNG-08, CP-SCORE-06)

    private func startLightningTimer() {
        suppressLightningToolCallRestart = false
        isLightningRound = true
        lightningSecondsRemaining = 120
        // Bug 21: Reset dedicated lightning counters
        lightningCorrect = 0
        lightningAnswered = 0
        roundCorrect = 0
        roundAnswered = 0
        roundHintsUsed = 0
        roundChallengesUsed = 0

        stateManager.updateLightningTimer(secondsRemaining: lightningSecondsRemaining, lightningCorrect: lightningCorrect)
        gameViewModel.lightningSecondsRemaining = lightningSecondsRemaining

        lightningTimer?.invalidate()
        lightningTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.lightningSecondsRemaining -= 1
            self.stateManager.updateLightningTimer(
                secondsRemaining: self.lightningSecondsRemaining,
                lightningCorrect: self.lightningCorrect
            )
            self.gameViewModel.lightningSecondsRemaining = self.lightningSecondsRemaining

            if self.lightningSecondsRemaining <= 0 {
                self.lightningTimer?.invalidate()
                self.lightningTimer = nil

                // End lightning state immediately so in-flight report_score cannot count as lightning (logs: Q at secs 0).
                let correct = self.lightningCorrect
                let answered = self.lightningAnswered
                self.pendingLightningFlushInstructions = "STOP! TIME IS UP! The lightning round is OVER. Score: \(correct) correct out of \(answered). Do NOT ask another question. Do NOT call report_score with isLightning=true for another question. Immediately announce the lightning score and transition to the next standard round or ask if they want to continue."
                self.suppressLightningToolCallRestart = true
                // #region agent log
                _dbg("D1","RealtimeGameCoordinator.swift:timer0","lightning timer zero — stopLightningTimer + merge TIME IS UP into next flush",["correct":correct,"answered":answered])
                // #endregion
                self.stopLightningTimer()

                // Cancel in-flight speech; TIME IS UP is delivered via ONE response.create merged in flushPendingResults (avoids conversation_already_has_active_response).
                Task {
                    try? await self.sessionManager.send(.responseCancel)
                }
            }
        }
        print("[RealtimeGame] Lightning round started — 120s timer")
    }

    private func stopLightningTimer() {
        // #region agent log
        _dbg("C1_C2","RealtimeGameCoordinator.swift:783","stopLightningTimer called",["secs":self.lightningSecondsRemaining,"isLightningRound":self.isLightningRound])
        // #endregion
        lightningTimer?.invalidate()
        lightningTimer = nil
        lightningEndCutoffWork?.cancel()
        lightningEndCutoffWork = nil
        isLightningRound = false
        lightningAnnouncedButNotStarted = false
        stateManager.clearLightning()
        gameViewModel.lightningSecondsRemaining = nil
        print("[RealtimeGame] Lightning round ended")
    }

    // MARK: - Sound Effects (Bug 26)

    /// Bug 26: Play cash register "ching" sound for correct answers
    private func playCorrectSound() {
        audioService.playBundledSound(named: "correct_ching")
    }

    /// Bug 26: Play gong sound for incorrect answers
    private func playIncorrectSound() {
        audioService.playBundledSound(named: "incorrect_gong")
    }

    // MARK: - Question History (Bug 7)

    private func loadQuestionHistory() {
        questionHistory = UserDefaults.standard.stringArray(forKey: questionHistoryKey) ?? []
        if questionHistory.count > 50 {
            questionHistory = Array(questionHistory.suffix(50))
        }
        print("[RealtimeGame] Loaded \(questionHistory.count) questions from history")
    }

    private func saveQuestionHistory() {
        // Save up to 200 questions on disk for long-term dedup,
        // but only send 20 to the LLM via the system prompt.
        var allHistory = UserDefaults.standard.stringArray(forKey: questionHistoryKey) ?? []
        // Merge any new questions not already in the full list
        for q in questionHistory where !allHistory.contains(q) {
            allHistory.append(q)
        }
        if allHistory.count > 200 {
            allHistory = Array(allHistory.suffix(200))
        }
        UserDefaults.standard.set(allHistory, forKey: questionHistoryKey)
    }

    // MARK: - Submit Function Result

    /// Queue a function result for batched submission. The result is sent to the
    /// API immediately, but response.create is deferred until responseDone fires,
    /// collapsing multiple function calls per turn into a single response cycle.
    private func submitResult(callId: String, result: [String: Any]) {
        // MainActor: after lightning TIME IS UP, merge instructions with tool output in one response.create
        // (response.done often fires before this queue completes — see flushPendingResults defer path).
        Task { @MainActor in
            do {
                try await sessionManager.queueFunctionResult(callId: callId, result: result)
                if let wrap = pendingLightningFlushInstructions, sessionManager.hasPendingResults {
                    pendingLightningFlushInstructions = nil
                    // #region agent log
                    _dbg("D1","RealtimeGameCoordinator.swift:submitResult","post-queue flush TIME IS UP + tool result",[:])
                    // #endregion
                    try await sessionManager.flushPendingResults(instructions: wrap)
                }
            } catch {
                print("[RealtimeGame] Failed to submit function result: \(error)")
            }
        }
    }

    /// Submit a result AND immediately trigger a new LLM response.
    /// Used only for flows that can't wait (end_game, hint/challenge denial).
    private func submitResultImmediate(callId: String, result: [String: Any]) {
        Task {
            do {
                try await sessionManager.submitFunctionResult(callId: callId, result: result)
            } catch {
                print("[RealtimeGame] Failed to submit function result: \(error)")
            }
        }
    }

    /// Flush any pending batched results when the LLM finishes a response turn.
    private func flushPendingResults() {
        Task { @MainActor in
            do {
                let merge = pendingLightningFlushInstructions
                let hasP = sessionManager.hasPendingResults

                if let wrap = merge, hasP {
                    // Tool results already queued for this turn — single create with TIME IS UP.
                    pendingLightningFlushInstructions = nil
                    // #region agent log
                    _dbg("D1","RealtimeGameCoordinator.swift:flush","flush TIME IS UP + pending tool results (response.done)",[:])
                    // #endregion
                    try await sessionManager.flushPendingResults(instructions: wrap)
                    return
                }

                if merge != nil, !hasP {
                    // `report_score` may still be queueing after response.cancel; submitResult will flush, or idle path below.
                    // #region agent log
                    _dbg("D1","RealtimeGameCoordinator.swift:flush","defer TIME IS UP — no pending tool results yet",[:])
                    // #endregion
                    scheduleDeferredIdleLightningWrapUp()
                }

                try await sessionManager.flushPendingResults(instructions: nil)
            } catch {
                print("[RealtimeGame] Failed to flush pending results: \(error)")
            }
        }
    }

    /// If no `report_score` queues after cancel, still deliver TIME IS UP (nested main async ≈ later run-loop turns).
    private func scheduleDeferredIdleLightningWrapUp() {
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in
                        guard let wrap = self.pendingLightningFlushInstructions else { return }
                        guard !self.sessionManager.hasPendingResults else { return }
                        self.pendingLightningFlushInstructions = nil
                        // #region agent log
                        _dbg("D1","RealtimeGameCoordinator.swift:idleWrap","idle TIME IS UP flush (no tool queue)",[:])
                        // #endregion
                        try? await self.sessionManager.flushPendingResults(instructions: wrap)
                    }
                }
            }
        }
    }

    // MARK: - Connection Quality Monitoring

    private var pausedByConnectionLoss = false
    private var reconnectWorkItem: DispatchWorkItem?

    private func observeConnectionQuality() {
        connectionMonitor.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self else { return }
                let phase = self.gameViewModel.currentPhase
                guard phase != .idle && phase != .gameOver else { return }

                if !connected && phase != .paused {
                    print("[RealtimeGame] Network path lost — pausing game")
                    self.pausedByConnectionLoss = true
                    self.pauseGame()
                }

                // Network restored — trigger reconnect if we're paused by connection loss
                if connected && self.pausedByConnectionLoss {
                    print("[RealtimeGame] Network path restored — scheduling reconnect with full context")
                    self.scheduleReconnect()
                }
            }
            .store(in: &cancellables)
    }

    /// Schedule a reconnection attempt. Coalesces multiple triggers (NWPath restored + WebSocket drop).
    private func scheduleReconnect() {
        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pausedByConnectionLoss else { return }
            // Only reconnect if network path is available
            guard self.connectionMonitor.isConnected else {
                print("[RealtimeGame] Reconnect deferred — network path still down")
                return
            }
            print("[RealtimeGame] Reconnecting with full game context")
            // #region agent log
            _dbg("E2","RealtimeGameCoordinator.swift:reconnect","scheduleReconnect firing",["round":self.currentRoundNumber,"question":self.currentQuestionIndex,"score":self.totalCorrect])
            // #endregion
            self.pausedByConnectionLoss = false
            self.reconnectAfterConnectionLoss()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    // MARK: - Reconnect After Connection Loss

    private func reconnectAfterConnectionLoss() {
        guard let session = gameViewModel.currentSession else {
            resumeGame()
            return
        }

        let checkpoint = SessionCheckpoint(
            sessionID: session.id,
            roundIndex: currentRoundNumber > 0 ? currentRoundNumber - 1 : 0,
            questionIndex: currentQuestionIndex,
            totalScore: totalCorrect,
            hintsUsed: session.hintsUsed,
            challengesUsed: session.challengesUsed,
            currentCategory: currentCategory,
            locationLabel: session.locationLabel,
            lightningTimeRemaining: isLightningRound ? TimeInterval(lightningSecondsRemaining) : nil,
            difficulty: session.difficulty,
            playerCount: session.playerCount,
            ageBands: session.ageBands,
            teamName: session.teamName,
            savedAt: Date()
        )

        let resumeContext = ResumeContext(from: checkpoint)
        let config = SystemPromptBuilder.buildSessionConfig(
            locationLabel: locationService.currentLocationLabel,
            resumeContext: resumeContext,
            questionHistory: questionHistory.isEmpty ? nil : questionHistory,
            isFirstGame: false,
            roundsRemaining: RoundTracker.shared.totalRoundsAvailable
        )

        Task { @MainActor in
            do {
                audioService.stopStreaming()
                sessionManager.disconnect()

                audioManager.activateForSpeech()
                audioService.configure(sessionManager: sessionManager)
                sessionManager.autoReconnectDisabled = true
                try await sessionManager.connect(sessionConfig: config)
                try audioService.startStreaming()
                gameViewModel.transition(to: .playing)

                // Resume lightning timer if we were in a lightning round
                if isLightningRound {
                    resumeLightningTimer()
                }

                try await sessionManager.send(.responseCreate(instructions: nil))
                print("[RealtimeGame] Reconnected after connection loss with full game context (round \(self.currentRoundNumber), score \(self.totalCorrect))")
            } catch {
                print("[RealtimeGame] Reconnect failed: \(error)")
                gameViewModel.connectionError = "Failed to reconnect. Please restart the game."
                gameViewModel.transition(to: .paused)
            }
        }
    }

    // MARK: - Network Error Recovery

    private func handleNetworkError() {
        // Bug 29: Guard against nil session to prevent crash
        if let session = gameViewModel.currentSession {
            let checkpoint = SessionCheckpoint(session: session)
            DispatchQueue.global(qos: .utility).async { [persistence] in
                persistence.saveCheckpoint(checkpoint)
            }
        }

        audioService.stopStreaming()
        submitLeaderboardFromCurrentSessionIfEligible()
        gameViewModel.transition(to: .paused)
        gameViewModel.connectionError = "Connection lost. Your game has been saved."
    }

    // MARK: - Pause/Resume (CarPlay hardware button)

    /// Pause the game — called when user presses pause button on CarPlay.
    func pauseGame() {
        let phase = gameViewModel.currentPhase
        guard phase != .paused && phase != .idle && phase != .gameOver else {
            print("[RealtimeGame] Pause ignored — already paused or not playing")
            return
        }
        print("[RealtimeGame] Pausing game (was: \(phase))")
        lightningTimer?.invalidate()
        lightningTimer = nil
        audioService.stopStreaming()
        submitLeaderboardFromCurrentSessionIfEligible()
        gameViewModel.transition(to: .paused)
    }

    /// Resume the game — called when user presses play button on CarPlay.
    func resumeGame() {
        let phase = gameViewModel.currentPhase
        guard phase == .paused else {
            print("[RealtimeGame] Resume ignored — not paused (current: \(phase))")
            return
        }
        print("[RealtimeGame] Resuming game")
        do {
            audioManager.activateForSpeech()
            try audioService.startStreaming()
            gameViewModel.transition(to: .playing)

            Task {
                try? await sessionManager.send(.responseCreate(
                    instructions: "The player resumed the game. Welcome them back and continue with the next question."
                ))
            }
        } catch {
            print("[RealtimeGame] Failed to resume: \(error)")
            gameViewModel.connectionError = "Failed to resume. Please restart the game."
        }
    }

    // MARK: - Interruption Handling

    private func observeInterruptions() {
        audioManager.onInterruption = { [weak self] in
            guard let self else { return }
            print("[RealtimeGame] Audio interrupted — pausing game")
            // Pause lightning timer if running
            self.lightningTimer?.invalidate()
            self.lightningTimer = nil
            self.audioService.stopStreaming()
            self.submitLeaderboardFromCurrentSessionIfEligible()
            self.gameViewModel.transition(to: .paused)
        }

        audioManager.onInterruptionEnd = { [weak self] in
            guard let self else { return }
            print("[RealtimeGame] Audio interruption ended — resuming game")
            do {
                // Re-activate audio and restart streaming
                self.audioManager.activateForSpeech()
                try self.audioService.startStreaming()
                self.gameViewModel.transition(to: .playing)

                // Bug 25: Nudge the LLM to continue after the interruption.
                // The WebSocket stays connected but the LLM may have gone silent.
                if self.isLightningRound {
                    // Resume lightning timer with remaining time
                    self.resumeLightningTimer()
                    Task {
                        try? await self.sessionManager.send(.responseCreate(
                            instructions: "The player is back after a brief interruption. Continue the lightning round — \(self.lightningSecondsRemaining) seconds left. Ask the next question immediately."
                        ))
                    }
                } else {
                    Task {
                        try? await self.sessionManager.send(.responseCreate(
                            instructions: "The player is back after a brief interruption. Welcome them back briefly and continue where you left off. If you were mid-question, repeat it."
                        ))
                    }
                }
            } catch {
                print("[RealtimeGame] Failed to resume audio: \(error)")
                // If audio restart fails, try reconnecting the whole session
                self.gameViewModel.connectionError = "Audio failed to resume. Please restart the game."
            }
        }
    }

    /// Resume the lightning timer with whatever time was remaining when interrupted.
    private func resumeLightningTimer() {
        guard isLightningRound, lightningSecondsRemaining > 0 else { return }

        lightningTimer?.invalidate()
        lightningTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.lightningSecondsRemaining -= 1
            self.stateManager.updateLightningTimer(
                secondsRemaining: self.lightningSecondsRemaining,
                lightningCorrect: self.lightningCorrect
            )

            if self.lightningSecondsRemaining <= 0 {
                self.lightningTimer?.invalidate()
                self.lightningTimer = nil
                let correct = self.lightningCorrect
                let answered = self.lightningAnswered
                self.pendingLightningFlushInstructions = "STOP! TIME IS UP! The lightning round is OVER. Score: \(correct) correct out of \(answered). Do NOT ask another question. Do NOT call report_score with isLightning=true for another question. Immediately announce the lightning score and transition to the next standard round or ask if they want to continue."
                self.suppressLightningToolCallRestart = true
                self.stopLightningTimer()
                Task {
                    try? await self.sessionManager.send(.responseCancel)
                }
            }
        }
        print("[RealtimeGame] Lightning timer resumed with \(lightningSecondsRemaining)s remaining")
    }

    /// True when the host is *starting* lightning, not recapping scores (avoids false "announced" UI).
    private static func transcriptSuggestsStartingLightningRound(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.contains("lightning") else { return false }
        // Wrap-up / recap (do not re-arm the 2:00 UI)
        if lower.contains("total up") { return false }
        if lower.contains("score now") && lower.contains("lightning") { return false }
        if lower.contains("tally") && lower.contains("score") { return false }
        if lower.contains("totaling") || lower.contains("totalling") { return false }
        if lower.contains("that was") && lower.contains("lightning") { return false }
        if lower.contains("amazing job") && lower.contains("lightning") { return false }
        if lower.contains("great job") && lower.contains("lightning") { return false }

        if lower.contains("lightning round") { return true }

        let startPhrases = [
            "jumping", "into the lightning", "into a lightning",
            "start the lightning", "begin the lightning", "starting the lightning",
            "here's the lightning", "here is the lightning", "here’s the lightning",
            "time for a lightning", "time for the lightning",
            "going into a lightning", "going into the lightning",
            "let's do a lightning", "lets do a lightning",
            "you're jumping", "you are jumping"
        ]
        return startPhrases.contains { lower.contains($0) }
    }
}
