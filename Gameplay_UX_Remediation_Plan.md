# Roadtrip Trivia — Gameplay UX Remediation Plan

*Prepared 2026-06-11, from a review of the `feature/gemini-live` codebase and the Cursor chat
history (Apr 13 + May 14 exports, ~160 user reports across ~20 builds).*

---

## 1. What the chat history actually shows

Grouping every user-reported issue from both chat exports, the same six symptom families recur
across ~20 builds, and the user's own closing assessment names the top two:

| # | Symptom family | Representative reports | Frequency |
|---|----------------|------------------------|-----------|
| 1 | **Host speech cut off** mid-question, mid-reaction, mid-farewell | "host comments are all cut off after 5 seconds", "wrap-up cut off again like previous builds" | The single most-reported issue; survived 10+ "fixes" |
| 2 | **Dead pauses / host doesn't hear the user** | "user has to answer twice", "10–30s stalls", "dead pause after difficulty question" | Co-#1; present from the very first report |
| 3 | **State divergence** — spoken score ≠ screen, wrong grading, question counters wrong, repeated/skipped questions, host "restarts" | "user said D but host said 'correct, the answer is C'", "question 6/5", "host redid the entire prior round" | Constant |
| 4 | **Rounds / paywall accounting** | decrement-at-start vs completion, stale CarPlay balance, 3-pack credited as 6, purchase doesn't resume the game, host ends game with no explanation | Constant |
| 5 | **Lightning round chaos** | timer ends early/late, lightning starts in a normal round, not announced | Recurrent |
| 6 | **Cost explosion** | ~$0.20/round → $1.00+/round while quality declined | Worsened as fixes piled up |

And one meta-issue, in the user's own words: *"we have been going around in circles for close to
20 builds playing whack a mole. new bugs are fixed and just create new bugs."*

## 2. Why the whack-a-mole happened (root-cause diagnosis)

### 2.1 The architecture fights itself at the audio layer

`AudioStreamingService.swift` implements aggressive client-side mic gating (mute while AI speaks,
during tool processing, and 1s after user speech) to save tokens, **and** honors server-side VAD
barge-in by calling `playerNode.stop()` the moment Gemini reports `speechStarted`
(AudioStreamingService.swift:373-406). These two mechanisms produce the top two symptoms directly:

- **Cut-offs:** any cabin noise, crosstalk, or echo tail that trips Gemini's server VAD instantly
  kills local playback. The `farewellMuted` lock (added May) fixed this *for the farewell only* —
  the identical kill path is still live for every question read, grading reaction, and round
  intro. The code comment at line 374 even identifies this as "the root cause of every 'host cut
  off' regression" — but the protection was only applied to one of many vulnerable phases.
- **Dead pauses / "didn't hear me":** when the mic is gated, the first words of an answer spoken
  immediately after the host finishes are simply never sent (unmute happens only ~150ms *after*
  the last playback buffer drains). Server VAD then never opens a turn → silence → a watchdog
  eventually nudges → token cost + awkward delay. The user reported "happens when the user
  responds immediately after the host's question" in the *first* message of the history; the
  mechanism is still in place.
- **Stuck mute:** `suspendedForProcessing` is only cleared by specific event orderings
  (`responseDone` with no audio, audio drain, barge-in). Any other ordering leaves the mic muted
  with no failsafe → "game frozen, user had to restart."

### 2.2 Six overlapping watchdogs patch the symptoms and create new ones

`RealtimeGameCoordinator.swift` (3,636 lines) now contains: `silenceWatchdog`,
`postScoreSilenceWatchdog` + `postScoreEscalationWatchdog`, `questionReadWatchdog`,
`midTurnSilenceWatchdog`, `round1StuckEscalationWork`, the no-rounds farewell chain driver, the
lightning timer, and coordinator-managed reconnect. Several send `responseCancel` /
`responseCreate` on timing heuristics. The git/chat history shows the loop clearly: a stall is
fixed by adding/tightening a watchdog → the watchdog fires during a natural pause → host cut off
or question repeated → that's fixed by loosening/adding another timer → new stall. (The
`QuestionReadWatchdogPolicy` comment documents exactly this: watchdog firing during "natural read
pauses" chopped the host off.) Every nudge also burns tokens, which is a large part of the cost
regression.

