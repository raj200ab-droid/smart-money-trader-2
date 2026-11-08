# HANDOFF — everything a new chat needs

**Purpose:** this file exists so work can continue in a fresh conversation
without losing a single decision, number, or promise. Read it top to bottom
before touching anything. If something here conflicts with the code, the code
wins — then update this file.

Last updated: 2026-11-08 · branch `arena/5182e84b-smart-money-trader-2` ·
build `v8 · swingTP` / `8.0.0+8` · `lib/main.dart` ≈ 3600 lines ·
PR #1 merged; this branch is the 300-coin work

---

## 0. How to talk to this user

- **Write in Bengali / Banglish.** Not English-only. Technical words stay in
  English (`order block`, `win rate`, `total R`) — that is how he writes.
- **No flattery, no "done, it's great".** He has twice asked for an honest
  verdict and once rejected reassurance. A version is only "better" when a
  number says so.
- **Never claim quality without a measurement.** Every engine change in this
  project was first mirrored and measured in Python, then written in Dart.
- **A confidence percentage is not a win rate.** He said this explicitly.
- When something is broken because of a mistake on our side, say so plainly and
  fix it in the same turn.
- He tests on a real Android phone and sends screenshots. Screenshots are the
  primary source of truth about what the app actually did.

## 1. What he asked for, in order

1. **"Ata tikh koro"** — fix the broken Flutter smart-money app.
2. **It must work without a VPN.** He rejected "just use a VPN" with evidence
   that it fails behind the VPN too.
3. **Port the LuxAlgo "Smart Money Concepts" logic** from his TradingView link.
4. **"Ata ki valo holo nh ki amader ager version tayo valo cilo"** — honest
   verdict on whether the new version is better than the old.
5. **"Yes koro"** — build a backtest that proves signal quality with a real win
   rate, not an opinion.
6. **"Ami chai tumi nuton akta repo banayo GitHub a"** — a separate new repo.
7. **"Ami chai nh je tumi vule a jayo"** — keep the reasoning, write it down.

## 2. The verdict already given (do not water it down)

The previous version was **worse**, and not subtly: `main.dart` was truncated at
20,001 bytes and never compiled. The current version runs — but "better" only
means *measurable*. That is why the backtest exists.

## 3. Architecture (current, v1)

`lib/main.dart`, one file, in this order:

| lines | section |
|---|---|
| 67–355 | MODELS — `Candle`, `CoinData`, `OrderBlock`, `FVG`, `SwingPoint`, `StructureBreak`, `TFAnalysis`, `TradeSignal` (`tier`: `STRICT` / `WATCH` / `RADAR`) |
| 356–927 | MARKET DATA — Binance (5 mirrors) → Bybit → OKX → MEXC, per-feed health, `_binancePaged` for deep history |
| 928–1934 | SMART MONEY ENGINE — `Engine.swings`, `breaks`, `_structureOb`, `fvgs`, `equalHighs`, `analyze`, `analyzeLong`, `buyZone`/`sellZone`/`nearestObTo`, `multiTF`, `radar` |
| 1935–2153 | BACKTEST — `BacktestTrade`, `BacktestResult`, `Backtester.run` |
| 2154–3079 | UI — `HomeScreen`/`_HS` (scan, filters, detail sheet), `_SignalCard` |
| 3080+ | BACKTEST SCREEN — `BacktestScreen`/`_BTS` |

`tool/patch_manifest.py` adds `INTERNET` to `android/app/src/main/AndroidManifest.xml`
(idempotent). `.github/workflows/build.yml` runs `flutter create` (Flutter 3.16.0),
patch, analyze, build, then asserts the permission with `aapt2`, then uploads
`smart-money-trader-apk`.

## 4. Engine rules — exact, as implemented

**Swings (LUX `swings(len)`).** `len = 50` for structure, `5` for internal.
Window is `[n-len+1 .. n]` — **inclusive of the current bar**. Oscillator state
starts **unknown** (not 0) and no pivot is emitted until the first real flip.
Pivot is read at `high[n-len]` / `low[n-len]`.

**Bias.** `trend` = direction of the **freshest confirmed break** over the whole
window (LUX keeps `var trend`), not the HH/HL shape of the last two pivots.
4H only — the old "neutral → borrow from 1H / internal break" fallbacks are
**deleted** because they invented bias.

**Scoring in `multiTF`** (STRICT threshold 60, WATCH 40):

| condition | points |
|---|---|
| 4H bias agrees | +30 |
| 1H OB on the bias side | +25 |
| 1H FVG (bias side) | +20 if no OB, else +10 |
| 15M swing break still holding beyond its pivot | +20 |
| 15M internal break (WATCH only) | +20 |
| 15M volume spike | +5 |
| 1H premium zone | BUY −25 |
| 1H discount zone | SELL −25 |
| 1H breakout / breakdown | +5 |

**Structure floor.** `nearestObTo()` picks the closest still-valid OB; a bearish
OB overhead blocks BUY, a bullish OB underneath blocks SELL. This is what
stopped the "all SELL" bug.

