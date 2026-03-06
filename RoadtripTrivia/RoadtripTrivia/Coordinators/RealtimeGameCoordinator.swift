import Foundation
import Combine

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

    // Lightning round timer
    private var lightningTimer: Timer?
    private var lightningCorrect = 0
    private var lightningAnswered = 0
    private var isLightningRound = false
    private var lightningSecondsRemaining = 120
    private var lightningEndCutoffWork: DispatchWorkItem?
    private var lightningAnnouncedButNotStarted = false

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

    // MARK: - Init

    init(gameViewModel: GameViewModel, stateManager: VoiceControlStateManager) {
        self.gameViewModel = gameViewModel
        self.stateManager = stateManager
        observeRealtimeEvents()
        observeInterruptions()
    }

    deinit {
        disconnect()
    }

    // MARK: - Start New Game

    func startNewGame() {
        gameViewModel.transition(to: .connecting)
        gameViewModel.resetDisplayProperties()

        // Load question history to avoid repeats (Bug 7)
        loadQuestionHistory()

        // Bug 23: Check if this is the user's first game
        let isFirstGame = !UserDefaults.standard.bool(forKey: hasPlayedBeforeKey)

        let config = SystemPromptBuilder.buildSessionConfig(
            locationLabel: locationService.currentLocationLabel,
            questionHistory: questionHistory.isEmpty ? nil : questionHistory,
            isFirstGame: isFirstGame
        )

        Task { @MainActor in
            do {
                audioService.configure(sessionManager: sessionManager)
                try await sessionManager.connect(sessionConfig: config)
                try audioService.startStreaming()
                gameViewModel.transition(to: .playing)

                // Kick off the conversation
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
            isFirstGame: false
        )

        Task { @MainActor in
            do {
                audioService.configure(sessionManager: sessionManager)
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
        gameViewModel.transition(to: .connecting)
        gameViewModel.resetDisplayProperties()
        gameViewModel.createSession(
            difficulty: difficulty,
            playerCount: playerCount,
            ageBands: ageBands,
            teamName: teamName
        )

        stateManager.setTeamName(teamName)
        // Bug 36: Show team name and previous score on iPhone display immediately for replayed games
        gameViewModel.displayTeamName = teamName ?? ""
        if previousTotalCorrect > 0 {
            totalCorrect = previousTotalCorrect
            gameViewModel.displayTotalCorrect = previousTotalCorrect
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
            isFirstGame: false
        )

        Task { @MainActor in
            do {
                audioService.configure(sessionManager: sessionManager)
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
        lightningTimer?.invalidate()
        lightningTimer = nil
        lightningEndCutoffWork?.cancel()
        lightningEndCutoffWork = nil
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

        // Observe connection state
        sessionManager.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                self?.gameViewModel.isConnected = connected
            }
            .store(in: &cancellables)
    }

    private func handleEvent(_ event: RealtimeServerEvent) {
        switch event {
        case .responseFunctionCallArgumentsDone(let callId, let name, let arguments):
            handleFunctionCall(callId: callId, name: name, arguments: arguments)

        case .inputAudioBufferSpeechStarted:
            // User is speaking — update UI to listening
            gameViewModel.transition(to: .listening)

        case .responseAudioDelta:
            // Model is speaking — update UI to speaking
            let phase = gameViewModel.currentPhase
            if phase == .listening || phase == .playing || phase == .waiting {
                gameViewModel.transition(to: .speaking)
            }

        case .responseAudioDone:
            // Model finished speaking — transition to listening for user response
            if gameViewModel.currentPhase == .speaking {
                gameViewModel.transition(to: .listening)
            }

        case .error(let message, let code):
            print("[RealtimeGame] Error [\(code ?? "?")]: \(message)")
            if message.contains("session_expired") || message.contains("invalid_api_key") {
                handleNetworkError()
            } else if code == "reconnect_failed" {
                // Bug 29/31: All reconnection attempts exhausted — save game and go idle
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

        case "update_ui":
            handleUpdateUI(callId: callId, data: data)

        case "checkpoint_game":
            handleCheckpoint(callId: callId, data: data)

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

        // Bug 23: Mark that the user has played at least one game
        UserDefaults.standard.set(true, forKey: hasPlayedBeforeKey)

        print("[RealtimeGame] Config set: \(args.playerCount) players, \(args.difficulty), team: \(args.teamName ?? ""), ages: \(args.ageBands)")

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

        // Update tracking
        totalAnswered += 1
        roundAnswered += 1
        if args.isCorrect {
            totalCorrect += 1
            roundCorrect += 1
        }
        currentQuestionIndex = args.questionIndex

        // Bug 26/34: Play correct/incorrect sound effect — but NOT for hints or challenges
        let isHintOrChallenge = (args.wasHint ?? false) || (args.wasChallenge ?? false)
        if !isHintOrChallenge {
            if args.isCorrect {
                playCorrectSound()
            } else {
                playIncorrectSound()
            }
        }

        // Bug 21: Dedicated lightning counters — only increment during lightning
        if isLightningRound {
            lightningAnswered += 1
            if args.isCorrect {
                lightningCorrect += 1
            }
        }

        // Bug 20/27/28: Track per-round hint/challenge usage with explicit denial
        var actualHint = args.wasHint ?? false
        var actualChallenge = args.wasChallenge ?? false
        var hintDenied = false
        var challengeDenied = false
        if actualHint {
            if roundHintsUsed >= maxHintsPerRound {
                actualHint = false // exceeded limit, don't count
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

        // Update view model
        gameViewModel.recordAnswerFromRealtime(
            answer: args.playerAnswer ?? "",
            isCorrect: args.isCorrect,
            wasHint: actualHint,
            wasChallenge: actualChallenge
        )

        // Update CarPlay score display + iPhone display properties
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
        // Mirror display properties for iPhone UI
        gameViewModel.displayRoundCorrect = roundCorrect
        gameViewModel.displayTotalCorrect = totalCorrect
        gameViewModel.displayQuestionInRound = args.questionIndex + 1

        // Bug 20/27/28: Return hint/challenge limits and denial info so LLM enforces limits
        var result: [String: Any] = [
            "acknowledged": true,
            "totalCorrect": totalCorrect,
            "totalAnswered": totalAnswered,
            "roundQuestionIndex": args.questionIndex,
            "hintsRemainingThisRound": max(0, maxHintsPerRound - roundHintsUsed),
            "challengesRemainingThisRound": max(0, maxChallengesPerRound - roundChallengesUsed)
        ]
        // Bug 27: Explicitly tell LLM when a hint was denied
        if hintDenied {
            result["hintDenied"] = true
            result["hintDeniedMessage"] = "HINT DENIED: All \(maxHintsPerRound) hints used this round. Tell the player: Sorry, no more hints this round!"
        }
        // Bug 28: Explicitly tell LLM when a challenge was denied
        if challengeDenied {
            result["challengeDenied"] = true
            result["challengeDeniedMessage"] = "CHALLENGE DENIED: The \(maxChallengesPerRound) challenge for this round has been used. Tell the player: No more challenges this round!"
        }
        submitResult(callId: callId, result: result)

        // Bug 35: Force-interrupt the LLM if a hint was denied — cancel any in-progress
        // response (which may already be speaking a hint) and make it announce the denial
        if hintDenied {
            Task {
                try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s for result to process
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

    private func handleUpdateUI(callId: String, data: Data) {
        guard let args = try? JSONDecoder().decode(UpdateUIArgs.self, from: data) else {
            submitResult(callId: callId, result: ["acknowledged": true])
            return
        }

        // Detect lightning round start/stop from the label (LTNG-08)
        // Timer is deferred until instructions are delivered (state == "listening")
        let label = args.label?.lowercased() ?? ""
        if label.contains("lightning") && !isLightningRound && !lightningAnnouncedButNotStarted {
            lightningAnnouncedButNotStarted = true
            gameViewModel.lightningSecondsRemaining = 120
            print("[RealtimeGame] Lightning round announced — timer deferred until first question")
        } else if lightningAnnouncedButNotStarted && args.state == "listening" {
            lightningAnnouncedButNotStarted = false
            startLightningTimer()
        } else if isLightningRound && args.state == "waiting" && !label.contains("lightning") {
            stopLightningTimer()
        }

        switch args.state {
        case "listening":
            gameViewModel.transition(to: .listening)
        case "announcement":
            gameViewModel.transition(to: .speaking)
        case "result":
            // Bug 26: Correct/incorrect sounds now play in handleReportScore instead
            gameViewModel.transition(to: .showingResult)
        case "waiting":
            gameViewModel.transition(to: .waiting)
        default:
            break
        }

        submitResult(callId: callId, result: ["acknowledged": true])
    }

    private func handleCheckpoint(callId: String, data: Data) {
        guard let args = try? JSONDecoder().decode(CheckpointGameArgs.self, from: data) else {
            submitResult(callId: callId, result: ["acknowledged": true])
            return
        }

        // Detect round change — show round summary (GAME-02, CP-SCORE-05)
        let isNewRound = args.roundNumber != currentRoundNumber && currentRoundNumber > 0
        if isNewRound {
            // Mark previous round complete in view model
            gameViewModel.completeCurrentRound()

            stateManager.showRoundSummary(
                roundScore: roundCorrect,
                roundTotal: roundAnswered,
                cumCorrect: totalCorrect,
                cumAnswered: totalAnswered,
                hints: gameViewModel.currentSession?.hintsUsed ?? 0,
                challenges: gameViewModel.currentSession?.challengesUsed ?? 0
            )
            // Reset per-round counters
            roundCorrect = 0
            roundAnswered = 0
            roundHintsUsed = 0
            roundChallengesUsed = 0
        }

        currentRoundNumber = args.roundNumber
        currentQuestionIndex = args.questionIndex
        currentCategory = args.category ?? currentCategory

        // Bug 5: Fallback lightning detection — if LLM didn't call update_ui with
        // "Lightning" label, detect lightning from round pattern (every 5th round = lightning)
        if !isLightningRound && currentRoundNumber > 4 && (currentRoundNumber - 1) % 5 == 0 {
            print("[RealtimeGame] Fallback: detected lightning round from round number \(currentRoundNumber)")
            startLightningTimer()
        }

        // Bug 16: Ensure the session has a round object for this round number
        let roundType: RoundType = isLightningRound ? .lightning : .standard
        gameViewModel.startNewRoundIfNeeded(roundNumber: args.roundNumber, category: currentCategory, type: roundType)

        // Update round label on CarPlay display + iPhone display properties
        stateManager.updateRound(number: currentRoundNumber, category: currentCategory)
        gameViewModel.displayRoundNumber = currentRoundNumber
        gameViewModel.displayCategory = currentCategory

        // Bug 30: Save checkpoint off main thread to prevent blocking the UI/WebSocket loop
        let checkpoint = SessionCheckpoint(
            sessionID: gameViewModel.currentSession?.id ?? UUID(),
            roundIndex: args.roundNumber - 1,
            questionIndex: args.questionIndex,
            totalScore: args.totalCorrect,
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

        submitResult(callId: callId, result: ["saved": true])
    }

    private func handleEndGame(callId: String, data: Data) {
        if let args = try? JSONDecoder().decode(EndGameArgs.self, from: data) {
            print("[RealtimeGame] Game over: \(args.finalScore)/\(args.totalQuestions)")
        }

        // Stop lightning timer if running
        stopLightningTimer()

        // Reset CarPlay display
        stateManager.reset()

        // Save completed session to history (Bug 8)
        if let session = gameViewModel.currentSession {
            persistence.saveCompletedSession(session)
        }

        // Clear checkpoint so home screen won't show "Resume"
        persistence.clearCheckpoint()
        gameViewModel.endSession()
        gameViewModel.transition(to: .gameOver)

        // Let the LLM's farewell audio finish playing, then disconnect
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.disconnect()
        }

        submitResult(callId: callId, result: ["acknowledged": true])
    }

    // MARK: - Lightning Round Timer (LTNG-08, CP-SCORE-06)

    private func startLightningTimer() {
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

                // Bug 19: Interrupt anything the LLM is currently saying, then tell it time is up
                Task {
                    // Cancel any in-progress response so the "TIME IS UP" message takes priority
                    try? await self.sessionManager.send(.responseCancel)
                    try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s pause
                    try? await self.sessionManager.send(.responseCreate(
                        instructions: "STOP! TIME IS UP! The lightning round is OVER. Score: \(self.lightningCorrect) correct out of \(self.lightningAnswered). Do NOT ask another question. Announce the final lightning score and ask if they want to keep playing the NEXT round."
                    ))
                }

                // Bug 19: Hard cutoff — if LLM hasn't moved on within 10s, force stop lightning
                let cutoff = DispatchWorkItem { [weak self] in
                    guard let self, self.isLightningRound else { return }
                    print("[RealtimeGame] Force-ending lightning round (10s cutoff)")
                    self.stopLightningTimer()
                    // Send one more nudge
                    Task {
                        try? await self.sessionManager.send(.responseCreate(
                            instructions: "Lightning round is over. Move to the next standard round now."
                        ))
                    }
                }
                self.lightningEndCutoffWork = cutoff
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: cutoff)
            }
        }
        print("[RealtimeGame] Lightning round started — 120s timer")
    }

    private func stopLightningTimer() {
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

    private func submitResult(callId: String, result: [String: Any]) {
        Task {
            do {
                try await sessionManager.submitFunctionResult(callId: callId, result: result)
            } catch {
                print("[RealtimeGame] Failed to submit function result: \(error)")
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
        gameViewModel.transition(to: .paused)
        gameViewModel.connectionError = "Connection lost. Your game has been saved."
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
                Task {
                    try? await self.sessionManager.send(.responseCancel)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    try? await self.sessionManager.send(.responseCreate(
                        instructions: "STOP! TIME IS UP! Lightning score: \(self.lightningCorrect)/\(self.lightningAnswered). Announce the score and ask if they want to keep playing."
                    ))
                }

                let cutoff = DispatchWorkItem { [weak self] in
                    guard let self, self.isLightningRound else { return }
                    self.stopLightningTimer()
                }
                self.lightningEndCutoffWork = cutoff
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: cutoff)
            }
        }
        print("[RealtimeGame] Lightning timer resumed with \(lightningSecondsRemaining)s remaining")
    }
}
