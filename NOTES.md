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

---

## 10. v6 · unify — the dead score, EQH/EQL, and internal freshness (2026-11-08)

**Asked:** "analyze()-র নিজের buyScore/sellScore ... multiTF কখনো পড়ে না ... eqh/eql শুধু
UI-তে দেখানো হয় ... এই সমস্যাটা সমাধান করে ঠিক করে দাও". Chosen approach: **B (unify)**
with EQH/EQL as a **zone/veto**, not a sweep trigger.

### Three defects, all real

| # | defect | evidence | fix |
|---|---|---|---|
| 1 | `analyze()` built a whole second score (`buyScore/sellScore`, `buyConf/sellConf`, `sweep`, `bos`, `choch`) that **no caller read** | `grep` showed 2 refs each: the field and its construction site | deleted: 83 lines of scoring + 7 fields. `multiTF` is the only score |
| 2 | `equalHighs/equalLows` sourced from **swing** pivots at **0.1×ATR** | measured **0/48** timeframes true; consecutive swing pivots sit a median **4.9 ATR** apart, so the condition is unreachable. The UI "Liquidity" row always read None | sourced from **internal** pivots (len 5, LUX) at **0.5×ATR** → **29%** hit rate |
| 3 | `internalFresh`/`internalEvent` were **never assigned** in `analyze()` | field initialised from a local that did not exist → always false/'' | computed from `internalRecent`; the WATCH internal-break trigger and RADAR fallback can now fire |

Defect 3 was found while doing defect 1, and it is the biggest of the three: the
relaxed pass had a trigger that could never fire.

### The measured answer on scoring EQH/EQL (do not re-litigate without new data)

Paired test, identical candles, 12 synthetic series × 4 regimes (mixed / trend /
range / volatile), walk-forward with the app's own rules:

| variant | trades | closed | WR | totalR | avgR |
|---|---|---|---|---|---|
| OLD (EQH/EQL unused, 0.1×ATR on swings) | 86 | 76 | 50.0% | +36.7 | +0.483 |
| FIXED (internal pivots, 0.5×ATR) | 86 | 76 | 50.0% | +36.7 | +0.483 |
| + veto, pool within 0.5 ATR | 86 | 76 | 50.0% | +36.7 | +0.483 |
| + veto, pool within 1.0 ATR | 87 | 77 | 49.4% | +35.7 | +0.464 |
| + veto, pool within 1.5 ATR | 87 | 77 | 49.4% | +35.7 | +0.464 |
| + veto, pool within 2.5 ATR | 87 | 78 | 50.0% | +37.7 | +0.484 |

The veto **does fire** (instrumented: 288 arms over 6 series, 24,746 calls) but it
either skips one trade or flips one SELL to a BUY: **43/43 → 43/44**. At 86
trades that is noise. So EQH/EQL stays **display-only** and the code says so.
Shipping it as a filter would have been a number this project could not defend.

### Mirror added

`/home/user/smt-verify/mirror.py` — Python mirror of `multiTF`, `analyze` and
`Backtester.walk`, with `swings()` verified against the naive form (40 random
series, exact match) and sped up from 29 s to 4 s per walk. `measure.py` /
`measure4.py` / `measure5.py` are the drivers. No exchange access here (only
GitHub hosts are reachable), so all of it is synthetic — it proves a change is
not broken, not that it is profitable. That caveat applies to every number above.


---

## 11. v7 · tp1.05 — fixed 1.05% target (2026-11-08)

**Asked:** "Backtest korar sumy ... real market takhe data niba ... just t.p rakhba 1.05% ...
onuck gula candle er data use korba jeno ami proti tah test er e valo akta result pai".
Chosen: **TP fixed 1.05%, SL unchanged**, and show **win rate and total R both**.

### What changed

| change | value |
|---|---|
| take profit | fixed `kTpPct = 1.05%` from entry (was 15M swing / 2R) |
| stop | **unchanged** — OB/FVG/swing + 0.25 x ATR(1H) |
| new guard | a trade whose stop is **closer than the target** is rejected (it can only lose) |
| backtest history | 15M 4000 → **12000 bars (~125 days)**, 4H 1500, 1H 3000 |
| maxTrades | 200 → 2000 (a deeper sample is pointless if it is truncated) |
| report | win rate **and** total R side by side, plus R:R, break-even win rate, and the result after 0.25% fees+spread |

### Measured BEFORE shipping (`tool/mirror/measure_tp.py`, synthetic, paired, identical candles)

12 series x 4 regimes, walk-forward:

| target | trades | WR | totalR |
|---|---|---|---|
| 15M swing / 2R (old) | 241 | 38.9% | **+13.4** |
| **fixed 1.05%** | 643 | **75.6%** | **−8.4** |
| fixed 0.50% | 989 | 85.7% | −9.2 |
| fixed 2.00% | 416 | 66.4% | +0.1 |

**The win rate goes up and the money goes down.** A fixed target does not change
the stop, so the reward:risk is decided by the stop distance:

| ATR(1H) | risk | R:R at 1.05% TP | break-even WR |
|---|---|---|---|
| 0.45% | 0.54% | 1.94 | 34.0% |
| 0.90% | 1.08% | 0.97 | 50.7% |
| 1.80% | 2.16% | **0.49** | **67.3%** |
| 3.00% | 3.60% | 0.29 | 77.4% |

On a coin with ATR(1H) ≈ 1.8% the trade needs a 67.3% win rate just to break
even, and with 0.25% fees it needs even more. The screen therefore prints the
break-even rate next to the win rate; a 75% win rate at R:R 0.49 is a losing
system and the report says so in words.

Note the guard matters: without it, any trade whose stop was tighter than 1.05%
is a certain loss that still shows up as a trade. It is now rejected before it
is reported.

### Real market data

The backtest already pulls **live** Binance klines (paged, 1000 rows per
request) — there is no synthetic data in the app path. It cannot be measured
from this sandbox (only GitHub hosts are reachable, and Binance answers 451 from
this IP range), so every number above is from the synthetic mirror. The device
run is the missing piece, as always.


---

## 12. v8 · swingTP — the fixed 1.05% target was removed again (2026-11-08)

**Asked:** "Tp er bisoy jta eakhon add korlam ota bad dayo" — remove the fixed
1.05% take profit that v7 introduced.

**Done:** target is back to `15M swing high/low when beyond entry, else 2R`.
Removed with it: the "stop closer than target" reject and the `invertedTrades`
counter that existed only to describe the fixed-target artefact.

**Kept,** because they are improvements on their own and none of them changes the
engine:

- 12000 bars of 15M history (~125 days), 4H 1500, 1H 3000, `maxTrades` 2000
- the report's win rate + total R + R:R + break-even win rate + 0.25% cost line
- `tool/mirror/` (mirror, self-tests, measurement scripts) committed to the repo

**The measurement that justifies the revert** is NOTES §11: the same engine on
the same candles went from **38.9% WR / +13.4R** (swing target) to
**75.6% WR / −8.4R** (fixed 1.05%). The revert is not a preference, it is that
table.

Build `v8 · swingTP` / `8.0.0+8`.


---

## 13. v9 · diag — the screenshot that exposed two real bugs (2026-11-09)

**Device evidence (v5 · 300 build):** `35 / 35` coins scanned, and near-miss
cards reading `score 55/40` with no signal. Both were real.

### Bug A — OKX quote volume (the reason a 300-coin scan said 35)

Every feed's tickers go through `_isTradable`, which requires
`quoteVolume > 5,000,000` **USDT**. Binance, Bybit and MEXC all report quote
volume. **OKX reports `volCcy24h` in BASE units** (BTC, not USDT) — and when
Binance is geo-blocked the app falls back to OKX. So 1000 BTC *price* is
~100M USDT but 1000 XRP *price* is ~2,000 USDT, and the filter removed almost
every pair. Fixed: `volCcy24h * price`, or `vol24h` when present.

This had been wrong since the fallback chain was written; it only became visible
once the universe grew and the number on screen could be compared with 300.

### Bug B — a passing score with no explanation