**Trigger.** STRICT needs the freshest swing break **with price still on the far
side of its pivot**. WATCH may also use the internal break. A break that only
counted inside the last 2 bars was a lottery (0.8–1.0% funnel); a live trigger is
4–7 per 100 coins.

**SL / TP.** SL from OB → 1H FVG → 15M swing, each with `0.25 × ATR(1H)`; TP =
15M swing high/low if beyond entry, else `2R`. Reject if `risk/entry > 8%`.

**RADAR.** Bias + live 15M break but missing zone or score. Same SL/TP maths,
`confidence 0`, labelled grey, confirmations say *"Zone nei — wait koro"* or
`"Premium penalty"`. It is a candidate list, never a trade instruction. It
exists so a quiet scan is not a blank screen we cannot tune.

**Windows fed to the engine.** 4H = **400 bars** (200 holds under one pivot per
side → 87% "no trend"), 1H = 200, 15M = 200. Scanner fetches 600 per timeframe;
`analyzeLong` compares the 400-bar bias against the full series and flags a
`structureConflict` warning.

## 5. Backtest — exact semantics

Fetches `4h 900`, `1h 1200`, `15m 4000` (~40 days; 1000 bars was 10 days).
Walks 15M bar by bar from bar 200, feeding only closed candles on the 1H/4H
windows aligned by `closeTime` (4H window degrades 400 → 200 → 120 for young
listings). One trade at a time; `openUntil` always advances so an unresolved
trade cannot silence the walk. A bar touching both SL and TP counts as a loss.
`maxTrades = 200`. Report: win rate, wins/losses, **open**, total R, avg R,
strict-only rate, streak, full trade list. **Under 20 decided trades the screen
says the sample is too small and greys the win rate out** — keep that honest,
it is a feature, not a nit.

## 6. Every root cause found (do not re-introduce)

| # | symptom | cause / fix |
|---|---|---|
| 1 | "all exchanges skipped" | `INTERNET` only in `src/debug`/`src/profile`; release merges `src/main`. Fixed by `tool/patch_manifest.py` + `aapt2` CI assertion |
| 2 | 73/73 coins, 0 signals | swing window was `[n-len .. n-1]` — the tested bar could never exceed its own high. Old form: 0 pivots; LUX form: 3 per 200 bars |
| 3 | every signal a SELL | oscillator started at 0 → first pivot of every window forced to be a low (82 highs vs 147 lows). 4H bias 33 bull/82 bear → 133/143 |
| 4 | bullish setups never got the OB bonus | bonus only fired on the bias side; fixed with the structure floor |
| 5 | 87% "no 4H trend" | 400 bars instead of 200 (bias present 53% → 73%) |
| 6 | "50% win rate" from 2 trades | 5 of 7 were OPEN; `openUntil` never advanced and 1000 bars = 10 days |
| 7 | wrong backtest copy | it literally claimed "50% mane protiti 3 trade e 2 tar target hobe" — replaced with real counts |
| 8 | release APK lost INTERNET again | a README commit deleted `.gitignore` **and** `tool/patch_manifest.py`. After any splice, run `git ls-files` |

## 7. Numbers worth quoting

Synthetic funnel (200 series/side): `no 4H bias 30.0/29.5%`, `no 1H zone
19.0/19.5%`, `no 15M trigger 0.8/1.0%`, strict pass ≈1%.

After the fixes, regime-switching synthetic, 120 coins: **STRICT 7 BUY / 9 SELL,
WATCH 12 BUY / 13 SELL**. Walk-forward mirror over three long series: **114 BUY /
108 SELL, 77% win rate, +299R** — synthetic, so it proves the maths is not
broken, not that the strategy makes money. Say that out loud every time.

Random entries at 1:1 gave ~57% "win rate" and +6R of pure noise — the reason the
UI leads with total R.

## 8. Live evidence so far

