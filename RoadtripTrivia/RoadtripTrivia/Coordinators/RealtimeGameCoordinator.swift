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
    /// Timestamp of the last lightning timer expiry with rounds remaining. Used to reject
    /// a stray `end_game` that the AI emits in the race window before it processes our
    /// "move to next round" instruction.
    private var lightningExpiredWithRoundsRemainingAt: Date?
    /// Set to true after we reject an `end_game` call that arrived with rounds
    /// remaining. The rejection asks the AI to verbally confirm with the player
    /// whether they want to stop. A second `end_game` call while this flag is
    /// set is honored (the player confirmed). Cleared on any `get_next_question`
    /// or `report_score` (the player chose to continue).
    private var endGameConfirmationPending: Bool = false
    /// Set when input transcription shows the player explicitly chose to stop
    /// between rounds. This app-side latch prevents the model from ignoring
    /// "no, let's end game" and calling get_next_question anyway.
    private var playerRequestedEndGame = false

    // Difficulty tracking for point calculations
    private var currentDifficulty: Difficulty = .tricky
    /// True after the first accepted set_game_config in a session. Gemini can
    /// repeat setup tool calls when we give it competing startup instructions;
    /// duplicates must be acknowledged without resetting Round 1 state or
    /// re-arming startup nudges.
    private var gameConfigAccepted = false

    // Round consumption: only deduct when a round is fully completed (5 questions)
    private var currentRoundConsumed = false
    /// Hard idempotency for round-credit consumption: a given round number can
    /// only ever be consumed once per game, no matter which code path
    /// (report_score completion, rejected-duplicate safety net, lightning
    /// timer stop) gets there first. `currentRoundConsumed` is reset on round
    /// transitions in several places; this set is the belt-and-suspenders
    /// against the double-decrement bugs ("played 2 rounds, charged 3").
    private var consumedRoundNumbers: Set<Int> = []

    /// Single funnel for consuming a round credit. Returns true if a credit
    /// was actually consumed.
    @discardableResult
    private func consumeRoundCreditOnce(reason: String) -> Bool {
        guard !currentRoundConsumed, !consumedRoundNumbers.contains(currentRoundNumber) else {
            // #region agent log
            _dbg("RCONS","RealtimeGameCoordinator.swift:\(#line)","consume skipped — already consumed",["roundNumber":currentRoundNumber,"reason":reason])
            // #endregion
            return false
        }
        RoundTracker.shared.consumeOneRound()
        currentRoundConsumed = true
        consumedRoundNumbers.insert(currentRoundNumber)
        // #region agent log
        _dbg("RCONS","RealtimeGameCoordinator.swift:\(#line)","round consumed",["roundNumber":currentRoundNumber,"reason":reason,"remaining":RoundTracker.shared.totalRoundsAvailable])
        // #endregion
        return true
    }

    /// Debounced posting of the round-limit-reached notification. Several
    /// code paths can decide "no rounds left" within the same second; the
    /// paywall must be presented exactly once.
    private var lastRoundLimitPostAt: Date?
    private func postRoundLimitReached(context: String) {
        if let last = lastRoundLimitPostAt, Date().timeIntervalSince(last) < 3.0 {
            // #region agent log
            _dbg("PAYWALL_POST","RealtimeGameCoordinator.swift:\(#line)","duplicate roundLimitReached suppressed",["context":context])
            // #endregion
            return
        }
        lastRoundLimitPostAt = Date()
        // #region agent log
        _dbg("PAYWALL_POST","RealtimeGameCoordinator.swift:\(#line)","posting roundLimitReachedNotification",["context":context,"remaining":RoundTracker.shared.totalRoundsAvailable])
        // #endregion
        NotificationCenter.default.post(name: RoundTracker.roundLimitReachedNotification, object: nil)
    }

    // Per-round hint/challenge limits (Bug 20)
    private var roundHintsUsed = 0
    private var roundChallengesUsed = 0
    private let maxHintsPerRound = 2
    private let maxChallengesPerRound = 1

    // Question history (Bug 7) — tracks questions asked to avoid repeats
    private var questionHistory: [String] = []
    private let questionHistoryKey = "askedQuestionHistory"
    /// Questions asked in the current round — used for reconnect context
    private var currentRoundQuestions: [String] = []
    /// ALL questions asked in this game session — sent on reconnect for strong dedup
    private var sessionQuestions: [String] = []

    // Category history — tracks used categories to prevent repeats
    private var usedCategories: [String] = []

    // Batch pre-generation: questions are generated via REST in advance
    private var batchTask: Task<QuestionBatch, Error>?
    /// Set to `true` at `set_game_config` — means the app still owes the AI a
    /// "call get_next_question now" nudge before Round 1 can actually start.
    /// Cleared when either (a) the nudge is sent after batch + audio complete,
    /// or (b) the first question is successfully served.
    ///
    /// Why this exists: Gemini's tool-call timeout is ~3-5s. If the AI calls
    /// `get_next_question` before the batch is ready, we return a short
    /// BATCH_PENDING result instead of awaiting too long. The app then nudges
    /// with a fresh `responseCreate` the instant the batch is ready.
    private var firstRoundNudgeArmed = false
    /// Tracks whether the question batch for Round 1 is ready to serve. Used
    /// together with `firstRoundNudgeArmed` to decide when to fire the Round 1
    /// start nudge.
    private var firstRoundBatchReady = false
    /// True while a get_next_question tool call is actively polling for the
    /// first batch to finish. When the batch completes, that pending call will
    /// serve Q1 itself, so the batch-ready callback must not also fire the R1
    /// nudge. Without this, Q1 can be served and a duplicate get_next_question
    /// can be prompted within milliseconds, advancing the cursor to Q2.
    private var getNextQuestionAwaitingBatch = false
    /// Coalesced retry handle for the R1 nudge audio-drain gate. Set by
    /// `scheduleFirstRoundNudgeRetry`, cancelled when the nudge actually
    /// fires or game resets. Ensures we never queue more than one pending
    /// retry even if `maybeFireFirstRoundNudge` is called repeatedly.
    private var firstRoundNudgeRetryWork: DispatchWorkItem?
    /// Minimum quiet window we require after the AI's last audio delta
    /// before we'll fire the R1 nudge. The phase transitions from
    /// `.speaking` to `.listening` the instant the audio data stream ends,
    /// but device playback continues for several hundred ms after that.
    /// Sending the nudge during that tail clips the AI's speech audibly.
    private let audioDrainGraceSeconds: TimeInterval = 0.6
    /// Tracks the most recent get_next_question tool call ID so we can detect its cancellation.
    private var lastGetNextQuestionCallId: String?
    /// Set when a question is about to be RE-served because a previous
    /// get_next_question call was cancelled (`tool_call_cancelled`) and the
    /// batch was rewound. The re-serve is recovery, NOT forward progress, so
    /// the next "serving question" must NOT reset the per-question recovery
    /// budget — otherwise the cancel→rewind→re-serve cycle hands the governor
    /// a clean slate every iteration and the cancel budget can never trip,
    /// producing an unbreakable tool_call_cancelled loop (R3 freeze,
    /// debug-f3b222.log 2026-06-24 lines 365–386).
    private var reserveDueToCancelRewind = false
    /// Cache of the most-recently-served question result. Used by the soft-guard
    /// when the AI emits an early duplicate get_next_question before delivering
    /// the current question to the player (Case A, <12s window): instead of
    /// advancing the cursor (which would skip a question) or rewinding (which
    /// can become stale), we simply re-send the cached result with the new
    /// callId. The AI gets the same question data; the cursor doesn't move.
    private var lastServedQuestionResult: [String: Any]?
    /// Timestamp of the most recent question serve. Used by the soft-guard to
    /// distinguish a rapid-fire duplicate (Case A) from a "forgot to score"
    /// duplicate (Case B): in Case B the AI has already delivered the question
    /// and received the answer, so the correct recovery is to nudge it to call
    /// report_score — NOT to re-serve the same question (which confuses the AI
    /// and causes it to freeze mid-turn).
    private var lastQuestionServedAt: Date?
    /// Timestamp of the most recent non-empty player input transcript.
    /// Used to reject report_score calls where the model invented an answer
    /// for a silent player (2026-06-12: every time the player paused to
    /// think, the model scored the question as a "skip" — gong + answer
    /// reveal — even though the player never spoke).
    private var lastPlayerSpeechAt: Date?
    /// Timestamp when the answer window opened for the active question — i.e.
    /// when the host FINISHED reading the question and the mic became live
    /// (set on `responseAudioDone` while a question is served and unscored).
    /// The no-answer guard measures player speech against THIS, not the serve
    /// time, because the mic is muted for the whole question read and the
    /// pre-roll flush at mic-open otherwise reads as a phantom answer
    /// (2026-07-21 R2Q5: scored ~1.5s after mic opened, player never spoke).
    private var answerWindowOpenedAt: Date?
    /// Times the no-player-answer guard has rejected a report_score for the
    /// currently served question. Capped so a broken transcription stream
    /// degrades to the old behavior instead of deadlocking the game.
    private var answerDenialsForCurrentQuestion = 0
    /// Correct answer for the active question. Kept app-side so Gemini does not
    /// see the answer while reading the question and accidentally reveal it.
    private var activeQuestionCorrectAnswer: String?
    private var activeQuestionOptions: [String]?
    private var batchAPIKey: String?
    /// Last app-graded correctness per `roundNumber-questionIndex` for plain
    /// (non-hint, non-challenge) scores — enables host corrections without
    /// double-counting questions answered.
    private var lastGradedByQuestion: [String: Bool] = [:]
    /// If the Round 1 start nudge fires but no question is served, escalates
    /// with a stronger `responseCreate` (see `debug-30dda1` freeze after intro).
    private var round1StuckEscalationWork: DispatchWorkItem?

    /// Ring buffer of recently served questions, keyed by "round-questionIndex".
    /// Enables: (a) authoritative challenge re-grading after `get_next_question`
    /// has advanced the cursor, (b) deriving `report_score` context fields the
    /// LLM no longer sends (slim contract).
    private var servedQuestionBuffer: [String: ServedQuestionEntry] = [:]

    /// Metadata snapshot taken when a question is served via `get_next_question`.
    private struct ServedQuestionEntry {
        let roundNumber: Int
        let questionIndex: Int
        let correctAnswer: String
        let options: [String]?
        let questionText: String
        let category: String
        let isLightning: Bool
    }

    /// Global rate-limit state for all watchdog recovery actions. Every
    /// nudge / cancel+nudge must be approved by `TurnRecoveryGovernor`
    /// before firing — this is what prevents the "nudge storm" failure
    /// mode where several watchdogs each fire per question, burning tokens
    /// and interrupting slow-but-healthy turns.
    private var recoveryState = TurnRecoveryGovernor.State()

    /// Asks the governor for permission to run a recovery action. Records
    /// the action when permitted. Returns false (and logs) when denied.
    private func permitRecovery(_ kind: TurnRecoveryGovernor.ActionKind, context: String) -> Bool {
        let now = Date().timeIntervalSince1970
        let verdict = TurnRecoveryGovernor.decide(kind: kind, now: now, state: recoveryState)
        guard verdict == .allow else {
            // #region agent log
            _dbg("RECOVERY_GOV","RealtimeGameCoordinator.swift:\(#line)","recovery action DENIED",["kind":"\(kind)","context":context,"verdict":"\(verdict)","round":currentRoundNumber,"question":currentQuestionIndex])
            // #endregion
            print("[RealtimeGame] Recovery \(kind) denied by governor (\(verdict)) — \(context)")
            return false
        }
        TurnRecoveryGovernor.record(kind: kind, now: now, state: &recoveryState)
        apiLogger.noteTrigger("recovery:\(context)")
        return true
    }

    /// Silence watchdog: fires when the AI hasn't produced audio or tool calls
    /// for too long after a question is served, and sends a nudge.
    private var silenceWatchdog: DispatchWorkItem?
    private let silenceTimeoutSeconds: Double = 12.0

    /// Post-score specific watchdogs. Reducing the post-score timeout from
    /// 12s → 5s and adding an escalation stage is the core fix for the
    /// "5-20s paused after every interaction" regression observed in
    /// debug-f3b222 2.log (R1→Q2 gap of 7.9s; R1Q4 → dead 12.6s stall →
    /// session died with `input_tokens=6917 output_tokens=0` — meaning our
    /// single nudge reached Gemini but it produced zero audio in response).
    ///
    /// Flow:
    ///   1. `handleReportScore` arms `postScoreSilenceWatchdog`.
    ///   2. Any AI audio or non-`report_score` tool call cancels both timers;
    ///      recent tool activity re-arms instead of firing (model composing).
    ///   3. On fire: send a `responseCreate` text nudge only (never a
    ///      `responseCancel` — see fireHard note in PostScoreWatchdogPolicy).
    ///      Then arm the escalation.
    ///   4. If escalation fires (the nudge also produced no audio AND no
    ///      tool activity, the Gemini "stuck empty turn" failure mode) →
    ///      trigger `scheduleReconnect()` which preserves the resumption
    ///      handle — the only reliable recovery for that state.
    private var postScoreSilenceWatchdog: DispatchWorkItem?
    private var postScoreEscalationWatchdog: DispatchWorkItem?
    /// Watches the window AFTER a connection-loss reconnect: the resume
    /// `responseCreate` can itself stall (Gemini produces no audio), leaving
    /// the player staring at dead air until they quit — observed as ~43s of
    /// silence after the 2nd reconnect, then the game effectively died
    /// (debug-f3b222.log 2026-06-29, R1Q3). This watchdog retries the resume
    /// once and, if still silent, ends gracefully instead of hanging.
    private var reconnectResumeWatchdog: DispatchWorkItem?
    private var reconnectResumeRetries = 0
    private let reconnectResumeSilenceSeconds: Double = 9.0
    // Relaxed from 3.5 → 7.0 on 2026-06-11: the 3.5s window fired while
    // Gemini was still silently composing its verdict turn (time-to-first-
    // audio after a tool response is routinely 4-6s under load). Combined
    // with the then-destructive "[stop]" cancel, that nudge interrupted a
    // HEALTHY turn, orphaned its in-flight function call, and cascaded
    // into a re-grade loop that killed the session (debug-f3b222 6.log,
    // 17:59 and 18:01 freezes). The policy's tool-quiet gate covers most
    // of this window, but the timeout itself must also exceed normal
    // composition latency. The cost of a genuinely wedged turn now
    // surfacing at ~7.5s instead of ~4s is acceptable; killing a healthy
    // game is not.
    //
    // Values live in FarewellEndGamePolicy (the contract) so the
    // init-time assert can never diverge from the runtime values again
    // (a divergence crashed every CarPlay game start on 2026-06-12).
    private let postScoreInitialSilenceSeconds: Double =
        FarewellEndGamePolicy.maxPostScoreInitialSilenceSeconds
    /// Kept generous so we don't fire between sub-turns of a multi-part
    /// reaction (e.g. wrong-answer explanations). A `responseAudioDelta`
    /// (or any tool call) cancels this timer, so it only fires after a
    /// genuine post-reaction silence.
    private let postScoreContinuationSilenceSeconds: Double =
        FarewellEndGamePolicy.maxPostScoreContinuationSilenceSeconds
    /// Must exceed a full nudge → regenerate → first-audio cycle. At 7s
    /// the escalation tore down sessions that were busy regenerating
    /// after the nudge interrupted them (2026-06-11 freeze #2).
    private let postScoreEscalationSilenceSeconds: Double = 12.0
    /// Counts consecutive post-score nudges that fired without producing
    /// audio. Used to decide when to stop nudging and escalate to a
    /// full reconnect (Gemini's "empty turn" failure mode).
    private var postScoreNudgeFiredWithoutAudio: Bool = false

    /// Set true the moment we accept a `report_score` and continue the game
    /// (i.e. NOT round-complete, NOT hint/challenge, NOT no-rounds-left).
    /// Cleared the moment the AI calls `get_next_question`.
    ///
    /// Why this exists (added 2026-04-18): `startSilenceWatchdog()` is armed
    /// once when we hand the score back to the AI, but the very next thing
    /// the AI does is stream its 3-6s reaction speech — and every audio
    /// delta cancels the watchdog. After `responseAudioDone` we previously
    /// did NOT re-arm it, so if the AI then forgot to call `get_next_question`
    /// we'd sit silent indefinitely (the player heard a 30-40s dead pause
    /// until they spoke up, which often caused the AI to re-ask the prior
    /// question — see R2Q1/R2Q2/R3Q4 in debug-f3b222 2.log). We now re-arm
    /// in `responseAudioDone` whenever this flag is true so the silence
    /// timer guards the post-reaction gap, not just the post-toolResponse gap.
    private var pendingPostScoreContinuation: Bool = false

    /// Post-question-serve watchdog. Distinct from `silenceWatchdog` because
    /// audio deltas from the AI's pre-serve turn-tail would otherwise cancel
    /// the general watchdog even though the AI never actually read the new
    /// question. Observed failure mode: user barges in, AI starts a brief new
    /// turn (~200ms of audio) that includes a `get_next_question` tool call,
    /// we serve the question, AI emits a few more tokens finishing its
    /// transition phrase, then its turn ends WITHOUT reading the question —
    /// and the tool response is orphaned. This watchdog fires a targeted
    /// responseCreate to force the read if we detect sustained silence after
    /// serving.
    private var questionReadWatchdog: DispatchWorkItem?
    // Relaxed on 2026-04-22: the aggressive 2s/1s watchdog was frequently
    // firing while the host was still in a speaking phase tail, causing
    // response interruptions and audible cut-offs. Give the model a bit more
    // room before nudging and require a longer true-silence window.
    //
    // Relaxed again on 2026-05-04: silence threshold of 1.5s was still firing
    // and chopping off natural 2-3s mid-question pauses during the AI's
    // reaction-then-question read. In `debug-f3b222 3.log` the watchdog fired
    // during R1Q3, R2Q1, R3Q1 with silentSec of 2.65–2.9s and sent
    // `responseCancel` — user heard "host cut off during R1Q3 response".
    // Bumping to 3.0s aligns with the midTurn watchdog (4.0s) so the QREAD
    // path only fires for genuinely stuck reads, not natural pauses.
    private let questionReadTimeoutSeconds: Double = 3.0
    private let questionReadSilenceThreshold: Double = 3.0
    /// Timestamp of the most recent `responseAudioDelta`. Used by
    /// `questionReadWatchdog` to tell sustained AI reading from a brief
    /// post-serve tail that trails off into silence.
    private var lastAudioDeltaAt: Date?

    /// Timestamp of the most recent tool activity in either direction —
    /// a function call arriving from the model or a tool result being
    /// submitted back. After a tool response Gemini composes its next
    /// turn silently for several seconds; the post-score watchdog must
    /// treat that window as "model alive", not dead air, or its nudge
    /// interrupts the in-flight generation and orphans pending function
    /// calls (the 2026-06-11 freeze cascade).
    private var lastToolEventAt: Date?

    /// Mid-turn silence watchdog. Catches the failure mode where Gemini
    /// starts a turn (we receive a few `responseAudioDelta` events), then
    /// stops streaming audio WITHOUT sending `responseAudioDone`. App-side
    /// `phase` stays at `.speaking` indefinitely; the mic is suppressed
    /// (because "AI is speaking"), so the player can't barge in to recover.
    /// All the other watchdogs were either cancelled by the brief audio
    /// (silenceWatchdog, postScoreSilenceWatchdog) or skipped on the phase
    /// gate (questionReadWatchdog) — so the session sat frozen until the
    /// server eventually closed it.
    ///
    /// Observed in debug-30dda1 3 / debug-f3b222 3 on 2026-04-30, R1Q2:
    /// AI emitted 5 audio chunks (~600ms) starting Q2, then went silent.
    /// 37s of dead time, no recovery, WS closed by server.
    ///
    /// Re-armed on every `responseAudioDelta`. Cancelled by
    /// `responseAudioDone`, `responseFunctionCallArgumentsDone`, disconnect.
    /// On fire: forces `phase → .listening` (re-enables mic) and sends
    /// `responseCancel` to clear the dead turn on Gemini's side.
    private var midTurnSilenceWatchdog: DispatchWorkItem?
    private let midTurnSilenceTimeoutSeconds: Double = 4.0

    /// End-of-game "no rounds left" driver.
    ///
    /// When the player finishes their final available round, the AI gives a
    /// farewell speech and directs the player to purchase more rounds. We
    /// used to instruct the AI to call `end_game` at the end of that speech,
    /// but the AI consistently called the tool mid-sentence (following the
    /// literal prompt "then call end_game"), and the subsequent `gameOver`
    /// transition tore down the WebSocket before the farewell finished —
    /// cutting off the host. Now the app owns the end-of-game trigger: the
    /// AI is told NOT to call `end_game`, this flag is armed when the
    /// farewell prompt is sent, and the app ends the session either (a) a
    /// couple seconds after the AI's audio goes silent, or (b) after a
    /// hard fallback timeout if the AI never stops or never starts.
    private var pendingNoRoundsEnd = false
    /// Hard safety-net: ends the session even if the AI never finishes
    /// speaking (runaway speech) or never starts (no audio at all).
    private var noRoundsEndFallback: DispatchWorkItem?
    /// Triggered a few seconds after `responseAudioDone` fires while
    /// `pendingNoRoundsEnd` is set — lets the AI breathe between sentences.
    /// Reset every time a new audio delta arrives.
    private var noRoundsEndSilenceTimer: DispatchWorkItem?
    private let noRoundsEndFallbackSeconds: Double = 45.0
    // Bumped from 2.5 -> 4.0 on 2026-04-18: Gemini sometimes returns a very
    // brief audio turn for the goodbye chunk (~0.3s). With a 2.5s silence
    // window the WebSocket was being torn down ~2.9s after we even sent the
    // goodbye prompt, which the player perceives as the host being cut off
    // mid-farewell. 4.0s gives the audio playback queue time to drain and
    // gives the AI a chance to deliver a full sentence before we disconnect.
    //
    // Bumped again 5.0 -> 8.0 on 2026-05-04: in `debug-f3b222 3.log` the
    // chain ran through all three chunks (summary / purchase / goodbye) but
    // each chunk's actual audio was only 2.6–3.7s. The 5s silence timer fired
    // ~5s after the goodbye chunk's audioDone — but the device was still
    // draining queued audio, so the player heard the goodbye get clipped at
    // disconnect. 8s gives the audio engine plenty of time to flush before
    // teardown.
    private let noRoundsEndSilenceSeconds: Double = 8.0
    /// Sequential farewell scripts. Each entry is a short, explicit
    /// `responseCreate` instruction that the AI should speak as its next
    /// turn. After each `responseAudioDone` while `pendingNoRoundsEnd` is
    /// set, the coordinator sends the next script in this chain — this
    /// guarantees the full farewell (summary + CTA + goodbye) is spoken
    /// even when the AI would otherwise truncate a long single-turn prompt.
    private var farewellChain: [FarewellChunk] = []
    /// Index of the next script to send. `farewellChain[farewellChainIndex]`
    /// is the next one queued; once `farewellChainIndex == farewellChain.count`
    /// the silence timer is allowed to fire and end the session.
    private var farewellChainIndex: Int = 0
    /// Gemini can emit a `responseAudioDone`/turn-complete event before audio
    /// for a newly-created farewell response has actually started. Do not use
    /// that early done event to advance the chain or the next chunk interrupts
    /// the purchase guidance.
    private var farewellChunkAudioStarted = false
    /// Per-chunk timeout: if Gemini never sends `responseAudioDone` for a
    /// farewell chunk within this window, we force advancement so the chain
    /// doesn't stall and cut off the farewell. 10 s is long enough for any
    /// realistic Gemini turn (typical chunk audio is 3-6 s) and short enough
    /// that the player doesn't perceive a dead hang.
    private let farewellChunkTimeoutSeconds: Double = 10.0
    private var farewellChunkTimeoutWork: DispatchWorkItem?

    // Bug 23: Track whether user has played before (for first-time instructions)
    private let hasPlayedBeforeKey = "hasPlayedBefore"
    private var isFirstGameSession = false

    /// True when the AI is collecting team-name / ages / difficulty itself
    /// (`startNewGame` flow). False when the app supplied a pre-configured
    /// context up-front (`startNewGameWithConfig` carry-over flow). Used by
    /// `handleSetGameConfig` to decide whether to permit a brief "welcome back"
    /// greeting after `set_game_config` returns. In the conversational-setup
    /// flow we suppress all post-`set_game_config` speech and force the AI
    /// straight into `get_next_question` — otherwise Gemini routinely emits
    /// a 3–5 s transition utterance ("Alright, here's your first question…")
    /// and forgets to call the tool, leaving 5–10 s of dead air while the
    /// batch generates (see debug-30dda1 4.log on 2026-04-30 12:56:40).
    private var aiDidConversationalSetup: Bool = true

    // MARK: - Init

    init(gameViewModel: GameViewModel, stateManager: VoiceControlStateManager) {
        self.gameViewModel = gameViewModel
        self.stateManager = stateManager

        assert(
            FarewellEndGamePolicy.areThresholdsAcceptable(
                initialSilence: postScoreInitialSilenceSeconds,
                continuationSilence: postScoreContinuationSilenceSeconds
            ),
            "Post-score watchdog thresholds exceed FarewellEndGamePolicy limits — will cause perceptible dead air (5.log regression)"
        )

        observeRealtimeEvents()
        observeInterruptions()
        observeConnectionQuality()
    }

    deinit {
        disconnect()
    }

    // MARK: - Per-Game State Reset

    /// Clears every piece of per-game tracking state to its "no game in
    /// progress" default. MUST be called from every game-entry point
    /// (`startNewGame`, `startNewGameWithConfig`, `resumeGame`) BEFORE any
    /// caller-specific overrides (e.g. `resumeGame` then restores
    /// `currentRoundNumber` / `totalCorrect` from the checkpoint).
    ///
    /// Why this exists (added 2026-04-18): prior to this, `startNewGame*`
    /// reset only a subset of state. Counters like `currentRoundNumber`,
    /// `currentQuestionIndex`, `totalCorrect`, `roundAnswered`,
    /// `isLightningRound`, and `lightningSecondsRemaining` were left at
    /// the previous game's final values until the AI eventually called
    /// `set_game_config` / `report_score` to overwrite them. In the
    /// meantime any error path, R1 nudge, or `_dbg` log used stale state
    /// (visible in debug-f3b222 2.log: a fresh-connect error event
    /// reported `round=3` from the previous game). This routinely
    /// destabilized first-round timing, mid-game guards, and breadcrumbs.
    private func resetGameTrackingState() {
        // Round / question counters
        currentRoundNumber = 0
        currentQuestionIndex = 0
        totalCorrect = 0
        totalAnswered = 0
        currentCategory = ""
        roundCorrect = 0
        roundAnswered = 0
        hasSubmittedLeaderboard = false
        currentRoundConsumed = false
        gameConfigAccepted = false
        roundHintsUsed = 0
        roundChallengesUsed = 0
        currentRoundQuestions = []
        lastPlayerSpeechAt = nil
        answerWindowOpenedAt = nil
        answerDenialsForCurrentQuestion = 0

        // Lightning round state — invalidate any stale timer/work directly
        // (do NOT call `stopLightningTimer()` here: it has the side-effect of
        // consuming a round credit when `isLightningRound && !currentRoundConsumed`,
        // which would incorrectly burn a round at the start of a new game if
        // the previous game ended with leaked lightning state).
        lightningTimer?.invalidate()
        lightningTimer = nil
        lightningEndCutoffWork?.cancel()
        lightningEndCutoffWork = nil
        isLightningRound = false
        lightningSecondsRemaining = 120
        lightningCorrect = 0
        lightningAnswered = 0
        lightningAnnouncedButNotStarted = false
        pendingLightningFlushInstructions = nil
        suppressLightningToolCallRestart = false
        lightningExpiredWithRoundsRemainingAt = nil
        stateManager.clearLightning()
        gameViewModel.lightningSecondsRemaining = nil

        // Session-level history (NOT questionHistory — that's persisted across
        // games on disk for long-term dedup; loadQuestionHistory restores it).
        sessionQuestions = []
        usedCategories = []

        // Batch / question-serve state
        QuestionBatchService.shared.reset()
        batchTask = nil
        firstRoundNudgeArmed = false
        firstRoundBatchReady = false
        getNextQuestionAwaitingBatch = false
        firstRoundNudgeRetryWork?.cancel()
        firstRoundNudgeRetryWork = nil
        lastGetNextQuestionCallId = nil
        reserveDueToCancelRewind = false
        lastServedQuestionResult = nil
        lastQuestionServedAt = nil
        answerWindowOpenedAt = nil
        activeQuestionCorrectAnswer = nil
        activeQuestionOptions = nil
        lastGradedByQuestion.removeAll()
        servedQuestionBuffer.removeAll()
        round1StuckEscalationWork?.cancel()
        round1StuckEscalationWork = nil

        // Watchdog / end-of-game flags
        pendingPostScoreContinuation = false
        lastAudioDeltaAt = nil
        endGameConfirmationPending = false
        playerRequestedEndGame = false
        recoveryState = TurnRecoveryGovernor.State()
        consumedRoundNumbers.removeAll()
        cancelAllGameWatchdogs()
        disarmNoRoundsEnd()
    }

    // MARK: - Start New Game

    func startNewGame() {
        // Check round budget BEFORE connecting to Gemini (saves API costs)
        guard RoundTracker.shared.canPlayRound else {
            print("[RealtimeGame] No rounds available — showing paywall")
            NotificationCenter.default.post(name: RoundTracker.showPaywallNotification, object: nil)
            return
        }

        resetGameTrackingState()

        gameViewModel.transition(to: .connecting)
        gameViewModel.resetDisplayProperties()

        // Load question history to avoid repeats (Bug 7)
        loadQuestionHistory()

        // Bug 23: Check if this is the user's first game
        let isFirstGame = !UserDefaults.standard.bool(forKey: hasPlayedBeforeKey)
        isFirstGameSession = isFirstGame
        // Conversational setup: AI will collect name/ages/difficulty itself,
        // then call set_game_config. After that we want it straight into
        // get_next_question (no "let's hit the road" transition). See the
        // `aiDidConversationalSetup` doc comment for the failure mode.
        aiDidConversationalSetup = true

        let config = SystemPromptBuilder.buildSessionConfig(
            locationLabel: locationService.currentLocationLabel,
            isFirstGame: isFirstGame,
            roundsRemaining: max(0, RoundTracker.shared.totalRoundsAvailable - 1)
        )

        Task { @MainActor in
            do {
                _dbg("CONN","RealtimeGameCoordinator.swift:\(#line)","startNewGame: connecting",["isFirstGame":isFirstGame])
                audioService.configure(sessionManager: sessionManager)
                sessionManager.autoReconnectDisabled = true
                try await sessionManager.connect(sessionConfig: config)
                _dbg("CONN","RealtimeGameCoordinator.swift:\(#line)","startNewGame: connected, starting audio",[:])
                try audioService.startStreaming()
                gameViewModel.transition(to: .playing)

                try await sessionManager.send(.responseCreate(instructions: "Ask ONLY for the team name, then stop and wait for their answer."))
                _dbg("CONN","RealtimeGameCoordinator.swift:\(#line)","startNewGame: game started successfully",[:])
                print("[RealtimeGame] Game started")
            } catch {
                _dbg("CONN","RealtimeGameCoordinator.swift:\(#line)","startNewGame: FAILED",["error":"\(error)"])
                print("[RealtimeGame] Failed to start: \(error)")
                gameViewModel.transition(to: .idle)
                gameViewModel.connectionError = error.localizedDescription
            }
        }
    }

    // MARK: - Resume Game

    func resumeGame(from checkpoint: SessionCheckpoint) {
        guard RoundTracker.shared.canPlayRound else {
            print("[RealtimeGame] No rounds available — showing paywall")
            NotificationCenter.default.post(name: RoundTracker.showPaywallNotification, object: nil)
            return
        }

        resetGameTrackingState()

        // Resume flow doesn't invoke set_game_config (we drive `responseCreate`
        // directly), but keep the flag honest in case AI-side calls it later.
        aiDidConversationalSetup = false

        let checkpointRound = checkpoint.roundIndex + 1
        let answeredInCheckpointRound = max(0, min(5, checkpoint.questionIndex))
        var resumeRound = checkpointRound
        var nextQuestionInRound = answeredInCheckpointRound + 1
        if nextQuestionInRound > 5 {
            // Checkpoint was saved after Q5 was scored; continue at next round Q1.
            resumeRound += 1
            nextQuestionInRound = 1
        }

        // #region agent log
        _dbg("RESUME","RealtimeGameCoordinator.swift:\(#line)","resumeGame(from checkpoint) — continuing at next unasked question",["checkpointRound":checkpointRound,"checkpointQ":checkpoint.questionIndex,"resumeRound":resumeRound,"nextQuestion":nextQuestionInRound,"difficulty":checkpoint.difficulty.rawValue,"roundsAvailable":RoundTracker.shared.totalRoundsAvailable])
        // #endregion

        gameViewModel.transition(to: .connecting)
        gameViewModel.resetDisplayProperties()
        gameViewModel.restoreFromCheckpoint(checkpoint)

        // Restore tracking state to continue at the next unasked question.
        // Example: if checkpoint.questionIndex == 2, resume at Q3 in the same round.
        // If checkpoint was saved after Q5, continue at next round Q1.
        currentRoundNumber = resumeRound
        currentQuestionIndex = max(0, nextQuestionInRound - 1)
        totalCorrect = checkpoint.totalScore
        totalAnswered = (resumeRound - 1) * 5 + currentQuestionIndex
        currentCategory = (resumeRound == checkpointRound) ? checkpoint.currentCategory : ""
        currentDifficulty = checkpoint.difficulty
        roundAnswered = (resumeRound == checkpointRound) ? answeredInCheckpointRound : 0

        // Bug 9: Restore team name on CarPlay display
        stateManager.setTeamName(checkpoint.teamName)

        // Bug 32/36: Restore iPhone display properties from checkpoint
        gameViewModel.displayTotalCorrect = checkpoint.totalScore
        gameViewModel.displayRoundCorrect = 0
        gameViewModel.displayRoundNumber = resumeRound
        gameViewModel.displayCategory = currentCategory
        gameViewModel.displayTeamName = checkpoint.teamName ?? ""
        gameViewModel.displayQuestionInRound = nextQuestionInRound

        // Load question history to avoid repeats (Bug 7)
        loadQuestionHistory()

        let resumeContext = ResumeContext(from: checkpoint)
        // Resumed games are never first-time
        let config = SystemPromptBuilder.buildSessionConfig(
            locationLabel: checkpoint.locationLabel,
            resumeContext: resumeContext,
            isFirstGame: false,
            roundsRemaining: max(0, RoundTracker.shared.totalRoundsAvailable - 1)
        )

        Task { @MainActor in
            do {
                audioService.configure(sessionManager: sessionManager)
                sessionManager.autoReconnectDisabled = true
                try await sessionManager.connect(sessionConfig: config)
                try audioService.startStreaming()
                gameViewModel.transition(to: .playing)

                let ageBands = checkpoint.ageBands.map { $0.rawValue }
                self.startBatchGeneration(
                    difficulty: checkpoint.difficulty.rawValue,
                    ageBands: ageBands,
                    startingRound: self.currentRoundNumber > 0 ? self.currentRoundNumber : 1
                )

                let resumeInstruction: String
                if nextQuestionInRound == 1 && checkpoint.questionIndex >= 5 {
                    resumeInstruction = "Welcome the player back warmly in one brief sentence. Their previous round was completed before pause. Continue at Round \(resumeRound), Question 1: call get_next_question immediately. Do NOT ask setup questions. Do NOT restart prior rounds."
                } else {
                    resumeInstruction = "Welcome the player back warmly in one brief sentence. Continue at Round \(resumeRound), Question \(nextQuestionInRound): call get_next_question immediately. Do NOT restart the round. Do NOT ask setup questions. Do NOT re-ask or re-score already completed questions."
                }
                try await sessionManager.send(.responseCreate(
                    instructions: resumeInstruction
                ))
                print("[RealtimeGame] Game resumed, continuing at Round \(currentRoundNumber), Question \(nextQuestionInRound)")
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
        guard RoundTracker.shared.canPlayRound else {
            print("[RealtimeGame] No rounds available — showing paywall")
            NotificationCenter.default.post(name: RoundTracker.showPaywallNotification, object: nil)
            return
        }

        resetGameTrackingState()

        gameViewModel.transition(to: .connecting)
        gameViewModel.resetDisplayProperties()
        gameViewModel.createSession(
            difficulty: difficulty,
            playerCount: playerCount,
            ageBands: ageBands,
            teamName: teamName
        )

        // Pre-configured carry-over: AI did NOT collect anything itself —
        // a brief "welcome back, Team X, you had Y pts" greeting after
        // set_game_config is meaningful, so we don't suppress it.
        aiDidConversationalSetup = false

        currentDifficulty = difficulty
        stateManager.setTeamName(teamName)
        gameViewModel.displayTeamName = teamName ?? ""
        // Carry-over from a previous completed game (multi-game session).
        // Applied AFTER `resetGameTrackingState()` so the reset doesn't wipe
        // these out.
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
            isFirstGame: false,
            roundsRemaining: max(0, RoundTracker.shared.totalRoundsAvailable - 1)
        )

        Task { @MainActor in
            do {
                audioService.configure(sessionManager: sessionManager)
                sessionManager.autoReconnectDisabled = true
                try await sessionManager.connect(sessionConfig: config)
                try audioService.startStreaming()
                gameViewModel.transition(to: .playing)

                try await sessionManager.send(.responseCreate(instructions: "Begin the game with the pre-configured settings."))
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
        // #region agent log
        _dbg("DISCONNECT","RealtimeGameCoordinator.swift:\(#line)","disconnect() called",["round":currentRoundNumber,"question":currentQuestionIndex,"phase":"\(gameViewModel.currentPhase)","isReconnecting":isReconnecting,"reconnectAttempts":reconnectAttempts])
        // #endregion
        cancelAllGameWatchdogs()
        pendingPostScoreContinuation = false
        disarmNoRoundsEnd()
        stopLightningTimer()
        pendingLightningFlushInstructions = nil
        suppressLightningToolCallRestart = false
        firstRoundNudgeRetryWork?.cancel()
        firstRoundNudgeRetryWork = nil
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        pausedByConnectionLoss = false
        reconnectAttempts = 0
        isReconnecting = false
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

                if !connected && !self.pausedByConnectionLoss && !self.isReconnecting && phase != .paused {
                    print("[RealtimeGame] WebSocket disconnected during gameplay — pausing for reconnect")
                    // #region agent log
                    _dbg("E1","RealtimeGameCoordinator.swift:ws_drop","WebSocket isConnected→false during gameplay",["phase":"\(phase)","round":self.currentRoundNumber,"question":self.currentQuestionIndex,"closeInfo":self.sessionManager.lastCloseInfo ?? "none","reconnectAttempts":self.reconnectAttempts])
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
            cancelSilenceWatchdog()
            cancelMidTurnSilenceWatchdog()
            lastToolEventAt = Date()
            // Any tool call that isn't `report_score` moves us out of the
            // post-score "AI should call get_next_question next" expectation
            // (e.g. an `end_game` confirmation interlude, or a `get_location`
            // request). Clearing here prevents a stale post-score nudge from
            // firing on the next responseAudioDone. `handleReportScore` will
            // re-set the flag if the score is accepted.
            if name != "report_score" {
                pendingPostScoreContinuation = false
                cancelPostScoreWatchdogs()
            }
            handleFunctionCall(callId: callId, name: name, arguments: arguments)

        case .responseDone:
            // Flush any batched function call results so the LLM continues
            flushPendingResults()

        case .inputAudioBufferSpeechStarted:
            // Only flip to .listening for a corroborated barge-in. False
            // VAD events (noise/echo) used to flip the phase mid-host-speech,
            // confusing every phase-gated watchdog downstream.
            if audioService.currentBargeInVerdict() == .honor {
                gameViewModel.transition(to: .listening)
            }

        case .responseAudioTranscriptDelta(let text):
            handleInputTranscriptDelta(text)

        case .responseAudioDelta:
            lastAudioDeltaAt = Date()
            cancelSilenceWatchdog()
            // AI audio means a pending reconnect-resume succeeded.
            cancelReconnectResumeWatchdog()
            // Audio from the AI means it IS responding — clear both
            // post-score watchdogs so the escalation-to-reconnect
            // doesn't fire on a healthy turn. Re-arming (if still
            // waiting for get_next_question after the reaction ends)
            // happens in `responseAudioDone`.
            cancelPostScoreWatchdogs()
            // Re-arm the mid-turn silence watchdog. If audio stops
            // streaming and `responseAudioDone` never arrives, this fires
            // and unsticks the session. See `armMidTurnSilenceWatchdog`
            // doc for the full failure mode this addresses (R1Q2 stuck
            // after 600ms of audio, debug logs of 2026-04-30).
            armMidTurnSilenceWatchdog()
            // AI is still speaking its no-rounds farewell — push out the
            // "ended on silence" timer so we don't cut it off mid-sentence.
            if pendingNoRoundsEnd {
                farewellChunkAudioStarted = true
                noRoundsEndSilenceTimer?.cancel()
                noRoundsEndSilenceTimer = nil
            }
            let phase = gameViewModel.currentPhase
            if phase == .listening || phase == .playing || phase == .waiting || phase == .showingResult {
                gameViewModel.transition(to: .speaking)
            }

        case .responseAudioDone:
            cancelMidTurnSilenceWatchdog()
            if gameViewModel.currentPhase == .speaking {
                gameViewModel.transition(to: .listening)
            }
            // The host just finished speaking. Mark the answer window open —
            // the mic goes live post-playback and the player can now respond.
            // Two cases both need this timestamp:
            //   • A served, unscored question (player answers it) — the
            //     no-answer guard measures speech from here, not the muted
            //     question read.
            //   • A completed round (player answers "keep going?") — the
            //     between-rounds continue guard measures the decision window
            //     from here so we don't serve the next round before the player
            //     can decline (2026-07-21 R2→R3).
            // Updated on every done so a re-read/clarification resets it.
            let awaitingContinueDecision = roundAnswered >= 5 && !isLightningRound && gameViewModel.currentSession != nil
            if lastQuestionServedAt != nil || awaitingContinueDecision {
                answerWindowOpenedAt = Date()
            }
            // The AI just finished a turn. If we're waiting on the
            // no-rounds-left farewell to wrap up:
            //   • If more chunks remain in the chain, send the next one —
            //     we want to guarantee the player hears the CTA + goodbye
            //     even if the AI was terse on the first turn.
            //   • Otherwise (chain drained), arm the silence timer so we
            //     end the session after a brief quiet window.
            if pendingNoRoundsEnd {
                let state = FarewellState(
                    chainIndex: farewellChainIndex,
                    chainCount: farewellChain.count,
                    chunkAudioStarted: farewellChunkAudioStarted
                )
                switch FarewellAdvancer.handle(.audioDone, state: state) {
                case .ignoreEarlyDone:
                    // #region agent log
                    _dbg("NO_ROUNDS_END","RealtimeGameCoordinator.swift:\(#line)","ignoring early responseAudioDone before farewell audio started",["chainIndex":farewellChainIndex,"chainCount":farewellChain.count])
                    // #endregion
                    return
                case .sendNextChunk:
                    farewellChunkTimeoutWork?.cancel()
                    farewellChunkAudioStarted = false
                    sendNextFarewellChunk(reason: "responseAudioDone")
                case .armSilenceAutoEnd:
                    farewellChunkTimeoutWork?.cancel()
                    farewellChunkAudioStarted = false
                    scheduleNoRoundsEndAfterSilence()
                case .markAudioStarted:
                    // Not produced for .audioDone — exhaustive switch.
                    break
                }
            }
            // If we just heard the AI's reaction-to-answer speech end and
            // it still hasn't called `get_next_question`, re-arm the silence
            // watchdog with a sharper post-score nudge. Without this, every
            // audio delta during the reaction speech cancels the watchdog
            // and we never get a fresh timer for the post-reaction gap —
            // which let the AI sit silent for 30+ seconds (R2Q1/R2Q2/R3Q4
            // in debug-f3b222 2.log) until the player spoke up, at which
            // point the AI typically re-asked the previous question.
            if pendingPostScoreContinuation
                && !pendingNoRoundsEnd
                && gameViewModel.currentSession != nil {
                startPostScoreSilenceWatchdog(reason: "post-score-continuation")
            }
            // If the AI just finished speaking during setup (rules walkthrough
            // or "let's jump in!" bridge) and the Round 1 batch is ready,
            // nudge the AI to call get_next_question now. See the
            // `firstRoundNudgeArmed` docs for full context.
            maybeFireFirstRoundNudge(trigger: "responseAudioDone")

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

        case .usageMetadata(let prompt, let response, let total, _):
            let usage = ResponseUsage(
                inputTokens: prompt, outputTokens: response, totalTokens: total,
                inputTextTokens: nil, inputAudioTokens: nil, inputImageTokens: nil,
                cachedInputTokens: nil, cachedInputTextTokens: nil, cachedInputAudioTokens: nil,
                cachedInputImageTokens: nil, outputTextTokens: nil, outputAudioTokens: nil, outputImageTokens: nil)
            apiLogger.logResponseDone(status: "grok_turn", usage: usage)

        case .error(let message, let code):
            print("[RealtimeGame] Error [\(code ?? "?")]: \(message)")
            _dbg("ERR","RealtimeGameCoordinator.swift:\(#line)","API error event",["code":code ?? "nil","message":message,"phase":"\(gameViewModel.currentPhase)","round":currentRoundNumber,"question":currentQuestionIndex])
            if code == "go_away" {
                guard !pausedByConnectionLoss else {
                    _dbg("GOAWAY","RealtimeGameCoordinator.swift:\(#line)","go_away duplicate ignored — reconnect already pending",["reconnectAttempts":reconnectAttempts])
                    return
                }
                print("[RealtimeGame] go_away received — scheduling reconnect with retry tracking")
                // #region agent log
                _dbg("GOAWAY","RealtimeGameCoordinator.swift:\(#line)","go_away: scheduling reconnect",["round":currentRoundNumber,"question":currentQuestionIndex,"score":totalCorrect,"reconnectAttempts":reconnectAttempts])
                // #endregion
                pausedByConnectionLoss = true
                scheduleReconnect()
            } else if message.contains("session_expired") || message.contains("invalid_api_key") {
                handleNetworkError()
            } else if code == "reconnect_failed" {
                print("[RealtimeGame] Reconnection exhausted — ending session gracefully")
                handleNetworkError()
            } else if code == "tool_call_cancelled" && currentRoundNumber == 0 {
                if batchTask != nil {
                    print("[RealtimeGame] Tool call cancelled but config already set — nudging to proceed")
                    // #region agent log
                    _dbg("CANCEL","RealtimeGameCoordinator.swift:\(#line)","tool_call_cancelled post-config — nudging proceed",["message":message])
                    // #endregion
                    Task {
                        try? await sessionManager.send(.responseCreate(
                            instructions: "Game config is already set. Give a brief enthusiastic transition (1 sentence) and then immediately call get_next_question to start Round 1."
                        ))
                    }
                } else {
                    print("[RealtimeGame] Tool call cancelled during intro — nudging AI to retry config")
                    // #region agent log
                    _dbg("CANCEL","RealtimeGameCoordinator.swift:\(#line)","tool_call_cancelled during intro — nudging retry",["message":message])
                    // #endregion
                    Task {
                        try? await sessionManager.send(.responseCreate(
                            instructions: "Your set_game_config call was cancelled. Please call set_game_config again with the player's answers before proceeding."
                        ))
                    }
                }
            } else if code == "tool_call_cancelled" && currentRoundNumber > 0 {
                // Mid-game cancellation (cross-talk detected). If the cancelled call was
                // a get_next_question, rewind the batch so the same question is re-served.
                let cancelledCallId = message.replacingOccurrences(of: "Tool call cancelled: ", with: "")
                if cancelledCallId == lastGetNextQuestionCallId {
                    QuestionBatchService.shared.rewindLastQuestion()
                    if !sessionQuestions.isEmpty { sessionQuestions.removeLast() }
                    lastGetNextQuestionCallId = nil
                    // The upcoming re-serve is recovery, not progress: preserve
                    // the recovery budget so a repeated cancel loop can trip it.
                    reserveDueToCancelRewind = true
                    // #region agent log
                    _dbg("REWIND","RealtimeGameCoordinator.swift:\(#line)","tool_call_cancelled for get_next_question — rewound batch",["cancelledCallId":cancelledCallId,"round":currentRoundNumber,"question":currentQuestionIndex])
                    // #endregion
                    print("[RealtimeGame] get_next_question cancelled (cross-talk) — rewound batch to re-serve")
                    Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        try? await sessionManager.send(.responseCreate(
                            instructions: "Your last question delivery was interrupted. Call get_next_question again to get the question."
                        ))
                    }
                } else {
                    // A NON-served tool call was cancelled — typically the
                    // model's post-score get_next_question (or a report_score)
                    // that was still in-flight when a watchdog nudge or barge-in
                    // arrived. Left unhandled the model stalls and re-scores the
                    // same question, then freezes (debug-f3b222.log 2026-06-25,
                    // R2Q2). Recover with ONE governed nudge that explicitly
                    // forbids re-scoring; if the recovery budget is spent,
                    // escalate to a clean reconnect.
                    // #region agent log
                    _dbg("CANCEL","RealtimeGameCoordinator.swift:\(#line)","tool_call_cancelled (non-served) — recovering",["cancelledCallId":cancelledCallId,"round":currentRoundNumber,"question":currentQuestionIndex])
                    // #endregion
                    print("[RealtimeGame] tool_call_cancelled (non-served) — nudging to continue without re-scoring")
                    if permitRecovery(.softNudge, context: "tool-cancel-recover") {
                        Task {
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            try? await sessionManager.send(.responseCreate(
                                instructions: "Continue the game: call get_next_question to move to the NEXT question. The previous question is already scored — do NOT call report_score again."
                            ))
                        }
                    } else {
                        escalateStuckToReconnect(context: "tool-cancel-recover")
                    }
                }
            }

        default:
            break
        }
    }

    private func handleInputTranscriptDelta(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lastPlayerSpeechAt = Date()

        // Only meaningful once a game is actually in progress.
        guard currentRoundNumber > 0, gameViewModel.currentSession != nil else { return }

        let signal = PlayerIntentClassifier.classifyEndGame(trimmed)

        // A soft "no"/"nope"/"nah" is ambiguous mid-round (it's frequently a
        // trivia ANSWER), so it is only honored inside the between-rounds
        // confirmation window where the host just asked "keep going?".
        let isBetweenRoundsStopWindow =
            endGameConfirmationPending ||
            (!isLightningRound && roundAnswered >= 5)

        // An EXPLICIT quit ("stop playing", "quit", "end the game", "no more",
        // "done playing") is unambiguous and must be honored at ANY time —
        // including mid-round. Previously it was gated to the between-rounds
        // window too, so a player trying to bail out mid-round was ignored and
        // the game ground on to the end of the round (2026-07-21: "user said no
        // to continue but game progressed").
        let shouldEnd: Bool
        switch signal {
        case .explicit:
            shouldEnd = true
        case .softNo:
            shouldEnd = isBetweenRoundsStopWindow
        case .none:
            shouldEnd = false
        }
        guard shouldEnd else { return }

        playerRequestedEndGame = true
        _dbg("ENDGAME_TRANSCRIPT","RealtimeGameCoordinator.swift:\(#line)","player requested end game from input transcript",["transcript":String(trimmed.prefix(120)),"signal":"\(signal)","round":currentRoundNumber,"roundAnswered":roundAnswered,"confirmationPending":endGameConfirmationPending])
        forceEndGameFromPlayerTranscript(reason: "input_transcript")
    }

    private static func transcriptRequestsEndGame(_ text: String) -> Bool {
        PlayerIntentClassifier.transcriptRequestsEndGame(text)
    }

    private func forceEndGameFromPlayerTranscript(reason: String) {
        guard gameViewModel.currentPhase != .gameOver,
              gameViewModel.currentSession != nil else { return }

        playerRequestedEndGame = true
        endGameConfirmationPending = false
        pendingPostScoreContinuation = false
        cancelAllGameWatchdogs()
        disarmNoRoundsEnd()
        stopLightningTimer()
        stateManager.reset()

        if let session = gameViewModel.currentSession {
            persistence.saveCompletedSession(session)
            if !hasSubmittedLeaderboard {
                submitScoreToLeaderboard(from: session)
                hasSubmittedLeaderboard = true
            }
        }

        persistence.clearCheckpoint()
        gameViewModel.endSession()
        gameViewModel.transition(to: .gameOver)

        _dbg("ENDGAME_TRANSCRIPT","RealtimeGameCoordinator.swift:\(#line)","forceEndGameFromPlayerTranscript — transitioning to gameOver",["reason":reason,"round":currentRoundNumber,"totalCorrect":totalCorrect,"remaining":RoundTracker.shared.totalRoundsAvailable])

        audioService.suspendMicForProcessing()
        Task { [weak self] in
            guard let self else { return }
            try? await self.sessionManager.send(.responseCancel)
            try? await Task.sleep(nanoseconds: 150_000_000)
            try? await self.sessionManager.send(.responseCreate(
                instructions: "The player chose to stop. Say one brief goodbye and do not ask another question."
            ))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            self?.disconnect()
        }
    }

    // MARK: - Function Call Dispatch

    private func handleFunctionCall(callId: String, name: String, arguments: String) {
        print("[RealtimeGame] Function call: \(name)(\(arguments.prefix(100)))")

        guard let data = arguments.data(using: .utf8) else {
            submitResult(callId: callId, name: name, result: ["error": "Invalid arguments"])
            return
        }

        switch name {
        case "set_game_config":
            handleSetGameConfig(callId: callId, name: name, data: data)

        case "report_score":
            handleReportScore(callId: callId, name: name, data: data)

        case "get_location":
            handleGetLocation(callId: callId, name: name)

        case "get_next_question":
            handleGetNextQuestion(callId: callId, name: name)

        case "end_game":
            handleEndGame(callId: callId, name: name, data: data)

        default:
            print("[RealtimeGame] Unknown function: \(name)")
            submitResult(callId: callId, name: name, result: ["error": "Unknown function"])
        }
    }

    // MARK: - Function Handlers

    private func handleSetGameConfig(callId: String, name: String, data: Data) {
        guard let args = try? JSONDecoder().decode(SetGameConfigArgs.self, from: data) else {
            submitResult(callId: callId, name: name, result: ["error": "Invalid arguments"])
            return
        }

        if gameConfigAccepted {
            let instruction: String
            if lastGetNextQuestionCallId != nil {
                instruction = "Config is already set and a question is already active. Do NOT call set_game_config again. Continue the current question flow: read the active question if you have not finished it, then wait for the player's answer and call report_score."
            } else if QuestionBatchService.shared.currentBatch == nil && batchTask != nil {
                instruction = "Config is already set and questions are already loading. Do NOT call set_game_config again. Do NOT call get_next_question again yet. Wait silently; the app will prompt you when questions are ready."
            } else {
                instruction = "Config is already set. Do NOT call set_game_config again. Call get_next_question now if you need the next question."
            }
            audioService.suspendMicForProcessing()
            _dbg("H1_CONFIG","RealtimeGameCoordinator.swift:\(#line)","duplicate set_game_config ignored",["difficulty":args.difficulty,"hasActiveQuestion":lastGetNextQuestionCallId != nil,"round":currentRoundNumber,"question":currentQuestionIndex])
            submitResultImmediate(callId: callId, name: name, result: [
                "acknowledged": true,
                "duplicate": true,
                "instruction": instruction
            ])
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

        currentDifficulty = difficulty
        gameConfigAccepted = true

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

        // Gemini does not support mid-session config updates. The initial system prompt
        // covers all difficulties; the model naturally uses the chosen one from here.

        audioService.suspendMicForProcessing()
        // #region agent log
        _dbg("H1_CONFIG","RealtimeGameCoordinator.swift:\(#line)","set_game_config submitResultImmediate (was buffered)",["difficulty":args.difficulty])
        // #endregion
        // IMPORTANT — tell Gemini exactly what to do next. Without an explicit
        // instruction, the model frequently emits a 3–5 s "transition" utterance
        // ("Alright, here's your first question…") and then ends its turn WITHOUT
        // calling get_next_question. The batch can take 5–10 s to generate, so
        // the user hears: (a) the AI start a question, (b) abrupt silence,
        // (c) the AI start a *different* question once the R1 nudge fires (this
        // is the "host started asking first question, abruptly stopped, then
        // started a whole new question" defect — see debug-30dda1 4.log on
        // 2026-04-30 12:56:40).
        //
        // For conversational-setup games (AI just asked name/ages/difficulty),
        // we suppress all post-config speech and force the tool call. The
        // BATCH_PENDING branch in handleGetNextQuestion emits a clean,
        // coordinated one-liner if the batch is still loading.
        //
        // For carry-over (preconfigured) games, the system prompt asks for a
        // brief "welcome back, Team X" greeting that's user-meaningful, so we
        // allow ONE short greeting before the tool call.
        let nextStepInstruction: String
        if aiDidConversationalSetup {
            nextStepInstruction = "Call get_next_question NOW. Do NOT speak first — no transition, no \"alright let's go\", no \"here's your first question\". Just call the tool. The app will return either the question content (read it) or a status telling you exactly what to say while it loads."
        } else {
            nextStepInstruction = "Greet the player by team name in ONE short sentence acknowledging any carry-over score, then IMMEDIATELY call get_next_question — do not pause or wait for confirmation. The app will return either the question or a status with what to say next."
        }
        submitResultImmediate(callId: callId, name: name, result: [
            "acknowledged": true,
            "difficulty": args.difficulty,
            "playerCount": args.playerCount,
            "ageBands": args.ageBands,
            "instruction": nextStepInstruction
        ])

        // Arm the Round 1 start nudge — see `firstRoundNudgeArmed` docs.
        firstRoundNudgeArmed = true
        firstRoundBatchReady = false

        // Kick off batch question generation in the background.
        // Only start if there isn't already a batch in progress (avoid duplicate on retry).
        if batchTask == nil {
            startBatchGeneration(
                difficulty: args.difficulty,
                ageBands: args.ageBands,
                startingRound: 1
            )
        }
    }

    private func handleReportScore(callId: String, name: String, data: Data) {
        recoveryState.resetForNewQuestion()
        // NOTE: lastGetNextQuestionCallId is NOT cleared here. It is cleared
        // below only for real answers — a hint/challenge report_score must
        // leave the pending-question guard intact, otherwise the AI's next
        // get_next_question advances the batch cursor past the unanswered
        // question (2026-06-12: challenge on R1Q4 erased the guard and the
        // game jumped from an unanswered R1Q5 straight to R2Q1, which also
        // meant round 1 was never consumed).
        // Player answered — the AI clearly read the question. Disarm the
        // post-serve read watchdog so it doesn't fire during the scoring flow.
        cancelQuestionReadWatchdog()
        // Player chose to continue — cancel any pending end_game confirmation.
        endGameConfirmationPending = false
        // ── Slim contract enrichment ──────────────────────────────────────
        // The LLM only sends `playerAnswer` + `isCorrect` (+ optional flags).
        // Fill in questionIndex, roundNumber, category, questionText, isLightning
        // from the served-question buffer / current coordinator state so all
        // downstream code sees a fully-populated `ReportScoreArgs`.
        guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            submitResult(callId: callId, name: name, result: ["error": "Invalid arguments"])
            return
        }
        let enrichIsChallenge = (json["wasChallenge"] as? Bool) ?? false
        if json["questionIndex"] == nil {
            if enrichIsChallenge {
                json["questionIndex"] = currentQuestionIndex
            } else {
                json["questionIndex"] = (lastServedQuestionResult?["questionIndex"] as? Int) ?? currentQuestionIndex
            }
        }
        if json["roundNumber"] == nil {
            if enrichIsChallenge {
                json["roundNumber"] = currentRoundNumber
            } else {
                json["roundNumber"] = (lastServedQuestionResult?["roundNumber"] as? Int) ?? currentRoundNumber
            }
        }
        let enrichQIdx = json["questionIndex"] as? Int ?? currentQuestionIndex
        let enrichRNum = json["roundNumber"] as? Int ?? currentRoundNumber
        let enrichKey = "\(enrichRNum)-\(enrichQIdx)"
        let enrichEntry = servedQuestionBuffer[enrichKey]
        if json["category"] == nil {
            json["category"] = enrichEntry?.category ?? currentCategory
        }
        if json["questionText"] == nil {
            json["questionText"] = enrichEntry?.questionText
        }
        if json["isLightning"] == nil {
            json["isLightning"] = enrichEntry?.isLightning ?? isLightningRound
        }
        guard let enrichedData = try? JSONSerialization.data(withJSONObject: json),
              let args = try? JSONDecoder().decode(ReportScoreArgs.self, from: enrichedData) else {
            submitResult(callId: callId, name: name, result: ["error": "Invalid arguments"])
            return
        }

        // Enforce 5-question limit per standard round (lightning rounds are unlimited).
        // Only enforce when the report_score is for the CURRENT round (not a new round transition).
        let reportedLightning = args.isLightning ?? false
        let isSameRound = args.roundNumber == nil || args.roundNumber == currentRoundNumber
        if !reportedLightning && !isLightningRound && roundAnswered >= 5 && isSameRound {
            print("[RealtimeGame] Round question limit reached (\(roundAnswered)/5) — rejecting extra report_score")
            // #region agent log
            _dbg("QLIMIT","RealtimeGameCoordinator.swift:\(#line)","report_score REJECTED: round already has 5 questions",["roundAnswered":roundAnswered,"questionIndex":args.questionIndex,"roundNumber":String(describing:args.roundNumber),"currentRoundNumber":currentRoundNumber])
            // #endregion
            // Belt-and-suspenders: the round IS complete at this point, so
            // consume the round credit if we somehow haven't yet. This prevents
            // a round from being "played" without decrementing the counter
            // when the final scoring call is rejected (e.g. due to a duplicate
            // score from a re-served question).
            consumeRoundCreditOnce(reason: "rejected report_score safety net")

            // If consuming this round just exhausted the player's available
            // rounds, we MUST drive the no-rounds-left flow ourselves —
            // otherwise the success-path branch (which posts the paywall
            // notification + arms the farewell chain) is never reached and
            // the player only hears the AI's farewell while the iOS UI sits
            // on the trivia screen instead of showing the subscription page.
            // Observed in debug-f3b222 2.log on R3Q5 rejection.
            let noRoundsLeftOnRejection = !RoundTracker.shared.canPlayRound
            if noRoundsLeftOnRejection {
                let ppc = currentDifficulty.pointsPerCorrect
                _dbg("NO_ROUNDS","RealtimeGameCoordinator.swift:\(#line)","rejected report_score consumed last round — posting paywall + farewell chain",["totalCorrect":totalCorrect,"ppc":ppc,"currentRound":currentRoundNumber])
                postRoundLimitReached(context: "rejected_report_score_no_rounds")
                pendingPostScoreContinuation = false
                cancelSilenceWatchdog()
                cancelPostScoreWatchdogs()
                let chain = makeNoRoundsFarewellChain(
                    finalScore: totalCorrect * ppc,
                    roundsPlayed: currentRoundNumber,
                    context: "rejected_report_score_no_rounds_left"
                )
                submitResultImmediate(callId: callId, name: name, result: [
                    "error": "ROUND_COMPLETE_NO_ROUNDS",
                    "message": "This round is complete and the player has used their LAST available round. The app will drive the farewell — acknowledge briefly and wait for the app's next instruction. Do NOT call end_game. Do NOT call get_next_question. Do NOT ask any questions."
                ])
                armNoRoundsEnd(withChain: chain)
                return
            }

            // Round complete with rounds remaining: AI is being asked to give
            // a summary and prompt the player. Clear the post-score flag so
            // the silence-watchdog re-arm doesn't fire a stale "call
            // get_next_question NOW" nudge during the player's confirmation.
            pendingPostScoreContinuation = false
            submitResult(callId: callId, name: name, result: [
                "error": "ROUND_COMPLETE",
                "message": "This round already has 5 questions answered. Give the round summary and ask if they want to continue. Then call get_location and start the next round with roundNumber=\(currentRoundNumber + 1)."
            ])
            return
        }

        // Lightning round detection from isLightning field
        // #region agent log
        _dbg("B1_B2_C2","RealtimeGameCoordinator.swift:435","report_score lightning check",["reportedLightning":reportedLightning,"isLightningRound":self.isLightningRound,"announced":self.lightningAnnouncedButNotStarted,"argsIsLightning":String(describing:args.isLightning),"roundNumber":String(describing:args.roundNumber),"questionIndex":args.questionIndex,"category":args.category ?? "nil","secs":self.lightningSecondsRemaining])
        // #endregion
        if args.isLightning == false && !isLightningRound {
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
            // Lightning timer is still running — ignore the false flag and remind the AI.
            // Timer only stops on natural expiration (0s), end_game, or player quit.
            print("[RealtimeGame] WARNING: report_score(isLightning:false) while lightning timer active — ignoring, \(lightningSecondsRemaining)s remain")
            // #region agent log
            _dbg("C2","RealtimeGameCoordinator.swift:452","IGNORING isLightning=false while timer active",["roundNumber":String(describing:args.roundNumber),"questionIndex":args.questionIndex,"secs":self.lightningSecondsRemaining])
            // #endregion
            Task {
                try? await sessionManager.send(.responseCreate(
                    instructions: "Lightning round is still active with \(lightningSecondsRemaining)s remaining. Set isLightning=true in report_score calls."
                ))
            }
        }

        let isChallenge = args.wasChallenge ?? false
        let isHintCheck = args.wasHint ?? false
        let actualIsCorrect = appGradedCorrectness(for: args)
        let roundNumForScore = args.roundNumber ?? currentRoundNumber
        let scoreKey = ScoreRevisionPolicy.scoreKey(roundNumber: roundNumForScore, questionIndex: args.questionIndex)
        let priorGraded = ScoreRevisionPolicy.previousCorrectIfRevision(
            existingGraded: lastGradedByQuestion[scoreKey],
            isHint: isHintCheck,
            isChallenge: isChallenge
        )
        let isScoringRevision = priorGraded != nil

        // Reject fabricated scores for a silent player BEFORE any state
        // mutation, chime, or verdict (which reveals the answer). See
        // NoAnswerGuardPolicy for the 2026-06-12 "every pause became a
        // gong + answer reveal" failure mode, and the 2026-07-21 R2Q5 case
        // where the model chimed ~1.5s after the mic opened — before the
        // player could answer. Measure speech from the answer window (mic
        // live), not the muted question-read.
        let playerSpokeSinceServe = NoAnswerGuardPolicy.playerProvidedAnswer(
            lastPlayerSpeechAt: lastPlayerSpeechAt,
            answerWindowOpenedAt: answerWindowOpenedAt,
            questionServedAt: lastQuestionServedAt
        )
        let answerVerdict = NoAnswerGuardPolicy.decide(
            playerAnswer: args.playerAnswer ?? "",
            isHint: isHintCheck,
            isChallenge: isChallenge,
            isScoringRevision: isScoringRevision,
            isLightning: reportedLightning || isLightningRound,
            playerSpokeSinceServe: playerSpokeSinceServe,
            priorDenials: answerDenialsForCurrentQuestion
        )
        if case .deny(let denyReason) = answerVerdict {
            answerDenialsForCurrentQuestion += 1
            // #region agent log
            let answerWindowElapsed = answerWindowOpenedAt.map { Date().timeIntervalSince($0) } ?? -1
            _dbg("NO_ANSWER_GUARD","RealtimeGameCoordinator.swift:\(#line)","report_score DENIED — \(denyReason)",["playerAnswer":args.playerAnswer ?? "nil","denials":answerDenialsForCurrentQuestion,"round":currentRoundNumber,"question":args.questionIndex,"spokeSinceServe":playerSpokeSinceServe,"answerWindowElapsedSec":answerWindowElapsed])
            // #endregion
            print("[RealtimeGame] report_score denied (\(denyReason)) — telling AI to wait for a real answer")
            audioService.suspendMicForProcessing()
            submitResultImmediate(callId: callId, name: name, result: [
                "error": "NO_PLAYER_ANSWER",
                "instruction": "The app heard NO answer from the player (\(denyReason)). Do NOT score this question, do NOT reveal the answer or any options' correctness, and NEVER treat silence as a skip. Briefly invite them — e.g. 'Take your time — what do you think?' — then WAIT for the player to actually speak."
            ])
            startSilenceWatchdog()
            startQuestionReadWatchdog()
            return
        }

        // Clear the served-question cache ONLY for regular answers, not
        // for challenges/hints. Challenges re-score a previous question
        // while the NEXT question has already been served; clearing the
        // cache here caused `get_next_question` to advance the batch
        // cursor past the already-served question, skipping it entirely
        // (debug-f3b222 4.log, 2026-05-07: challenge on Q1 → Q2
        // skipped → jumped straight to Q3).
        if !isChallenge && !isHintCheck {
            lastServedQuestionResult = nil
            lastQuestionServedAt = nil
            answerWindowOpenedAt = nil
            lastGetNextQuestionCallId = nil
        } else if lastGetNextQuestionCallId != nil {
            // A served question is still unanswered while the player took a
            // hint/challenge detour. Refresh the serve clock so that when the
            // AI calls get_next_question afterwards it lands in Case A
            // (re-serve the same question) rather than Case B's "forgot to
            // score" nudge — the elapsed time was spent on the detour, not
            // on the player hearing and answering the question.
            lastQuestionServedAt = Date()
        }

        // Reset round counters BEFORE the increment when entering a new round.
        // Without this, the first question's increment is lost because the later
        // isNewRound block resets roundAnswered to 0 AFTER the increment.
        if let rn = args.roundNumber, rn != currentRoundNumber, currentRoundNumber > 0 {
            roundAnswered = 0
            currentRoundConsumed = false
        }

        // #region agent log
        _dbg("H1","RealtimeGameCoordinator.swift:\(#line)","roundAnswered check",["roundAnswered":roundAnswered,"isHintCheck":isHintCheck,"isChallenge":isChallenge,"questionIndex":args.questionIndex,"willIncrement":(!isChallenge && !isHintCheck && !isScoringRevision),"isScoringRevision":isScoringRevision])
        // #endregion

        // Hints and challenges are not real answers — don't count them toward the round limit.
        // A second `report_score` for the same (round, question) without hint/challenge is a
        // host correction: adjust correctness deltas only — do not increment answered counts.
        if !isChallenge && !isHintCheck {
            if isScoringRevision, let prev = priorGraded {
                let d = ScoreRevisionPolicy.correctnessDelta(previous: prev, newGraded: actualIsCorrect)
                if d != 0 {
                    totalCorrect += d
                    roundCorrect += d
                    // #region agent log
                    _dbg("SCORE_REV","RealtimeGameCoordinator.swift:\(#line)","host revised grade",["key":scoreKey,"delta":d,"newGraded":actualIsCorrect])
                    // #endregion
                }
                lastGradedByQuestion[scoreKey] = actualIsCorrect
            } else {
                totalAnswered += 1
                roundAnswered += 1
                if args.questionIndex >= 5 && !isLightningRound {
                    consumeRoundCreditOnce(reason: "round completed (Q\(args.questionIndex))")
                }
                if actualIsCorrect {
                    totalCorrect += 1
                    roundCorrect += 1
                }
                lastGradedByQuestion[scoreKey] = actualIsCorrect
            }
        } else if actualIsCorrect {
            totalCorrect += 1
            roundCorrect += 1
        }
        currentQuestionIndex = args.questionIndex

        let isHintOrChallenge = (args.wasHint ?? false) || isChallenge
        if !isHintOrChallenge {
            if isScoringRevision, let prev = priorGraded {
                let d = ScoreRevisionPolicy.correctnessDelta(previous: prev, newGraded: actualIsCorrect)
                if d > 0 { playCorrectSound() }
                else if d < 0 { playIncorrectSound() }
            } else if actualIsCorrect {
                playCorrectSound()
            } else {
                playIncorrectSound()
            }
        } else if isChallenge && actualIsCorrect {
            playCorrectSound()
        }

        if isLightningRound {
            if isScoringRevision, let prev = priorGraded, !isHintCheck, !isChallenge {
                let d = ScoreRevisionPolicy.correctnessDelta(previous: prev, newGraded: actualIsCorrect)
                lightningCorrect += d
            } else {
                lightningAnswered += 1
                if actualIsCorrect {
                    lightningCorrect += 1
                }
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

        if let questionText = args.questionText, !questionText.isEmpty, !isScoringRevision {
            let compressed = Self.compressQuestion(text: questionText, answer: args.playerAnswer)
            questionHistory.append(compressed)
            currentRoundQuestions.append(questionText)
            sessionQuestions.append(compressed)
            if questionHistory.count > 100 {
                questionHistory = Array(questionHistory.suffix(100))
            }
            saveQuestionHistory()
            // #region agent log
            _dbg("QSAVE","RealtimeGameCoordinator.swift:\(#line)","question saved to history",["compressed":compressed,"historyCount":questionHistory.count])
            // #endregion
        } else {
            print("[RealtimeGame] WARNING: report_score missing questionText — question not recorded in history")
            // #region agent log
            _dbg("QMISS","RealtimeGameCoordinator.swift:\(#line)","report_score MISSING questionText",["questionIndex":args.questionIndex,"roundNumber":String(describing:args.roundNumber),"category":args.category ?? "nil"])
            // #endregion
        }

        if isScoringRevision, let prev = priorGraded {
            gameViewModel.reviseRealtimeScore(
                fromPreviousCorrect: prev,
                to: actualIsCorrect,
                wasHint: actualHint,
                wasChallenge: actualChallenge
            )
        } else {
            gameViewModel.recordAnswerFromRealtime(
                answer: args.playerAnswer ?? "",
                isCorrect: actualIsCorrect,
                wasHint: actualHint,
                wasChallenge: actualChallenge
            )
        }

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

        // Do not park in `.showingResult`; it can block watchdog progression
        // and create long post-score stalls.
        gameViewModel.transition(to: .playing)

        if isLightningRound {
            stateManager.updateLightningTimer(
                secondsRemaining: lightningSecondsRemaining,
                lightningCorrect: lightningCorrect
            )
        } else {
            stateManager.updateScore(
                correct: totalCorrect,
                answered: totalAnswered,
                questionInRound: args.questionIndex,
                totalInRound: 5
            )
        }
        gameViewModel.displayRoundCorrect = roundCorrect
        gameViewModel.displayTotalCorrect = totalCorrect
        gameViewModel.displayQuestionInRound = args.questionIndex

        // Checkpoint logic (merged from checkpoint_game)
        var roundLimitReached = false
        if let roundNumber = args.roundNumber {
            let reportedCategory = args.category ?? currentCategory

            let isNewRound = roundNumber != currentRoundNumber && currentRoundNumber > 0
            if isNewRound {
                if !RoundTracker.shared.canPlayRound {
                    roundLimitReached = true
                    // #region agent log
                    _dbg("RLIMIT","RealtimeGameCoordinator.swift:\(#line)","ROUND_LIMIT_REACHED — scoring answer then ending",["roundNumber":roundNumber,"currentRound":currentRoundNumber,"totalRoundsAvailable":RoundTracker.shared.totalRoundsAvailable])
                    // #endregion
                    print("[RealtimeGame] Round limit reached mid-session — will force end after scoring")
                } else {
                    currentRoundConsumed = false
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
                    roundHintsUsed = 0
                    roundChallengesUsed = 0
                    currentRoundQuestions = []
                }
            }

            currentRoundNumber = roundNumber
            if !reportedCategory.isEmpty && !usedCategories.contains(reportedCategory) {
                usedCategories.append(reportedCategory)
            }
            currentCategory = reportedCategory

            // Fallback lightning detection: after every 4 standard rounds (rounds 5, 10, 15…)
            // Guard: don't restart if the timer already ran and was consumed for this round.
            if !isLightningRound && !currentRoundConsumed && currentRoundNumber >= 5 && currentRoundNumber % 5 == 0 {
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

        let ppc = currentDifficulty.pointsPerCorrect
        let isRoundComplete = args.questionIndex >= 5 && !isLightningRound

        // Use the pure `ReportScoreActionPolicy` to compute the post-score
        // regime AND the explicit `nextAction` instruction text. This
        // module is unit-tested against the regressions where the AI
        // hallucinated "no more rounds" with rounds still available
        // (debug-f3b222 3.log, 2026-05-04: R2 end with 1 left, R3 end
        // with 3 left after a mid-session purchase).
        //
        // We pass `roundsLeftAfterScoring = totalRoundsAvailable` because
        // round consumption (`RoundTracker.shared.consumeRound()`) has
        // already happened earlier in this method when applicable, so
        // `totalRoundsAvailable` already reflects the post-consumption
        // count.
        let roundsLeftAfterScoring = RoundTracker.shared.totalRoundsAvailable
        let outcome = ReportScoreActionPolicy.decide(
            questionIndex: args.questionIndex,
            isLightningRound: isLightningRound,
            canPlayRound: RoundTracker.shared.canPlayRound,
            roundsLeftAfterScoring: roundsLeftAfterScoring
        )
        let noRoundsLeft = (outcome == .roundCompleteNoRoundsLeft)
        let nextAction = ReportScoreActionPolicy.nextActionText(for: outcome)
        // Resolve the stored letter ("B") into the full spoken answer ("Oslo")
        // so both the tool result and the verbatim verdict name a real answer
        // instead of a bare letter (2026-07-21: "state the full correct answer
        // not just the letter"). Prefer the served-question buffer (survives
        // revisions) and fall back to the active question.
        let rawCorrectAnswer = enrichEntry?.correctAnswer ?? activeQuestionCorrectAnswer
        let answerOptions = enrichEntry?.options ?? activeQuestionOptions
        let spokenCorrectAnswer = AnswerGrader.spokenCorrectAnswer(
            correctAnswer: rawCorrectAnswer,
            options: answerOptions
        )
        let baseResult = ReportScoreResult(
            isCorrect: actualIsCorrect,
            correctAnswer: spokenCorrectAnswer,
            totalPoints: totalCorrect * ppc,
            roundsRemaining: roundsLeftAfterScoring,
            nextAction: nextAction
        )
        var result = baseResult.toDictionary()
        assert(ReportScoreResultContract.isValid(result),
               "report_score result missing required keys: \(ReportScoreResultContract.missingKeys(in: result))")

        // App-composed verdict line. The model reads this VERBATIM — verdicts,
        // correct answers, and point totals are app-owned facts. This closes
        // the "host said the wrong verdict / never revealed the answer /
        // spoke a different score than the screen" defect family.
        if !actualHint && !hintDenied && !challengeDenied {
            let answerForSpeech = spokenCorrectAnswer
            let sayLine: String
            if actualChallenge {
                sayLine = actualIsCorrect
                    ? VerdictLineComposer.composeChallengeOverturned(totalPoints: totalCorrect * ppc)
                    : VerdictLineComposer.composeChallengeRejected(
                        correctAnswer: answerForSpeech, totalPoints: totalCorrect * ppc)
            } else if isScoringRevision, let prev = priorGraded {
                sayLine = VerdictLineComposer.composeRevision(
                    delta: ScoreRevisionPolicy.correctnessDelta(previous: prev, newGraded: actualIsCorrect),
                    correctAnswer: answerForSpeech,
                    totalPoints: totalCorrect * ppc)
            } else {
                sayLine = VerdictLineComposer.compose(
                    isCorrect: actualIsCorrect,
                    correctAnswer: answerForSpeech,
                    pointsPerCorrect: ppc,
                    totalPoints: totalCorrect * ppc)
            }
            result["say"] = sayLine
        }
        if hintDenied {
            result["hintDenied"] = true
            result["hintDeniedMessage"] = "All \(maxHintsPerRound) hints used this round."
        }
        if challengeDenied {
            result["challengeDenied"] = true
            result["challengeDeniedMessage"] = "Challenge already used this round."
        }
        if actualChallenge && actualIsCorrect {
            result["scoreUpdated"] = true
            result["challengeOverturned"] = true
        }

        if roundLimitReached {
            result["roundLimitReached"] = true
            result["message"] = "The player has used all available rounds. The app will drive the farewell — just acknowledge this result and wait for instructions. Do NOT call end_game. Do NOT ask if they want to play again."
            // #region agent log
            _dbg("PAYWALL_POST","RealtimeGameCoordinator.swift:\(#line)","posting roundLimitReachedNotification (roundLimitReached path)",["totalCorrect":totalCorrect,"round":currentRoundNumber,"remaining":RoundTracker.shared.totalRoundsAvailable])
            // #endregion
            audioService.suspendMicForProcessing()
            submitResultImmediate(callId: callId, name: name, result: result)
            postRoundLimitReached(context: "round_limit_reached_mid_session")
            // Drive the farewell as a chain of short, explicit turns so the
            // CTA actually gets spoken (a single "say 4 things in one turn"
            // prompt was being truncated by the model).
            let chain = makeNoRoundsFarewellChain(
                finalScore: totalCorrect * currentDifficulty.pointsPerCorrect,
                roundsPlayed: currentRoundNumber,
                context: "round_limit_reached"
            )
            armNoRoundsEnd(withChain: chain)
            return
        }

        let isHintOrChallengeReport = (args.wasHint ?? false) || isChallenge

        audioService.suspendMicForProcessing()
        // #region agent log
        _dbg("H2_SCORE","RealtimeGameCoordinator.swift:\(#line)","report_score submitResultImmediate",["isRoundComplete":isRoundComplete,"isHintOrChallenge":isHintOrChallengeReport,"willNudge":false,"questionIndex":args.questionIndex])
        // #endregion
        submitResultImmediate(callId: callId, name: name, result: result)

        // Arm the dedicated post-score watchdog (5s initial, 7s escalation
        // to reconnect) to catch cases where the AI goes silent after we
        // return the score. The generic 12s watchdog was too slow: the
        // user perceived 5-20s dead pauses between every question
        // (debug-f3b222 2.log: Q1→Q2 gap 7.9s, Q4 stalled 12.6s before
        // the generic watchdog even fired, then died entirely). Any AI
        // audio delta or non-`report_score` tool call cancels these timers.
        if !isRoundComplete && !isHintOrChallengeReport && !hintDenied && !challengeDenied && !noRoundsLeft {
            startPostScoreSilenceWatchdog(reason: "post-score-armed")
            // Mark that we are awaiting the AI's get_next_question call.
            // `responseAudioDone` will re-arm the watchdog (with a sharper
            // nudge) once the AI's reaction-speech audio ends, since that
            // audio would otherwise cancel the watchdog and leave us with
            // no safety net for the post-reaction silence gap.
            pendingPostScoreContinuation = true
        }

        if hintDenied {
            Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                try? await sessionManager.send(.responseCancel)
                try? await sessionManager.send(.responseCreate(
                    instructions: "Hint DENIED — all \(maxHintsPerRound) hints used this round. Give NO clue. Tell them and continue the question."
                ))
            }
        } else if challengeDenied {
            Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                try? await sessionManager.send(.responseCancel)
                try? await sessionManager.send(.responseCreate(
                    instructions: "Challenge DENIED — challenge already used this round. Tell them and move on."
                ))
            }
        } else if noRoundsLeft {
            // #region agent log
            _dbg("NO_ROUNDS","RealtimeGameCoordinator.swift:\(#line)","noRoundsLeft path: posting notification + farewell chain",["totalCorrect":totalCorrect,"ppc":ppc,"currentRound":currentRoundNumber])
            // #endregion
            postRoundLimitReached(context: "report_score_no_rounds_left")
            // Drive the end-of-game farewell as a sequence of short
            // `responseCreate` turns (summary → CTA → goodbye). Each
            // chunk is short enough that the model reliably speaks it,
            // and the app guarantees the full message is delivered even
            // if any single turn is terse. The app ends the session
            // after the chain completes and the AI goes silent.
            let chain = makeNoRoundsFarewellChain(
                finalScore: totalCorrect * ppc,
                roundsPlayed: currentRoundNumber,
                context: "report_score_no_rounds_left"
            )
            armNoRoundsEnd(withChain: chain)
        }
    }

    private func handleGetNextQuestion(callId: String, name: String) {
        Task { @MainActor in
            // #region agent log
            _dbg("BATCH","RealtimeGameCoordinator.swift:\(#line)","get_next_question called",["hasBatch":QuestionBatchService.shared.currentBatch != nil,"hasTask":batchTask != nil])
            // #endregion

            if playerRequestedEndGame {
                _dbg("ENDGAME_TRANSCRIPT","RealtimeGameCoordinator.swift:\(#line)","blocking get_next_question — player requested end game",["round":currentRoundNumber,"question":currentQuestionIndex,"roundAnswered":roundAnswered])
                audioService.suspendMicForProcessing()
                submitResultImmediate(callId: callId, name: name, result: [
                    "error": "PLAYER_REQUESTED_END_GAME",
                    "instruction": "The player said they do NOT want to continue and wants to end the game. Do NOT ask another question. Say a brief goodbye only; the app is ending the session."
                ])
                forceEndGameFromPlayerTranscript(reason: "blocked_get_next_question")
                return
            }

            // Between-rounds continue guard. When the previous round just
            // finished, the host asks "want to keep going?" — but the mic is
            // muted while it asks, and the model tends to call
            // get_next_question ~2s after the mic finally opens, RACING the
            // player's spoken "no" and its transcription (2026-07-21 R2→R3:
            // player said "no", but Round 3 was served 1.8s after the mic
            // opened, before the decline transcript landed). Give the player a
            // real answer window here, then re-check for a decline before
            // committing to the next round.
            if roundAnswered >= 5, !isLightningRound, gameViewModel.currentSession != nil {
                let minContinueWindow: TimeInterval = 3.0
                let elapsed = answerWindowOpenedAt.map { Date().timeIntervalSince($0) }
                let waitSeconds: TimeInterval = {
                    guard let elapsed else { return 2.5 } // window never opened yet
                    return max(0, minContinueWindow - elapsed)
                }()
                if waitSeconds > 0 {
                    // #region agent log
                    _dbg("CONTINUE_GUARD","RealtimeGameCoordinator.swift:\(#line)","holding new-round serve for continue decision",["round":currentRoundNumber,"waitSec":waitSeconds,"windowElapsed":elapsed ?? -1])
                    // #endregion
                    try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
                }
                // A decline transcript may have arrived (and force-ended) while
                // we waited — bail out instead of serving the next round.
                if playerRequestedEndGame || gameViewModel.currentPhase == .gameOver {
                    _dbg("CONTINUE_GUARD","RealtimeGameCoordinator.swift:\(#line)","blocking new-round serve — player declined to continue",["round":currentRoundNumber,"roundAnswered":roundAnswered])
                    audioService.suspendMicForProcessing()
                    submitResultImmediate(callId: callId, name: name, result: [
                        "error": "PLAYER_REQUESTED_END_GAME",
                        "instruction": "The player said they do NOT want to continue. Do NOT ask another question. Say a brief goodbye only; the app is ending the session."
                    ])
                    if gameViewModel.currentPhase != .gameOver {
                        forceEndGameFromPlayerTranscript(reason: "continue_declined")
                    }
                    return
                }
            }

            // The AI is asking for the next question — clear the post-score
            // continuation flag so `responseAudioDone` won't keep re-arming
            // the silence watchdog while we're in the question-read phase
            // (`questionReadWatchdog` covers that gap). Also cancel any
            // pending post-score watchdog / escalation: the AI is clearly
            // progressing the game.
            pendingPostScoreContinuation = false
            cancelPostScoreWatchdogs()
            // Player chose to continue — cancel any pending end_game confirmation.
            endGameConfirmationPending = false

            // Soft-guard: the previous question hasn't been scored yet.
            // Nudge the AI to call report_score BUT clear the flag so a retry
            // of get_next_question will succeed — preventing a permanent freeze
            // if the AI ignores the nudge.
            if let pendingCallId = lastGetNextQuestionCallId {
                // There are TWO distinct scenarios a duplicate get_next_question
                // can represent — handle each with the correct recovery:
                //
                //   CASE A — Early duplicate (<12s since serve).
                //   The AI emitted two tool calls in the same turn and hasn't
                //   delivered the question to the player yet. Safe to re-serve
                //   the cached question under the new callId: cursor doesn't
                //   move; the AI's context gets the same data back and it
                //   proceeds to read it to the user normally.
                //
                //   CASE B — "Forgot to score" duplicate (>=12s).
                //   The AI already delivered the question, the player answered,
                //   but the AI skipped report_score and went straight to
                //   get_next_question. Re-serving the cached question here is
                //   BAD: the AI receives the same question data mid-turn, gets
                //   confused (it's "already asked" that Q), and freezes. The
                //   correct fix is to nudge the AI to call report_score first.
                //   After scoring, the AI can ask for the next question and we
                //   serve Q+1 normally.
                // Gemini Live can take several seconds to begin/read a question
                // after the tool result. In debug-f3b222 5.log, a duplicate
                // get_next_question arrived 2.57s after Q1 was served; treating
                // that as "forgot to score" cleared the active-question guard
                // and allowed Q2 to advance, so Q1 was skipped. Keep early
                // duplicates pinned to the cached question until the player has
                // realistically had time to hear and answer it.
                let rapidDuplicateWindow: TimeInterval = 12.0
                let timeSinceServe = lastQuestionServedAt.map { Date().timeIntervalSince($0) } ?? .infinity

                if timeSinceServe < rapidDuplicateWindow, let cached = lastServedQuestionResult {
                    // CASE A: re-serve cached question.
                    //
                    // Race we're guarding against (added 2026-04-18): the
                    // first get_next_question call already produced a
                    // response.create on the AI side (it began reading the
                    // question, often a few hundred ms of audio). The rapid
                    // duplicate get_next_question came in BEFORE that audio
                    // turn finished. If we just `submitResultImmediate` the
                    // cached payload here, Gemini queues a NEW response.create
                    // on top of the still-in-flight one and the player hears
                    // the same opening words doubled/garbled (R1Q4 in
                    // debug-f3b222 2.log: "host response garbled and
                    // repeated"). Issuing `responseCancel` first flushes the
                    // in-flight turn so the new tool response starts a single
                    // clean read of the question.
                    _dbg("BATCH_GUARD","RealtimeGameCoordinator.swift:\(#line)","get_next_question soft-blocked (Case A: rapid duplicate) — cancelling in-flight response then re-serving cached question",["pendingCallId":pendingCallId,"round":currentRoundNumber,"question":currentQuestionIndex,"gapSec":timeSinceServe])
                    lastGetNextQuestionCallId = callId
                    audioService.suspendMicForProcessing()
                    Task { [weak self] in
                        guard let self else { return }
                        // Best-effort: cancel any in-flight response from the
                        // first get_next_question call. If there's no active
                        // response, this is a no-op on Gemini's side.
                        try? await self.sessionManager.send(.responseCancel)
                        // Tiny pause so the cancel is processed before the new
                        // tool result lands in the AI's context.
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        self.submitResultImmediate(callId: callId, name: name, result: cached)
                    }
                    startSilenceWatchdog()
                    startQuestionReadWatchdog()
                    return
                }

                // CASE B (or no cache): AI likely delivered question but skipped
                // report_score. Nudge it to score first.
                _dbg("BATCH_GUARD","RealtimeGameCoordinator.swift:\(#line)","get_next_question soft-blocked (Case B: forgot to score) — nudging AI to call report_score",["pendingCallId":pendingCallId,"round":currentRoundNumber,"question":currentQuestionIndex,"gapSec":timeSinceServe])
                lastGetNextQuestionCallId = nil
                audioService.suspendMicForProcessing()
                Task {
                    do {
                        await self.audioService.waitForPlaybackToDrain()
                        try await self.sessionManager.submitFunctionResult(
                            callId: callId,
                            result: [
                                "error": "SCORE_PENDING",
                                "instruction": "You forgot to grade the player's answer to the previous question. Call report_score now with your grading (isCorrect, category, questionIndex, roundNumber), then call get_next_question again for the next question."
                            ],
                            name: name
                        )
                    } catch {
                        print("[RealtimeGame] Failed to submit SCORE_PENDING result: \(error)")
                    }
                }
                startSilenceWatchdog()
                return
            }

            // Batch not yet ready — wait briefly, but DO NOT exceed Gemini's
            // internal tool-call timeout (~3-5s). If we await too long, Gemini
            // cancels the tool call and we end up in a cancel/retry loop that
            // produces 5+ seconds of perceptible silence between set_game_config
            // and Q1. Instead: poll for up to ~2s; if the batch is still not
            // ready, return a BATCH_PENDING keep-alive so the AI can fill time
            // speaking, and schedule a nudge once the batch completes.
            if QuestionBatchService.shared.currentBatch == nil, let task = batchTask {
                // #region agent log
                _dbg("BATCH","RealtimeGameCoordinator.swift:\(#line)","waiting for batch generation (short poll, max 2s)…",[:])
                // #endregion
                let deadline = Date().addingTimeInterval(2.0)
                getNextQuestionAwaitingBatch = true
                while QuestionBatchService.shared.currentBatch == nil && Date() < deadline {
                    if task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }
                getNextQuestionAwaitingBatch = false

                // Did the task fail while we were polling?
                if task.isCancelled {
                    // #region agent log
                    _dbg("BATCH","RealtimeGameCoordinator.swift:\(#line)","batch task cancelled while polling",[:])
                    // #endregion
                    batchTask = nil
                    firstRoundNudgeArmed = false
                    firstRoundBatchReady = false
                    firstRoundNudgeRetryWork?.cancel()
                    firstRoundNudgeRetryWork = nil
                    audioService.suspendMicForProcessing()
                    submitResultImmediate(callId: callId, name: name, result: [
                        "error": "BATCH_UNAVAILABLE",
                        "instruction": "Generate a trivia question yourself for this round."
                    ])
                    return
                }

                // Still no batch? Return a keep-alive and let the post-batch
                // nudge in `maybeFireFirstRoundNudge` drive the retry. The
                // `firstRoundNudgeArmed` flag is already set (from
                // `set_game_config`) so we just need to make sure the AI fills
                // the brief wait with something audible.
                if QuestionBatchService.shared.currentBatch == nil {
                    // #region agent log
                    _dbg("BATCH","RealtimeGameCoordinator.swift:\(#line)","BATCH_PENDING — returning keep-alive, nudge will fire when batch ready",["firstRoundNudgeArmed":firstRoundNudgeArmed])
                    // #endregion
                    audioService.suspendMicForProcessing()
                    submitResultImmediate(callId: callId, name: name, result: [
                        "status": "preparing",
                        "instruction": "Questions are still loading — give a quick enthusiastic one-liner like \"Alright, let me pull up your first question…\" and then WAIT silently. The app will tell you the instant they're ready. Do NOT call get_next_question again on your own; the app will prompt you."
                    ])
                    return
                }
            }

            guard let next = QuestionBatchService.shared.nextQuestion() else {
                // Exhausted — trigger a new batch for the next 5 rounds
                let nextStart = currentRoundNumber + 1
                let diff = currentDifficulty.rawValue
                let ages = gameViewModel.currentSession?.ageBands.map { $0.rawValue } ?? ["adults"]
                startBatchGeneration(difficulty: diff, ageBands: ages, startingRound: nextStart)

                audioService.suspendMicForProcessing()
                submitResultImmediate(callId: callId, name: name, result: [
                    "error": "BATCH_EXHAUSTED",
                    "instruction": "Generate a trivia question yourself for this round while new questions load."
                ])
                return
            }

            // Backstop: if we're advancing into a new round but the previous
            // round was played without its Q5 ever being scored (a question
            // got skipped somehow), the "round completed (Q5)" consumption
            // never fired. Rounds are billed on completion, and moving on
            // means the previous round is complete — consume it now.
            // (2026-06-12: a challenge erased the pending-question guard,
            // R1Q5 was skipped, and round 1 was never deducted.)
            if next.round.roundNumber > currentRoundNumber, currentRoundNumber > 0,
               !currentRoundConsumed, roundAnswered >= 1 {
                _ = consumeRoundCreditOnce(reason: "round advanced with only \(roundAnswered)/5 scored")
            }

            // Guard: refuse to serve a new-round question when rounds are exhausted
            if next.round.roundNumber > currentRoundNumber && currentRoundNumber > 0 && !RoundTracker.shared.canPlayRound {
                // #region agent log
                _dbg("GUARD_ROUND","RealtimeGameCoordinator.swift:\(#line)","get_next_question BLOCKED — no rounds left",["nextRound":next.round.roundNumber,"currentRound":currentRoundNumber,"remaining":RoundTracker.shared.totalRoundsAvailable])
                // #endregion
                audioService.suspendMicForProcessing()
                submitResultImmediate(callId: callId, name: name, result: [
                    "error": "NO_ROUNDS_AVAILABLE",
                    "instruction": "The player has used all available rounds. The app will drive the farewell. Acknowledge this and wait for further instructions. Do NOT call end_game. Do NOT ask another question."
                ])
                postRoundLimitReached(context: "get_next_question_guard")
                let chain = makeNoRoundsFarewellChain(
                    finalScore: totalCorrect * currentDifficulty.pointsPerCorrect,
                    roundsPlayed: currentRoundNumber,
                    context: "get_next_question_guard"
                )
                armNoRoundsEnd(withChain: chain)
                return
            }

            // Track the category when a new round starts
            if next.questionIndex == 1 && !usedCategories.contains(next.round.category) {
                usedCategories.append(next.round.category)
            }

            // Add to session history for long-term dedup
            let compressed = Self.compressQuestion(text: next.question.questionText, answer: next.question.correctAnswer)
            sessionQuestions.append(compressed)
            activeQuestionCorrectAnswer = next.question.correctAnswer
            activeQuestionOptions = next.question.options
            let serveKey = "\(next.round.roundNumber)-\(next.questionIndex)"
            servedQuestionBuffer[serveKey] = ServedQuestionEntry(
                roundNumber: next.round.roundNumber,
                questionIndex: next.questionIndex,
                correctAnswer: next.question.correctAnswer,
                options: next.question.options,
                questionText: next.question.questionText,
                category: next.round.category,
                isLightning: next.round.isLightning
            )

            let location = locationService.currentLocationLabel ?? "somewhere in the United States"
            let isNewRound = next.questionIndex == 1
            var result: [String: Any] = [
                "roundNumber": next.round.roundNumber,
                "questionIndex": next.questionIndex,
                "category": next.round.category,
                "questionText": next.question.questionText,
                "isLightning": next.round.isLightning,
                "isNewRound": isNewRound,
                "location": location,
                "instruction": isNewRound
                    ? "Say the announce field VERBATIM, then 'Question \(next.questionIndex)', then read questionText VERBATIM. Do NOT paraphrase or reveal the answer. After the player answers, call report_score."
                    : "Say 'Question \(next.questionIndex)' then read questionText VERBATIM. Do NOT paraphrase or reveal the answer. After the player answers, call report_score."
            ]
            if isNewRound {
                // App-composed round announcement — round number, category,
                // and (critically) the lightning format are app-owned facts.
                result["announce"] = RoundIntroComposer.compose(
                    roundNumber: next.round.roundNumber,
                    category: next.round.category,
                    isLightning: next.round.isLightning,
                    locationLabel: locationService.currentLocationLabel
                )
            }
            if let options = next.question.options {
                result["options"] = options
            }

            // #region agent log
            _dbg("BATCH","RealtimeGameCoordinator.swift:\(#line)","serving question",["round":next.round.roundNumber,"qIdx":next.questionIndex,"total":next.round.questions.count,"category":next.round.category,"isLightning":next.round.isLightning,"isNew":next.questionIndex == 1,"hasOptions":next.question.options != nil])
            // #endregion

            lastGetNextQuestionCallId = callId
            lastServedQuestionResult = result
            lastQuestionServedAt = Date()
            updateTranscriptionKeyterms(
                questionText: next.question.questionText,
                options: next.question.options,
                correctAnswer: next.question.correctAnswer,
                category: next.round.category
            )
            // Answer window is CLOSED until the host finishes reading this
            // freshly-served question (reopened on the next responseAudioDone).
            answerWindowOpenedAt = nil
            answerDenialsForCurrentQuestion = 0
            // Only reset the per-question recovery budget on genuine forward
            // progress. A re-serve triggered by a tool_call_cancelled rewind is
            // the SAME question being recovered — resetting here would defeat
            // the governor's per-question cancel cap and allow an infinite
            // cancel→rewind→re-serve loop (R3 freeze).
            if reserveDueToCancelRewind {
                reserveDueToCancelRewind = false
                // #region agent log
                _dbg("REWIND","RealtimeGameCoordinator.swift:\(#line)","re-serve after cancel — preserving recovery budget",["round":next.round.roundNumber,"qIdx":next.questionIndex,"nudgeCount":recoveryState.nudgeCount,"cancelCount":recoveryState.cancelCount])
                // #endregion
            } else {
                recoveryState.resetForNewQuestion()
            }
            round1StuckEscalationWork?.cancel()
            round1StuckEscalationWork = nil
            // The Round 1 start nudge (if any) is no longer needed: a real
            // question is now on the wire.
            firstRoundNudgeArmed = false
            firstRoundBatchReady = false
            firstRoundNudgeRetryWork?.cancel()
            firstRoundNudgeRetryWork = nil
            if gameViewModel.currentPhase == .showingResult {
                gameViewModel.transition(to: .playing)
            }
            audioService.suspendMicForProcessing()
            submitResultImmediate(callId: callId, name: name, result: result)
            startSilenceWatchdog()
            startQuestionReadWatchdog()
        }
    }

    private func handleGetLocation(callId: String, name: String) {
        let location = locationService.currentLocationLabel ?? "somewhere in the United States"
        var result: [String: Any] = ["locationLabel": location]
        if !usedCategories.isEmpty {
            result["previousCategories"] = usedCategories
        }
        audioService.suspendMicForProcessing()
        submitResult(callId: callId, name: name, result: result)
    }

    private func handleEndGame(callId: String, name: String, data: Data) {
        if let args = try? JSONDecoder().decode(EndGameArgs.self, from: data) {
            print("[RealtimeGame] Game over: \(args.finalScore)/\(args.totalQuestions)")
            // #region agent log
            _dbg("C1","RealtimeGameCoordinator.swift:660","end_game called",["finalScore":args.finalScore,"totalQuestions":args.totalQuestions,"isLightningRound":self.isLightningRound,"secs":self.lightningSecondsRemaining,"announced":self.lightningAnnouncedButNotStarted,"pendingNoRoundsEnd":self.pendingNoRoundsEnd])
            // #endregion
        }

        let lightningExpirySecondsAgo: TimeInterval = lightningExpiredWithRoundsRemainingAt
            .map { Date().timeIntervalSince($0) } ?? .infinity
        let action = EndGamePolicy.decide(
            pendingNoRoundsEnd: pendingNoRoundsEnd,
            sessionAlive: gameViewModel.currentSession != nil,
            canPlayRound: RoundTracker.shared.canPlayRound,
            lightningExpiredWithRoundsRemainingSecondsAgo: lightningExpirySecondsAgo,
            isLightningRound: isLightningRound,
            roundAnswered: roundAnswered,
            endGameConfirmationPending: endGameConfirmationPending,
            playerRequestedEndGame: playerRequestedEndGame
        )

        switch action {
        case .deferDuringFarewell:
            // The AI fired end_game during the no-rounds-left farewell.
            // Acknowledge so its turn can complete cleanly, but let the
            // app's silence-based auto-end drive the actual teardown so
            // the farewell speech finishes.
            // #region agent log
            _dbg("ENDGAME_DEFERRED","RealtimeGameCoordinator.swift:\(#line)","end_game received during pendingNoRoundsEnd — acknowledging but deferring teardown to silence timer",["round":currentRoundNumber,"totalCorrect":totalCorrect])
            // #endregion
            audioService.suspendMicForProcessing()
            submitResultImmediate(callId: callId, name: name, result: [
                "acknowledged": true,
                "instruction": "Session ending. Do not speak further."
            ])
            if noRoundsEndSilenceTimer == nil {
                scheduleNoRoundsEndAfterSilence()
            }
            return

        case .rejectLightningRace:
            lightningExpiredWithRoundsRemainingAt = nil
            _dbg("ENDGAME_REJECTED","RealtimeGameCoordinator.swift:\(#line)","end_game rejected — rounds remain; instructing AI to continue",["remaining":RoundTracker.shared.totalRoundsAvailable,"round":currentRoundNumber])
            audioService.suspendMicForProcessing()
            Task {
                do {
                    await self.audioService.waitForPlaybackToDrain()
                    try await self.sessionManager.submitFunctionResult(
                        callId: callId,
                        result: [
                            "error": "ROUNDS_REMAIN",
                            "instruction": "The player still has purchased rounds available. Do NOT end the game. Ask the player if they want to continue to the next round. If yes, call get_next_question to start the next standard round."
                        ],
                        name: name
                    )
                } catch {
                    print("[RealtimeGame] Failed to submit ROUNDS_REMAIN result: \(error)")
                }
            }
            return

        case .rejectAndAskForConfirmation:
            endGameConfirmationPending = true
            _dbg("ENDGAME_REJECTED","RealtimeGameCoordinator.swift:\(#line)","end_game rejected — rounds remain; asking player to confirm",["remaining":RoundTracker.shared.totalRoundsAvailable,"round":currentRoundNumber,"totalCorrect":totalCorrect])
            audioService.suspendMicForProcessing()
            Task {
                do {
                    await self.audioService.waitForPlaybackToDrain()
                    try await self.sessionManager.submitFunctionResult(
                        callId: callId,
                        result: [
                            "error": "ROUNDS_REMAIN",
                            "instruction": "The player has \(RoundTracker.shared.totalRoundsAvailable) purchased round(s) remaining. Do NOT end the game yet. Ask the player clearly: 'You still have \(RoundTracker.shared.totalRoundsAvailable) round(s) left. Do you want to continue playing, or stop here?' If they want to continue, call get_next_question to start the next round. If they confirm they want to stop, call end_game again."
                        ],
                        name: name
                    )
                } catch {
                    print("[RealtimeGame] Failed to submit ROUNDS_REMAIN result: \(error)")
                }
            }
            return

        case .honor:
            // Clear the flag now that end_game is proceeding (no rounds
            // remain, the player confirmed via a second call, or we
            // just finished a standard round).
            endGameConfirmationPending = false
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

        let hasRoundsLeft = RoundTracker.shared.canPlayRound
        // #region agent log
        _dbg("ENDGAME","RealtimeGameCoordinator.swift:\(#line)","handleEndGame — transitioning to gameOver",["hasRoundsLeft":hasRoundsLeft,"remaining":RoundTracker.shared.totalRoundsAvailable,"round":currentRoundNumber,"totalCorrect":totalCorrect])
        // #endregion
        audioService.suspendMicForProcessing()
        submitResultImmediate(callId: callId, name: name, result: [
            "acknowledged": true,
            "instruction": hasRoundsLeft
                ? "Say a brief goodbye. Do NOT start a new game or ask to play again — the app handles that."
                : "Say a brief goodbye. The player has no rounds remaining — tell them to check the Roadtrip Trivia app on their phone to purchase a subscription or round pack for more rounds. Do NOT start a new game."
        ])

        // Disconnect after farewell speech finishes
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            self?.disconnect()
        }
    }

    // MARK: - Round 1 Start Nudge

    /// Fires the Round 1 start nudge when BOTH (a) the question batch is
    /// ready and (b) the AI is not currently speaking. If the AI is still
    /// finishing its rules walkthrough / bridge line, the nudge is deferred
    /// until the next `responseAudioDone` (the `.responseAudioDone` handler
    /// calls this again).
    ///
    /// This avoids interrupting the AI mid-word while also ensuring we don't
    /// leave the host silent after the rules end if the batch is slow.
    private func maybeFireFirstRoundNudge(trigger: String) {
        guard firstRoundNudgeArmed else { return }
        // Never fire the Round 1 nudge during end-of-game wind-down.
        guard !pendingNoRoundsEnd else {
            firstRoundNudgeArmed = false
            firstRoundNudgeRetryWork?.cancel()
            firstRoundNudgeRetryWork = nil
            return
        }
        guard firstRoundBatchReady else {
            // #region agent log
            _dbg("R1_NUDGE","RealtimeGameCoordinator.swift:\(#line)","nudge gated — batch not ready yet",["trigger":trigger])
            // #endregion
            return
        }
        // Don't interrupt the AI mid-speech. The responseAudioDone handler
        // will call us again when the turn ends.
        let phase = gameViewModel.currentPhase
        if phase == .speaking {
            // #region agent log
            _dbg("R1_NUDGE","RealtimeGameCoordinator.swift:\(#line)","nudge gated — AI still speaking, will retry on responseAudioDone",["trigger":trigger,"phase":"\(phase)"])
            // #endregion
            return
        }
        // Audio-drain gate (added 2026-04-18): `phase` flips to `.listening`
        // the instant `responseAudioDone` fires, but the device's audio
        // playback queue keeps draining for several hundred ms after that.
        // If we send the nudge before the queue drains, the player hears the
        // AI's tail clipped (e.g. "intro welcome host chat cut off" — see
        // debug-f3b222 2.log: R1 nudge fired 1ms after batch-ready then
        // mic barge-in 50ms later, both inside the playback tail). Defer
        // until the AI has been silent for at least `audioDrainGraceSeconds`.
        if let last = lastAudioDeltaAt {
            let sinceLastDelta = Date().timeIntervalSince(last)
            if sinceLastDelta < audioDrainGraceSeconds {
                let remaining = audioDrainGraceSeconds - sinceLastDelta
                // #region agent log
                _dbg("R1_NUDGE","RealtimeGameCoordinator.swift:\(#line)","nudge gated — audio still draining, deferring",["trigger":trigger,"sinceLastDeltaSec":sinceLastDelta,"deferSec":remaining])
                // #endregion
                scheduleFirstRoundNudgeRetry(after: remaining + 0.05, reason: "audio-drain")
                return
            }
        }
        // All conditions met — fire.
        firstRoundNudgeArmed = false
        firstRoundNudgeRetryWork?.cancel()
        firstRoundNudgeRetryWork = nil
        // #region agent log
        _dbg("R1_NUDGE","RealtimeGameCoordinator.swift:\(#line)","firing Round 1 start nudge",["trigger":trigger,"phase":"\(phase)"])
        // #endregion
        Task { [weak self] in
            guard let self else { return }
            try? await self.sessionManager.send(.responseCreate(
                instructions: "Questions are ready — start Round 1 NOW by calling get_next_question immediately. Do NOT ask the player 'ready?', do NOT add filler, just call the tool."
            ))
        }
        scheduleRound1StuckEscalationAfterNudge()
    }

    /// If Gemini ignores the soft Round 1 nudge, force `get_next_question` after a short wait.
    private func scheduleRound1StuckEscalationAfterNudge() {
        round1StuckEscalationWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.round1StuckEscalationWork = nil
            guard self.lastServedQuestionResult == nil else { return }
            guard self.gameViewModel.currentSession != nil else { return }
            // #region agent log
            _dbg("R1_ESCALATE","RealtimeGameCoordinator.swift:\(#line)","Round 1 stuck after nudge — escalating get_next_question",["phase":"\(self.gameViewModel.currentPhase)","totalAnswered":self.totalAnswered])
            // #endregion
            Task {
                try? await self.sessionManager.send(.responseCancel)
                try? await Task.sleep(nanoseconds: 150_000_000)
                try? await self.sessionManager.send(.responseCreate(
                    instructions: "You still have not started Round 1. Call get_next_question immediately to fetch question 1 — tool call only, no small talk."
                ))
            }
        }
        round1StuckEscalationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.5, execute: work)
    }

    /// Schedules a single deferred retry of the R1 nudge. Repeated calls
    /// coalesce so we never have more than one pending retry.
    private func scheduleFirstRoundNudgeRetry(after seconds: TimeInterval, reason: String) {
        firstRoundNudgeRetryWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.firstRoundNudgeRetryWork = nil
            self.maybeFireFirstRoundNudge(trigger: "retry-\(reason)")
        }
        firstRoundNudgeRetryWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    // MARK: - Batch Question Generation

    private func startBatchGeneration(difficulty: String, ageBands: [String], startingRound: Int) {
        // #region agent log
        _dbg("BATCH","RealtimeGameCoordinator.swift:\(#line)","startBatchGeneration",["difficulty":difficulty,"startingRound":startingRound,"historyCount":questionHistory.count,"usedCats":usedCategories.joined(separator: ",")])
        // #endregion
        QuestionBatchService.shared.reset()
        batchTask = Task {
            do {
                let key: String
                if let cached = batchAPIKey {
                    key = cached
                } else {
                    key = try await QuestionBatchService.shared.fetchAPIKey()
                    await MainActor.run { self.batchAPIKey = key }
                }

                let location = locationService.currentLocationLabel ?? "United States"
                let batch = try await QuestionBatchService.shared.generateBatch(
                    apiKey: key,
                    location: location,
                    difficulty: difficulty,
                    ageBands: ageBands,
                    questionHistory: questionHistory,
                    usedCategories: usedCategories,
                    startingRound: startingRound
                )

                // Batch just finished generating. Record that the batch is
                // ready and try to fire the Round 1 start nudge. The helper
                // checks whether the AI is mid-speech and defers to the
                // `responseAudioDone` handler if so.
                await MainActor.run {
                    if startingRound == 1 {
                        self.firstRoundBatchReady = true
                        // #region agent log
                        _dbg("BATCH","RealtimeGameCoordinator.swift:\(#line)","batch ready for Round 1 — checking nudge eligibility",["armed":self.firstRoundNudgeArmed,"phase":"\(self.gameViewModel.currentPhase)","getNextAwaitingBatch":self.getNextQuestionAwaitingBatch])
                        // #endregion
                        guard !self.getNextQuestionAwaitingBatch else {
                            // A get_next_question handler is already polling
                            // and will serve Q1 immediately. Do not also nudge
                            // Gemini to call get_next_question, or we create a
                            // duplicate tool call that can advance to Q2.
                            return
                        }
                        self.maybeFireFirstRoundNudge(trigger: "batch_ready")
                    }
                }

                return batch
            } catch {
                // On failure, clear batchTask so handleGetNextQuestion's check
                // (`batchTask != nil`) falls through to the BATCH_EXHAUSTED path
                // instead of polling a permanently-stuck task. Also fire the
                // pending nudge so the AI doesn't sit silent forever waiting
                // for questions that will never arrive.
                await MainActor.run {
                    // #region agent log
                    _dbg("BATCH","RealtimeGameCoordinator.swift:\(#line)","batch generation threw — clearing task",["error":"\(error)"])
                    // #endregion
                    self.batchTask = nil
                    if self.firstRoundNudgeArmed && startingRound == 1 {
                        self.firstRoundNudgeArmed = false
                        self.firstRoundBatchReady = false
                        self.firstRoundNudgeRetryWork?.cancel()
                        self.firstRoundNudgeRetryWork = nil
                        Task {
                            try? await self.sessionManager.send(.responseCreate(
                                instructions: "The question service is taking a moment — generate a location-appropriate trivia question yourself and start Round \(startingRound) right now."
                            ))
                        }
                    }
                }
                throw error
            }
        }
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
                self.suppressLightningToolCallRestart = true
                self.stopLightningTimer()
                if RoundTracker.shared.canPlayRound {
                    self.pendingLightningFlushInstructions = "TIME IS UP! Lightning over. Score: \(correct)/\(answered). Do NOT ask another question or call report_score. Announce score, move to next standard round."
                    // Arm the end_game guard window: the AI may try to call end_game
                    // before receiving this instruction; reject such calls.
                    self.lightningExpiredWithRoundsRemainingAt = Date()
                } else {
                    // Rounds exhausted and lightning timer expired. Have the
                    // AI announce the lightning result only; then the app
                    // drives the full farewell chain so the purchase CTA
                    // reliably gets spoken.
                    self.pendingLightningFlushInstructions = "TIME IS UP! Lightning over. Score: \(correct)/\(answered). Announce the lightning result in ONE short sentence, then stop. Do NOT ask another question. Do NOT call any tools."
                    postRoundLimitReached(context: "lightning_timeout_no_rounds")
                    let chain = self.makeNoRoundsFarewellChain(
                        finalScore: self.totalCorrect,
                        roundsPlayed: self.currentRoundNumber,
                        context: "lightning_timeout_no_rounds_start"
                    )
                    self.armNoRoundsEnd(withChain: chain)
                }
                // #region agent log
                _dbg("D1","RealtimeGameCoordinator.swift:timer0","lightning timer zero — stopLightningTimer + merge TIME IS UP into next flush",["correct":correct,"answered":answered])
                // #endregion

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
        // Only consume a round credit if a lightning round was actually running
        if isLightningRound {
            consumeRoundCreditOnce(reason: "lightning timer stop (\(lightningSecondsRemaining)s left)")
        }
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
        var raw = UserDefaults.standard.stringArray(forKey: questionHistoryKey) ?? []

        // Re-compress all entries that exceed the new 50-char topic limit or
        // lack the " | " separator. This normalizes old/bloated entries.
        var migrated = 0
        raw = raw.map { entry in
            if let sep = entry.range(of: " | ") {
                let topicPart = String(entry[entry.startIndex..<sep.lowerBound])
                if topicPart.count <= 50 { return entry }
                let answer = String(entry[sep.upperBound...])
                migrated += 1
                return Self.compressQuestion(text: topicPart, answer: answer)
            }
            migrated += 1
            return Self.compressQuestion(text: entry, answer: nil)
        }
        if migrated > 0 {
            UserDefaults.standard.set(raw, forKey: questionHistoryKey)
        }

        if raw.count > 100 {
            raw = Array(raw.suffix(100))
        }
        questionHistory = raw

        let compressedCount = questionHistory.filter { $0.contains(" | ") }.count
        let fullTextCount = questionHistory.count - compressedCount
        let totalChars = questionHistory.reduce(0) { $0 + $1.count }
        // #region agent log
        _dbg("QHIST","RealtimeGameCoordinator.swift:\(#line)","loadQuestionHistory",["count":questionHistory.count,"first3":Array(questionHistory.prefix(3)),"last3":Array(questionHistory.suffix(3))])
        // #endregion
        // #region agent log
        _dbg("H2","RealtimeGameCoordinator.swift:\(#line)","questionHistory format breakdown",["total":questionHistory.count,"compressedEntries":compressedCount,"fullTextEntries":fullTextCount,"totalChars":totalChars,"migrated":migrated])
        // #endregion
        print("[RealtimeGame] Loaded \(questionHistory.count) questions from history (\(compressedCount) compressed, \(fullTextCount) full-text, \(migrated) migrated)")
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

    // MARK: - Question History Compression

    /// Compress a full question text + answer into a compact "topic | answer" string
    /// for dedup in the system prompt. Keeps entries small to fit more history.
    /// Thin wrapper that snapshots active-question state into the pure
    /// `AnswerGrader` so it can be exercised by unit tests in isolation.
    private func appGradedCorrectness(for args: ReportScoreArgs) -> Bool {
        let roundNum = args.roundNumber ?? currentRoundNumber
        let bufKey = "\(roundNum)-\(args.questionIndex)"

        // Challenges target a previously scored question whose answer
        // has been overwritten by the next get_next_question. The ring
        // buffer keeps the authoritative answer so re-grading is exact
        // instead of falling back to the LLM's self-assessment.
        if let entry = servedQuestionBuffer[bufKey],
           (args.wasChallenge ?? false) || entry.questionIndex != currentQuestionIndex {
            return AnswerGrader.isCorrect(
                playerAnswer: args.playerAnswer,
                correctAnswer: entry.correctAnswer,
                options: entry.options,
                playerQuestionIndex: args.questionIndex,
                currentQuestionIndex: args.questionIndex,
                playerRoundNumber: roundNum,
                currentRoundNumber: roundNum,
                fallbackIsCorrect: args.isCorrect
            )
        }

        return AnswerGrader.isCorrect(
            playerAnswer: args.playerAnswer,
            correctAnswer: activeQuestionCorrectAnswer,
            options: activeQuestionOptions,
            playerQuestionIndex: args.questionIndex,
            currentQuestionIndex: currentQuestionIndex,
            playerRoundNumber: args.roundNumber,
            currentRoundNumber: currentRoundNumber,
            fallbackIsCorrect: args.isCorrect
        )
    }

    static func compressQuestion(text: String, answer: String?) -> String {
        var cleaned = text
        // Strip multi-choice option lines and everything after the first newline if it has options
        if let questionEnd = cleaned.range(of: "\n") {
            let afterNewline = String(cleaned[questionEnd.upperBound...])
            if afterNewline.contains("A)") || afterNewline.contains("A:") || afterNewline.contains("A ") ||
               afterNewline.contains("B)") || afterNewline.contains("B:") {
                cleaned = String(cleaned[cleaned.startIndex..<questionEnd.lowerBound])
            }
        }
        // Strip common preamble patterns (round announcements, numbering)
        let preamblePatterns = [
            "Final question", "Next question", "Here's question", "Question \\d+",
            "Here comes", "Alright,", "Okay,", "Let's move on", "Moving on",
            "For \\d+ points", "round coming up:"
        ]
        for pattern in preamblePatterns {
            if let range = cleaned.range(of: pattern, options: .regularExpression, range: cleaned.startIndex..<cleaned.endIndex) {
                if let colonOrColon = cleaned[range.upperBound...].range(of: ":") {
                    cleaned = String(cleaned[colonOrColon.upperBound...]).trimmingCharacters(in: .whitespaces)
                } else if let comma = cleaned[range.upperBound...].range(of: ",") {
                    let afterComma = cleaned[comma.upperBound...]
                    if afterComma.count > 10 {
                        cleaned = String(afterComma).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }
        var topic = cleaned
            .replacingOccurrences(of: "What is ", with: "")
            .replacingOccurrences(of: "What's ", with: "")
            .replacingOccurrences(of: "What are ", with: "")
            .replacingOccurrences(of: "What was ", with: "")
            .replacingOccurrences(of: "Who is ", with: "")
            .replacingOccurrences(of: "Who was ", with: "")
            .replacingOccurrences(of: "Which ", with: "")
            .replacingOccurrences(of: "Where is ", with: "")
            .replacingOccurrences(of: "Where was ", with: "")
            .replacingOccurrences(of: "How many ", with: "#")
            .replacingOccurrences(of: "Is it ", with: "")
            .replacingOccurrences(of: "Was it ", with: "")
            .replacingOccurrences(of: "the name of ", with: "")
            .replacingOccurrences(of: "the term for ", with: "")
        topic = topic.trimmingCharacters(in: CharacterSet(charactersIn: "? \n\t"))
        if topic.count > 50 {
            topic = String(topic.prefix(50))
        }
        let ans = (answer ?? "").isEmpty ? "?" : answer!
        return "\(topic) | \(ans)"
    }

    // MARK: - Submit Function Result

    /// Queue a function result for batched submission. The result is sent to the
    /// session manager's buffer, then flushed as a single `toolResponse` when
    /// `responseDone` fires (or immediately if lightning TIME IS UP is pending).
    private func submitResult(callId: String, name: String, result: [String: Any]) {
        lastToolEventAt = Date()
        Task { @MainActor in
            do {
                try await sessionManager.queueFunctionResult(callId: callId, result: result, name: name)
                await audioService.waitForPlaybackToDrain()
                try await sessionManager.flushPendingResults()
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
    private func submitResultImmediate(callId: String, name: String, result: [String: Any]) {
        lastToolEventAt = Date()
        Task {
            do {
                // Queue the tool output immediately so response.done can mark
                // the turn finished even if playback drain takes several seconds.
                // Drain only gates the follow-up response.create.
                try await sessionManager.queueFunctionResult(callId: callId, result: result, name: name)
                await audioService.waitForPlaybackToDrain()
                try await sessionManager.flushPendingResults()
            } catch {
                print("[RealtimeGame] Failed to submit function result: \(error)")
            }
        }
    }

    /// Flush any pending batched results when the LLM finishes a response turn.
    private func flushPendingResults() {
        Task { @MainActor in
            do {
                // xAI can finish producing a response before its final audio
                // buffers have played locally. Do not start the tool follow-up
                // until the current host utterance has drained.
                await audioService.waitForPlaybackToDrain()
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
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var isReconnecting = false

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

                if connected && self.pausedByConnectionLoss && !self.isReconnecting {
                    print("[RealtimeGame] Network path restored — scheduling reconnect with full context")
                    self.scheduleReconnect()
                }
            }
            .store(in: &cancellables)
    }

    /// Schedule a reconnection attempt with exponential backoff and max retry enforcement.
    private func scheduleReconnect() {
        reconnectWorkItem?.cancel()

        guard reconnectAttempts < maxReconnectAttempts else {
            // #region agent log
            _dbg("RECONN_EXHAUST","RealtimeGameCoordinator.swift:\(#line)","reconnect attempts exhausted — ending game gracefully",["attempts":reconnectAttempts,"maxAttempts":maxReconnectAttempts,"round":currentRoundNumber])
            // #endregion
            print("[RealtimeGame] Reconnect exhausted (\(reconnectAttempts)/\(maxReconnectAttempts)) — ending game gracefully")
            pausedByConnectionLoss = false
            isReconnecting = false
            connectionMonitor.speakOffline("Sorry, we couldn't reconnect. Your progress has been saved. You can restart the game to continue.")
            handleNetworkError()
            return
        }

        let delay = pow(2.0, Double(reconnectAttempts)) + 1.0
        reconnectAttempts += 1

        // #region agent log
        _dbg("RECONN_SCHED","RealtimeGameCoordinator.swift:\(#line)","scheduleReconnect",["attempt":reconnectAttempts,"maxAttempts":maxReconnectAttempts,"delaySec":delay,"round":currentRoundNumber,"question":currentQuestionIndex])
        // #endregion

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pausedByConnectionLoss else { return }
            guard self.connectionMonitor.isConnected else {
                print("[RealtimeGame] Reconnect deferred — network path still down")
                return
            }
            print("[RealtimeGame] Reconnecting (attempt \(self.reconnectAttempts)/\(self.maxReconnectAttempts))")
            // #region agent log
            _dbg("E2","RealtimeGameCoordinator.swift:reconnect","scheduleReconnect firing",["attempt":self.reconnectAttempts,"round":self.currentRoundNumber,"question":self.currentQuestionIndex,"score":self.totalCorrect])
            // #endregion
            self.reconnectAfterConnectionLoss()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Arms (or re-arms) the post-reconnect resume watchdog. Call once right
    /// after the reconnect's resume `responseCreate` is sent. If no AI audio
    /// arrives within `reconnectResumeSilenceSeconds`, the resume stalled:
    /// retry the nudge once, then on a second timeout end gracefully so the
    /// player isn't left in indefinite dead air.
    private func armReconnectResumeWatchdog() {
        reconnectResumeWatchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.gameViewModel.currentSession != nil else { return }
            // If audio started since we armed, the resume succeeded.
            let silentFor = self.lastAudioDeltaAt.map { Date().timeIntervalSince($0) } ?? .infinity
            guard silentFor >= self.reconnectResumeSilenceSeconds else { return }

            if self.reconnectResumeRetries == 0 {
                self.reconnectResumeRetries += 1
                // #region agent log
                _dbg("RECONN_RESUME","RealtimeGameCoordinator.swift:\(#line)","resume silent — retrying nudge once",["round":self.currentRoundNumber,"question":self.currentQuestionIndex,"silentFor":silentFor])
                // #endregion
                print("[RealtimeGame] Reconnect resume stalled — retrying resume nudge")
                let retry = "Continue the game now. Resume Round \(self.currentRoundNumber), Question \(self.currentQuestionIndex + 1)/5 using the GAME STATE JSON. Speak now — do NOT re-ask or re-score anything."
                Task { [weak self] in
                    try? await self?.sessionManager.send(.responseCreate(instructions: retry))
                }
                self.armReconnectResumeWatchdog()
            } else {
                // #region agent log
                _dbg("RECONN_RESUME","RealtimeGameCoordinator.swift:\(#line)","resume failed twice — ending gracefully instead of dead air",["round":self.currentRoundNumber,"question":self.currentQuestionIndex])
                // #endregion
                print("[RealtimeGame] Reconnect resume failed twice — ending gracefully")
                self.reconnectResumeRetries = 0
                self.connectionMonitor.speakOffline("Sorry, I'm having trouble getting back into the game. Your progress is saved — you can restart to keep playing.")
                self.handleNetworkError()
            }
        }
        reconnectResumeWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectResumeSilenceSeconds, execute: item)
    }

    private func cancelReconnectResumeWatchdog() {
        reconnectResumeWatchdog?.cancel()
        reconnectResumeWatchdog = nil
        reconnectResumeRetries = 0
    }

    // MARK: - Game State Packet

    private func buildStatePacket() -> GameStatePacket {
        let session = gameViewModel.currentSession
        return GameStatePacket(
            roundNumber: currentRoundNumber,
            questionIndex: currentQuestionIndex,
            category: currentCategory,
            difficulty: currentDifficulty.rawValue,
            playerCount: session?.playerCount ?? 1,
            teamName: session?.teamName ?? "Team",
            ageBands: session?.ageBands.map { $0.rawValue } ?? ["adults"],
            totalCorrect: totalCorrect,
            totalAnswered: totalAnswered,
            roundCorrect: roundCorrect,
            roundAnswered: roundAnswered,
            totalPoints: totalCorrect * currentDifficulty.pointsPerCorrect,
            roundPoints: roundCorrect * currentDifficulty.pointsPerCorrect,
            hintsUsed: roundHintsUsed,
            challengesUsed: roundChallengesUsed,
            isLightningRound: isLightningRound,
            lightningSecondsRemaining: isLightningRound ? lightningSecondsRemaining : nil,
            currentRoundQuestions: currentRoundQuestions,
            usedCategories: usedCategories
        )
    }

    // MARK: - Silence Watchdog

    private func startSilenceWatchdog(reason: String = "generic", instructions: String? = nil) {
        silenceWatchdog?.cancel()
        let nudgeText = instructions ?? "You went silent. Continue the game: if you have a pending question to read, read it aloud; if you owe a score for the previous question, call report_score; otherwise call get_next_question to keep the game moving."
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Only fire while a game session is active. This permits the
            // watchdog to catch freezes even before the first report_score
            // (e.g. AI silent on Q1), while preventing spurious nudges in
            // pre-game setup.
            guard self.gameViewModel.currentSession != nil else { return }
            // #region agent log
            _dbg("WATCHDOG","RealtimeGameCoordinator.swift:\(#line)","silence watchdog FIRED — AI unresponsive for \(self.silenceTimeoutSeconds)s",["round":self.currentRoundNumber,"question":self.currentQuestionIndex,"phase":"\(self.gameViewModel.currentPhase)","reason":reason])
            // #endregion
            print("[RealtimeGame] Silence watchdog fired (\(reason)) — nudging AI after \(self.silenceTimeoutSeconds)s of silence")
            guard self.permitRecovery(.softNudge, context: "silence-\(reason)") else { return }
            Task {
                try? await self.sessionManager.send(.responseCreate(
                    instructions: nudgeText
                ))
            }
        }
        silenceWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + silenceTimeoutSeconds, execute: item)
    }

    /// Arms the dedicated post-score watchdog (5s). If no AI audio arrives
    /// in that window, sends `responseCancel` → small delay → `responseCreate`
    /// to jog the AI out of a stuck/empty turn, then arms the escalation
    /// watchdog (7s). If escalation also fires (nudge produced no audio —
    /// Gemini's "accepted input, zero output" failure mode), triggers
    /// `scheduleReconnect()` which preserves the session resumption handle.
    ///
    /// `reason` is one of:
    ///   • "post-score-armed"        — armed the moment the score is accepted
    ///   • "post-score-continuation" — re-armed after reaction audio ends
    private func startPostScoreSilenceWatchdog(reason: String) {
        postScoreSilenceWatchdog?.cancel()
        postScoreEscalationWatchdog?.cancel()
        postScoreEscalationWatchdog = nil
        postScoreNudgeFiredWithoutAudio = false

        let armedAt = Date()
        let nudgeText: String
        let timeout: Double
        switch reason {
        case "post-score-continuation":
            nudgeText = "Call get_next_question NOW. Do NOT re-ask or re-read the previous question — it has already been scored."
            timeout = postScoreContinuationSilenceSeconds
        default:
            nudgeText = "React briefly (one sentence) to the player's last answer, then call get_next_question immediately."
            timeout = postScoreInitialSilenceSeconds
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let recentAudioGap = self.lastAudioDeltaAt
                .map { Date().timeIntervalSince($0) } ?? .infinity
            let phase = self.gameViewModel.currentPhase
            let policyPhase: HostPhase = {
                switch phase {
                case .speaking: return .speaking
                case .listening: return .listening
                default: return .other
                }
            }()
            let policyReason: PostScoreReason = (reason == "post-score-continuation") ? .continuation : .armed

            let recentToolGap = self.lastToolEventAt
                .map { Date().timeIntervalSince($0) } ?? .infinity

            let action = PostScoreWatchdogPolicy.decide(
                sessionAlive: self.gameViewModel.currentSession != nil,
                pendingNoRoundsEnd: self.pendingNoRoundsEnd,
                phase: policyPhase,
                secondsSinceLastAudioDelta: recentAudioGap,
                reason: policyReason,
                secondsSinceLastToolEvent: recentToolGap
            )

            switch action {
            case .skip:
                return
            case .reArm(let why):
                // #region agent log
                _dbg("POST_SCORE_WATCHDOG","RealtimeGameCoordinator.swift:\(#line)","initial nudge skipped — \(why); re-arming",["reason":reason,"round":self.currentRoundNumber,"question":self.currentQuestionIndex,"armedAgoSec":Date().timeIntervalSince(armedAt),"recentAudioGapSec":recentAudioGap])
                // #endregion
                self.startPostScoreSilenceWatchdog(reason: reason)
                return
            case .fireSoft, .fireHard:
                // fireHard no longer sends responseCancel ("[stop]"):
                // text input already interrupts the current generation,
                // and the explicit stop orphaned in-flight function calls
                // (toolCallCancellation → re-grade loop → 1001 close).
                // "Hard" now means: nudge + arm the escalation watchdog.
                let isHard = (action == .fireHard)
                // #region agent log
                _dbg("POST_SCORE_WATCHDOG","RealtimeGameCoordinator.swift:\(#line)","initial nudge FIRED — sending responseCreate\(isHard ? " + arming escalation" : "")",["reason":reason,"round":self.currentRoundNumber,"question":self.currentQuestionIndex,"phase":"\(phase)","armedAgoSec":Date().timeIntervalSince(armedAt),"isHard":isHard])
                // #endregion
                print("[RealtimeGame] Post-score watchdog (\(reason)) fired after \(timeout)s — soft nudge\(isHard ? " + escalation armed" : "")")

                guard self.permitRecovery(.softNudge,
                                          context: "post-score-\(reason)") else { return }
                self.postScoreNudgeFiredWithoutAudio = true

                Task { [weak self] in
                    guard let self else { return }
                    try? await self.sessionManager.send(.responseCreate(instructions: nudgeText))
                }

                if isHard {
                    self.armPostScoreEscalationWatchdog(reason: reason)
                }
            }
        }
        postScoreSilenceWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
    }

    /// Arms the escalation-stage post-score watchdog (7s after the initial
    /// nudge fired). Only fires if `postScoreNudgeFiredWithoutAudio` is
    /// still true, meaning the nudge did not elicit any AI audio. In that
    /// case we trigger `scheduleReconnect()` to recover the session.
    private func armPostScoreEscalationWatchdog(reason: String) {
        postScoreEscalationWatchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.gameViewModel.currentSession != nil else { return }
            guard self.postScoreNudgeFiredWithoutAudio else {
                // Audio started — false alarm, clear.
                self.postScoreEscalationWatchdog = nil
                return
            }
            // Tool activity since the nudge means the model is alive and
            // working (e.g. it responded to the nudge by calling
            // get_next_question, whose audio hasn't started yet). Tearing
            // down the session here would kill a healthy game — re-check
            // after another escalation window instead.
            let toolGap = self.lastToolEventAt
                .map { Date().timeIntervalSince($0) } ?? .infinity
            if toolGap < self.postScoreEscalationSilenceSeconds {
                // #region agent log
                _dbg("POST_SCORE_WATCHDOG","RealtimeGameCoordinator.swift:\(#line)","escalation deferred — tool activity \(String(format: "%.1f", toolGap))s ago; model alive",["reason":reason,"round":self.currentRoundNumber,"question":self.currentQuestionIndex])
                // #endregion
                self.armPostScoreEscalationWatchdog(reason: reason)
                return
            }
            // #region agent log
            _dbg("POST_SCORE_WATCHDOG","RealtimeGameCoordinator.swift:\(#line)","escalation FIRED — nudge produced no audio; triggering reconnect",["reason":reason,"round":self.currentRoundNumber,"question":self.currentQuestionIndex,"phase":"\(self.gameViewModel.currentPhase)"])
            // #endregion
            print("[RealtimeGame] Post-score escalation fired — nudge produced no audio. Reconnecting to clear Gemini stuck state.")

            // Reset state before reconnect so the post-score flow can
            // re-arm cleanly once the resumed session is back online.
            self.postScoreSilenceWatchdog?.cancel()
            self.postScoreSilenceWatchdog = nil
            self.postScoreEscalationWatchdog = nil
            self.postScoreNudgeFiredWithoutAudio = false

            // Drive the proven reconnect path. It preserves the resumption
            // handle so game context (round/score/question) survives.
            guard !self.pausedByConnectionLoss && !self.isReconnecting else { return }
            self.pausedByConnectionLoss = true
            self.audioService.stopStreaming()
            self.gameViewModel.transition(to: .paused)
            self.connectionMonitor.speakOffline("Hold on, reconnecting.")
            self.scheduleReconnect()
        }
        postScoreEscalationWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + postScoreEscalationSilenceSeconds, execute: item)
    }

    private func cancelSilenceWatchdog() {
        silenceWatchdog?.cancel()
        silenceWatchdog = nil
    }

    /// Cancels both post-score watchdogs and clears the "nudge fired with no audio"
    /// tracking flag. Called any time we see evidence that the AI IS responding
    /// (audio delta, tool call, successful question serve) or we intentionally
    /// tear everything down (disconnect, game entry).
    private func cancelPostScoreWatchdogs() {
        postScoreSilenceWatchdog?.cancel()
        postScoreSilenceWatchdog = nil
        postScoreEscalationWatchdog?.cancel()
        postScoreEscalationWatchdog = nil
        postScoreNudgeFiredWithoutAudio = false
    }

    /// Arm the post-question-serve watchdog. Call this immediately after a
    /// question has been submitted to the AI via `submitResultImmediate`.
    /// Fires after `questionReadTimeoutSeconds`; only takes action if the AI
    /// has been silent (no audio delta) for at least
    /// `questionReadSilenceThreshold` seconds — this avoids interrupting a
    /// healthy read-in-progress.
    private func startQuestionReadWatchdog() {
        questionReadWatchdog?.cancel()
        let armedAt = Date()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let phase = self.gameViewModel.currentPhase
            let policyPhase: QuestionReadPhase = {
                switch phase {
                case .speaking: return .speaking
                case .listening: return .listening
                case .gameOver, .connecting, .idle, .paused, .resumePrompt:
                    return .ineligible
                default: return .other
                }
            }()
            let silentSince = self.lastAudioDeltaAt
                .map { Date().timeIntervalSince($0) } ?? .infinity

            // Decision logic lives in `QuestionReadWatchdogPolicy` so we can
            // unit-test every regression that's chopped off the host
            // mid-question (debug-f3b222 3.log, 2026-05-04: silentSec 2.65–
            // 2.9s firing `responseCancel` during natural read pauses).
            let action = QuestionReadWatchdogPolicy.decide(
                sessionAlive: self.gameViewModel.currentSession != nil,
                pendingNoRoundsEnd: self.pendingNoRoundsEnd,
                phase: policyPhase,
                secondsSinceLastAudioDelta: silentSince,
                silenceThreshold: self.questionReadSilenceThreshold
            )

            switch action {
            case .skip(let why):
                // #region agent log
                _dbg("QREAD_WATCHDOG","RealtimeGameCoordinator.swift:\(#line)","skipping nudge — \(why)",["silentSec":silentSince,"armedAgoSec":Date().timeIntervalSince(armedAt),"round":self.currentRoundNumber,"question":self.currentQuestionIndex,"phase":"\(phase)"])
                // #endregion
                return

            case .fireSoftNudge:
                // #region agent log
                _dbg("QREAD_WATCHDOG","RealtimeGameCoordinator.swift:\(#line)","AI silent post-serve — soft re-prompt",["silentSec":silentSince,"round":self.currentRoundNumber,"question":self.currentQuestionIndex,"phase":"\(phase)","stuckSpeaking":false])
                // #endregion
                print("[RealtimeGame] questionReadWatchdog fired — soft re-prompt after \(silentSince)s silence")
                guard self.permitRecovery(.softNudge, context: "question-read-soft") else { return }
                Task { [weak self] in
                    guard let self else { return }
                    try? await self.sessionManager.send(.responseCreate(
                        instructions: "Go ahead and read the question from the get_next_question tool result now: say \"Question X\" using its questionIndex, then read the questionText word-for-word followed by all four options. No transition, no preamble — straight into the question."
                    ))
                }

            case .fireStuckSpeakingRecovery:
                // #region agent log
                _dbg("QREAD_WATCHDOG","RealtimeGameCoordinator.swift:\(#line)","AI silent post-serve — forcing question read",["silentSec":silentSince,"round":self.currentRoundNumber,"question":self.currentQuestionIndex,"phase":"\(phase)","stuckSpeaking":true])
                // #endregion
                print("[RealtimeGame] questionReadWatchdog fired — clearing stuck turn after \(silentSince)s silence")
                // We deliberately NO LONGER send responseCancel here. When a
                // get_next_question call is in-flight, responseCancel orphans it
                // → Gemini emits tool_call_cancelled → the cancel handler rewinds
                // and re-prompts → the model re-issues the call → this watchdog
                // cancels again: an unbreakable loop that froze R3
                // (debug-f3b222.log 2026-06-24). A plain text responseCreate
                // already interrupts the current generation. Once the per-question
                // cancel budget is spent, escalate to a full reconnect instead of
                // nudging in place forever.
                let stuckVerdict = TurnRecoveryGovernor.decide(
                    kind: .cancelAndNudge,
                    now: Date().timeIntervalSince1970,
                    state: self.recoveryState
                )
                if case .denyCancelBudget = stuckVerdict {
                    self.escalateStuckToReconnect(context: "question-read-stuck")
                    return
                }
                guard self.permitRecovery(.cancelAndNudge, context: "question-read-stuck") else { return }
                // Force phase back to listening so the mic can re-engage, then
                // nudge with plain text only (no responseCancel — see above).
                self.gameViewModel.transition(to: .listening)
                Task { [weak self] in
                    guard let self else { return }
                    try? await self.sessionManager.send(.responseCreate(
                        instructions: "Go ahead and read the question from the get_next_question tool result now: say \"Question X\" using its questionIndex, then read the questionText word-for-word followed by all four options. No transition, no preamble — straight into the question."
                    ))
                }
            }
        }
        questionReadWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + questionReadTimeoutSeconds, execute: item)
    }

    private func cancelQuestionReadWatchdog() {
        questionReadWatchdog?.cancel()
        questionReadWatchdog = nil
    }

    /// Escalates a wedged question-read turn to a full reconnect using the
    /// proven path that preserves the session resumption handle (round / score /
    /// question survive). Called when in-place recovery has spent its
    /// per-question cancel budget — nudging further would just spin (see the
    /// R3 tool_call_cancelled loop, 2026-06-24).
    private func escalateStuckToReconnect(context: String) {
        guard !pausedByConnectionLoss && !isReconnecting else { return }
        // #region agent log
        _dbg("QREAD_WATCHDOG","RealtimeGameCoordinator.swift:\(#line)","recovery budget exhausted — escalating to reconnect",["context":context,"round":currentRoundNumber,"question":currentQuestionIndex])
        // #endregion
        print("[RealtimeGame] Question-read recovery exhausted — reconnecting to clear stuck state (\(context))")
        _ = permitRecovery(.reconnectEscalation, context: "\(context)-reconnect")
        pausedByConnectionLoss = true
        audioService.stopStreaming()
        gameViewModel.transition(to: .paused)
        connectionMonitor.speakOffline("Hold on, reconnecting.")
        scheduleReconnect()
    }

    /// Arms / re-arms the mid-turn silence watchdog. Called from
    /// `responseAudioDelta` so each fresh chunk pushes the deadline forward.
    /// If `midTurnSilenceTimeoutSeconds` elapse without another delta AND
    /// `phase == .speaking` AND we never received `responseAudioDone`, the
    /// turn is stuck — we force `phase → .listening` and send
    /// `responseCancel` to clear it.
    private func armMidTurnSilenceWatchdog() {
        midTurnSilenceWatchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.gameViewModel.currentSession != nil else { return }
            // Don't fight the no-rounds-left farewell flow.
            guard !self.pendingNoRoundsEnd else { return }

            let phase = self.gameViewModel.currentPhase
            guard phase == .speaking else {
                // We already transitioned out (responseAudioDone fired) —
                // this watchdog has nothing to do.
                self.midTurnSilenceWatchdog = nil
                return
            }
            let silentSince = self.lastAudioDeltaAt.map { Date().timeIntervalSince($0) } ?? .infinity
            if silentSince < self.midTurnSilenceTimeoutSeconds - 0.5 {
                // A delta arrived between scheduling and firing — re-arm
                // for the remaining window instead of false-firing.
                self.armMidTurnSilenceWatchdog()
                return
            }
            // #region agent log
            _dbg("MIDTURN_WATCHDOG","RealtimeGameCoordinator.swift:\(#line)","stuck-speaking detected — unsticking phase + responseCancel",["silentSec":silentSince,"round":self.currentRoundNumber,"question":self.currentQuestionIndex])
            // #endregion
            print("[RealtimeGame] midTurnSilenceWatchdog fired — AI stopped streaming mid-turn after \(silentSince)s; unsticking phase")

            guard self.permitRecovery(.cancelAndNudge, context: "mid-turn-stuck") else {
                // Denied: still unstick the phase so the mic re-engages, but
                // don't send another cancel into the model.
                self.gameViewModel.transition(to: .listening)
                self.midTurnSilenceWatchdog = nil
                return
            }
            // Force phase out of .speaking so the mic gating re-enables.
            self.gameViewModel.transition(to: .listening)
            Task { [weak self] in
                try? await self?.sessionManager.send(.responseCancel)
            }
            // Don't issue a fresh responseCreate here. The other watchdogs
            // (questionReadWatchdog if a question was just served,
            // postScoreSilenceWatchdog if we were waiting on a continuation)
            // will pick up the recovery now that phase is no longer wedged.
            self.midTurnSilenceWatchdog = nil
        }
        midTurnSilenceWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + midTurnSilenceTimeoutSeconds, execute: item)
    }

    private func cancelMidTurnSilenceWatchdog() {
        midTurnSilenceWatchdog?.cancel()
        midTurnSilenceWatchdog = nil
    }

    // MARK: - Consolidated Watchdog Teardown

    /// Cancels every game watchdog in one call. Use in full teardown paths
    /// (`resetGameTrackingState`, disconnect, `startNewGame`) to avoid
    /// stale timers surviving across sessions.
    ///
    /// Watchdog ownership by game phase:
    ///  ┌─────────────────────┬───────────────────────────────────────────┐
    ///  │ Phase               │ Active watchdog(s)                        │
    ///  ├─────────────────────┼───────────────────────────────────────────┤
    ///  │ Question served     │ silenceWatchdog + questionReadWatchdog    │
    ///  │ AI speaking         │ midTurnSilenceWatchdog (re-armed on Δ)   │
    ///  │ Post-score          │ postScoreSilence → postScoreEscalation   │
    ///  │ R1 batch wait       │ round1StuckEscalationWork                │
    ///  └─────────────────────┴───────────────────────────────────────────┘
    private func cancelAllGameWatchdogs() {
        cancelSilenceWatchdog()
        cancelPostScoreWatchdogs()
        cancelQuestionReadWatchdog()
        cancelMidTurnSilenceWatchdog()
        cancelReconnectResumeWatchdog()
        round1StuckEscalationWork?.cancel()
        round1StuckEscalationWork = nil
    }

    // MARK: - No-Rounds-Left End-of-Game Driver

    /// Builds the sequential farewell scripts played when rounds are
    /// exhausted. Each string is its own short `responseCreate` turn so
    /// the AI is more likely to actually speak each part — long "say all
    /// four of these things in one turn" prompts tend to get truncated.
    ///
    /// - Parameters:
    ///   - finalScore: Player's final total points.
    ///   - roundsPlayed: How many rounds the player completed this session.
    ///     When zero (e.g. lightning-timeout mid-round), the round summary
    ///     chunk is simplified.
    ///   - context: Short tag for logging / minor wording variants
    ///     ("report_score", "round_limit_reached", "lightning_timeout",
    ///     "get_next_question_guard").
    private func makeNoRoundsFarewellChain(
        finalScore: Int,
        roundsPlayed: Int,
        context: String
    ) -> [FarewellChunk] {
        FarewellScript.makeNoRoundsChain(
            finalScore: finalScore,
            roundsPlayed: roundsPlayed,
            context: context
        )
    }

    /// Arms the app-driven end-of-game flow used when the player exhausts
    /// their available rounds. Takes an ordered list of short farewell
    /// scripts — one sentence each — that will be sent as separate
    /// `responseCreate` turns. The first script is sent immediately; each
    /// subsequent `responseAudioDone` triggers the next. This guarantees
    /// the full farewell (summary + "rounds exhausted" + purchase CTA +
    /// goodbye) is delivered, even when a single long prompt would be
    /// truncated by the model.
    ///
    /// Also schedules a hard fallback timeout so the session always ends,
    /// even if the AI goes silent or never stops.
    private func armNoRoundsEnd(withChain chain: [FarewellChunk]) {
        pendingNoRoundsEnd = true
        farewellChain = chain
        farewellChainIndex = 0
        farewellChunkAudioStarted = false
        noRoundsEndFallback?.cancel()
        noRoundsEndSilenceTimer?.cancel()
        noRoundsEndSilenceTimer = nil
        // The farewell chain owns all nudging from here; a lingering
        // post-score timer could fire a reconnect mid-goodbye, and a
        // mid-turn silence watchdog could yank the player out of the
        // farewell because brief gaps between chunks look like a stall.
        cancelPostScoreWatchdogs()
        cancelMidTurnSilenceWatchdog()

        // Lock the mic for the entire farewell. User speech during the
        // farewell causes barge-ins that cancel the AI's response mid-
        // sentence — in `debug-f3b222 6.log` this killed chunk 3 (the
        // purchase CTA) and the AI generated an off-script response to
        // the user's interruption instead.
        audioService.setFarewellMute(true)

        let fallback = DispatchWorkItem { [weak self] in
            guard let self, self.pendingNoRoundsEnd else { return }
            // #region agent log
            _dbg("NO_ROUNDS_END","RealtimeGameCoordinator.swift:\(#line)","fallback timer fired — auto-ending (AI never settled)",["round":self.currentRoundNumber,"totalCorrect":self.totalCorrect,"chainIndex":self.farewellChainIndex,"chainCount":self.farewellChain.count])
            // #endregion
            self.triggerInternalEndGame(reason: "fallback")
        }
        noRoundsEndFallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + noRoundsEndFallbackSeconds, execute: fallback)

        // #region agent log
        _dbg("NO_ROUNDS_END","RealtimeGameCoordinator.swift:\(#line)","armed farewell chain — app will auto-end after chain completes + silence, or \(Int(noRoundsEndFallbackSeconds))s fallback",["round":currentRoundNumber,"totalCorrect":totalCorrect,"chainCount":chain.count])
        // #endregion

        sendNextFarewellChunk(reason: "initial")
    }

    /// Sends the next farewell line via xAI `force_message` (verbatim TTS).
    /// No-op if the chain is done.
    private func sendNextFarewellChunk(reason: String) {
        guard pendingNoRoundsEnd else { return }
        guard farewellChainIndex < farewellChain.count else {
            // #region agent log
            _dbg("NO_ROUNDS_END","RealtimeGameCoordinator.swift:\(#line)","farewell chain complete — waiting for silence",["reason":reason,"chainCount":farewellChain.count])
            // #endregion
            return
        }
        let idx = farewellChainIndex
        let chunk = farewellChain[idx]
        let spoken = chunk.spokenText
        farewellChainIndex += 1

        // #region agent log
        _dbg("NO_ROUNDS_END","RealtimeGameCoordinator.swift:\(#line)","sending farewell force_message",["reason":reason,"step":idx + 1,"of":farewellChain.count,"chars":spoken.count])
        // #endregion

        farewellChunkAudioStarted = false

        // Per-chunk timeout: if no `responseAudioDone` arrives, speak the
        // same line locally and advance so the CTA/goodbye are never dropped.
        farewellChunkTimeoutWork?.cancel()
        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self, self.pendingNoRoundsEnd else { return }
            let state = FarewellState(
                chainIndex: self.farewellChainIndex,
                chainCount: self.farewellChain.count,
                chunkAudioStarted: self.farewellChunkAudioStarted
            )
            let action = FarewellAdvancer.handle(.chunkTimeout, state: state)
            // #region agent log
            _dbg("NO_ROUNDS_END","RealtimeGameCoordinator.swift:\(#line)","chunk timeout fired — forcing advancement",["chainIndex":self.farewellChainIndex,"chainCount":self.farewellChain.count,"chunkAudioStarted":self.farewellChunkAudioStarted,"action":"\(action)"])
            // #endregion
            if !self.farewellChunkAudioStarted {
                let failedIndex = max(0, self.farewellChainIndex - 1)
                if failedIndex < self.farewellChain.count {
                    let fallbackLine = self.farewellChain[failedIndex].fallbackSpeech
                    _dbg("NO_ROUNDS_END","RealtimeGameCoordinator.swift:\(#line)","speaking chunk fallback via local TTS",["failedIndex":failedIndex])
                    self.connectionMonitor.speakOffline(fallbackLine)
                }
            }
            switch action {
            case .sendNextChunk:
                self.farewellChunkAudioStarted = false
                self.sendNextFarewellChunk(reason: "chunkTimeout")
            case .armSilenceAutoEnd:
                self.farewellChunkAudioStarted = false
                self.scheduleNoRoundsEndAfterSilence()
            case .markAudioStarted, .ignoreEarlyDone:
                break
            }
        }
        farewellChunkTimeoutWork = timeoutItem
        DispatchQueue.main.asyncAfter(deadline: .now() + farewellChunkTimeoutSeconds, execute: timeoutItem)

        // Natural sentence beat between farewell lines.
        let delayNs: UInt64 = (idx == 0) ? 300_000_000 : 800_000_000
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            // force_message IS the turn — do not send response.create after it.
            try? await self?.sessionManager.send(.forceMessage(text: spoken, interruptible: false))
        }
    }

    /// Bias Grok ASR toward the current question's answer vocabulary.
    private func updateTranscriptionKeyterms(
        questionText: String?,
        options: [String]?,
        correctAnswer: String?,
        category: String?
    ) {
        let terms = TranscriptionKeytermsBuilder.build(
            questionText: questionText,
            options: options,
            correctAnswer: correctAnswer,
            category: category
        )
        guard !terms.isEmpty else { return }
        Task { [weak self] in
            try? await self?.sessionManager.send(.transcriptionKeyterms(terms))
        }
    }

    private func disarmNoRoundsEnd() {
        guard pendingNoRoundsEnd || noRoundsEndFallback != nil || noRoundsEndSilenceTimer != nil || !farewellChain.isEmpty else { return }
        pendingNoRoundsEnd = false
        farewellChain = []
        farewellChainIndex = 0
        farewellChunkAudioStarted = false
        farewellChunkTimeoutWork?.cancel()
        farewellChunkTimeoutWork = nil
        noRoundsEndFallback?.cancel()
        noRoundsEndFallback = nil
        noRoundsEndSilenceTimer?.cancel()
        noRoundsEndSilenceTimer = nil
        audioService.setFarewellMute(false)
    }

    /// Called from the `responseAudioDone` path when `pendingNoRoundsEnd`
    /// is set: schedules the internal end-game trigger for a few seconds
    /// from now. Any incoming audio delta before then resets the timer
    /// (the AI is still in the middle of its farewell).
    private func scheduleNoRoundsEndAfterSilence() {
        guard pendingNoRoundsEnd else { return }
        noRoundsEndSilenceTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.pendingNoRoundsEnd else { return }
            // #region agent log
            _dbg("NO_ROUNDS_END","RealtimeGameCoordinator.swift:\(#line)","silence timer fired — AI done speaking; auto-ending",["round":self.currentRoundNumber,"totalCorrect":self.totalCorrect])
            // #endregion
            self.triggerInternalEndGame(reason: "silence")
        }
        noRoundsEndSilenceTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + noRoundsEndSilenceSeconds, execute: item)
    }

    /// App-driven end-of-game: mirrors the non-tool-call half of
    /// `handleEndGame` (session save, leaderboard, checkpoint clear,
    /// gameOver transition) and then tears down the WebSocket after a
    /// short grace period. Safe to call multiple times — guarded by
    /// `pendingNoRoundsEnd`.
    private func triggerInternalEndGame(reason: String) {
        guard pendingNoRoundsEnd else { return }
        pendingNoRoundsEnd = false
        farewellChain = []
        farewellChainIndex = 0
        farewellChunkAudioStarted = false
        farewellChunkTimeoutWork?.cancel()
        farewellChunkTimeoutWork = nil
        noRoundsEndFallback?.cancel()
        noRoundsEndFallback = nil
        noRoundsEndSilenceTimer?.cancel()
        noRoundsEndSilenceTimer = nil

        // #region agent log
        _dbg("NO_ROUNDS_END","RealtimeGameCoordinator.swift:\(#line)","triggerInternalEndGame",["reason":reason,"round":currentRoundNumber,"totalCorrect":totalCorrect])
        // #endregion

        stopLightningTimer()
        stateManager.reset()

        if let session = gameViewModel.currentSession {
            persistence.saveCompletedSession(session)
            submitScoreToLeaderboard(from: session)
            hasSubmittedLeaderboard = true
        }

        persistence.clearCheckpoint()

        // The ordering here is load-bearing — validated by
        // FarewellEndGamePolicyTests. See `debug-f3b222 5.log`:
        // putting .gameOver before disconnect caused UI observers to
        // call disconnect() within 56ms, cutting off farewell audio.
        let steps: [FarewellEndGamePolicy.EndGameStep] = [
            .cleanupState,          // already done above (timers, state reset)
            .disconnectWebSocket,   // MUST come before gameOver
            .endSession,
            .transitionToGameOver
        ]
        assert(
            FarewellEndGamePolicy.isDisconnectBeforeGameOver(steps: steps),
            "disconnect MUST precede .gameOver transition — see 5.log regression"
        )

        disconnect()

        gameViewModel.endSession()
        gameViewModel.transition(to: .gameOver)

        // The paywall was shown when rounds ran out (before the
        // farewell chain), but the .gameOver transition may have
        // dismissed that modal sheet. Re-post after a brief delay
        // so the subscription screen re-appears on top of the
        // game-over UI, giving the user a chance to purchase rounds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(
                name: RoundTracker.roundLimitReachedNotification,
                object: nil
            )
        }
    }

    // MARK: - Reconnect After Connection Loss

    private func reconnectAfterConnectionLoss() {
        guard !isReconnecting else {
            // #region agent log
            _dbg("RECONN_SKIP","RealtimeGameCoordinator.swift:\(#line)","reconnectAfterConnectionLoss skipped — already in progress",[:])
            // #endregion
            return
        }
        isReconnecting = true

        guard let session = gameViewModel.currentSession else {
            isReconnecting = false
            resumeGame()
            return
        }

        // Grab the resumption token BEFORE disconnecting so it survives teardown
        let savedResumptionToken = sessionManager.lastResumptionToken
        let statePacket = buildStatePacket()

        var config = SystemPromptBuilder.buildSessionConfig(
            locationLabel: locationService.currentLocationLabel,
            gameStatePacket: statePacket,
            isFirstGame: false,
            roundsRemaining: currentRoundConsumed
                ? RoundTracker.shared.totalRoundsAvailable
                : max(0, RoundTracker.shared.totalRoundsAvailable - 1)
        )

        if let token = savedResumptionToken {
            config.resumptionHandle = token
            print("[RealtimeGame] Will attempt session resumption with token (\(token.prefix(12))...)")
        }

        Task { @MainActor in
            do {
                audioService.stopStreaming()
                sessionManager.disconnect(preserveResumptionToken: true)

                audioManager.activateForSpeech()
                audioService.configure(sessionManager: sessionManager)
                sessionManager.autoReconnectDisabled = true
                try await sessionManager.connect(sessionConfig: config)
                try audioService.startStreaming()
                gameViewModel.transition(to: .playing)

                if isLightningRound {
                    resumeLightningTimer()
                }

                let resumeInstructions = "Continue the game. The GAME STATE JSON in your system prompt has everything you need. Resume Round \(statePacket.roundNumber), Question \(statePacket.questionIndex + 1)/5. Do NOT re-ask or re-score anything."
                try await sessionManager.send(.responseCreate(instructions: resumeInstructions))
                print("[RealtimeGame] Reconnected after connection loss (token=\(savedResumptionToken != nil), round=\(self.currentRoundNumber), score=\(self.totalCorrect))")
                self.isReconnecting = false
                self.reconnectAttempts = 0
                self.pausedByConnectionLoss = false
                // Guard the resume: if the model produces no audio, the resume
                // itself stalled — retry once, then end gracefully rather than
                // leaving the player in dead air (debug-f3b222.log 2026-06-29).
                self.reconnectResumeRetries = 0
                self.armReconnectResumeWatchdog()
            } catch {
                print("[RealtimeGame] Reconnect failed: \(error)")
                self.isReconnecting = false
                if self.reconnectAttempts < self.maxReconnectAttempts {
                    self.pausedByConnectionLoss = true
                    self.scheduleReconnect()
                } else {
                    // #region agent log
                    _dbg("RECONN_EXHAUST","RealtimeGameCoordinator.swift:\(#line)","reconnect failed and retries exhausted",["attempt":self.reconnectAttempts,"error":"\(error)"])
                    // #endregion
                    self.connectionMonitor.speakOffline("Sorry, we couldn't reconnect. Your progress has been saved.")
                    self.handleNetworkError()
                }
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
                    instructions: "Player resumed. Welcome back briefly, continue next question."
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
            let wsConnected = self.sessionManager.isConnected
            // #region agent log
            _dbg("H3","RealtimeGameCoordinator.swift:\(#line)","onInterruptionEnd fired",["wsConnected":wsConnected,"round":self.currentRoundNumber,"question":self.currentQuestionIndex,"phase":"\(self.gameViewModel.currentPhase)"])
            // #endregion
            print("[RealtimeGame] Audio interruption ended — resuming game (ws=\(wsConnected))")

            if !wsConnected {
                // WebSocket died during the interruption — full reconnect needed
                // #region agent log
                _dbg("H3","RealtimeGameCoordinator.swift:\(#line)","WS dead after interruption — reconnecting",["round":self.currentRoundNumber,"question":self.currentQuestionIndex])
                // #endregion
                self.pausedByConnectionLoss = true
                self.reconnectAfterConnectionLoss()
                return
            }

            do {
                self.audioManager.activateForSpeech()
                try self.audioService.startStreaming()
                self.gameViewModel.transition(to: .playing)

                if self.isLightningRound {
                    self.resumeLightningTimer()
                    Task {
                        try? await self.sessionManager.send(.responseCreate(
                            instructions: "Player back. Lightning round — \(self.lightningSecondsRemaining)s left. Next question now."
                        ))
                    }
                } else {
                    Task {
                        try? await self.sessionManager.send(.responseCreate(
                            instructions: "Player back after interruption. Continue where you left off; repeat question if mid-question."
                        ))
                    }
                }
            } catch {
                print("[RealtimeGame] Failed to resume audio: \(error)")
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
                self.suppressLightningToolCallRestart = true
                self.stopLightningTimer()
                if RoundTracker.shared.canPlayRound {
                    self.pendingLightningFlushInstructions = "TIME IS UP! Lightning over. Score: \(correct)/\(answered). Do NOT ask another question or call report_score. Announce score, move to next standard round."
                    self.lightningExpiredWithRoundsRemainingAt = Date()
                } else {
                    // Rounds are exhausted AND lightning timer expired.
                    // Use a short pending instruction (AI will announce the
                    // lightning result), then drive the full farewell via
                    // the chain so the purchase CTA is guaranteed to be spoken.
                    self.pendingLightningFlushInstructions = "TIME IS UP! Lightning over. Score: \(correct)/\(answered). Announce the lightning result in ONE short sentence, then stop. Do NOT ask another question. Do NOT call any tools."
                    self.postRoundLimitReached(context: "lightning_timeout_no_rounds_resume")
                    let chain = self.makeNoRoundsFarewellChain(
                        finalScore: self.totalCorrect,
                        roundsPlayed: self.currentRoundNumber,
                        context: "lightning_timeout_no_rounds"
                    )
                    self.armNoRoundsEnd(withChain: chain)
                }
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
