#!/usr/bin/env python3
"""Post-drive-test log auditor for Roadtrip Trivia.

Scans the JSONL debug logs (debug-f3b222 / debug-30dda1 / mic_gating) and the
api_usage log produced during a test game and prints a pass/fail report for
the known gameplay-defect signatures, so every road test yields objective
results instead of relying on memory.

Usage:
    python3 scripts/analyze_game_logs.py [LOG_FILE ...]
    # with no args, scans ~/Downloads for the standard log names

Checks:
  CUTOFF    barge-ins honored during host speech / farewell (should be ~0)
  STALL     gaps > STALL_SECONDS between consecutive events mid-game
  STORM     recovery nudges exceeding budget (governor denials are GOOD —
            they mean the cap held; raw nudge counts per question > 3 are BAD)
  DOUBLE    a round number consumed more than once
  FAILSAFE  stuck-mute failsafe firings (should be rare; >2/game = problem)
  PREROLL   pre-roll flushes (info: early answers that would have been lost)
  TTSFALL   farewell chunks delivered via local TTS fallback (info)
  COST      Provider audio-minute estimate + token/context usage
"""

import json
import os
import re
import sys
from collections import defaultdict
from glob import glob

STALL_SECONDS = 10.0
NUDGE_BUDGET_PER_QUESTION = 3

# Events that mark the start of a new app launch / connection — the gap
# BEFORE these is the phone sitting idle between sessions, not in-game
# dead air, so the stall detector resets instead of flagging.
SESSION_BOUNDARY_MARKERS = (
    "loadQuestionHistory",
    "fetching ephemeral token",
    "fetching API key",
    "STREAMING_STARTED",
    "Starting Grok Voice connection",
    "Starting Gemini connection",
)

# Grok Voice Think Fast 2.0: billed per audio minute + text input events.
# https://docs.x.ai/developers/models
PRICE_AUDIO_PER_MIN = 0.08
PRICE_TEXT_INPUT_EVENT = 0.004
# Soft budget for a normal ~5-question round (~3–6 audio minutes wall/mic).
COST_BUDGET_PER_ROUND = 0.50


def load_jsonl(path):
    events = []
    with open(path, errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict) and "timestamp" in obj:
                events.append(obj)
    return events


def audit_debug_logs(events, report):
    events.sort(key=lambda e: e.get("timestamp", 0))

    # STALL: long gaps between consecutive events while a game is active.
    last_ts = None
    for e in events:
        ts = e.get("timestamp", 0) / 1000.0
        msg = e.get("message", "")
        is_boundary = any(m in msg for m in SESSION_BOUNDARY_MARKERS)
        if (last_ts is not None and ts - last_ts > STALL_SECONDS
                and not is_boundary):
            report["STALL"].append(
                f"{ts - last_ts:.1f}s gap before {e.get('hypothesisId','?')}/"
                f"{msg[:60]}"
            )
        last_ts = ts

    # STORM: nudges per (round, question)
    nudges = defaultdict(int)
    for e in events:
        msg = e.get("message", "")
        if "FIRED" in msg and "watchdog" in msg.lower() or "nudge FIRED" in msg:
            d = e.get("data", {})
            key = (d.get("round", "?"), d.get("question", "?"))
            nudges[key] += 1
    for key, n in sorted(nudges.items()):
        if n > NUDGE_BUDGET_PER_QUESTION:
            report["STORM"].append(f"round {key[0]} Q{key[1]}: {n} nudges")

    # Governor denials (informational — the cap working as designed)
    denials = [e for e in events if e.get("hypothesisId") == "RECOVERY_GOV"]
    if denials:
        report["INFO"].append(f"{len(denials)} recovery actions rate-limited by governor")

    # DOUBLE: same round consumed twice
    consumed = defaultdict(int)
    for e in events:
        if e.get("hypothesisId") == "RCONS" and "round consumed" in e.get("message", ""):
            rn = e.get("data", {}).get("roundNumber")
            consumed[rn] += 1
    for rn, n in consumed.items():
        if n > 1:
            report["DOUBLE"].append(f"round {rn} consumed {n} times")


