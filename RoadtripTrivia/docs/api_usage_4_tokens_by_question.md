# api_usage 4.log — token usage by phase / round / question / category

Source: `api_usage 4.log` — only `response.done` with `status=completed` and `total_tokens > 0`.

**Token categories:** `in_text`, `in_audio`, `out_text`, `out_audio`, and cached input (`cached_in_text`, `cached_in_audio`).

**~USD:** estimated for `gpt-realtime` (text/audio/cached rates; non-cached input ≈ modality minus cached portion).

| Phase | Rnd | Q | Category | Difficulty | #Resp | In | Out | Total | in_txt | in_aud | out_txt | out_aud | c_in_txt | c_in_aud | ~USD |
|---|---:|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| _preamble | 0 | 0 | (no context yet) | n/a | 4 | 9443 | 701 | 10144 | 8616 | 827 | 163 | 538 | 6400 | 768 | $0.0507 |
| intro | 0 | 1 |  | Simple | 3 | 8700 | 719 | 9419 | 6846 | 1854 | 190 | 529 | 4480 | 1152 | $0.0711 |
| intro | 2 | 5 | Cape Cod wildlife and nature | Wicked Hard | 4 | 49144 | 814 | 49958 | 22322 | 26822 | 220 | 594 | 16448 | 19904 | $0.3009 |
| trivia | 0 | 1 |  | Simple | 3 | 11306 | 692 | 11998 | 7627 | 3679 | 247 | 445 | 7488 | 3648 | $0.0384 |
| trivia | 1 | 1 | Cape Cod history and culture | Simple | 3 | 25349 | 694 | 26043 | 12405 | 12944 | 241 | 453 | 12224 | 12864 | $0.0462 |
| trivia | 1 | 2 | Cape Cod history and culture | Simple | 4 | 18838 | 890 | 19728 | 11463 | 7375 | 282 | 608 | 10944 | 6784 | $0.0715 |
| trivia | 1 | 3 | Cape Cod history and culture | Simple | 3 | 16630 | 753 | 17383 | 9444 | 7186 | 242 | 511 | 9280 | 7168 | $0.0444 |
| trivia | 1 | 4 | Cape Cod history and culture | Simple | 3 | 19133 | 740 | 19873 | 10316 | 8817 | 255 | 485 | 9984 | 8256 | $0.0617 |
| trivia | 1 | 5 | Cape Cod history and culture | Simple | 4 | 29167 | 1210 | 30377 | 15065 | 14102 | 356 | 854 | 14784 | 13952 | $0.0778 |
| trivia | 2 | 1 | Cape Cod wildlife and nature | Wicked Hard | 3 | 39967 | 753 | 40720 | 17984 | 21983 | 258 | 495 | 17728 | 21696 | $0.0618 |
| trivia | 2 | 2 | Cape Cod wildlife and nature | Simple | 3 | 27672 | 719 | 28391 | 13253 | 14419 | 241 | 478 | 13056 | 14400 | $0.0468 |
| trivia | 2 | 3 | Cape Cod wildlife and nature | Simple | 3 | 30091 | 735 | 30826 | 14104 | 15987 | 243 | 492 | 13888 | 15936 | $0.0498 |
| trivia | 2 | 4 | Cape Cod wildlife and nature | Simple | 3 | 32499 | 680 | 33179 | 14962 | 17537 | 238 | 442 | 14784 | 17472 | $0.0478 |
| trivia | 2 | 5 | Cape Cod wildlife and nature | Simple | 2 | 22936 | 492 | 23428 | 10440 | 12496 | 182 | 310 | 10112 | 11968 | $0.0498 |
| trivia | 3 | 1 | Cape Cod maritime history | Wicked Hard | 3 | 55108 | 656 | 55764 | 22941 | 32167 | 208 | 448 | 22720 | 32128 | $0.0561 |
| trivia | 3 | 2 | Cape Cod maritime history | Wicked Hard | 3 | 42464 | 783 | 43247 | 18871 | 23593 | 262 | 521 | 18624 | 23488 | $0.0587 |
| trivia | 3 | 3 | Cape Cod maritime history | Wicked Hard | 3 | 44986 | 689 | 45675 | 19760 | 25226 | 248 | 441 | 19584 | 25152 | $0.0532 |
| trivia | 3 | 4 | Cape Cod maritime history | Wicked Hard | 3 | 47302 | 763 | 48065 | 20600 | 26702 | 243 | 520 | 20352 | 26560 | $0.0615 |
| trivia | 3 | 5 | Cape Cod maritime history | Wicked Hard | 5 | 84922 | 1625 | 86547 | 36254 | 48668 | 434 | 1191 | 35840 | 48192 | $0.1337 |
| trivia | 4 | 1 | Sports | Wicked Hard | 2 | 46713 | 279 | 46992 | 18637 | 28076 | 110 | 169 | 18432 | 27776 | $0.0415 |
| trivia | 4 | 2 | Sports | Wicked Hard | 3 | 57276 | 628 | 57904 | 23706 | 33570 | 217 | 411 | 23488 | 33472 | $0.0566 |
| trivia | 4 | 3 | Sports | Wicked Hard | 3 | 59377 | 693 | 60070 | 24469 | 34908 | 227 | 466 | 24000 | 34432 | $0.0739 |
| trivia | 4 | 4 | Sports | Wicked Hard | 5 | 104166 | 1568 | 105734 | 42691 | 61475 | 469 | 1099 | 42368 | 61312 | $0.1258 |
| trivia | 4 | 5 | Sports | Wicked Hard | 3 | 67164 | 1119 | 68283 | 27078 | 40086 | 348 | 771 | 26880 | 40000 | $0.0852 |
| trivia | 5 | 2 | Pop Trivia | Wicked Hard | 2 | 47398 | 240 | 47638 | 18946 | 28452 | 121 | 119 | 18816 | 28416 | $0.0301 |
| trivia | 5 | 3 | Pop Trivia | Wicked Hard | 2 | 47986 | 294 | 48280 | 19260 | 28726 | 129 | 165 | 18752 | 28096 | $0.0536 |
| trivia | 5 | 4 | Pop Trivia | Wicked Hard | 2 | 48687 | 252 | 48939 | 19597 | 29090 | 121 | 131 | 19456 | 29056 | $0.0314 |
| trivia | 5 | 5 | Pop Trivia | Wicked Hard | 2 | 49295 | 237 | 49532 | 19905 | 29390 | 98 | 139 | 19776 | 29312 | $0.0331 |
| trivia | 5 | 6 | Pop Trivia | Wicked Hard | 2 | 49908 | 242 | 50150 | 20212 | 29696 | 99 | 143 | 20160 | 29696 | $0.0309 |
| trivia | 5 | 7 | Pop Trivia | Wicked Hard | 2 | 50539 | 239 | 50778 | 20527 | 30012 | 118 | 121 | 20416 | 29952 | $0.0321 |
| trivia | 5 | 8 | Pop Trivia | Wicked Hard | 2 | 51127 | 305 | 51432 | 20839 | 30288 | 111 | 194 | 20800 | 30208 | $0.0373 |
| trivia | 5 | 9 | Pop Trivia | Wicked Hard | 2 | 51892 | 255 | 52147 | 21184 | 30708 | 123 | 132 | 20672 | 30208 | $0.0488 |
| trivia | 5 | 10 | Pop Trivia | Wicked Hard | 3 | 79528 | 680 | 80208 | 32480 | 47048 | 234 | 446 | 32320 | 46848 | $0.0710 |

**Sum ~USD (all rows):** $2.1331

## Per round (trivia only)

| Round | Σ total_tokens | ~USD |
|------:|---------------:|-----:|
| 0 | 11998 | $0.0384 |
| 1 | 113404 | $0.3015 |
| 2 | 156544 | $0.2560 |
| 3 | 279298 | $0.3631 |
| 4 | 338983 | $0.3830 |
| 5 | 479104 | $0.3683 |