`multiTF` has four gates: score >= threshold, 4H bias, live 15M trigger, and
`!bullBlocked/!bearBlocked` (the structure floor added for bug #3). The near-miss
trace printed the score and the zone penalty but **never mentioned the floor**,
so a card could say `score 55/40` and show no signal — indistinguishable from a
bug. Measured on synthetic data: the floor silently kills **39% (174/449)** of
setups whose score already passed (SELL side; the BUY side does not reach the
gate in that generator's regimes). The trace now names the gate:

- `gate: 15M trigger nai`
- `gate: upore bearish 1H OB block korche`
- `gate: niche bullish 1H OB block korche`
- `gate: dui dikei score soman/kom`

The floor **stays**: it is the fix for "every signal was a SELL". The user chose
to measure on the device before loosening it, which is the right order.

### Bug C (visibility) — a small universe was silent

The status line now shows `raw tickers -> tradable -> picked` while scanning and
warns `Sotorkota: matro N coin — <feed> puro list dey nai` below 120 coins. A
quiet market and a broken feed must not look the same.

## 14. v10 — the RR gate, and a stop cap that the data rejected

Three defects showed up on the v9 device screenshot (2026-11-09 01:05), plus two
carried over from the 00:55 shot.

### Bug A — a SELL that risked 4.5% to make 0.5% (RR 1:0.11)

The 15M swing was accepted as a target whenever it sat **beyond entry**, with no
minimum size:

```dart
t15.swingLow != null && t15.swingLow!.price < entry * 0.995   // v9
    ? t15.swingLow!.price : entry - risk * 2;
```

That is a 0.5% test, not a quality test. Live:

| symbol | entry | SL | TP | risk | reward | RR |
|---|---|---|---|---|---|---|
| SOL (00:55) | 89.6100 | 92.7443 | 88.7300 | 3.50% | 0.98% | **1:0.28** |
| ETH (01:05) | 2234.45 | 2335.94 | 2223.15 | 4.54% | 0.51% | **1:0.11** |

Breakeven win rate for the ETH trade is ~90% before costs. Fixed with
`kMinRR = 1.5`: the swing is used only if it is worth at least 1.5R, otherwise
the target falls back to 2R.

### The stop cap I proposed was wrong, and the measurement said so

The first fix paired `kMinRR` with `kMaxStopPct = 2.5` on the reasoning that a
15M trigger should not carry a 4.5% stop. Measured, 12 seeds x 4 regimes,
closed trades only, `cost_r = 0.25 / stop_pct`:

| bucket (v9 rule) | n | WR | gross | net |
|---|---|---|---|---|
| stop <= 2.5% | 71 | 26.8% | −5.4R | **−18.4R** |
| stop 2.5 – 8% | 150 | 44.7% | +18.8R | **+9.8R** |

The narrow-stop bucket is the losing one; the cap would have deleted the only
net-positive bucket. Wider stops win because they are further from noise and
because the fixed 0.25% fee is a smaller fraction of R. **The cap was reverted**
— `0.08` is back in all three places.

### What v10 actually changes, measured

`tool/mirror/measure_v10_final.py`, old target rule vs `kMinRR = 1.5`, identical
candles, 0.25% cost:

| rule | n (closed) | WR | gross | net | minRR shipped |
|---|---|---|---|---|---|
| v9 (swing if beyond entry) | 208 | 35.1% | +7.2R | −13.7R | 0.52 |
| v10 (`swing if >= 1.5R`) | 196 | 32.1% | +8.0R | −12.0R | 1.51 |

v10 refuses 33 of 208 (16%) of the trades v9 would ship, and loses slightly less.
Both are negative net of cost and every 95% CI straddles zero, so this is
**not** a profitability claim — it is the removal of trades whose own arithmetic
demanded a 78–90% win rate. The honest statement is: *no trade can now be
shipped that needs an unrealistic hit rate to break even.*

### Bug B — every card said `BOS 대 Unknown`

`zoneOf` returns `'Unknown'` when `premium == 0`, and `premium` was set only
when **both** a confirmed swing high and a confirmed swing low existed. On a
short 1H window (or when one pivot is missing) the range collapses to zero and
the label degrades. Every card in both screenshots showed it.

Fix: when no swing pair exists but the window has >= 20 bars, fall back to the
window's own high/low for premium/equilibrium/discount. A range always exists;
"Unknown" now means what it says.

### Bug C — `4H cache 0/0+36`, every scan a full refetch

The cache stores `fresh.length - 1` bars (closed only, the forming bar is
rebuilt from 15M). The hit test then demanded `merged.length >= lim`, i.e. the
cache had to return the same count as the exchange while structurally holding
one bar fewer. It could never pass. Every scan refetched 36 x 600 4H bars.

Fix: a hit is `merged.length >= lim - 1`. The engine's window is 400 bars; one
bar short of a 600-bar request is not a shortfall.

### Still open — why 36 coins and not 300

v5 showed 35, v9 showed 38, v10 shows 36. Three runs, three days, always ~36,
never near the 300 that `_pick(gainers: 150, losers: 150)` allows. The scan
status line proves the funnel only while scanning; the Done state did not.

v10 adds the funnel to the Done state:
`raw ticker → tradable → picked`. Until that number comes back from the device,
the cause is **not known** — a short ticker list and our own 5M USDT floor look
identical from here.

### Where the 300 coins actually go

`_total` on screen is `coins.length`, i.e. the output of
`_pick(all, gainers: 150, losers: 150)`, which is capped at **300 by design**
(150 best gainers + 150 worst losers, deduped). So the ceiling is
`min(tradable, 300)` and the funnel is:

```
/ticker/24hr  ~2800 rows
  -> _isTradable   symbol endsWith USDT, not stablecoin/leveraged, lastPrice > 0,
                   quoteVolume > 5,000,000 USDT        <- the only hard floor
  -> _pick(150,150)                                   <- capped at 300
  -> analysis loop (all coins, no further cap)
```

Seeing ~36 means the pool **entering** `_pick` was already ~36. `_pick` could
not have caused it: with a healthy list it returns 150–300 depending on the
market, never a flat 36 on three different days.

Time is not the limit either. 300 coins = 900 klines requests; at 4–6 workers
that is 68–202 s cold, 45–135 s on a warm 4H cache (after the v10 hit-test
fix), inside the 5-minute refresh slot.

The likely cause is the same class of bug as the v9 OKX one — a volume field
that is not what the floor assumes — but on the Binance path the field goes
straight through `double.parse(j['quoteVolume'])`, so it cannot silently
degrade to zero; it would throw and fall through to the next mirror. That makes
"the feed returned a short list" the leading suspicion, which the funnel line
now settles on the device in one run:

- `raw` low, `tradable` low → the exchange sent a truncated list
- `raw` high, `tradable` low → our 5M floor is eating it
- `tradable` high, `picked` low → `_pick` is the limit

`resetFunnel()` now clears all three counters at the start of every scan and
`lastFunnelFeed` records which exchange the numbers belong to, so a failed
Binance attempt can no longer leave its raw count next to an OKX coin list.

## 15. v11 — actually analysing 300 coins

The v10 diagnosis said "~36 coins arrive, cause unknown, read the funnel". The
user asked for 300 directly, so the cause had to be found and removed. It was
two separate defects, either of which alone was fatal.

### Defect 1 — the 5M USDT floor was applied inside the feed parsers

`_isTradable` was called from all four ticker parsers, so a 300-coin scan never
had 300 candidates to choose from. Every pair under $5M/day was gone before
`_pick` ran. That is why three device runs showed 35 / 38 / 36: the pool
entering `_pick` was already ~36.

The floor is a real requirement (a 15M setup on a $200k/day pair cannot be
filled at the shown price), so it was not simply deleted. It is now two tiers:

- **strong** — above 5M USDT/day, always preferred
- **quiet** — everything else that is genuinely listed, sorted by volume,
  used only to reach the 300 target

`selectUniverse(all, target)` does the split; `_isListed()` only checks shape
(USDT, not a stablecoin, not a leveraged token, positive price). Verified
against a Binance-shaped snapshot: 455 listed → 165 strong → 300 selected.

`_pick` was also silently returning 292 of 300 when the green side ran short of
150 coins. It now fills the shortfall from the remaining movers by absolute
move, so the target is honoured, and honestly reports 80 when the exchange only
lists 80.

### Defect 2 — 300 coins could not have been fetched anyway

Binance bills klines by `limit`, not by bars used:

| limit | weight |
|---|---|
| ≤100 | 1 |
| ≤500 | **2** |
| ≤1000 | **5** |

The scan asked for 600 bars on all three timeframes = **15 weight per coin**,
4500 for 300 coins, against a 1200/min public budget — **3.2× over**. A scan
fast enough to finish in 70 s would ask for 3857/min. The requests that get
rate-limited are the coins, so a "300 coin scan" degrades into a small one.

Two changes:

1. **Ask for what the engine uses.** The engine windows are 400 (4H), 200 (1H),
   200 (15M), so the scan now requests 400/500/500 for weight 2+2+2 = 6 per
   coin, 1800 total, 1200 once the 4H cache is warm.
2. **Meter the requests instead of the workers.** `reserveWeight()` keeps a
   rolling one-minute window (budget 900/min, margin below 1200) and every
   Binance klines call takes a slot first. Extra workers now add concurrency
   only, never request rate — before this, *more* workers made rate-limiting
   worse.

### Also fixed in the same pass

- `_cache4hMax` was 320 while the scan now needs 400 bars per coin. On a
  300-coin scan the cache evicted the coldest series every time, so hits were
  impossible even after the `>= lim - 1` fix. Raised to 400, and the hit path
  was re-verified for 399+1, 599-downgraded, and no-tail cases.
- The funnel line is now always shown:
  `feed raw ticker → listed (strong) → analysed`. A shortfall can no longer be
  silent, and the three tiers are distinguishable at a glance.

**No engine rule changed.** Windows, scoring, gates, targets and stops are
untouched — the scan simply receives 300 coins instead of 36, so the same rules
are applied to 8× more candidates.

## 16. v11.1 — "will 300 actually happen?" answered with numbers, not hope

v11 removed the two causes. The remaining question was whether a 300-coin scan
is actually *feasible* on a phone, so each layer was computed rather than
assumed.

### The universe really does fill to 300

`tool/mirror/test_universe.py` mirrors `_isListed` / `selectUniverse` / `_pick`
and asserts the properties on a Binance-shaped snapshot:

```
455 listed -> 165 strong -> 300 selected -> 300 picked
v10 behaviour on the same snapshot:         165 analysed
```

Also asserted: a quiet day (no pair above 5M) still reaches 300; an exchange
listing only 80 pairs reports 80 (an honest shortfall, never invented coins);
leveraged tokens and stablecoins never appear.

Exchange capacity, from their published pair counts:

| feed | USDT pairs | 300 reachable |
|---|---|---|
| Binance | ~450–500 | yes |
| Bybit spot | ~350 | yes |
| MEXC | ~1500 | yes |
| OKX | ~250–300 | marginal (reports ~250–280) |

### The rate limit I had assumed was wrong

v11 metered at 900/min on the belief that the Binance budget is 1200/min. It is
not: the spot per-IP limit was **raised from 1200 to 6000 weight/min on
2023-08-25**, and 1200 now applies to order endpoints, not market data. At
900/min a cold 300-coin scan was paced to ~120 s for no reason.

Raised to 4500/min — a real margin under 6000 for the ticker call, retries and
mirrors:

| cache | weight | metered floor | HTTP work (6 workers) | scan |
|---|---|---|---|---|
| cold | 1800 | 24 s | 68 s | **~68 s** |
| warm | 1200 | 16 s | 45 s | **~45 s** |

The 4H cache is what turns 68 s into 45 s, which is why the `_cache4hMax`
eviction bug mattered.

### Young listings no longer vanish from the count

The worker skipped any coin with fewer than 120 closed 4H bars (`_tooYoung`).
The wide universe reaches into exactly those young listings, so a 300-coin scan
could still analyse fewer. The engine needs 60 bars to form a swing at all, so:

- **< 60 bars** — skipped, counted as `_tooYoung` (honest: no structure exists)
- **60–119 bars** — analysed on the shorter window, counted as `_short4h`

`_short4h` is printed rather than hidden, because a weaker 4H read is a fact the
user should see, not a silent degradation.

### The status line now states all four numbers

```
feed raw ticker -> listed (strong) -> picked -> analysed (short 4H)
```

`analysed = picked - tooYoung - failed`. "300 picked" and "300 analysed" can no
longer be confused, and any shortfall has a name.

## 17. v12 — the first real 300-coin scan, and what it exposed

The v11.1 device scan worked: **300 / 300 analysed, 13 signal · 33 watch ·
1 radar** (v9 produced one signal from 36 coins). The status line read:

```
Binance 3745 ticker → 300 listed (36 strong) → 300 picked → 300 analysed
4H cache 0/0+300 (295)
```

Four defects were visible in that one line plus the GAL card.

### A (P0) — signals could be computed on another exchange's candles

`_fetchCandles` walked `_feedOrder()` = `[activeFeed, ...rest]`. A pair the
primary feed could not serve was silently answered by the next venue. The card
still said `(Binance)`, and the candles could be a different market entirely.
The user's own Binance screenshot (GALA at 0.00153) against the app's GAL card
(2.5420) is exactly how differently two venues can label the same ticker.

Fixed: `candles(..., scan: true)` marks scan requests, and `_fetchCandles`
then refuses any feed other than `activeFeed`. A pair the scan feed cannot
serve is dropped and counted as failed — never answered by another exchange.
The backtest and deep history keep the old multi-feed behaviour, because there
the user has asked for one specific chart.

### B — "300 listed" was a lie the funnel told every time

`lastTradable = universe.length` *after* the 300 cap, so that field could never
print anything but 300. The pool is now measured before the cap:
`lastListed` and `lastStrongPool`. Only `lastListed` answers the real question
("did the exchange send 450 pairs or 80?").

### C — 36 strong is far too few, and the cause is not yet known

On Binance, roughly 150–200 USDT pairs clear 5M/day. The scan found 36. Either
`quoteVolume` is arriving small for most rows, or the 300-cap discards strong
pairs before they are counted (it does: `selectUniverse` returns strong-first,
so strong should dominate — getting only 36 means the strong pool really is
~36). The new pre-cap `lastStrongPool` number settles this on the next scan.

### D — the 4H cache is still `0/0+300`

Everything is written (295 cached) and nothing is ever hit. `_cache4hFresh`
is the only gate between write and reuse, so the expiry horizon must be
comparing against a stale `openTime`. Not fixed yet — needs the hit/miss split
after the next scan, which the status line already prints.

### E — a thin book produced a STRICT trade

The GAL card: entry 2.5420, SL 2.4509 (**−3.58%**), TP 2.7241 (+7.16%),
R:R 1:2.00, **75% confidence, STRICT**, five confirmations. The arithmetic is
fine. The subject is not: GALUSDT sits in the quiet tier, below 5M USDT/day,
which is precisely the class of pair the old 5M floor existed to keep out of
the trade list — and the wide universe is what pulled it back in.

A 3.58% stop on a thin book can be jumped; entry and exit both slip. The fix
is not to restore the hard floor (that returns the universe to 36). It is to
stop the quiet tier from masquerading as liquid:

- `TradeSignal.thinVolume` records the tier
- `asThin()` demotes STRICT → WATCH and never downgrades RADAR
- the card prints `Thin book (<5M USDT/day) — entry/SL e slippage hote pare`

The engine itself is untouched: it still scores the setup the same way. What
changes is the label the user acts on.

## 18. v12.1 — GAL: the app was scanning a delisted pair

The user caught this, not me: **GAL is not on Binance spot.** Searching "GAL" in
the Binance app returns **GALA** at 0.00153. The scanner's GAL card showed
2.5420 — Galxe, a different token on a different venue, and its BinanceUSDT pair
was delisted from spot.

The app could reach it three ways, and all three were open:

### 1. `/ticker/24hr` is not a list of live markets

Binance keeps returning rows for symbols it no longer trades, and for delisted
pairs the row carries the last snapshot. `_isListed` only checked the *shape* of
the symbol (ends in USDT, positive price), so a dead pair looked identical to a
live one. There was no `status` check anywhere in the app.

Fixed with the authority Binance publishes for exactly this:
`/exchangeInfo` → symbol is live only when `status == 'TRADING'`,
`quoteAsset == 'USDT'`, `isSpotTradingAllowed != false`. Cached per process
(weight 20, one call). On failure it returns an empty set, which makes the
filter a no-op — the scan still runs.

### 2. Nothing checked how old the candles were

This is the deeper bug. A delisted symbol still answers `/klines` **with its
old history**, and the engine has no notion of "now": 400 bars of 4H and 500 of
15M from a year ago score exactly like today's. `isLive()` now requires the
newest bar to end within 6 hours (10 for 4H, which legitimately misses the
forming bar). A coin that fails is counted as `_delisted` and skipped.

### 3. v11.1 would have priced it on another exchange anyway

Even with a Binance ticker row, Binance could not serve the candles, so
`_feedOrder()` fell through to OKX/Bybit/MEXC — where a GALUSDT market may still
exist at 2.54 — while the card said `(Binance)`. The v12 `scan: true` lock
closes this, and it is why the GAL card was internally consistent: the entry,
stop and target all came from one coherent series, just not Binance's.

### On screen

```
Binance 3745 ticker (N delisted) → N listed (N strong) → N picked → N analysed (N stale data)
```

`delisted` is rows the exchange sent for symbols it no longer trades; `stale
data` is coins dropped because their candles ended hours ago. Both are printed
because a silent filter is how this went unnoticed for ten versions.

## 19. v13 — order-block mitigation: LUX's High/Low, because CLOSE put stops
## behind structure price had already broken

The LuxAlgo script defaults `orderBlockMitigationInput` to **High/Low**. The app
had shipped the CLOSE variant since the first port. That is not a cosmetic
difference: under CLOSE a block stays "active" until a candle *closes* beyond
it, so after price has already wicked through the zone the block is still
offered as a place to lean — and the stop goes behind a level that is no longer
intact.

Measured over identical synthetic candles (12 seeds × 4 regimes, closed trades
only, 0.25% round-trip cost):

| mitigation | n | WR | gross | net | avgNet |
|---|---|---|---|---|---|
| close (shipped until v12.1) | 196 | 32.1% | +8.0R | −12.0R | −0.061 |
| **highlow (v13)** | 193 | **33.7%** | **+17.0R** | **−2.8R** | **−0.014** |

Signal count barely moved (−1.5%), so this is not "fewer trades" — it is the
same trades taken against blocks that still exist.

### Per regime, to check it is not one lucky bucket

| regime | close net | highlow net | delta |
|---|---|---|---|
| trend | −0.1R | **+4.5R** | +4.6R |
| range | −4.5R | −1.2R | +3.3R |
| mixed | −2.8R | −1.5R | +1.3R |
| volatile | −4.6R | −4.6R | **±0.0** |

3 of 4 improved, 1 unchanged, 0 worse. The gain is concentrated in trending
conditions, which is the case the rule change predicts (in a trend the surviving
blocks are the meaningful ones). Volatile conditions are unaffected — mitigation
style does not matter when price is whipping through everything anyway.

**Honesty about strength:** the 4-regime mean delta is +2.30R with a 95% CI of
[−0.55, +5.15]. The direction is consistent, the magnitude is not established.
What distinguishes this from the v7 fixed-TP mistake is the signature: there the
win rate rose while total R *fell*. Here gross R, net R **and** win rate all
move the same way, and no regime regresses.

### What was deliberately NOT added

The same audit found six LUX features the app lacks — `drawLevels` (MTF
highs/lows), `displayStructure` (candle colouring), `drawLabel` (HH/HL/LH/LL),
`drawHighLowSwings`, `showSwingsInput`, and `alertcondition`. All six are
**visual**: they draw on a chart the app does not render, and none of them
touches a score, gate or price. They were left out.

Two other differences turned out not to be differences at all:

- **OB "two sets"** — LUX has `internalOrderBlocks` and `swingOrderBlocks`, but
  `showSwingOrderBlocksInput` defaults to **false**, so the chart shows only
  internal blocks. The app matches the default.
- **EQH/EQL threshold** (LUX `0.1 × ATR(200)` + 3-bar confirmation vs the app's
  `0.5 × ATR`) — `eqh`/`eql` are computed and displayed but never enter a score
  or a gate anywhere. Changing the threshold would alter a label, not a signal.

## 20. v14 — the universe target is 400, not 300

Binance lists roughly **400–500 USDT spot pairs**, of which ~150–200 clear
5M USDT/day. A 300-coin target was therefore always going to be mostly quiet
tier; 400 is the largest number that can be filled without descending deep into
pairs nobody trades.

`MarketData.scanTarget = 400` is now the single source of truth. It feeds the
scan call (`gainers: 200, losers: 200`), the `marketScan` defaults, the warning
threshold (half the target) and the 4H cache bound.

### Changed with it

| item | before | after | why |
|---|---|---|---|
| scan target | 300 | **400** | the request |
| `_cache4hMax` | 400 | **460** | a cache smaller than the universe can never hit |
| worker pool | ≤6 | **8** above 200 coins | HTTP-bound, not meter-bound |
| small-universe warning | <120 | **<200** | half the target, scales with it |

### Cost at 400 coins

Weight per coin is 6 cold (15m 500 = 2, 4h 400 = 2, 1h 500 = 2) and 4 warm
once the 4H cache is populated:

| workers | cache | HTTP work | meter floor | scan |
|---|---|---|---|---|
| 6 | cold | 90 s | 32 s | **90 s** |
| 6 | warm | 60 s | 21 s | **60 s** |
| 8 | cold | 68 s | 32 s | **68 s** |
| 8 | warm | 45 s | 21 s | **45 s** |

Every configuration is **HTTP-bound, not meter-bound** — the 4500/min budget is
never the limit at 400 coins, so raising the worker pool from 6 to 8 is safe and
does not risk a 429. A cold scan still finishes well inside the 5-minute
refresh slot.

### Verified

`tool/mirror/test_universe.py` is now parametrised over both targets and asserts,
on a Binance-shaped snapshot (455 listed, 165 strong):

```
target 300: 455 listed -> 165 strong -> 300 selected -> 300 picked
target 400: 455 listed -> 165 strong -> 400 selected -> 400 picked
```

plus: a quiet day still reaches the target, an 80-pair exchange honestly reports
80, and leveraged/stable tokens never appear — at **both** targets.

The engine is untouched. Windows, scores, gates, targets and stops are the same;
the scan simply hands it 400 candidates instead of 300.

## 21. v15 — what the v14 device screenshot got wrong

The v14 scan ran: `400 / 400`, `Binance 3745 ticker (3227 delisted) → 509
listed (71 strong) → 400 picked → 400 analysed (3 short)`, 4 signal · 43 watch
· 4 radar, tabs `ALL 51 / BUY 5 / SELL 46`.

Two of those numbers were wrong, one was a real trade-quality problem, and one
was correct.

### Wrong 1 — "3227 delisted" (fixed)

`lastDeadSymbols = data.length - live.length`. `data` is `/ticker/24hr`, which
returns every quote asset (~3745 rows: BNBBTC, ETHTRY, BTCEUR…). `live` is the
USDT-only set from `/exchangeInfo` (~518). Subtracting one from the other calls
every non-USDT pair "delisted" — 86% of the exchange, which no venue does.

Now the count only includes symbols that *look* tradable to us (USDT, not a
stablecoin, not leveraged) but are not marked TRADING. The real number should
be in the tens.

### Wrong 2 — every card is RR 1:2.00 exactly (diagnosed, revert kept)

All four STRICT cards: risk 3.24% / 4.90% / 5.35% / 5.81%, reward exactly 2x
each. That is the `kMinRR` fallback firing on 100% of signals, i.e. **the 15M
swing target has never qualified since v10**.

Cause: the stop comes from 1H structure (`sellOb.high + 0.25 ATR(1H)`) while the
target is a 15M swing. A 15M swing almost never sits 1.5x a 1H stop away, so the
gate always rejects it and the trade becomes a mechanical 2R with no structural
objective.

**The obvious fix was measured and rejected.** Letting the 15M swing act as the
stop when it is tighter (12 seeds × 4 regimes, 0.25% cost):

| variant | n | WR | gross | net | 2R-fallback |
|---|---|---|---|---|---|
| loose (shipped) | 193 | 33.7% | +17.0R | **−2.8R** | 70% |
| tight (proposed) | 201 | 32.3% | +15.9R | **−9.1R** | 67% |

Per regime: trend +2.9R, mixed −2.7R, range **−6.5R**, volatile 0.0R. It only
reduced the fallback rate by 3 points while making the stop tighter (worse
R-multiples) and net worse in two regimes. **Reverted.** The fallback rate is
*not* the problem; a tighter stop is simply a worse trade here.

### Wrong 3 — NVDAB is a tokenized stock, not crypto (fixed)

`NVDABUSDT` is a Binance bStock (an NVIDIA token listed Oct 2026). It is a real
spot USDT pair — exchangeInfo does not flag it, the delisted check passes, the
volume is real — but a tokenized equity gaps on the underlying market's hours
and a 5.8% structural stop on it is not comparable to one on SOL. It is now
excluded by an explicit symbol list (`_tokenizedStocks`), since matching a `B`
suffix would misfire on real tickers.

### Correct — BUY 5 / SELL 46 was not a bug

All four STRICT cards carry `4H bearish bias` on four unrelated symbols at once.
In a broad selloff a 46:5 skew is the market, not the engine. The structure
floor is symmetric (`bullBlocked` mirrors `bearBlocked`). The header numbers are
also consistent: `4 signal` counts STRICT only, while `ALL 51` = 4 STRICT + 43
watch + 4 radar.

### Still open

`509 listed → 400 picked` means ~109 pairs were dropped between the listed pool
and the universe, and only 71 of 509 cleared the 5M/day floor (down from 165 of
455 in v11.1). That drop is **not explained**. It may be a genuine 24h volume
collapse in the quiet tier, or the exchangeInfo filter interacting with the
ticker list. The next scan's funnel line settles it.

## 22. v16 — two cards that lied about their own confluence

The v14 DODO card: `WATCH (relaxed)`, **90% confidence**, RR 1:2.00, risk −4.77%,
with five confirmations — one of which read **`15M bullish break 999 bar age`**.

### Lie 1 — `999` is a sentinel that reached the screen

```dart
breakAge: lastBreak == null ? 999 : c.length - 1 - lastBreak.bar
if (t15.breakAge > 2) bC.add('15M bullish break ${t15.breakAge} bar age');
```

`999` meant "no break found", but `999 > 2` is true, so a signal that had **no
break at all** printed a confirmation claiming one, aged 999 bars. 999 × 15M is
10.4 days — outside the 200-bar window entirely. A fabricated confluence,
sitting alongside real ones, on a card the user is meant to trust.

Fixed: the sentinel is now **−1**, and a negative age prints
`15M break nai (age unknown)` instead of a fake number.

### Lie 2 — a WATCH card scoring higher than every STRICT card

STRICT needs 60, WATCH needs 40, and **both render the raw score as
"NN% confidence"**. On the device the relaxed DODO card showed **90%** while the
STRICT cards showed 70–75%. A less reliable setup displaying a bigger number is
worse than useless.

Fixed: a relaxed signal's displayed confidence is clamped to **59**, just under
the strict threshold. It can no longer claim more than the gate it actually
passed. (The engine still scores it identically; only the number the user acts
on is bounded.)

### Not a bug — why DODO had no break yet still fired

`trigBuy = triggerBull || (relaxed && internalBull)`. The relaxed pass accepts a
15M **internal** break, which is by design. The defect was never "it fired
without a break" — it was that the card **claimed** a break it did not have.

### Still open

`509 listed → 400 picked` with only **71 of 509 strong** (v11.1 had 165 of 455).
That drop remains unexplained and is the next thing to settle from a device
scan.

## 23. v17 — scalp mode, and the honest measurement of it

Requested: a mode that analyses 3/10/15/30 minutes, multiple timeframes,
following the existing rules.

### 10M does not exist

No major spot exchange publishes a 10-minute candle — Binance, Bybit and OKX
offer 3/15/30, and MEXC does not even offer 3M. Resampling ten 1M bars into a
10M bar is arithmetically fine but multiplies the request weight by ten, which
is not feasible at a 400-coin scan. The user chose **5M** as the substitute.

Final stack, confirmed with the user:

| mode | bias | zones | trigger |
|---|---|---|---|
| swing | 4H | 1H | 15M |
| **scalp** | **30M** | **15M** | **5M** |

### Nothing in the engine changed

`multiTF` and `radar` take a `TradeMode` and read three strings from it
(`biasTf`, `zoneTf`, `triggerTf`). Every weight, gate, stop rule, target rule and
confidence clamp is the same code, and the parameters keep their swing names
(`c4`, `c1`, `c15`) so the Python mirror stays readable. In scalp mode they
simply carry the 30M / 15M / 5M series.

The UI switch restarts the scan, because the candles and the cache are
per-timeframe.

### A real bug this exposed: the 4H cache was keyed by symbol only

`_cache4h[sym]`. Switching to scalp mode writes **30M** bars under the same
symbol, which would have poisoned every 4H entry (and been poisoned by them —
a 30M series served as a 4H series is silently wrong data, not an error). The
key is now `'$tf|$sym'`.

### The measurement the user should read before using it

Identical price paths, identical rules, 12 seeds × 4 regimes, closed trades,
0.25% round trip:

| mode | n | WR | gross | net | avgStop | cost/trade |
|---|---|---|---|---|---|---|
| swing | 193 | 33.7% | +17.0R | −2.8R | 3.54% | 0.103R |
| **scalp** | **2496** | **31.7%** | **+116.6R** | **−200.6R** | 3.72% | **0.127R** |

Per regime, scalp is negative in **all four**: mixed −92.7R, trend −35.3R,
range −23.2R, volatile −49.4R.

Read the two lines together:

```
gross per trade  +0.047R      <- there IS a real edge
cost  per trade  -0.127R      <- but the fee is 2.7x the edge
net   per trade  -0.080R      <- every trade loses on average
```

Scalping does not fail because the signals are bad. It fails because a 5M/30M
trade holds for minutes, so the round-trip fee is a much larger fraction of R
than on a swing trade. Break-even on this sample needs roughly **0.045%** round
trip (VIP8–9), not the 0.25% the app models or the 0.20% VIP0 taker rate.

**Scalp mode is shipped and labelled, but it is not profitable at retail fees.**
This is the same shape as the v7 fixed-TP lesson: a feature that looks like more
opportunity is a worse trade once costs are counted.

Released as tag `v17.0.0` (commit `be559bd`, CI run `42686518272` success, release run `42687019960` success). Asset `smart-money-trader-v17-scalp-17.0.0-20.apk`, 20.6 MB. Release notes carry the negative measurement table so the warning travels with the download.

## 24. v17.1 — two swing labels were still hard-coded

Device screenshot (INIT, scalp mode, 75% STRICT) exposed it. The confirmations
were correct — `30M bullish bias`, `15M bullish FVG`, `5M bullish BOS`,
`15M breakout`, `5M bullish break 21 bar age` — but two other places on the
same screen still printed the swing timeframe names:

| spot | was | now |
|---|---|---|
| summary bar timeframe badges | `4H` `1H` `15M` (`const`) | `_mode.biasTf/zoneTf/triggerTf` |
| detail sheet structure rows | `4H structure` / `1H structure` / `15M structure` | `s.mode.*` |

The engine was never wrong: `multiTF` was already fed the 30M/15M/5M series and
`TradeSignal.mode` was already carried on the signal. Only the labels lied, so a
scalp signal read like a swing signal on the same screen. Same class of bug as
the v16 `999 bar age` sentinel — the label a user reads must come from the same
object that produced the decision.

Also fixed: `tool/mirror/mirror.py` still used `breakAge = 999` for "no break"
(Dart was changed to `-1` in v16). Nothing scored on it, so no measured number
changes, but the two sides must agree.

Verification: tree-sitter parse 0 errors, `test_mirror.py` PASS,
`test_universe.py` PASS.

### What "21 bar age" actually means

`breakAge = c.length - 1 - lastBreak.bar` — closed bars of the **trigger**
timeframe since the break, counting the most recent closed bar as 0. On a 5M
trigger, `21 bar age` = 21 × 5 = **105 minutes ≈ 1h 45m** since the 5M close
that broke the pivot.

The break still counts as a trigger because
`triggerBull = breakEvent == 'BULLISH' && px > breakLevel`: the test is price
*holding* beyond the broken pivot, not recency. `freshBreak` (≤2 bars) is
computed but never read, so age is display-only. The only real freshness gate is
on the relaxed WATCH pass (`internalFresh`, ≤4 bars of the len-5 internal
series). That is deliberate — it is the LUX behaviour where a BOS line stays
valid for a run of bars, not one candle.

## 25. v17.2 — the APK filename lied about its own version

`v17.1.0` shipped as `smart-money-trader-v17.1-scalp-labels-17.0.0-20.apk`.
The stamp said v17.1, the version tail said `17.0.0-20`. Both came from
`lib/main.dart` — two hand-kept constants describing the same build:

| constant | used by | v17.1.0 value |
|---|---|---|
| `kBuild` | APK filename prefix, on-screen status | `v17.1 · scalp labels` ✔ |
| `kVersionName` | **APK filename tail only** | `17.0.0+20` ✘ stale |
| `version:` in `pubspec.yaml` | Gradle `versionName` / Settings | `17.1.0+21` ✔ |

Nothing in the repo read `kVersionName`, so bumping `pubspec.yaml` — which is
what Gradle actually uses — left the filename behind. A user comparing the
downloaded filename to Settings → App info would see two different versions.

Fix: the release workflow now derives the tail from `pubspec.yaml` (the single
source of truth), and `tool/mirror/test_stamps.py` fails if `kVersionName`
drifts from it or if the workflow goes back to reading the Dart constant.
The test is wired into **both** workflows before the Flutter build, so a stale
stamp costs 20 seconds instead of a wasted 3-minute APK build.

Proved the guard on the real failure: restoring `kVersionName = '17.0.0+20'`
makes `test_stamps.py` exit 1 with
`kVersionName is '17.0.0+20' but pubspec version is '17.1.0+21'`.

This is the third bug of the same family — v16 `999 bar age`, v17.1 swing labels
on a scalp screen, v17.2 version on the filename. The pattern: **a fact copied
into a second place with no test tying the two together.** Where it can be
computed from one source, it should be.

Released as tag `v17.2.0` (commit `ea35841`, CI `42696311324` success, release
run `42696835170` success). Asset
`smart-money-trader-v17.2-honest-filename-17.2.0-22.apk`, 20.6 MB — stamp and
version tail finally agree. `v17.1.0` stays published with a "superseded by
v17.2.0" note rather than being deleted: deleting a release someone may already
have downloaded hides the mistake instead of documenting it.

## 26. Fresh-BOS trigger — requested, measured, and it loses

The ask: "when 5M gives a BOS, confirm me right then" — i.e. stop accepting a
break that price is merely still sitting beyond (`5M bullish break 21 bar age`
= 105 minutes old on the device).

This is a pure *filter*: it only removes signals, never adds or rescales one.
So it could be measured exactly, with no engine rewrite. `mirror.multi_tf` /
`mirror.walk` gained `fresh_only` / `fresh_bars`; every other weight, gate,
stop and target is untouched.

Scalp horizons (30M/15M/5M), 8 seeds × 4 regimes, 0.25% round trip, closed
trades only:

| variant | n | WR | gross | net | R/trade |
|---|---|---|---|---|---|
| **holding** (shipped) | 1710 | 33.2% | +166.9 | **−53.0** | **+0.098** |
| fresh0 (break on last closed bar only) | 1487 | 32.0% | +112.3 | −77.4 | +0.076 |
| fresh1 (≤1 bar) | 1495 | 32.2% | +118.4 | −72.1 | +0.079 |
| fresh2 (≤2 bars) | 1495 | 32.2% | +118.4 | −72.1 | +0.079 |

Per regime (net R):

| regime | holding | fresh0 |
|---|---|---|
| mixed | −56.0 | −56.4 |
| trend | −7.3 | **+3.3** |
| range | **+14.8** | −10.2 |
| volatile | −4.6 | −14.1 |

**Reading it honestly.** Requiring freshness costs **−24.4R** over the sample
(−223 trades). It is not just fewer trades — it is a worse trade: gross
R/trade falls from +0.098 to +0.076, so the trades it removes are *better than
average*. The likely reason is mechanical: entering on the break bar puts the
entry right at the pivot with no evidence price holds beyond it, whereas the
shipped rule waits for that evidence. `fresh1` and `fresh2` are identical to
`fresh0` in practice, so widening the window by a bar changes nothing — this is
not a threshold-tuning problem.

It is not uniformly worse: in the **trend** regime fresh is the only variant
that is positive (+3.3R vs −7.3R), and in **range** it is much worse
(−10.2R vs +14.8R). A regime-conditional version is plausible but is a new
rule, and nothing here measures it.

Not shipped to the app. `tk` measurement only.

## 27. v17.3 — the scan was full of shares, and missing Jupiter

A device screenshot (scalp, 400/400, 17 signal · 130 watch · 1 radar) showed
everything mode-correct — `Scalp 30M/15M/5M`, `30M bullish bias`,
`15M bullish FVG`, `5M bullish BOS`. The bugs were underneath.

### Bug 1 — AAPLB: a tokenized Apple share, ranked as a coin (fixed)

The top card was `AAPLB · 352.7500 · BUY 75% · WATCH` with a 5% stop and a
1.58% target. 352.75 is a **share price**, and AAPLB is Binance's bStock for
Apple. It cleared every filter: it is a genuine spot USDT pair, exchangeInfo
marks it TRADING, volume is real (about $6M/day), and the delisted check passes.

`_tokenizedStocks` existed for exactly this — it knew **5** tickers
(NVDAB, MDBB, PENGB, UVXYB, BBB). Binance has listed **20**. Missing:
AAPLB, AMATB, AMZNB, BEB, CRCLB, DELLB, FLNCB, GSB, MUB, PYPLB, SMHB, SNDKB,
SOXSB, SPCXB, TSLAB.

This is not cosmetic. A tokenized equity trades 24/7 while the underlying share
is closed, so it gaps at the open; a structural 5% stop computed from crypto
candle mechanics is not the same instrument as one on SOL. Worse, the whole
`quoteVolume > 5M` tier ranking treats it as comparable liquidity.

Fixed by extending the explicit list to all 20 known bStocks and adding a test
that fails if a tokenized symbol can ever reach the universe. The test also
asserts the list does not over-match: `ARB`, `BNB`, `WB`, `JUP` must survive.

### Bug 2 — `JUPUSDT` was silently excluded from every scan (fixed)

Writing that test found this: the leveraged-token rule was a bare suffix match,
and **Jupiter's `JUPUSDT` ends in `UPUSDT`**, so a real, liquid pair was being
dropped from every universe since v11.

A leveraged token is a *wrapper*: `BTCUP` wraps `BTC`, `ETHBULL` wraps `ETH`.
So the rule is now "ends with a wrapper suffix **and** the stripped base is
itself a listed pair". `JUP` strips to `J`, and `JUSDT` is not listed, so it is
kept. When the live symbol set is unavailable (exchangeInfo failed) the old
conservative rule is kept, so a network failure cannot flood the list with
wrappers.

### Bug 3 — the 30M bias cache never hit (fixed)

`candles()` only took the cache branch for `tf == '4h'`, and every horizon
inside it was the constant `_ms4h`. In scalp mode the bias series is **30M**, so
the branch was never entered: every scan refetched 400 coins × 400 30M bars, and
the cache was dead in the slowest mode. The cache is now keyed by timeframe and
uses that timeframe's own bar span (`_isCacheable` covers 4h and 30m), so the
forming bar is still rebuilt from the fresh 5M tail and nothing served is stale.

### Bug 4 — WATCH cards wearing 70–75% (fixed)

Four visible cards read `WATCH` at 75%, 70%, 70%, 70% while the STRICT gate is
**60**. Cause: `asThin()` (thin book → demote STRICT to WATCH) copied
`confidence` unchanged. v16 clamped the *relaxed* path to 59 for exactly this
reason; the thin path was missed. Same lie as the `999 bar age`: a number that
claims more than the decision behind it. Confidence is now clamped to 59
wherever a signal is demoted.

### Also fixed — labels that lied in scalp mode

The footer cache note said `4H cache` in every mode, the empty-state text said
`4H trend nei` / `15M trigger`, and the trace said `gate: 15M trigger nai` /
`bearish 1H OB`. All now read from `_mode`.

### Not a bug — the funnel

`3745 ticker (175 delisted) → 518 listed (67 strong) → 400 picked → 400 analysed`
is consistent: 518 − 400 = 118 pairs simply did not make the 400 cap, and 333 of
the 400 came from the quiet tier because only 67 cleared the 5M/day floor. The
`(67 strong)` figure is the **raw** pool before shape filtering, so it counts
rows that are not tradable pairs — that number is the next thing to fix, not the
dropped 118.

Verification: tree-sitter 0 errors, `test_stamps` PASS, `test_mirror` PASS,
`test_universe` PASS (6 assertions incl. 2 new).

Released as tag `v17.3.0` (commit `c55d4e5`, CI `42829814562` success, release
run `42830326423` success). Asset
`smart-money-trader-v17.3-clean-universe-17.3.0-23.apk`, 20.6 MB, download link
returns 302.

## 28. v17.4 — MSTRB, and the stop that was smaller than the fee

Second device screenshot after v17.3. The fixes that shipped worked: footer
read `30M cache`, badges read `30M / 15M / 5M`, cards were STRICT at 90% with no
thin-book banner. Two things were still wrong.

### Bug 1 — MSTRB: the bStock list went stale again, in one release

Top-4 cards included **`MSTRB · 123.0300 · SELL 90% STRICT`**. MSTRB is
Binance's bStock for Strategy (MicroStrategy). The v17.3 list knew 20 tickers;
Binance has **44**. Still leaking: ALABB, AMDB, ASMLB, ASTSB, BMNRB, COHRB,
COINB, CRDOB, EWYB, GOOGLB, HOODB, IBMB, INTCB, IRENB, LITEB, METAB, MSFTB,
MSTRB, NFLXB, NOKIAB, PLTRB, QQQB, SMCIB, USARB.

This has now been wrong **twice in two releases**, which is the real lesson: an
explicit snapshot list cannot keep up with a product Binance extends in batches
every week or two. The list is now complete at 44 (sourced from the bStocks
launch announcements June–October 2026), and `test_universe.py` asserts the
whole set, so the next batch fails a test instead of appearing on a screenshot.

A suffix rule (`ends with B`) was considered and rejected: it would swallow real
tickers. `test_universe.py` now pins that `ARB`, `BNB`, `WB`, `JUP` survive.

### Bug 2 — a stop narrower than the round-trip fee (measured, then fixed)

    SOL   entry 85.1900  SL 85.5086  STOP 0.374%  TP 0.748%
    BCH   entry 236.5000 SL 237.3304 STOP 0.351%  TP 0.702%

Both STRICT SELL at 90%. At the app's own 0.25% round trip the fee is **67–71%
of one R**; the +0.75% target is a third eaten before the trade opens. One trade
in the mirror had a **0.075%** stop, where the fee alone is **3.35R**.

Measured with `measure_min_stop.py` on 1323 scalp trades:

| floor | refused | their gross | their net | net without them |
|---|---|---|---|---|
| 0.3% | 15 | −12.0 | −64.9 | +11.8 |
| **0.5%** | **23** | **−17.0** | **−74.7** | **+21.6** |
| 0.8% | 60 | +14.1 | −56.9 | +3.8 |
| 1.0% | 95 | +10.3 | −70.5 | +17.4 |

Baseline net −53.1R. A 0.5% floor removes 23 trades worth −74.7R between them,
so the same trade list becomes **+21.6R**. Swing is untouched — no swing trade
in the sample had a stop under 1%.

**Method note, because the first number I printed was wrong.** The naive
comparison (run the walk with and without the floor, compare totals) said
**+24.0R**. That figure is meaningless: `walk()` opens one trade at a time and
blocks re-entry, so adding a floor deletes one trade *and shifts every later
entry*. The two totals describe different sequences, not a better rule. The
honest read removes the trades from the *same* list and asks what they were
worth — +21.6R. The numbers are close only by coincidence; the mechanism is not
the one the naive comparison implies. `measure_min_stop.py` now prints the
refusal report and labels the per-floor totals as non-comparable.

### Not a bug

`16 signal · 93 watch · 1 radar` with `ALL 110` is consistent (16+93+1=110), and
`BUY 11 + SELL 99 = 110`. A 90% SELL skew across SOL/BCH/ETH is the market plus
`30M bearish bias` on correlated majors, not a scoring asymmetry.

Verification: tree-sitter 0 errors, `test_stamps` PASS, `test_mirror` PASS
(now also pins kMinStopPct against mirror.MIN_STOP_PCT), `test_universe` PASS.

Released as tag `v17.4.0` (commit `eb8f6a2`, CI `42836179617` success, release
run `42836565787` success). Asset
`smart-money-trader-v17.4-real-stops-17.4.0-24.apk`, 20.6 MB, link returns 302.

## 29. v18.0 — single-timeframe 3M, MACD buy-only, and a backtest bug that invalidated the numbers

Two features were asked for:

1. a mode that analyses **only 3M candles** and fires as the candle closes;
2. a **MACD buy-only** option on 3M.

Both are shipped. The path there found a defect in the measuring harness that is
more important than either feature.

### The backtest booked impossible fills

`walk()` sets `entry = orderBlock.midpoint` when the block is within 2% of price
— a LIMIT order away from the market — and then filled it on the next bar
unconditionally, scanning for the stop/target from there.

Measured on single-3M: **71 of 84 trades entered at a price their own decision
bar never traded.** A BUY could enter *below the session low* and then be booked
as a win. That is why the first honest-looking run reported:

| | n | WR | gross | net |
|---|---|---|---|---|
| before the fix | 3353 | 41.4% | **+906.5R** | +197.2R |

A +906R gross edge on a synthetic random walk is not an edge, it is a bug —
random walks have zero expectancy by construction. After modelling the limit
properly (a fill only counts if price returns to the level within 5 bars;
otherwise the setup is missed) the same mode reads:

| | n | WR | gross | net | R/trade |
|---|---|---|---|---|---|
| single3M (fixed) | 2271 | 33.7% | +105.2R | −259.9R | +0.046 |
| scalp | 1295 | 32.3% | +80.2R | −68.5R | +0.062 |
| swing | 89 | 38.2% | +25.7R | +17.3R | +0.289 |

**Every measurement in NOTES §20–§28 was produced by the old harness.** The
swing/scalp figures there share the same optimistic fills and should be read as
upper bounds. The *direction* of previous conclusions is unlikely to change
(honest fills make results worse, and the conclusions were already negative),
but the paragraph above is the number that matters now.

This was found because a good result looked wrong. It should have been checked
the first time a positive number appeared.

### Feature 1 — single-timeframe 3M mode

`TradeMode.single3m`: bias, zone and trigger all read the 3M series. One fetch,
reused for all three slots (`c15`/`c4`/`c1` are the same list) — three requests
for identical bytes would triple the weight for nothing.

**The honest caveat, which the UI now carries.** With one series, one structure
break contributes `+30` (bias) `+25` (OB) `+20` (trigger) at once, so a single
timeframe can clear the 60-point STRICT gate on its own evidence. The weights are
unchanged — that is the instruction — but "bias and zone agree" is not evidence
when they are the same candles. `TradeMode.isSingleTimeframe` exposes that fact.

Auto-refresh is 3 minutes in this mode (it was a flat 5, which would put a "fire
when the candle closes" claim up to two bars late). The timer is rebuilt on mode
switch rather than left at the old cadence.

`3m` was added to the Bybit/OKX interval mappers. **MEXC has no 3-minute
candle** and now throws instead of falling into the `default: '60m'` branch —
a 3M request answered with hourly bars under a 3M label is the same class of lie
as the 999-bar-age sentinel.

### Feature 2 — MACD buy-only, own screen

Rule, exactly as measured: BUY when **MACD line > signal AND histogram rising**.
The histogram condition is load-bearing: "above signal" stays true for a long
stretch and on its own re-fires every few bars, so the rising histogram is what
makes the trigger the moment the spread opens.

Own screen (chart icon in the app bar), because it deliberately ignores SMC
structure, order blocks and the premium/discount gate. `Engine.ema`/`Engine.macd`
mirror `mirror.ema`/`mirror.macd`; `test_mirror.py` pins the seeding rule and
the fast/slow alignment so the two cannot drift.

Measured, stop 3x ATR50, target 2R, 0.25% round trip, 6 seeds × 4 regimes:

| stop | n | WR | gross | net | R/trade |
|---|---|---|---|---|---|
| 1x ATR50 | 6991 | 35.1% | +371.0 | −1397.5 | +0.053 |
| 2x ATR50 | 8172 | 35.5% | +528.0 | −1416.4 | +0.065 |
| **3x ATR50** | **4787** | **35.6%** | **+328.0** | **−422.5** | **+0.069** |

Control (sell the same bars, same stop/target, no MACD filter): +286.0R gross at
3x. So MACD does select better than taking everything — **+42R of gross edge** —
and the fee is still about 2.3x the edge. The screen prints this rather than
leaving it to be discovered.

A first version of this measurement reported 3 trades in `trend` and 5702 in
`volatile`: a 1x ATR50 stop on 3M is ~0.4%, under the v17.4 0.5% floor, so the
floor was silently deciding which regimes produced any trades at all. That is
why the stop is swept rather than fixed.

Verification: tree-sitter 0 errors, `test_stamps` PASS, `test_mirror` PASS
(4 assertions incl. the new MACD pin), `test_universe` PASS.

Released as tag `v18.0.0` (commit `d779bc0`, CI `42842924096` success, release
run `42843378190` success). Asset
`smart-money-trader-v18.0-3M-modes-18.0.0-25.apk`, 20.7 MB, link returns 302.

The first CI run on this release failed in `flutter analyze`: the new
`TradeMode` getters used Dart 3 `switch` expressions. The SDK constraint is
`>=2.18.0`, so they were rewritten as plain conditionals, and two unused fields
were dropped. Nothing in the tree-sitter check caught this — a parser is not a
type checker, and CI is the only analyzer this project has.

## 30. v18.1 — the 3M list ordered by movement, and the quiet coins no longer vanish

The ask: on the 3-minute stack, rank by how much a coin actually moves, and
still show the ones that do not move — below the rest.

### Movement is measured, not inferred

`TradeSignal.chop` = ATR(14) on the trigger series / price × 100, computed from
the same candles the decision used. It is carried on the signal so the ordering
and the card cannot disagree.

Within a tier, `single3m` sorts by `chop` descending and then by confidence;
every other mode keeps confidence as the tiebreak, so swing and scalp ordering
is untouched. `test_3m_order.py` models the comparator literally from the Dart
source (it caught two sign errors in my own model, which is the point of it).

### The universe for a 3M scan is chosen differently

`marketScan(byVolatility: true)` ranks by the **24h high-low range** instead of
by 24h percent change. A coin that closed flat after swinging 8% inside the day
is workable on a 3-minute hold; a coin that drifted up 6% in one smooth line is
not, and the old "top gainers" picker would have chosen the second. Selection
only — every engine rule still applies, and the 0.5% stop floor still refuses
anything the move cannot pay for.

### Coins with no setup are listed, not dropped

`_Quiet` collects symbol, movement and bias for coins that produced no signal,
in `single3m` only, and renders them under a divider at the bottom (capped at
40 — a 400-coin scan can leave 350 coins empty, and printing all of them buries
the list). This also removes an ambiguity that existed since v14: "no setup" and
"never scanned" used to look identically absent.

### What this does not fix

Ordering does not create an edge. §29 measured single-3M at +105.2R gross and
−259.9R net; sorting by movement puts the tradeable coins first, it does not make
them profitable.

### Shipped

Released as **v18.1.0** on 2026-11-08.

| item | value |
|---|---|
| commit | `008b2aa` |
| build CI | `42848272780` success |
| release run | `42848804449` success |
| asset | `smart-money-trader-v18.1-3M-by-movement-18.1.0-26.apk`, 20 676 313 B |
| download link | 302 to `objects.githubusercontent.com` |

The first push of this commit was rejected non-fast-forward: the local branch
pointer had fallen behind `origin` (it still pointed at `dcc3df4` while the remote
carried that commit plus the earlier v18.1 commit). Fetching and replaying the
work on top of `origin` (cherry-pick, resolving the four conflicted files to the
worktree copy) produced `008b2aa`, which pushed cleanly. All four test scripts
were re-run on the resolved tree before pushing.

## 31. v18.2 — a real 3M scalping mode, and the first numbers measured on real candles

The ask was simple: one more mode, 3-minute, scalping only, use whatever
indicators help, just make the result good.

The honest answer took longer than the code. Everything above this section was
measured on **synthetic random walks**, because no exchange API is reachable
from this sandbox. A random walk has no volatility clustering, no session
structure and no volume/price relationship — and a 3-minute scalping rule is a
bet on exactly those things. Measuring it on noise tells you what noise does.

### Real data, finally

Binance's own API is blocked here, but a public archive of **real Binance spot
1-minute klines** lives on GitHub (`parshant231234-eng/<SYMBOL>-Historical-Data`,
one CSV per symbol per month). `tool/mirror/fetch_real_1m.py` downloads and caches
it outside the repo (`/tmp/klines`, override with `KLINES_CACHE`), splitting any
aggregate that spans a data gap instead of gluing over it.

Sample used for every number below: **41 Binance pairs, Feb–Nov 2026**, three
months of 3M candles per pair (~47 500 bars), aggregated from 1-minute.

### Why every obvious 3M rule loses

A 3-minute bar on a liquid pair has an ATR of **0.09%–0.35% of price** (median
0.22%). The round trip costs **0.25%**. In R terms, cost is not a constant:

    cost_R = 0.25 / stop_pct_as_percent

so a 1.5×ATR stop is 0.15–0.5% wide and the **fee alone is 0.5R–1.7R per trade**.
A fixed 2R target then needs a 50–73% win rate to break even. Measured on real
candles, every 3M rule — momentum ignition, pullback, band reversion, with fixed
targets or ATR trailing, 20- or 60-bar holds — landed at:

| rule (unanchored) | n | WR | net/tr @0.25% | break-even fee f* |
|---|---|---|---|---|
| ignite, rr2, h20 | 34 880 | 39.3% | −0.42R | 0.026% |
| pullback, rr3, h60 | 13 644 | 28.1% | −0.25R | 0.033% |
| pullback, trail2, h60 | 15 689 | 36.2% | −0.21R | 0.036% |

f* (the round-trip fee at which the rule is flat) of 0.02–0.04% means the rule
**cannot pay a real fee at any setting**. That is not a tuning problem.

### The one thing that works: the volatility gate

If the fee is `0.25 / stop_pct`, the only lever that moves it is stop width — and
stop width is set by how much the bar itself moves. So the mode refuses to trade
unless **ATR(14) ≥ 0.80% of price on the 3M bar**. That is 2–9× a liquid pair's
normal 3M ATR, i.e. it only fires on coins genuinely in play.

Same candles, only the gate added, everything else identical:

| gate | TRAIN n | TRAIN net@0.25% | TEST n | TEST net@0.25% | f* |
|---|---|---|---|---|---|
| 0.00 | 9 472 | −2381.3% | 11 504 | −2459.5% | 0.00% |
| 0.40 | 2 579 | −583.8% | 3 870 | −519.6% | — |
| 0.60 | 681 | −69.3% | 1 224 | +39.8% | — |
| 0.70 | 379 | −6.6% | 764 | +99.2% | — |
| **0.80** | **240** | **−1.5%** | **538** | **+147.5%** | **0.48%** |
| 1.00 | 110 | −5.7% | 326 | +168.8% | — |
| 1.30 | 40 | −55.4% | 185 | +120.9% | — |

TRAIN = Feb–Jul 2026 (6 months), TEST = Aug–Nov 2026 (4 months), **disjoint**;
nothing was tuned on TEST. Gross/net are percent of price, not R, because the fee
is quoted in percent.

Controls, because a positive number alone proves nothing:

- **gated random entries, same stop/target/hold/gate**: −486.0% (train),
  −715.3% (test). Same gate, same mechanics, entries by coin flip.
- **stock of trades**: 538 trades over 39 symbols is ~14 per symbol in 4 months.

### What the numbers do NOT support

The two best coins carry the TEST sample:

| | n | WR | net @0.25% |
|---|---|---|---|
| TEST, all 39 symbols | 538 | 36.4% | **+147.5%** |
| TEST, without IOST + ONE | 373 | 35.4% | **−31.7%** |
| TEST, IOST alone | 58 | 48.3% | +112.8% |
| TEST, ONE alone | 107 | 33.6% | +66.4% |
| TRAIN, all 22 symbols | 240 | 36.2% | −1.5% |
| TRAIN, without top 2 | 200 | 35.0% | −29.7% |

Positive on 19/39 symbols, **median symbol −0.6%**. So the release note says what
is true: the rule beats random by roughly 0.9% of price per trade (that is the
gate earning its keep), it was flat over six months and positive over the next
four, and two coins account for all of the positive period. It is shipped as a
mode with the fee printed on every card, not as a money machine.

### The shipped rule

`TradeMode.scalp3m`, 3M only, one series, its own engine (`Engine.scalp3m`) — it
does **not** reuse the SMC scoring:

    trend     EMA9 > EMA21 > EMA50                        (direction only)
    entry     close < EMA21, RSI(14) 30–55, green bar      (mirror for sells)
    gate      Wilder ATR(14) / price >= 0.80%             (fee filter)
    stop      min(5-bar low, close − 1.5 × ATR), reject under 0.35%
    target    3R, 60-bar (3-hour) time stop, one trade at a time

Entry is always the decision bar's **close**, never a limit, so the v18.0 fill
bug cannot recur in this mode. Every card prints `fee X.XXR on a Y.YY% stop`.

The 3M tab also ranks its universe by movement (§30) and refreshes on the 3M
boundary, because a 3M mode that rescans every 5 minutes is late by construction.

### Tooling added

| file | purpose |
|---|---|
| `fetch_real_1m.py` | download + cache real Binance 1m klines, gap-safe aggregation |
| `mirror3m.py` | Python mirror of the 3M rules (Wilder ATR, causal Series) |
| `measure_3m_scalp.py` | first pass on synthetic data — kept, and it is why the real-data run exists |
| `measure_real_3m.py` | rules vs random control on real candles |
| `measure_real_3m_exits.py` | exit structures × holds × volatility gates |
| `measure_real_3m_fee.py` | solves for f*, the break-even fee |
| `measure_real_3m_gate.py` | out-of-sample + gated control + per-symbol |
| `report_3m_scalp.py` | the shipped config, with the two-coin concentration check |
| `test_3m_scalp.py` | pins the Dart constants to the measured ones |
| `test_3m_parity.py` | Dart logic vs Python mirror, bar for bar on real candles |

`test_3m_parity.py` matters more than it looks. The mirror and the Dart engine
had already drifted twice — the mirror prepended one `None` too many, making
every indicator a bar stale (causal, but a different rule), and it used a simple
ATR where Dart used Wilder. A measurement of a different rule is not evidence, so
the parity test now compares 36 360 real bars and requires identical decisions,
stops and targets.

CI runs `test_3m_scalp.py`, which skips the data-dependent checks when the kline
cache is absent (GitHub CI does not have 200 MB of CSV) and says so in the log
rather than passing silently.

### Shipped

Released as **v18.2.0** on 2026-11-08.

| item | value |
|---|---|
| commit | `ba76780` |
| build CI | `42910839896` success (analyze green) |
| release run | `42911343418` success |
| asset | `smart-money-trader-v18.2-3M-scalp-fee-gate--18.2.0-27.apk`, 20 692 621 B |
| download link | 302 |

Two things this release fixed about its own process:

1. `test_3m_order.py` from v18.1 asserted the literal string
   `if (a.mode == TradeMode.single3m) {`. Widening the ordering to both 3M modes
   broke it, correctly. The pin now asserts the SET of modes, not one spelling.
2. The first version of `Engine.scalp3m` used the existing simple `atr()` while
   `mirror3m.py` used Wilder. The parity test was written exactly to catch this
   class of drift and did: the app now uses `atrWilder`, and `test_3m_parity.py`
   compares 36 360 real bars decision by decision.

## 32. v18.3 — the 3M scalp screen was honest about being empty, and wrong about why

Device screenshot, v18.2, 400 coins scanned:

    Kono setup nei ekhon (Binance) — 0/400 coin-e 3M trend nei

and directly underneath it a list of coins reading `BTTC bear 2.24%/bar`,
`PARTI bull 1.44%/bar`. The message was false, and it was false in a way that
made the mode look broken rather than selective.

### Bug 1 — the message came from counters that never ran

`scalp3m` has its own scan branch in `_HS.run`. The empty-state sentence,
though, was built from `_noBias` / `_biasNoSetup`, which are only incremented in
the SMC branch. In the 3M scalp branch they both stay 0, so `_noBias >= _biasNoSetup`
was `0 >= 0` and printed "0/400 ... trend nei" unconditionally. The quiet list
below it was computed from real EMAs, which is why the two disagreed on screen.

Fix: `Engine.scalp3m` now takes an `onRefuse` callback and names the stage that
stopped each coin — `gate`, `trend`, `side`, `rsi`, `bar`, `stop`, `data`. The
empty state counts them and prints the biggest one with its own number:

| stage | what it means for the user |
|---|---|
| gate | ATR% under 0.80 — the fee cannot be paid. Nothing to do. |
| trend | EMA 9/21/50 not stacked. |
| **side** | trend exists but price is not on the pullback side of EMA21 — a chase, not a dip. |
| rsi | on the pullback side, RSI not cooling. |
| bar | everything aligns except the candle has not turned. |
| stop | stop under 0.35% — the fee would eat it. |

### Bug 2 — the quiet row and the gate used different ATRs

The row printed `Engine.atr()` (simple average of the last 14 true ranges) while
the gate used `atrWilder`. So a coin could read `0.62%/bar` next to a list
explained by an 0.80% gate, or read above 0.80 and still be refused. The row now
prints the same Wilder number the gate used.

### What I tried to fix instead, and why it was rejected

The obvious reading of that screenshot is "0 signals means the filter is too
tight". It is. But loosening it was measured, and it does not work:

**Funnel, 390 948 real bars, gate 0.80, expected signals per 400-coin scan:**

| conditions | per scan |
|---|---|
| trend only | 14.59 |
| trend + candle direction | 7.07 |
| trend + pullback side | 2.26 |
| trend + side + RSI band | 2.26 (**RSI adds nothing**) |
| trend + side + sideways-turned candle | 0.41 (shipped) |

**Entry filters at a fixed gate, 12 pairs:** at gate 0.80 and again at 0.55,
`pullback` is the *only* entry with a positive net. `trend_any` (−0.05/trade),
`trend_green` (−0.15), `breakout` (−0.33) and `ema_reclaim` (−0.05) all lose.
The rarity is the edge.

**And the "turn" confirmation is load-bearing.** Same stops, same targets, same
gate, 10 months, same 1070 trades — dropping only the candle-turn requirement:

| entry | n | net | net/trade |
|---|---|---|---|
| pullback with the candle turn (shipped) | 440 | **+117.2%** | +0.266% |
| pullback side only (turn removed) | 1070 | **−77.3%** | −0.072% |
| side only, gate 0.50 | 4975 | −880.5% | −0.177% |

So the frequency cannot be bought by relaxing the rule: every relaxation tested
turns a positive entry into a negative one. The mode is genuinely selective, and
what was broken was the *explanation*, not the selectivity. That is what v18.3
fixes. Saying "it is supposed to be empty, and here is the exact reason" is a
better product than a screen full of signals that lose money.

### What this means for the numbers in §31

They stand. §31's `pullback` variant already included the candle turn; the
10-month re-run of the same rule gives +117.2% net over 440 trades. What changes
is the claim on frequency: expect **~0.4 signals per 400-coin scan**, i.e. a
mostly empty screen is normal, and the quiet list plus the stage counter is the
product in the meantime.

### Shipped

Released as **v18.3.0** on 2026-11-08.

| item | value |
|---|---|
| commit | `615a5f3` |
| build CI | `42914732554` success |
| release run | `42915128837` success |
| asset | `smart-money-trader-v18.3-3M-scalp-says-why-18.3.0-28.apk`, 20 698 083 B |
| download link | 302 |

The branch pointer reverted to the pre-v18.2 base again mid-session (a repeat of
the §30 incident), which is why the first push of the v18.3 commit was rejected
as non-fast-forward even though the content was correct. Repairing it by
cherry-picking onto `85a9015` left conflict markers inside
`tool/mirror/test_3m_scalp.py`; those were caught by grepping the tree for
markers before pushing, not by the test run (the markers sat in code paths the
test did not execute). The marker check is now part of the routine before a
commit, and the file was restored from the known-good commit.

---

## §33 · v18.4.0 — Gemini as a second opinion (2026-11-08)

**Ask.** "আমি চাই আমার সব mode-এ Gemini add করতে, যেন সে আরো ভালো decision দিতে পারে.
App-এর মধ্যে Gemini API key add করার একটা option, আর Gemini যেন সব signal-এ help করতে পারে."

**What that has to mean.** "Help" cannot mean "change the answer". If the model could add,
drop or re-rank a signal, the app would have two engines and no way to say which one
produced what — and the one thing this project has been careful about is that every
number on screen is reproducible from the rule. So Gemini is built as an **advisor**:

| Layer | What it does | What it can't do |
|---|---|---|
| `GeminiService.reviewSignal` | one signal → STANCE / CONFIDENCE / WHY / RISK / WHEN | touch the signal |
| `_autoReview` | reviews the **top 3** after a scan | delay the scan (fire-and-forget) |
| `_reviewScan` | one note about the whole scan | re-order the list |
| `GeminiNote` | stored in `_gNotes` / `_gScanNote` | be the source of truth |

Enforced by construction and pinned by `tool/mirror/test_gemini.py` (7 groups, 22 checks):
no `await` on a review, no review statement writes `_signals`/`_quiets`/`_scratch`, the sort
never reads a note, the chip is *passed into* `_SignalCard` rather than built there.

**Why the prompt attacks instead of approves.** Ask a model "is this a good trade" and it
says yes — the answer is a function of the question, not the setup. The system prompt
orders it to find the reason the trade fails, and hands it the arithmetic to argue with:
`feeR = round-trip cost / stop distance` and `barsToTarget = reward% / typical bar move`.
A criticism that can be checked is worth more than a verdict that cannot.

**Key in-app, key on the device.** Settings sheet behind the sparkle icon in the app bar:
masked field, **Test key** (real `generateContent` round trip), **Find a model** (`GET
/models`, keeps only `generateContent` models — a retired model name is the second most
likely failure after a typo), two switches. No `shared_preferences`: adding it means a new
pub.dev fetch inside the release build, and that build has already failed on network steps.
Instead `tool/patch_prefs.py` writes a ~40-line Kotlin handler over the app-private
`SharedPreferences` and installs it into the `flutter create` scaffold, idempotently, and
fails the build if the generated Kotlin does not balance.

**Two failure modes found while shipping, both fixed.**
1. The patch step failed in CI in **0 seconds**, twice, with unreadable logs. Cause: the
   script searched `android/` only. It now searches the whole tree and prints a traceback
   and the resolved package.
2. `_geminiBadge` was called from `_SignalCard`, which is a different class → 2 analyzer
   errors, invisible because this repo's Actions logs and artifacts are served from a host
   this environment cannot reach. Fixed by passing the chip in as a `Widget?` (also the
   better design) and by **publishing `flutter analyze` output as workflow annotations**,
   which does come back through the API. That CI change is worth keeping beyond this
   version: for the first time a broken build reports *why*.

**Costs, stated plainly.** One review = ~1.5 k input tokens. Auto mode = 4 requests per
scan (3 signals + 1 scan) ≈ 20 k tokens/hour at the 5-minute refresh, well inside the free
tier. `maxOutputTokens 700`, `temperature 0.2`, 45 s timeout, `_gInFlight` dedupe, failures
stored as notes so nothing retries in a loop.

**Not verified.** No Android device here, so the settings sheet, the chip and the Kotlin
channel are compile-verified and test-verified but **not run-verified**. `GeminiStore.persistent`
returns false when the channel is missing, and the sheet then shows a warning instead of
pretending the key was saved — the honest failure, but it means the first real-world check
is the user's.

### §33 · Shipped

| | |
|---|---|
| commit | `53ed5af` (tag `v18.4.0`) |
| CI | `42918656029` — green, prefs patch step passed for the first time |
| release | `42919078302` |
| asset | `smart-money-trader-v18.4-Gemini-advisor-18.4.0-29.apk`, 21 008 645 B |
| page | https://github.com/raj200ab-droid/smart-money-trader-2/releases/tag/v18.4.0 |
| QR | `/home/user/v18.4-apk-qr.png` (decoded back to the exact URL) |

**The debugging lesson worth keeping.** Three CI runs burned on one step because
this environment cannot read Actions logs (the runner serves them from
`productionresultssa*.blob.core.windows.net`, and artifact ZIPs from the same
host). The fix was not cleverness, it was making CI report through a channel
that *is* reachable: `::error title=...::message` becomes a check-run
annotation, and annotations come back through `api.github.com`. Every failure
path in `patch_prefs.py` now emits one, and `flutter analyze` output is
published the same way. **When a build fails where you cannot see it, change
how it reports before changing what it does.**

Two of the three bugs were only found by reproducing the *generated* file
locally — the template has changed shape since the notes in `tool/` were
written. A patch step against generated code needs a fixture of that generated
code, which is why `test_gemini.py` group 8 renders both templates.

## §34 · v18.5.0 — the quiet list stops contradicting itself (2026-11-11)

**Reported from a v18.2.0 device screenshot**, 3M S mode, 400/400 scanned, zero signals:

```
400 coin gate-e atke nai (beshi move kora age)
Egulo analyse kora hoise but 3M scalp rule pay nai. ATR 0.80%-er kom hole
fee uthano jay na, tai skip.

INIT    flat    3.81%/bar
IQ      bear    3.17%/bar
BTTC    flat    2.78%/bar
...
OPG     bull    0.60%/bar
```

Two sentences, both false, both on the same screen:

1. **"gate-e atke nai"** — of the 19 rows visible in the screenshot, **10 have
   ATR above the 0.80% gate** (3.81, 3.17, 2.78, 2.47, 2.28, 1.72, 1.49, 1.14,
   0.89, 0.81). They passed the gate and were refused later — trend, pullback,
   RSI, candle turn or stop. The header named one stage for all 400 coins.
2. **"400 coin"** — the list is capped at `_quietShown` = 40. The header counted
   `_quiets.length`, the rows printed `_quietShown`. The number above the list
   was not the number of rows in the list.

The rows were also unreadable as evidence: `INIT flat 3.81%/bar` states a trend
and a volatility and nothing about *why* a coin moving 3.8% a bar produced no
trade. That is the question the screen exists to answer, and the answer was
already computed and thrown away — `Engine.scalp3m` reports its refusing stage
through `onRefuse`, the scan increments `_scalp3mWhy[stage]`, and the code then
constructed `_Quiet` without it.

**Fix.** `_Quiet` carries `why`; the scan captures the stage it was already
counting and maps it through one word list (`_scalp3mWhyWord`: quiet / no trend /
no pullback / no rsi / no turn / stop too tight / short history) used by the
rows, while the header stops printing a count it did not measure:

```
19 / 400 coin analyse kora hoise, signal pay nai
Prottek coin-e EMAs, ATR ar candle turn check kora hoise. Por-er line-e je
condition e atkeche setai lekha — "quiet" mane ATR 0.80%-er niche ...

INIT     no turn    flat    3.81%/bar
IQ       no turn    bear    3.17%/bar
BTTC     no turn    flat    2.78%/bar
PARTI    quiet      bear    0.62%/bar
```

**Why this mattered more than it looks.** A mode that gives no signals is
already asking the user to trust a refusal. A refusal that is described wrongly
is worse than no description: it invites the reader to conclude the filter is
broken, when the filter is working exactly as measured (the ATR gate really did
eat most of the market — just not all of it, and not those ten coins).

**Still not fixed, needs a decision.** Ten coins with 0.8–3.8% ATR bars passed
the fee gate and still produced nothing on the same close. The next stage that
refuses them is `side`/`rsi`/`bar` — and `side` (price not pulled back to EMA21)
is structurally the most common, because a coin that just ran is above its EMA.
So the screen will now honestly show a wall of "no pullback". Whether that means
the *entry* is too strict for a 3M chart, or the mode is simply selective, is a
measurement question — and the answer is not "loosen it": dropping the turn rule
measured **+117.2% → −77.3%** over ten months. If the pullback wall is what
actually bites, the honest options are (a) label these near-misses as
non-tradeable, or (b) test a chase entry as a *separate* rule set with its own
measurement, never as a relaxation of this one.

### §34 · Shipped

| | |
|---|---|
| commit | `f67df63` (tag `v18.5.0`) |
| CI | `42990230649` — green, 0 analyzer errors |
| release | `42990605382` |
| asset | `smart-money-trader-v18.5-3M-quiet-list-says-why-18.5.0-30.apk`, 21 010 228 B |
| QR | `/home/user/v18.5-apk-qr.png` |

**Branch-pointer incident (second time).** The working copy was still sitting on
`9112397`, a stale `main` from before this branch existed (the same commit that
had been the base of the v18.3 push failure). The v18.5 commit landed on top of
it, which would have replaced the branch tip with a tree missing v18.4 entirely.
Caught by the push rejection, repaired with `git reset --hard fde9c19` and
re-applying only the five changed files. Worth repeating: **after any push
rejection, check `git merge-base --is-ancestor` before cherry-picking** -- here
the local HEAD and origin were not related in the direction assumed.

---

## §35 · v19.0.0 — the 3M rule is replaced: BOS + MACD, one timeframe (2026-11-11)

**Ask, verbatim.**

> "Ami chai tumi ei mode a sob delete kore a diye, 3 minutes timeframe analysis
> korbe and recently hoya b.o.s + m.a.c.d green takha lagbe. 3 minutes sara r
> kono timeframe analysis korbe a nh. R 2 dollars er besi dam er coins gula akdom
> niche a show korbe a"

Three instructions: delete everything in 3M S, analyse 3M only, require a recent
BOS **and** green MACD; and put coins over $2 at the bottom.

### What was deleted

The whole v18 rule set: ATR(14) gate 0.80%, EMA 9/21/50 stack, pullback-to-EMA21
test, RSI band, candle-turn confirmation, 5-bar-extreme stop, 1.5xATR stop.
None of it survives in the decision path — `test_3m_scalp.py` now asserts each
one is *absent* from `Engine.scalp3m`, because "we deleted it" is exactly the
kind of claim that quietly stops being true.

### What replaced it

```
3M series only  ->  BOS within 3 bars  AND  MACD green  ->  enter at close
                    (pivot confirmed)      (line > signal, hist not falling)
```

Exit: 3xATR stop, 3R target, 40-bar time stop. Freshness window 3 bars
(`bos3mMaxAgo`) was chosen BY MEASUREMENT, not by taste — see the sweep below.

### The measurement, before the code was written

391 680 real Binance 3M bars, 12 spot pairs, Sep–Nov 2026, 0.25% round trip
charged per trade against its own stop, no look-ahead (a pivot is only knowable
`k` bars after it forms).

**1. How long does "recently" mean?** (1.5xATR stop, 3R, 20 bars)

| max_ago | time | trades | WR% | net R |
|---|---|---|---|---|
| 1 | 3 min | 4 679 | 33.6 | −2 291 |
| **3** | **9 min** | **5 521** | **33.5** | **−2 706** |
| 10 | 30 min | 7 782 | 34.4 | −3 752 |
| 30 | 90 min | 9 391 | 34.9 | −4 506 |
| 60 | 180 min | 9 528 | 34.8 | −4 608 |

Tighter is better, and 3 bars is the tightest window that still yields a
tradeable sample. Every wider window loses more.

**2. Which exit?** 18 combinations of stop multiple (1.5/2/3xATR), target
(1.5/2/3R), break-even and hold. Best of 18: **net −2 548R**. Shipped exit
(3xATR, 3R, 40 bars): n 6 893, WR 39.2%, **net −2 751R, −0.399R per trade**,
average fee 0.38R.

**3. Is it one coin?** No. Leave-one-symbol-out: removing the most negative pair
gains +449R and the result is still deep in the red. Every one of the 12 pairs is
negative alone (BNBUSDT best at −20R).

**4. Is the rule adding anything over noise?** Yes, a little:

| | trades | WR% | avg R |
|---|---|---|---|
| random entry, same exit | 13 646 | 28.3 | −0.527 |
| **BOS + MACD green** | **5 207** | **28.9** | **−0.489** |

So the rule is genuinely better than a coin flip — and still loses. The cause is
arithmetic: a 3R target on a 3M chart fills ~25% of the time, most wins are
time-stopped at partial R, and 0.38R of fee per trade absorbs the difference.
This is the same wall §29 hit from the other side.

### Why ship it anyway

Because the user asked for exactly this rule and asked for the old one removed,
and because a *labelled* negative rule is not the same thing as a *dishonest*
one. What made the old modes trustworthy was never that they won — it was that
the number on the card was the number the rule produced. So:

- the card prints the fee in R on its own stop,
- `Engine.scalp3m`'s doc comment carries the table above,
- `test_3m_scalp.py` fails if the code ever claims a profit for it,
- the mode is labelled **"3M BOS"**, not "3M S", so the installed build cannot
  be mistaken for the deleted rule set.

### The $2 ceiling is a display rule, not a filter

Coins over $2 still produce signals; they sort below every cheaper coin. Making
it an entry filter would have shrunk the list silently, which is the exact class
of bug §34 was about. `kScalp3mMaxPrice = 2.0`, applied inside the 3M comparator
only, and the card says "price over $2" when it applies.

### The parity bug this uncovered

`test_3m_parity.py` compares the Dart rule with the Python measurement bar by
bar. It found three real bugs — **all three in the measurement, none in the app**:

1. `bos_series` scanned pivots only to `n-k`, so it could not see a pivot in the
   last k bars, while its streaming pass still reported a break off it. Dart
   (`i < n-k`) was right; the mirror was reporting breaks off pivots that did
   not exist yet.
2. The parity harness fed MACD an 80-bar window. EMA is an infinite impulse
   response, so truncation yields a *different* value — 950 false mismatches
   from warm-up alone.
3. The harness's mirror side had no min-stop floor, so 8 bars where the 3xATR
   stop fell under 0.35% looked like app bugs.

After the fixes: **32 445 bars, 2 993 both-signal bars, zero mismatches.** The
numbers in this section are from the corrected measurement — the first run of it
(§35 draft) quoted −3 042R from a rule that did not match the app.

### Shipped

| | |
|---|---|
| commit | `885c05e` (tag `v19.0.0`) |
| CI | `43080210636` — green, 0 analyzer errors |
| release | `43080600047` |
| asset | `smart-money-trader-v19.0-3M-BOS-MACD-only-19.0.0-31.apk`, 21 008 415 B |
| QR | `/home/user/v19.0-apk-qr.png` |
| corpus | `/tmp/klines` 156 MB, 12 pairs × Sep–Nov 2026 (wiped between turns) |

**The branch pointer reverted for the third time**, always to `9112397` (a
`main` from before this branch existed). The v19 work was written on top of it
and would have replaced the branch tip with a tree missing v18.4 and v18.5. Now
caught by the push rejection each time, repaired with
`git stash -u` → `git reset --hard origin/<branch>` → copy back the touched
files. The reliable pre-commit check is one line, and the argument order matters:

    git merge-base --is-ancestor origin/<branch> HEAD && echo ok

That asks "is the remote tip already inside my HEAD?", which is the healthy
state. Written the other way round (`HEAD origin/<branch>`) it answers "yes" in
the BROKEN case too — HEAD being an ancestor of origin is exactly what a stale
working copy looks like — which is how the fourth occurrence of this went
unnoticed for a whole turn. If the check fails, do not commit: `git stash -u`,
`git reset --hard origin/<branch>`, copy the touched files back. `git log
--oneline -3` alone will not show it, because the stale base has a
plausible-looking history.

**Records syntax.** `(int, double)` cost a CI run: this project targets a
language version without the `records` feature. tree-sitter parses it happily;
`flutter analyze` does not. Parallel lists were the fix.

---

## §36 · v19.1.0 — the 3M mode becomes a scanner (2026-11-11)

**Third revision of the same mode, in the user's words:**

> "ei mode a just 3 minutes timeframe a analyse korba j 5 candle er modhe a bos
> hoyse a ki nh r macd a green ace a ki nh. Jodi 2 tai mil takhe a tahole top a
> asbe oii coin gula r jodi just 1 ta match kore a tahole a niche a asbe coin
> gula. Besi up-down kore a sei coin gula opur er dikh a takhbe. Just 2 dollars
> er nice a j coin gula ace a sei gula filter korba. R kono kisu add korba nh,
> ami kono doroner entry or exit plan chai nh. Risk ratio eyo chai nh."

| v19.0 (yesterday) | v19.1 (this) |
|---|---|
| a trade setup | **a scanner** |
| entry, 3xATR stop, 3R target | **none of it** |
| BOS within 3 bars | BOS within **5 candles** |
| both / nothing | **2 of 2 -> TOP**, **1 of 2 -> BOTTOM** |
| over-$2 sunk to the bottom | over-$2 **filtered out** |
| fee in R on the card | **no R, no fee, no plan** |

### What was removed, and why it took a test to keep it removed

Entry, stop, target, R:R, the fee line, the confidence percentage, the BUY/SELL
word on the card, and the `RR 1:x` row in the details sheet. `test_3m_scalp.py`
now asserts the *absence* of each: `sl: 0`, `tp: 0`, no `kScalp3mRR` in the
decision, no `a14 * 3`, and the details sheet branching to a facts panel instead
of a plan. Without those assertions "we removed the plan" is a comment that
survives until the next edit.

**Why `sl`/`tp` are 0 and not the price:** a number there would be an invented
plan, and zero is the only value that cannot be mistaken for one. The card shows
`2.34%/bar` and `2 of 2` where the percentage and `RR 1:x` used to be.

### The measurement (391 680 real 3M bars, 12 pairs, Sep–Nov 2026)

**How the scan splits** (each bar is one observation):

| bucket | bars | share |
|---|---|---|
| 2 of 2 (BOS + MACD) | 48 111 | 12.3% |
| 1 of 2 (BOS only) | 113 353 | 29.0% |
| 1 of 2 (MACD only) | 54 397 | 13.9% |
| 0 of 2 | 174 367 | 44.7% |

So the sections are not decorative: **the top is a fifth of the signal bars.**

**How big the top is per scan** — ~15 coins per 120-coin scan, i.e. **roughly 49
on a 400-coin scan**, maximum 75; **8% of scans have an empty top.**

**What each bucket does next** (10 bars / 30 min, no exit invented):

| bucket | avg forward return | touched +1 ATR before -1 ATR |
|---|---|---|
| 2 of 2 | −0.008% | 48.6% |
| 1 of 2 (BOS) | +0.010% | 50.7% |
| 1 of 2 (MACD) | −0.000% | 48.7% |
| 0 of 2 | +0.001% | 50.1% |

**The 2-of-2 bucket is 48.6% — slightly WORSE than a coin flip (50%).** That is
the honest answer to "does both-matching predict direction on 3M": it does not.
It is a *scanner* — it tells you which coins are moving and which two conditions
are aligned right now — and the app must not imply more than that. This is why
the card carries no side, no target and no R:R: there is nothing measured to
justify one.

The first version of the section-3 measurement was wrong and said the top was
always empty: it counted per symbol instead of per timestamp, so the maximum was
1 by construction. A measurement that cannot produce a non-trivial answer should
be suspected before it is quoted.

### Parity

`test_3m_parity.py` re-derives the scanner from `lib/main.dart` and now compares
**match counts** instead of trade prices: 32 445 bars, 10 299 signal bars, 0
mismatches. The count rose from 2 993 because "1 of 2 only" is a signal now.

### Shipped