def audit_mic_log(events, report):
    for e in events:
        msg = e.get("message", "")
        data = e.get("data", {}) or {}
        if msg == "MUTE_FAILSAFE_FIRED":
            report["FAILSAFE"].append("stuck-mute failsafe fired")
        elif msg == "PREROLL_FLUSH":
            report["PREROLL"].append(
                f"pre-roll flushed {data.get('chunks','?')} chunks")
        elif msg == "BARGE_BLOCKED":
            report["INFO"].append(f"barge-in blocked ({data.get('verdict','')})")
        elif msg == "MIC_ON" and data.get("reason") == "barge-in":
            report["CUTOFF"].append("barge-in honored (check audio context: genuine answer or false trigger?)")
        elif msg == "SESSION_SUMMARY":
            # Rough upper-bound: wall-clock session seconds × Grok $/min.
            # Actual bill is audio sent+received; mic gating keeps this closer
            # to speech time than raw wall clock.
            total_sec = data.get("totalSessionSec") or data.get("totalOnSec")
            if isinstance(total_sec, (int, float)) and total_sec > 0:
                mins = total_sec / 60.0
                est = mins * PRICE_AUDIO_PER_MIN
                report["COST"].append(
                    f"mic session ≈ {mins:.1f} min wall → ~${est:.3f} "
                    f"(@ ${PRICE_AUDIO_PER_MIN:.2f}/audio-min Grok Voice 2.0)"
                )


def audit_tts_fallback(events, report):
    for e in events:
        if "speaking chunk fallback via local TTS" in e.get("message", ""):
            report["TTSFALL"].append(
                f"farewell chunk {e.get('data',{}).get('failedIndex','?')} spoken by app TTS")


USAGE_RE = re.compile(
    r"input_tokens=(\d+) \| output_tokens=(\d+) \| total_tokens=(\d+)(.*)$")
ROUND_RE = re.compile(r"round=(\d+)")
TRIGGER_RE = re.compile(r"trigger=(\S+)")
AUDIO_IN_RE = re.compile(r"in_audio=(\d+)")
AUDIO_OUT_RE = re.compile(r"out_audio=(\d+)")
GEMINI_USAGE_RE = re.compile(
    r"type=usageMetadata .*provider=gemini .*prompt_tokens=(\d+) .*"
    r"response_tokens=(\d+) .*thought_tokens=(\d+) .*total_tokens=(\d+) .*"
    r"input_audio_seconds=([\d.]+) .*output_audio_seconds=([\d.]+) .*"
    r"estimated_audio_cost_usd=([\d.]+) .*context_compression=(true|false)"
)


