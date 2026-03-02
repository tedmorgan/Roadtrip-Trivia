# Roadtrip Trivia — Build Plan

**CarPlay Voice-Based Conversational App (iOS 26.4+)**
Prepared: February 27, 2026

---

## 1. Platform Context: iOS 26.4 Conversational App Entitlement

iOS 26.4 (currently in beta, expected spring 2026) introduces a new CarPlay app category: **voice-based conversational apps**. This is a direct fit for Roadtrip Trivia. Key constraints from Apple's framework that shape this build:

- **Entitlement secured.** The voice-based conversational app CarPlay entitlement has been requested and granted. The provisioning profile (`Roadtrip_Trivia.mobileprovision`) is ready for Xcode project configuration.
- **`CPVoiceControlTemplate` is the primary UI surface.** This template displays voice control state indicators (listening, processing, recognized). You initialize it with up to 5 `CPVoiceControlState` objects and switch between them with `activateVoiceControlState:`. This maps naturally to the game's Listening → Grading → Result flow.
- **Maximum template depth of 3.** The entire CarPlay UI must stay within 3 stacked templates (including root). This means: Home screen (root) → Playing screen → Score Summary. No deeper navigation. The voice wizard for session setup should be implemented as state changes within a single template, not as separate pushed templates.
- **Voice must be the primary modality.** Apple requires voice-first interaction on launch and throughout. Text and imagery in responses must be minimal — score chips and status labels only, no rich content displays. This aligns perfectly with the PRD's safety-first, glanceable design.
- **Audio session discipline.** Conversational apps may only hold an active audio session while voice features are actively in use. The app must release the audio session between questions/rounds so it doesn't block music or FM radio when idle.
- **No vehicle or iPhone control.** The app cannot control vehicle systems or iPhone functions.
- **No wake word.** Users must open the app manually — there's no Siri-style activation. The "Start New Game" and "Resume Last Game" entry points on the Home template handle this.

### Impact on PRD Architecture

The PRD was written assuming traditional CarPlay templates (CPListTemplate, CPTabBarTemplate). The new conversational entitlement changes the approach:

| PRD Assumption | iOS 26.4 Reality | Adaptation |
|---|---|---|
| CPListTemplate for Home | Still valid as root template (depth 1 of 3) | Keep as-is |
| Multiple templates for game flow | Max depth of 3 | Playing + Score Summary = 2 more templates. Voice wizard must be state-based within Playing template, not a separate template stack |
| CPVoiceControlTemplate not mentioned | Now the core gameplay template | Use CPVoiceControlTemplate for the Playing screen with states: Asking, Listening, Grading, Result, Hint, Challenge |
| Touch fallback buttons | Still permitted but voice-primary | Large touch targets for Continue/End remain valid; keep minimal |

---

## 2. Architecture Decisions

### 2.1 App Architecture: MVVM-C (as specified in PRD)

- **Model**: Session, Round, Question, Score, Account data models. Codable structs for GPT payloads.
- **ViewModel**: GameViewModel (owns game state machine), SessionSetupViewModel, ScoreViewModel.
- **View**: Minimal — CarPlay templates are not custom views. The "view" layer is a CarPlay template coordinator that maps ViewModel state to template updates.
- **Coordinator**: AppCoordinator manages iPhone vs. CarPlay scene lifecycle. CarPlayCoordinator owns the template stack. GameFlowCoordinator manages the question loop state machine.

### 2.2 CarPlay Template Stack (3-deep max)

```
Depth 1: CPListTemplate (Home)
  ├── "Start New Game"  → pushes Playing template
  └── "Resume Last Game" → pushes Playing template (with restored state)

Depth 2: CPVoiceControlTemplate (Playing)
  States: SetupWizard | Asking | Listening | Grading | Result | RoundSummary | LightningCountdown
  (All gameplay happens as state transitions within this single template)

Depth 3: CPListTemplate (Score Summary — optional tap target)
  Shows cumulative score, hints used, challenges used/overturned
```

### 2.3 Backend Stack

