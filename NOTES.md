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