def audit_api_usage(path, report):
    per_round_in = defaultdict(int)
    per_round_out = defaultdict(int)
    per_round_audio = defaultdict(int)
    trigger_in = defaultdict(int)
    gemini_rounds = defaultdict(
        lambda: {
            "prompt": 0,
            "response": 0,
            "thoughts": 0,
            "total": 0,
            "input_seconds": 0.0,
            "output_seconds": 0.0,
            "cost": 0.0,
            "compressions": 0,
        }
    )
    with open(path, errors="replace") as f:
        for line in f:
            gm = GEMINI_USAGE_RE.search(line)
            if gm:
                rm = ROUND_RE.search(line)
                rnd = int(rm.group(1)) if rm else 0
                values = gemini_rounds[rnd]
                values["prompt"] += int(gm.group(1))
                values["response"] += int(gm.group(2))
                values["thoughts"] += int(gm.group(3))
                values["total"] += int(gm.group(4))
                values["input_seconds"] += float(gm.group(5))
                values["output_seconds"] += float(gm.group(6))
                values["cost"] += float(gm.group(7))
                values["compressions"] += gm.group(8) == "true"
                continue
            m = USAGE_RE.search(line)
            if not m:
                continue
            inp, out = int(m.group(1)), int(m.group(2))
            rest = m.group(4)
            rm = ROUND_RE.search(rest)
            rnd = int(rm.group(1)) if rm else 0
            per_round_in[rnd] += inp
            per_round_out[rnd] += out
            ain = AUDIO_IN_RE.search(rest)
            aout = AUDIO_OUT_RE.search(rest)
            if ain:
                per_round_audio[rnd] += int(ain.group(1))
            if aout:
                per_round_audio[rnd] += int(aout.group(1))
            tm = TRIGGER_RE.search(rest)
            if tm:
                trigger_in[tm.group(1)] += inp + out

    gemini_round_numbers = sorted(k for k in gemini_rounds if k > 0)
    if gemini_round_numbers:
        report["COST"].append(
            "Gemini 3.8 Live measured audio pricing: "
            "$0.005/input-min + $0.018/output-min"
        )
        for round_number in gemini_round_numbers:
            values = gemini_rounds[round_number]
            report["COST"].append(
                f"round {round_number}: ${values['cost']:.4f} audio, "
                f"in={values['input_seconds']:.1f}s, "
                f"out={values['output_seconds']:.1f}s, "
                f"tokens={values['total']:,} "
                f"(prompt={values['prompt']:,}, response={values['response']:,}, "
                f"thoughts={values['thoughts']:,}), "
                f"compressions={values['compressions']}"
            )

    rounds = sorted(k for k in per_round_in if k > 0)
    if not rounds:
        if not gemini_round_numbers:
            report["INFO"].append("no per-round token data in api_usage log")
        return

    report["COST"].append(
        f"Grok Voice pricing: ${PRICE_AUDIO_PER_MIN:.2f}/audio-min + "
        f"${PRICE_TEXT_INPUT_EVENT:.3f}/text-input event "
        f"(token totals below are diagnostic; bill is audio-minute based)"
    )
    for r in rounds:
        line = f"round {r}: in={per_round_in[r]:,} out={per_round_out[r]:,}"
        if per_round_audio[r]:
            line += f" audio_tokens={per_round_audio[r]:,}"
        report["COST"].append(line)
    if trigger_in:
        for t, tok in sorted(trigger_in.items(), key=lambda kv: -kv[1]):
            report["COST"].append(f"recovery-trigger spend: {t} = {tok:,} tokens")
    report["COST"].append(
        f"budget target ≤ ${COST_BUDGET_PER_ROUND:.2f}/round "
        f"(~{COST_BUDGET_PER_ROUND / PRICE_AUDIO_PER_MIN:.1f} audio-min)"
    )


def main():
    paths = sys.argv[1:]
    if not paths:
        downloads = os.path.expanduser("~/Downloads")
        for pattern in ("debug-f3b222*.log", "debug-30dda1*.log",
                        "mic_gating*.log", "api_usage*.log"):
            paths.extend(sorted(glob(os.path.join(downloads, pattern))))
    if not paths:
        print("No log files found. Pass paths explicitly.")
        sys.exit(2)

    report = defaultdict(list)
    for path in paths:
        name = os.path.basename(path)
        if name.startswith("api_usage"):
            audit_api_usage(path, report)
            continue
        events = load_jsonl(path)
        if not events:
            continue
        if name.startswith("mic_gating"):
            audit_mic_log(events, report)
        else:
            audit_debug_logs(events, report)
            audit_tts_fallback(events, report)

    print("=" * 64)
    print("ROADTRIP TRIVIA — GAME LOG AUDIT")
    print("=" * 64)
    failures = 0
    for key, label, is_failure in [
        ("CUTOFF", "Honored barge-ins (verify each was a genuine answer)", False),
        ("STALL", f"Dead-air gaps > {STALL_SECONDS:.0f}s", True),
        ("STORM", "Nudge storms (budget exceeded)", True),
        ("DOUBLE", "Double round consumption", True),
        ("FAILSAFE", "Stuck-mute failsafe firings", True),
        ("TTSFALL", "Farewell delivered via local TTS fallback", False),
        ("PREROLL", "Early answers rescued by pre-roll", False),
        ("COST", "Live provider cost estimate", False),
        ("INFO", "Info", False),
    ]:
        items = report.get(key, [])
        status = "FAIL" if (items and is_failure) else ("note" if items else "PASS")
        if items and is_failure:
            failures += 1
        print(f"\n[{status}] {label}: {len(items)}")
        for item in items[:20]:
            print(f"    - {item}")
        if len(items) > 20:
            print(f"    ... and {len(items) - 20} more")

    print("\n" + "=" * 64)
    print("RESULT:", "FAIL" if failures else "PASS",
          f"({failures} failing categories)" if failures else "")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
