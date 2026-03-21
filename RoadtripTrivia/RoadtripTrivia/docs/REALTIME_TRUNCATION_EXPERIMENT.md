# Realtime conversation truncation (experiment)

**Branch:** `feature/realtime-conversation-truncation`

## Goal

Reduce per-turn input tokens by capping how much **post-instruction** conversation context the Realtime session keeps. Implemented in `Services/Realtime/RealtimeModels.swift` on every `session.update`.

## Current settings

| Field | Value | Notes |
|-------|-------|--------|
| `type` | `retention_ratio` | OpenAI Realtime truncation mode |
| `retention_ratio` | `0.85` | Fraction of context to retain when trimming |
| `token_limits.post_instructions` | `10000` | Max tokens after the system instructions |

Tune `post_instructions` (e.g. 6000–16000) and `retention_ratio` (e.g. 0.75–0.9) and compare `api_usage.log` and game quality.

## Caveats

- Truncation can affect **prompt caching** behavior; watch cache hit rates if you rely on them.
- Too-aggressive limits may drop earlier Q&A context; increase limits if the host “forgets” the game state.

## Revert

Checkout `main` or remove the `session["truncation"]` block in `RealtimeClientEvent.toJSON()`.
