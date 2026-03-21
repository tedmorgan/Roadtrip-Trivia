# Realtime conversation truncation (experiment)

**Branch:** `feature/realtime-conversation-truncation`

## Goal

Reduce per-turn input tokens by capping how much **post-instruction** conversation context the Realtime session keeps.

## Implementation

1. **Main** `session.update` — instructions, tools, voice, modalities, turn detection (`RealtimeClientEvent.sessionUpdate`). **No** `truncation` on this payload.
2. **Follow-up** `session.update` — **only** `session.truncation` (`RealtimeClientEvent.sessionTruncationExperiment`), sent from `RealtimeSessionManager` right after the main config (connect + reconnect).

Bundling truncation with the first update appeared to risk the **entire** update being rejected; the session then kept default (generic assistant) behavior. Splitting keeps the game host prompt even if truncation is misconfigured.

## Current settings

| Field | Value | Notes |
|-------|-------|--------|
| `type` | `retention_ratio` | OpenAI Realtime truncation mode |
| `retention_ratio` | `0.65` | Fraction of context to retain when trimming — aggressive to reduce trim frequency |
| `token_limits.post_instructions` | `18000` | Max tokens after instructions — higher bucket to delay first trim and preserve cache |

### Previous settings and results

- **v1** (`retention_ratio: 0.85`, `post_instructions: 10000`): Truncation fired too often, busting cache on nearly every other turn. Dashboard showed higher cost than baseline despite lower per-turn input in app log.
- **v2** (current): Bigger bucket (18k) so truncation fires later; more aggressive trim (keep 65%) so each trim buys several turns of headroom before the next one.

Tune `post_instructions` and `retention_ratio` in `RealtimeModels.swift` (`sessionTruncationExperiment`) and compare `api_usage.log` and game quality.

**Encoding `retention_ratio`:** Use `NSDecimalNumber(string: "0.65")` (or another short decimal string), not a Swift `Double` literal. `JSONSerialization` can emit binary-float artifacts with **more than 16 decimal places**, which triggers API error `decimal_max_decimal_places_exceeded` and leaves truncation unset.

## Caveats

- Truncation can affect **prompt caching** behavior; watch cache hit rates if you rely on them.
- Too-aggressive limits may drop earlier Q&A context; increase limits if the host "forgets" the game state.
- Watch Xcode logs for `[Realtime] API error` after the second `session.update`; that indicates the server rejected truncation (game should still run with step 1 applied).

## Revert

Checkout `main`, or remove `sessionTruncationExperiment` from `RealtimeClientEvent` and the follow-up `send` calls in `RealtimeSessionManager.connect` / reconnect.
