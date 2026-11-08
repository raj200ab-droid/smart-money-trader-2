# NOTES — what was asked, what was decided, what is still open

This file is the memory of the project. If a decision looks strange later, the
reason is in here. Written down because the conversation that produced it will
not be readable forever.

---

## 1. What was originally asked (Bangla, in order)

1. **"Ata tikh koro"** — fix the broken Flutter smart-money app.
2. **"VPN charao cholte hobe"** — it must work *without* a VPN. The "just use a
   VPN" answer was explicitly rejected, after being shown that it fails behind
   the VPN too.
3. **Port the LuxAlgo "Smart Money Concepts" logic** from the user's TradingView
   link instead of the home-grown signal code.
4. **"Ata ki valo holo nh ki amader ager version tayo valo cilo"** — an honest
   verdict, not reassurance, on whether the new version is better.
5. **"Yes koro"** — build a backtest that proves signal quality with a real win
   rate instead of opinions.
6. **"Ami chai tumi nuton akta repo banayo GitHub a"** — a new, separate repo.

## 2. Standing rules the user set (do not break these)

| rule | why |
|---|---|
| Reply in Bengali / Banglish | the user's language |
| The app must work without a VPN | user rejected the VPN answer with evidence |
| No "it is good" without a measurement | user asked for an honest verdict twice |
| A confidence score is **not** a win rate | said explicitly; signal quality must be backtested |
| Do not ship a change based on opinion alone | every engine change here was measured in a Python mirror first |

## 3. The honest verdict that was given

The previous version was **worse**, but not for a subtle reason: `main.dart` was
truncated at 20,001 bytes and did not compile at all. The current version runs,
but "better" only means measurable — hence the backtest. This distinction was
stated to the user and must not be sugar-coated later.

## 4. Root causes found, in order

| # | symptom | actual cause |
|---|---|---|
| 1 | "all exchanges skipped" | `flutter create` puts `INTERNET` only in `src/debug` / `src/profile`; release merges `src/main` only. Fixed by `tool/patch_manifest.py` + a CI `aapt2` assertion |
| 2 | 73/73 coins scanned, 0 signals | `swings()` used the window `[n-len .. n-1]`, so the tested bar could never exceed its own high. Zero pivots → no breaks → no trend. Translated to Python: old form 0 pivots, LUX form 3 per 200 bars |
| 3 | every signal was a SELL | the oscillator started at `0`, so the first confirmed pivot of every window could only be a **low** (82 highs vs 147 lows). 4H bias went 33 bull / 82 bear → 133 / 143 after starting the state unknown |
| 4 | bullish setups never scored the zone bonus | the `+25` OB bonus only fired on the side the bias already favoured. Added a structure floor: the nearest valid OB decides which side is blocked |
| 5 | 87% of coins had "no 4H trend" | 200 bars of 4H at swing length 50 holds under one pivot per side. 400 bars → bias present on 73% instead of 53% |
| 6 | backtest reported "50% win rate" from 2 trades | 5 of 7 trades were still OPEN; the walk stopped at the first unresolved trade and `openUntil` never advanced. 1000 bars = 10 days. Now 4000 bars (~40 days) via Binance paging, open trades reported separately |
| 7 | misleading backtest copy | the screen literally said "50% mane protiti 3 trade e 2 tar target hobe" — nonsense. Replaced with the real counts, and a warning when under 20 decided trades |

## 5. Decisions that look odd but are deliberate

- **STRICT requires the swing break; WATCH may use the internal break.** A 15M
  trigger inside the last two bars is a lottery (0.8%/1.0% funnel). A trigger
  that stays alive while price holds beyond its pivot is 4-7 per 100 coins.
- **RADAR tier exists.** A blank screen cannot be tuned. RADAR lists coins where
  bias and a live break agree but the zone or score is missing, with an OB/FVG/
  swing-based SL and a "Zone nei — wait koro" note. It is a candidate list,
  never a trade instruction.
- **No invented bias.** The old "4H neutral → borrow the 1H trend" fallback was
  removed: it produced bias the higher timeframe did not have.
- **LUX is reimplemented, not copied.** The Pine source is CC BY-NC-SA 4.0
  (non-commercial). Only the mechanics were recovered and rewritten in Dart.
- **Build stamp `v4 · radar` + `version: 4.0.0+4`.** Added because the user
  installed an older APK twice and we could not tell from a screenshot.

## 6. Measured numbers worth keeping

Synthetic funnel, 200 series per side (Python mirror):
`no 4H bias 30.0% / 29.5%`, `no 1H zone 19.0% / 19.5%`, `no 15M trigger
0.8% / 1.0%`, strict pass ≈ 1%.

After the fixes, regime-switching synthetic data, 120 coins:
**STRICT 7 BUY / 9 SELL, WATCH 12 BUY / 13 SELL**. Walk-forward mirror over
three long series: 114 BUY / 108 SELL, 77% win rate, +299R — *on synthetic data,
so this says the maths is not broken, not that the strategy is profitable.*