- **GPT Proxy Service**: Lightweight API gateway (Node.js or Swift Vapor) that holds OpenAI API keys, enforces per-account rate limits, and caps rerolls/challenges. The iPhone app never holds GPT API keys.
- **Session Storage**: CloudKit (private database) for session state, account data, and resume checkpoints. Avoids building custom infrastructure for MVP.
- **Authentication**: AuthenticationServices framework for Sign in with Apple (P0). Firebase Auth or custom backend for email magic link, email/password, Google, Facebook (P1/P2).

### 2.4 On-Device Services

- **STT**: Apple Speech framework (`SFSpeechRecognizer`) with on-device recognition. Continuous listening within bounded answer windows.
- **TTS**: `AVSpeechSynthesizer` for all spoken game content.
- **Audio Session**: `AVAudioSession` configured for CarPlay with `.playAndRecord` category, interruption handling, and ducking.
- **Location**: `CLLocationManager` with "when in use" authorization, reverse geocoded to human-readable labels. No coordinates sent to GPT.

---

## 3. Phased Build Plan

### Phase 1 — Foundation (Months 1–3, Q1)

This phase establishes the skeleton: the app compiles, connects to CarPlay, speaks, listens, and authenticates. No gameplay yet.

**Month 1: Architecture & Core Infrastructure**

| Story | What to Build | Points | Notes |
|---|---|---|---|
| ARCH-001 | Document full architecture: MVVM-C layers, CarPlay integration via CPVoiceControlTemplate, GPT proxy design, data models | 8 | Include the 3-template-depth constraint |
| ARCH-002 | CI/CD with Xcode Cloud or Fastlane → TestFlight | 5 | Automated on PR merge to main |
| ARCH-003 | Backend: API gateway + GPT proxy + CloudKit session storage | 8 | Staging environment with health checks |
| ARCH-004 | GPT proxy: key management, per-account rate limiting, cost caps | 8 | Depends on ARCH-003 |
| ARCH-005 | Data models & API contracts (OpenAPI spec): Session, Round, Question, Score, Account | 5 | Review with team before M2 |
| AUTH-001 | Sign in with Apple (full SIWA flow, Keychain token storage) | 5 | P0 — required for all other auth |

**Month 1 total: 39 points**

**Month 2: Auth Completion + CarPlay Shell + Voice Engine Start**

| Story | What to Build | Points | Notes |
|---|---|---|---|
| AUTH-002 | Email magic link auth | 5 | P1 |
| AUTH-003 | Email/password auth | 5 | P1 |
| AUTH-004 | Google + Facebook OAuth | 5 | P2 — can defer if needed |
| AUTH-005 | Silent token refresh | 3 | Depends on AUTH-001 |
| AUTH-006 | Account deletion (App Store requirement) | 3 | Depends on AUTH-001 |
| AUTH-007 | Block all auth UI on CarPlay | 2 | CarPlay never shows login screens |
| AUTH-008 | Implement explicit sign-out flow (UC-33) | 2 | Clear tokens, reset session state |
| CPUI-001 | CarPlay Home screen: CPListTemplate with "Start New Game" + conditional "Resume Last Game" | 5 | Root template (depth 1) |
| CPUI-002 | CarPlay template navigation: Home → Playing (CPVoiceControlTemplate) → Score Summary | 8 | Implement the 3-deep stack; define all CPVoiceControlStates |
| VOICE-001 | Integrate SFSpeechRecognizer for on-device STT | 8 | Continuous listening, bounded windows |

**Month 2 total: 44 points**

**Month 3: Voice Wizard + Session Persistence + Audio**

| Story | What to Build | Points | Notes |
|---|---|---|---|
| CPUI-003 | Voice wizard for new session setup (within CPVoiceControlTemplate states — not separate templates) | 8 | Ask riders, age bands, difficulty — all by voice. Must fit within depth-2 template |
| CPUI-004 | Session state persistence (save after every question/scoring event) | 5 | Efficient writes, non-blocking |
| CPUI-005 | Resume Last Game flow: restore state, speak recap | 5 | Depends on CPUI-004 |
| VOICE-002 | AVSpeechSynthesizer for TTS (questions, hints, results, prompts) | 5 | |
| VOICE-003 | AVAudioSession management: interruptions, ducking, focus for CarPlay | 8 | Critical for audio session discipline per iOS 26.4 rules |
| VOICE-004 | Always-listening answer capture with crosstalk detection and final-answer prompting | 8 | ANS-01 through ANS-03 from PRD |