### 2.3 The LLM still holds authority it shouldn't

The app already owns the answer key, question batch, score, and round state (good — that was the
right migration). But the *host's speech* is still the user-facing source of truth for verdicts,
scores, round numbers, and end-of-game explanations, and prose instructions in
`SystemPromptBuilder` are the only enforcement. Hence "host said C when user said D," wrong round
numbers, lightning rounds not announced, and farewells that depend on the model choosing to speak
four chunks in a row.

### 2.4 Round/purchase accounting is scattered

`RoundTracker.consumeOneRound()` is called from 3 sites in the coordinator (report_score path
:1271, :1404, lightning timer :2452) and `roundLimitReached`/`showPaywall` notifications are
posted from **9+ sites**. UserDefaults is the ledger, with no transaction IDs, no idempotency, no
refund concept. That yields every commerce bug reported: double decrement, decrement-at-start,
stale balances, 3-pack → 6 rounds (almost certainly the same StoreKit transaction credited twice
via both `purchase()` result and `Transaction.updates`), and no reliable purchase→resume flow.

### 2.5 The verification gap (the real reason for 20 builds)

The only integration test was the user driving the car. Unit tests now exist for the extracted
policy structs (`Coordinators/Logic/` + `Tests/RoadtripTriviaLogicTests` — the right idea), but
**nothing tests the interaction layer where every regression actually lives**: event ordering
across session manager → coordinator → audio gating → watchdog timers. Timing-dependent code with
no deterministic harness can only be debugged by field testing, which is exactly what happened.

---

## 3. The plan

Ordering principle: **build the safety net first (Phase 0), then fix the two physical-layer
defects (Phase 1), then remove the structural cause of regressions (Phase 2).** Phases 3–5 are
correctness/cost work that becomes safe and cheap once 0–2 exist. Each phase has an explicit exit
criterion; do not start the next phase until it's met.

### Phase 0 — Deterministic replay harness (the anti-whack-a-mole investment)

**Goal:** every failure mode in the chat history becomes a named, repeatable test that runs in
seconds with no device, no car, no API spend.