Random entries at 1:1 produced ~57% "win rate" and +6R of pure noise, which is
why the UI leads with total R and greys the win rate out under 20 trades.

## 7. Still open

1. **The user has not sent backtest numbers from a real device yet.** Everything
   measured so far is a Python mirror of the engine; the mirror and the Dart
   code can drift.
2. **`openUntil` / paging path is untested on device** — build
   `41912355894` has never been run.
3. **New repo blocked.** The user created `smart-money-new-version-` (private),
   but the GitHub token is scoped to `smart-money-trader-2`: create → 403
   `createRepository`, push → 403 `Write access not granted`. Needs Arena's
   GitHub connection to be re-authorised with **All repositories**. The ready
   tree (README / .gitignore / LICENSE, commit `cba8372`) sits in
   `/home/user/smart-money-trader-v2/`, patch at `/home/user/v2-initial.patch`.
4. Not built, offered: STRICT-only toggle, breakeven/trailing stops,
   liquidity-based take profit.

## 8. Repo conventions

- `.gitignore` intentionally ignores `android/`, `ios/`, `test/` etc. — CI runs
  `flutter create` and only hand-written files are tracked. Several commits have
  been lost to accidentally deleting `.gitignore` or `tool/patch_manifest.py`
  while splicing `lib/main.dart`; check `git ls-files` after big edits.
- After non-trivial Dart edits, trust CI over local parsing: tree-sitter catches
  syntax but not type/arity errors.
- Backticks inside `gh pr comment --body '...'` heredocs need escaping.

---

## 9. v5 · 300 — wider universe, engine untouched (2026-11-08)

**Asked:** "আচ্ছা এখান থেকে ৩০০টা কয়েন অ্যাড করতে বলি তাহলে কি কোন সমস্যা হবে" →
"আচ্ছা করো কিন্তু কোন ধরনের চেঞ্জ করবে না আগে যে নিয়মে চলত সেই নিয়মেই যেন থাকে".

**What changed (scanner plumbing only):**

| change | why |
|---|---|
| `60/40` → `150/150` coins (300 max) | the ask; top-mover picker logic untouched |
| 15M fetched first, then 4H with `liveFrom:` | the 4H cache needs the fresh 15M tail anyway; one request per coin saved |
| **closed-bar 4H cache** (max 320 coins) | a closed 4H bar cannot change; the forming bar is rebuilt from the 15M series it already has |
| cache expires when the forming bar would close (1 min early) | a late expiry leaves a hole in the series (one bar short) — measured |
| 4–6 concurrent workers (`>120 coins` → 6) | keeps a 300-coin scan inside the 5-minute auto-refresh slot |
| per-pair 15-minute cooldown after a candle failure | one dead symbol used to burn 5 mirror attempts on every scan |
| chunked list commit (25 coins) | a 300-coin scan no longer rebuilds the list per coin, and it is not empty for the whole scan |
| `_tooYoung` counter | young listings (<120 4H bars) are counted apart instead of being reported as "no 4H trend" |
| `v5 · 300` / `5.0.0+5` | the installed build must be identifiable from a screenshot |
| status line shows `4H cache hits/hits+misses (cached coins)` | proof on device that the cache is warm |

**What did NOT change — deliberately:** swing lengths (50/5), the pivot state
machine, BOS/CHoCH, order blocks, FVGs, EQH/EQL, premium/discount, the scoring
table, STRICT 60 / WATCH 40, the live-trigger rule, SL/TP maths, the 8% risk
reject, RADAR semantics, and the windows fed to the engine (4H 400 / 1H 200 /
15M 200 from 600 fetched bars). The backtester is untouched and out of scope.

**Measured before committing** (`/home/user/smt-verify/`):

- `verify_4h_cache.py` — EQUIVALENCE: 3840 cases (120 series × 32 cut points
  inside a 4H bar), **0 mismatches** against the exchange's own 4H aggregation,
  forming bar rebuilt correctly in 3840/3840. FRESHNESS: 4/4 cases. A drift
  guard fails the run if `lib/main.dart` stops containing the lines the mirror
  was written against.
- `budget.py` — warm cache: 300 requests → 600 requests for 3× the coins
  (old 300 requests for 100 coins), 58 MB/scan vs 29 MB, 66 s vs 48 s.
  Cold first scan: 900 requests / 88 MB / 96 s.

**Bug found by the measurement, before it shipped:** the first `_merge4h` used
`k.openTime > lastClosedOpen`, which swept the 15 forming bars of the *last
closed* bar into the new one — 5440 mismatches. Fixed to `>= boundary`.
The freshness horizon also expired one bar too late at first (20-minute margin
on the wrong side), which would have left a hole in the 4H series.

**Still open:** device numbers for `v5 · 300` (scan time, cache hit ratio,
STRICT/WATCH/RADAR counts) — the CI APK has not been run yet.