**Month 3 total: 39 points**

**Phase 1 exit criteria:** App installs on device, connects to CarPlay, shows Home screen, runs voice wizard, speaks/listens, authenticates, persists session state. No trivia gameplay yet.

---

### Phase 2 — Core Gameplay (Months 4–6, Q2)

This phase builds the actual trivia game: GPT integration, location-aware questions, the full question loop, and Lightning Rounds.

**Month 4: GPT + Location + Game Loop Foundation**

| Story | What to Build | Points | Notes |
|---|---|---|---|
| GPT-001 | Question generation prompt: 5 questions + answers + hints + rubric per round, structured JSON | 8 | One GPT call per round (cost control) |
| GPT-002 | Answer grading prompt with strictness tiers (lenient → near-exact) | 8 | Depends on GPT-001 |
| GPT-003 | Challenge re-grade flow: second-pass GPT call, one per question, standard rounds only | 5 | P1 |
| GPT-004 | GPT response parser: extract fields, retry once on malformed JSON | 5 | |
| GPT-005 | Cost controls: cap rerolls at 2, cap challenges, per-account rate limits | 5 | Depends on ARCH-004 |
| LOC-001 | CLLocationManager with appropriate permissions | 5 | |
| LOC-002 | Reverse geocode → "Near {town}, {state} ({major city} area)" labels | 5 | Never send coordinates to GPT |
| LOC-003 | Location fallback: local → regional → state-level when quality is low | 3 | P1 |
| GAME-001 | Question loop (Q1–Q5): TTS ask → listen → grade → announce → advance | 13 | Core gameplay — depends on GPT-001 + VOICE-004. Map to CPVoiceControlTemplate states |

**Month 4 total: 57 points** (heavy month — consider pulling GAME-001 into M4–M5)

**Month 5: Gameplay Modes + Polish**

| Story | What to Build | Points | Notes |
|---|---|---|---|
| GAME-002 | Multiple choice for Simple mode (A/B/C/D on CarPlay, accept voice) | 5 | |
| GAME-003 | Free-response for Tricky/Hard/Einstein with difficulty-appropriate grading | 5 | |
| GAME-004 | Hint system: voice command → pre-generated hint, one per question, tracked | 3 | P1 |
| GAME-005 | Round summary screen: round score, cumulative, hints, challenges | 5 | Uses CPVoiceControlTemplate RoundSummary state |
| GAME-006 | Continue/end prompt: voice Yes/No + large touch fallback | 3 | |
| GAME-007 | Category selection + "pick another category" reroll (cap at 2) | 5 | P1 |
| GAME-008 | Grading feedback audio: game-show thinking sting, duck other audio | 3 | P1 |
| GAME-009 | Clarification flow: uncertain grade → ask once → re-grade or skip | 5 | P1 |

**Month 5 total: 34 points**

**Month 6: Lightning Round**

| Story | What to Build | Points | Notes |
|---|---|---|---|
| LTNG-001 | Offer Lightning Round after every 4 standard rounds | 3 | |
| LTNG-002 | 120-second countdown timer on CarPlay | 5 | CPVoiceControlTemplate LightningCountdown state |
| LTNG-003 | Rapid MCQ flow: fast question cycling, A/B/C/D by voice | 8 | |
| LTNG-004 | Disable hints + challenges during Lightning Round | 2 | P1 |
| LTNG-005 | Lightning Round results summary → return to standard flow | 3 | |

**Month 6 total: 21 points**

**Phase 2 exit criteria:** Full trivia game playable end-to-end on CarPlay. Standard rounds with all 4 difficulty modes, location-aware questions, hints, challenges, Lightning Rounds. Internal dogfooding begins.

---

### Phase 3 — Polish & Launch (Months 7–9, Q3)

Interruption handling, analytics, testing, and App Store submission.

**Month 7: Interruption Handling + Analytics Start**

| Story | What to Build | Points | Notes |
|---|---|---|---|
| INT-001 | Auto-pause on call/Siri/nav/audio loss/CarPlay disconnect; checkpoint state | 8 | P0 — safety critical. Must release audio session per iOS 26.4 rules |
| INT-002 | Post-interruption recovery: resume / restart round / end game | 5 | |
| INT-003 | Lightning Round interruption: pause timer, resume or end | 3 | P1 |
| INT-004 | Network loss: queue pending, clear messaging, retry on reconnect | 5 | P0 |
| INT-005 | GPS loss: fallback to last known area label | 3 | P1 |
| ANAL-001 | Session analytics: starts, completions, duration, rounds per session | 5 | P1 |