1. **Introduce seams** in the realtime stack:
   - Protocol `RealtimeSessionProviding` extracted from `RealtimeSessionManager` (send, events
     publisher, connection state) so a `FakeRealtimeSession` can script server event sequences.
   - Injectable clock/scheduler abstraction replacing direct `DispatchQueue.main.asyncAfter` in
     the coordinator and `AudioStreamingService`, so watchdog/gating timing runs on virtual time.
   - Extract mic-gating decisions ("should this buffer be sent?", "should playback stop on
     speechStarted?") into a pure `MicGatePolicy` / `BargeInPolicy` alongside the existing Logic/
     structs.
2. **Build fixture tests from the existing debug logs.** The `debug-30dda1` / `debug-f3b222` /
   `mic_gating` logs already contain real event traces for: farewell cut-off, post-score stall,
   question repeat after nudge, lightning mis-start, stuck `suspendedForProcessing`. Encode each
   as a scripted event sequence + assertion ("playback never stopped during locked utterance",
   "mic open within 300ms of audio drain", "no second consumeOneRound for same round").
3. **Wire into the existing `Makefile` / SPM test target** so `make test` gates every build.

*Exit criterion: ≥10 regression fixtures derived from the chat history run green, and a
deliberately re-introduced bug (e.g. removing the farewell lock) turns the right fixture red.*

### Phase 1 — Fix the audio layer (top two symptoms)

1. **Barge-in policy (cut-offs).** Never stop playback on server `speechStarted` alone.
   Require corroboration: client mic was open **and** a local energy/VAD check saw speech in the
   last N ms. Generalize `farewellMuted` into an *utterance lock* the coordinator sets for every
   must-finish segment: question reads, grading reactions, round intros/wrap-ups, paywall
   explanation, farewell. During a lock, barge-in is ignored (a trivia host should not be
   interruptible mid-question anyway).
2. **Pre-roll ring buffer (didn't hear me).** While "muted," keep capturing into a ~1s rolling
   buffer instead of dropping audio. On unmute (or local speech detection during the grace
   window), flush the ring buffer first, then stream live. The user's fastest answers stop being
   swallowed, server VAD sees the full utterance, and turn-taking recovers its rhythm.
3. **Predictive unmute.** Unmute based on scheduled-buffer playout time (the service already
   tracks `scheduledBufferCount`; track remaining duration too) instead of drain + 150ms.
4. **Stuck-mute failsafe.** One hard rule: mic may never stay muted more than N seconds (e.g. 5s)
   without server audio arriving — force-unmute and log. Kills the "frozen game" class.

*Exit criterion: fixtures for cut-off and swallowed-answer scenarios pass; one full manual game
with zero cut-offs and zero "answer twice" events.*

### Phase 2 — One turn supervisor instead of six watchdogs

Replace the watchdog pile with a single explicit state machine owned by the coordinator:

- States: `Intro`, `AwaitingQuestionRead`, `ReadingQuestion`, `AwaitingAnswer`, `Grading`,
  `Reacting`, `RoundBreak`, `LightningActive`, `Farewell`, `Paused/Reconnecting`.
- **One timer**, parameterized per state: each state declares its timeout and its single recovery
  action (re-prompt text, cancel+create, reconnect, local-TTS fallback). The existing tested
  policy structs (`PostScoreWatchdogPolicy`, `QuestionReadWatchdogPolicy`, `EndGamePolicy`,
  `FarewellAdvancer`…) become the per-state decision functions — they keep their tests.
- Recovery actions are *escalating and rate-limited* (soft re-prompt → cancel+create → reconnect →
  local fallback), with a per-question cap so nudges can't loop and burn tokens.
- Delete `silenceWatchdog`, `postScoreSilenceWatchdog(+escalation)`, `questionReadWatchdog`,
  `midTurnSilenceWatchdog`, `round1StuckEscalationWork` as independent entities.

This is also the start of breaking up the 3,636-line coordinator: the state machine, the function-
call handlers, and the reconnect logic become separate files with the coordinator as thin glue.

*Exit criterion: all Phase 0 fixtures still green against the new supervisor; grep shows zero
direct `asyncAfter` watchdog scheduling left in the coordinator.*

### Phase 3 — Shrink the LLM's authority over user-facing truth

The app already decides correctness and score. Finish removing the model's room to diverge:

1. **Verbatim verdict lines.** `report_score`'s result returns the exact reaction sentence
   (verdict + correct answer + running total) composed by the app; the prompt instructs "read the
   `say` field verbatim, then stop." Same for round intros (`isNewRound`/lightning announcements)
   and end-of-round summaries. The model keeps personality in *optional* color commentary, never
   in facts.
2. **Local TTS fallback for must-deliver messages.** For commerce-critical and game-critical
   utterances (out-of-rounds explanation + purchase CTA, "resuming where you left off",
   final farewell), if model audio doesn't start within the state timeout, speak the scripted
   line via `AVSpeechSynthesizer` through the existing audio engine. The paywall explanation can
   then *never* be cut off or skipped — it no longer depends on the model at all.
3. **Lightning round is app-driven end to end:** the app announces start (scripted line), runs the
   timer (it already does), force-ends at zero, and the model is told — never asked — what format
   the round is.
4. **Score revisions:** on a host mis-speak/challenge, `ScoreRevisionPolicy` already adjusts the
   ledger; ensure the revision also re-renders the screen and the host's follow-up line comes from
   the app (`say` field), closing the "score on screen didn't update after challenge" report.

*Exit criterion: a transcript audit of one full game shows zero numeric/factual content originating
from the model; paywall CTA delivered on a run where model audio is artificially suppressed.*

### Phase 4 — Commerce and round-ledger correctness

1. **Single `RoundLedger`** (replaces direct `RoundTracker` mutation from the coordinator): the
   only component allowed to consume/refund, fed by explicit events — `roundStarted`,
   `roundCompleted`, `gameAbandoned`. Consume **on completion** (the user's stated rule), with an
   in-flight marker so kill/relaunch mid-round can't double-charge or skip a charge.
2. **Idempotent purchase crediting:** dedupe StoreKit transactions by `Transaction.id` before
   `addPurchasedRounds` (fixes 3-pack → 6). Audit `StoreService` for the
   `purchase()`-result-plus-`Transaction.updates` double-delivery path.
3. **One paywall flow:** collapse the 9 notification post sites into a single
   `presentPaywall(reason:)` on the ledger/store layer; CarPlay balance label observes
   `roundBalance` only.
4. **Purchase → resume:** after a successful purchase with a suspended session, offer "continue
   your game" (the checkpoint/resume machinery already exists) without requiring app restart.

*Exit criterion: ledger unit tests cover start/complete/abandon/kill-mid-round/purchase-twice;
manual run of the chat-history commerce scenarios (run out → buy → resume) passes.*

### Phase 5 — Cost: measure, then cut

Do this *after* Phases 1–2, because stalls and nudge loops are themselves a major token sink —
some of the cost regression should fall out automatically.

1. **Attribute before optimizing.** Extend `APIUsageLogger` tagging so every `response.done`
   usage record carries game phase + trigger (normal turn, watchdog nudge, reconnect replay,
   idle). Produce ¢/round by category per test game (the `api_usage` log + existing CSV tooling
   already get close).
2. **Expected levers, in order of likely impact:**
   - Eliminate nudge/cancel loops (Phase 2) and reconnect replays (each re-setup resends context).
   - Confirm `GeminiCacheService` cache hits are real (log hit/miss); cache the policy block per
     key, keep the per-session memory block minimal.
   - Configure Live API context window compression / sliding window so long sessions don't grow
     unbounded; with questions app-held, old turns are disposable.
   - **Planned session recycle at round boundaries:** disconnect and restore via the existing
     state packet + resumption token between rounds, rather than carrying a full hour of audio
     context. This is now safe because question history lives in the app, not the conversation.
   - Keep mic gating *only* where it can't hurt UX (long batch fetches, paused states) — the
     pre-roll buffer from Phase 1 makes gating safe where it remains.
3. **Set and track a budget** (e.g. target ≤ $0.25/round) printed by a log-analyzer script after
   every test game.

*Exit criterion: ¢/round report generated automatically per test game; two consecutive games at or
under budget with no UX regressions.*

### Phase 6 — Per-build verification protocol (keep the mole whacked)

1. `make test` (policy tests + Phase 0 replay fixtures) gates every build — already wired to run
   on build per the May work; verify it actually executes and fails the build.
2. **Automated log audit:** a script that scans a drive-test's `debug-*`/`mic_gating`/`api_usage`
   logs for symptom signatures — playback stopped during a locked utterance, >Ns silence in
   awaiting states, repeated `questionIndex`, double consume, nudge storms, token spikes — and
   prints a pass/fail report. Every drive test then yields objective results instead of memory.
3. **Golden-game checklist** (10 min, scripted): intro Q&A, 2 normal rounds incl. one immediate
   answer and one challenge, lightning round, run out of rounds, purchase, resume. One page,
   pass/fail per row, kept in `docs/`.

---

## 4. Suggested sequencing & sizing

| Phase | Scope | Rough size |
|-------|-------|-----------|
| 0 | Seams + replay harness + 10 fixtures | 3–5 days of focused work |
| 1 | Barge-in lock, pre-roll buffer, predictive unmute, failsafe | 2–3 days |
| 2 | Turn supervisor, delete watchdogs, split coordinator | 3–5 days |
| 3 | Verbatim verdicts, local TTS fallback, lightning app-driven | 2–3 days |
| 4 | RoundLedger, StoreKit dedupe, single paywall path | 2–3 days |
| 5 | Cost attribution + levers | 1–2 days, then ongoing |
| 6 | Log auditor + golden-game checklist | 1–2 days |

Phases 0–1 alone should visibly transform gameplay (they target the two issues the user ranked
highest). Phase 2 is what stops regressions from coming back. Everything else slots in behind.

## 5. What *not* to do

- **No more prompt-tweak-and-pray builds.** Prompt changes only ship alongside a fixture or
  checklist row that would catch their failure.
- **No new timers in the coordinator.** Any new timeout becomes a state in the turn supervisor.
- **No model migration right now.** The user already evaluated GPT-Realtime and chose to stay on
  Gemini Live; the failure modes here are architectural, not model-specific, and would largely
  port with a migration.
- **Don't optimize tokens before Phase 2.** Several past cost "optimizations" (mic gating, prompt
  slimming) caused the worst UX regressions; attribution first, levers second.
