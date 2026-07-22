# Golden Game Checklist

A ~10-minute scripted test to run before calling any build good. Run it the
same way every time; mark each row pass/fail. After the drive, export the logs
and run `make audit` for the objective half of the report.

Setup: CarPlay connected, at least 2 rounds available, app open on iPhone.

| # | Step | Expect | Pass? |
|---|------|--------|-------|
| 1 | Start new game | Host asks team name only, waits | |
| 2 | Answer team name immediately (no pause) | Host hears it first try | |
| 3 | Answer ages, then difficulty ("tricky") immediately | No repeat needed, no dead air > 5s | |
| 4 | Wait for Round 1 intro | Host announces round + category verbatim, then Q1 | |
| 5 | Answer Q1 the instant the host stops talking | Heard first try; chime/gong plays fully | |
| 6 | Q2: answer, listen to verdict | Spoken verdict + points match the screen exactly | |
| 7 | Q3: give a wrong answer | Host states the correct answer; gong plays | |
| 8 | Say "challenge" on that grading | Host re-grades the PREVIOUS question; screen updates if overturned | |
| 9 | Ask for a hint on Q4 | Hint given (≤2/round); no spoiler | |
| 10 | Complete Round 1 | Round summary; rounds-remaining count matches app screen | |
| 11 | Round 2: let one question sit ~10s unanswered | At most ONE gentle re-prompt; host is never cut off mid-sentence | |
| 12 | Talk over the host mid-question (crosstalk) | Host finishes the question; no restart, no skip | |
| 13 | Play to a lightning round (round 5) or force one | "Lightning Round!" announced BEFORE first question; timer on screen | |
| 14 | Let lightning timer expire | Game moves on at 0:00 exactly; score announced matches screen | |
| 15 | Exhaust the last round | Farewell: score summary + purchase CTA + goodbye, ALL fully spoken | |
| 16 | After farewell | iPhone shows subscription/purchase screen | |
| 17 | Purchase a 3-round pack | Balance +3 exactly (not +6); CarPlay label updates without restart | |
| 18 | Resume/restart game | Continues at next unasked question; no replayed intro | |
| 19 | Trigger a connection loss (toggle airplane mode 10s) | "Reconnecting" spoken once; resumes where it left off, no round replay | |
| 20 | Run `make audit` on the exported logs | PASS (no stalls > 10s, no storms, no double consumption) | |

Hard rules — any one of these is an automatic build rejection:

- The host gets cut off mid-sentence at any point.
- The player has to repeat an answer that was clearly spoken.
- The spoken score and the on-screen score disagree.
- The purchase CTA is skipped or truncated when rounds run out.
- A round credit is consumed twice, or consumed for an unfinished round.