**Month 7 total: 29 points**

**Month 8: Analytics + Testing Begins**

| Story | What to Build | Points | Notes |
|---|---|---|---|
| ANAL-002 | Gameplay analytics: rounds, lightning rounds, hint/challenge rates | 5 | |
| ANAL-003 | Performance metrics: grading latency distribution, GPT success rate, STT accuracy | 5 | P0 |
| ANAL-004 | Crash reporting + crash-free session rate tracking | 3 | P0 |
| TEST-001 | Unit tests for core game logic (80%+ coverage target) | 8 | P0 |

**Month 8 total: 21 points**

**Month 9: Testing + Compliance + Launch**

| Story | What to Build | Points | Notes |
|---|---|---|---|
| TEST-002 | GPT integration tests (mock + live) | 5 | |
| TEST-003 | CarPlay UI tests on simulator | 5 | |
| TEST-004 | In-vehicle road testing: 3+ CarPlay head units, real driving conditions | 8 | P0 — critical for voice accuracy validation |
| TEST-005 | Backend load/stress testing | 5 | P1 |
| COMP-001 | CarPlay entitlement approval (voice-based conversational app category) | 0 | ✅ COMPLETE — entitlement granted, provisioning profile in project folder |
| COMP-002 | Privacy compliance: ATT, no persistent ages, no audio to GPT, no coordinates to GPT | 5 | |
| COMP-003 | App Store submission: screenshots, metadata, review notes | 3 | |
| COMP-004 | Age-appropriate content safeguards: validate across 1000 test rounds | 3 | |

**Month 9 total: 39 points**

**Additional notes for Phase 3:**

- **Early analytics:** Although ANAL-001 is scheduled for M7, instrument basic session start/complete counters from the first playable build in Phase 2 (lightweight — piggyback on GAME-001). Full analytics dashboard comes in M7–M8.
- **Content safeguards during development:** Don't wait until COMP-004 (M9) to validate GPT output safety. Add kid-safe content constraints to the GPT prompt in GPT-001 (M4) and spot-check output throughout Phase 2 dogfooding.
- **Grading latency monitoring:** Add latency logging to GPT-002 (M4) from day one. The 5-second SLA from PRD PERF-01 should be validated continuously during Phase 2, not just post-launch in OPT-001.

**Phase 3 exit criteria:** App approved on App Store with CarPlay voice-based conversational entitlement. Crash-free rate > 99%. P95 grading latency ≤ 5 seconds. In-vehicle testing passed on 3+ head units.

---

### Phase 4 — Growth & Future (Months 10–12, Q4)

Post-launch optimization, multi-car gameplay design, monetization foundation.

**Month 10: Post-Launch Optimization**

| Story | What to Build | Points | Notes |
|---|---|---|---|
| OPT-001 | Optimize grading latency → P95 under 3 seconds | 5 | |
| OPT-002 | Improve STT accuracy in noisy environments | 5 | |
| OPT-003 | Question quality feedback loop (skip/challenge rate tracking) | 5 | |

**Months 10–12: Multi-Car, Monetization, Social (roadmap items)**

| Story | What to Build | Points | Notes |
|---|---|---|---|
| MULTI-001–004 | Multi-car architecture, lobby, per-car scoring, end-of-game summary | 34 | P2 — out of scope for MVP |
| MON-001–003 | Premium tier design, StoreKit 2 subscriptions, paywall UI (iPhone only) | 16 | P2 |
| SOC-001 | Social sharing + leaderboard design spec | 3 | P2 |

---

## 4. Key Risks and Mitigations

**~~Entitlement approval timing.~~** ✅ Resolved — the voice-based conversational app entitlement has been granted and the provisioning profile is in hand. This was the longest-lead external dependency and it's now cleared.

**iOS 26.4 API stability.** The conversational app APIs are in beta and could change before the spring release. **Mitigation:** Abstract CarPlay template interactions behind a coordinator layer so template changes are isolated. Monitor beta releases closely during Q1.