- `v4 · radar` build: **74/74 scanned, 3 signal + 7 watch**, all SELL (that was
  bug #3, fixed after the screenshot).
- BTCUSDT backtest on the old build: `7 trade · win rate 50% · W/L 1/1 · Total R
  −0.14R`, five trades OPEN — statistically useless, and the reason the whole
  backtest path was reworked.
- **No backtest numbers from the fixed build have been reported yet.**

## 8b. v5 · 300 — the 300-coin scan (2026-11-08)

Asked for 300 coins, then: *"কোন ধরনের চেঞ্জ করবে না আগে যে নিয়মে চলত সেই নিয়মেই যেন
থাকে"*. So the engine was not touched — see NOTES.md §9 for the full diff list.

- universe `150 + 150`; the scorer, tiers, SL/TP and windows are byte-identical
- closed-bar 4H cache + forming bar rebuilt from the fresh 15M series
  (**3840/3840 cases identical to the exchange's own 4H**, drift-guarded test in
  `/home/user/smt-verify/verify_4h_cache.py`)
- warm cache: 3× the coins for 2× the requests (600), 66 s scan, 58 MB
- device numbers for this build are **not in yet** — that is the next open item

## 8c. v6 · unify — dead score removed, EQH/EQL repaired (2026-11-08)

The user noticed that `analyze()` computed `buyScore/sellScore`/`buyConf`/`sellConf`
that `multiTF` never read, and that EQH/EQL was display-only. Both were real.

- **deleted** 83 lines + 7 fields of scoring nothing consumed (`sweep`, `bos`,
  `choch` included). `multiTF` is now the only score in the program.
- **EQH/EQL was unreachable**: 0.1×ATR over *swing* pivots = 0/48 true.
  Now internal pivots at 0.5×ATR = 29%. Still **display-only**, on purpose.
- **`internalFresh`/`internalEvent` were never assigned**, so the WATCH pass's
  internal-break trigger and the RADAR fallback could never fire. Wired up.
- EQH/EQL as a *score/veto* was measured (84 paired series, 4 regimes) and moved
  the result by at most one trade — see NOTES.md §10 for the table. Not shipped
  as a rule; the code comment says why.

`/home/user/smt-verify/mirror.py` is the Python mirror again (the old `smt-mirror`
was gone). Fix `swings()` if it ever drifts — it is verified against the naive
form.

## 8d. v7 · tp1.05 — fixed 1.05% target (2026-11-08)

Requested: real data, TP = 1.05% only, more candles, "good result every test".

- TP is now `kTpPct = 1.05%` from entry for **every** signal (scan and backtest).
  **The stop is unchanged**, so R:R is set by the stop, not by the target.
- trades whose stop is closer than the target are **rejected** (guaranteed loss).
- backtest: 12000 15M bars (~125 days), 4H 1500, 1H 3000, maxTrades 2000.
- report prints win rate **and** total R, plus R:R, break-even WR, and the
  result after 0.25% costs.

Measured on the mirror **before** shipping: 643 trades, **75.6% win rate,
−8.4R**. The win rate rose and the expectancy went negative — NOTES.md §11 has
the table and the arithmetic. Do not "fix" this by raising the target without
measuring; the same table shows 2.0% is only break-even.

## 8e. v8 · swingTP — fixed target reverted (2026-11-08)

The 1.05% take profit added in v7 was removed at the user's request. Target is
`15M swing else 2R` again. Kept from v7: the deeper backtest sample (12000 15M
bars), `maxTrades` 2000, the richer report (win rate + total R + R:R +
break-even + cost), and `tool/mirror/` in the repo.

Justification for the revert is the paired table in NOTES §11: 38.9% WR /
+13.4R with the swing target vs 75.6% WR / −8.4R with the fixed one.

## 9. Open items

1. **New repo blocked.** He created `smart-money-new-version-` (private). The
   GitHub token is scoped to `smart-money-trader-2`: create → `403
   createRepository`, push → `403 Write access not granted`, `gh api` → `404`.
   Needs Arena's GitHub connection re-authorised with **All repositories**. The
   ready tree (README/.gitignore/LICENSE, commit `cba8372`) sits in
   `/home/user/smart-money-trader-v2/`, patch at `/home/user/v2-initial.patch`.
2. **PR #1 is still open**, so `NOTES.md` / `HANDOFF.md` are only on the branch —
   `main` does not have them. He asked why "the note is not copying"; the answer
   is: not merged yet.
3. **Device numbers for `v5 · 300`** — scan time, `4H cache hits/hits+misses`,
   STRICT/WATCH/RADAR counts. Nothing has been reported from a phone yet.
4. Offered, not built: STRICT-only toggle, breakeven/trailing stops,
   liquidity-based TP.

## 10. Tooling notes (learned the hard way)

- Python `str.replace` splices on `lib/main.dart` have matched the wrong block
  (identical constructor fragments). Anchor on unique lines, `grep -n` after.
- Tree-sitter parses Dart syntax but not arity/types — trust CI (`flutter
  analyze`) after non-trivial edits.
- `gh run view --log` is unreliable here (EOF); use `gh run watch <id>
  --interval 20 --exit-status` then `gh run view <id>`.
- Don't retry `gh pr edit` (fails). Don't use `gh run view --log-failed`.
- Blanket `git add -A` after a mirror/splice once deleted `.gitignore` and
  `tool/patch_manifest.py`; always check `git ls-files` before committing.
- Binance returns HTTP 451 from restricted IPs; Bangladesh restricts crypto
  trading, so VPN-region advice has to be honest about that.
- The Python mirror of the engine lives in `/home/user/smt-mirror/m.py` and
  `/home/user/smt-mirror/bt.py` (walk-forward). Keep them working; they are how
  every scoring change gets measured before it ships.

## 11. Next step recommendation

Get the device backtest numbers first (regenerate the APK from the latest
commit, run BTCUSDT, send the screen). Then decide between: STRICT-only toggle,
trailing/breakeven, or liquidity-based TP. Do not tune the score on intuition —
the whole point of this project's last ten commits is that intuition was wrong
every single time.