**CPVoiceControlTemplate limitations.** The PRD envisions richer score displays and status labels than the Voice Control template may support. The template is designed for simple state indicators (listening/processing/recognized), not custom game UIs. **Mitigation:** Prototype the Playing screen in Month 2 (CPUI-002) to validate what's visually possible. Fall back to CPListTemplate for the Playing screen if the voice control template is too restrictive — this still fits within the 3-template depth limit.

**Audio session release between interactions.** iOS 26.4 requires conversational apps release their audio session when voice features aren't active. This means the app must acquire and release the audio session around each question/answer cycle, not hold it for the entire game. **Mitigation:** Build acquire/release logic into VOICE-003 from the start. Test that music/radio resumes between questions.

**Voice accuracy in car environments.** Road noise, multiple speakers, and varied accents will challenge STT. **Mitigation:** The always-listening + final-answer prompting flow (ANS-01 through ANS-03) provides multiple chances. Budget real in-vehicle testing time (TEST-004). Plan OPT-002 for post-launch tuning.

**GPT latency for grading.** The PRD requires ≤ 5 second grading response. Network variability on the road could push latency higher. **Mitigation:** The thinking music sting (GAME-008) provides perceived-wait coverage. Implement hard timeout with skip fallback. Pre-generate hints and rubric in the round payload to avoid extra calls.

**3-template depth constraint.** All game states (setup wizard, question loop, round summary, lightning round, interruption recovery) must fit within the Playing template as state transitions, not separate templates. **Mitigation:** Build a robust state machine in GameFlowCoordinator that maps each game phase to a CPVoiceControlState. The Score Summary (depth 3) is the only additional template pushed.

---

## 5. Dependency Chain (Critical Path)

```
ARCH-003 (Backend)
  → ARCH-004 (GPT Proxy)
    → GPT-005 (Cost Controls)

AUTH-001 (SIWA)
  → AUTH-005 (Silent Re-auth)
  → AUTH-006 (Account Deletion)
  → AUTH-007 (Block CarPlay Auth)

VOICE-001 (STT)
  → VOICE-004 (Always-Listening)
    → GAME-001 (Question Loop)
      → GAME-002–009 (All gameplay)

CPUI-001 (Home)
  → CPUI-002 (Template Nav)
    → CPUI-003 (Voice Wizard)
    → LTNG-002 (Timer)

GPT-001 (Generation)
  → GPT-002 (Grading)
    → GPT-003 (Challenge)
  → GPT-004 (Parser)
  → GAME-001 (Question Loop)

VOICE-003 (Audio Session) + CPUI-004 (State Persistence)
  → INT-001 (Interruption Handling)
```

The longest critical path runs: ARCH-003 → ARCH-004 → ... and VOICE-001 → VOICE-004 → GAME-001 → full gameplay chain. Both converge in Month 4 at GAME-001. Any delay in backend infrastructure or voice engine directly pushes the entire gameplay phase.

---

## 6. Immediate Next Steps

1. ~~**Submit CarPlay entitlement request**~~ ✅ Done — entitlement granted, provisioning profile available.
2. **Install iOS 26.4 beta** on a test device and CarPlay simulator. Build a bare-bones CPVoiceControlTemplate prototype to validate state management and visual capabilities before committing to the architecture.
3. **Download and review the February 2026 CarPlay Developer Guide PDF** from Apple for the complete conversational app specification.
4. **Set up the Xcode project** with the granted provisioning profile, CarPlay entitlement configuration, Scene lifecycle for dual iPhone/CarPlay support, and the CI/CD pipeline (ARCH-002).
5. **Begin ARCH-001**: Document the full system architecture incorporating the 3-template-depth constraint and CPVoiceControlTemplate-based game flow.

---

## 7. Point Summary by Phase

| Phase | Months | Total Story Points | Stories |
|---|---|---|---|
| Q1: Foundation | M1–M3 | 122 | 21 |
| Q2: Core Gameplay | M4–M6 | 112 | 23 |
| Q3: Polish & Launch | M7–M9 | 89 | 19 |
| Q4: Growth & Future | M10–M12 | 68 | 12 |
| **Total** | **12 months** | **391** | **75** |
