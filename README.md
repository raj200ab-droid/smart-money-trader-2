# smart-money-trader-2

Smart Money Concepts (SMC) signal scanner for Binance USDT pairs, built with Flutter.

## What it does

Scans the top gainers and top losers on Binance (24h), then runs a multi-timeframe
SMC engine on every candidate:

| Timeframe | Role |
|-----------|------|
| 4H | Trend bias — market structure (HH/HL vs LH/LL) and break of structure |
| 1H | Zone — unmitigated order blocks and fair value gaps near price |
| 15M | Trigger — BOS or liquidity sweep in the last candles, volume spike |

A trade signal only fires when the 4H bias, the 1H zone and the 15M trigger agree.
Stops sit beyond the zone (ATR-buffered), targets are a fixed 2R, and setups risking
more than 8% of entry are discarded.

## Engine (LuxAlgo "Smart Money Concepts" model)

The confluence engine is a from-scratch Dart implementation of the published
logic of LuxAlgo's *Smart Money Concepts* indicator (CC BY-NC-SA 4.0) — no Pine
code is copied.

- Pivot state machine: swing length 50, internal length 5 (`ta.highest/lowest`
  semantics; a pivot is confirmed `len` bars later)
- **BOS vs CHoCH**: a break with the prior structure is a continuation BOS, a
  break against it is a reversal CHoCH
- Order blocks built from the structure interval between the break and the
  pivot (candles under 2× ATR), removed once price closes through them
- Fair value gaps with the running-mean delta threshold, removed on fill
- EQH/EQL liquidity pools at 0.1× ATR
- Premium / discount / equilibrium zones (5% / 47.5% split); breakouts above or
  below the swing range are labelled separately and do not block a trend entry

Signals fire in two passes: a **STRICT** pass (4H bias + 1H OB/FVG zone +
15M BOS/CHoCH trigger + zone location) and, if that finds nothing, a **WATCH**
pass with a lower threshold and no counter-trend gate. Watch signals are marked
`WATCH` in the list.

## Why the list can be empty

The scanner runs three tiers and labels every card:

| tier | meaning |
|---|---|
| **STRICT** | full confluence: 4H bias + 1H OB/FVG + live 15M swing break, score ≥ 60 |
| **WATCH** | relaxed: internal 15M break accepted, score ≥ 40 |
| **RADAR** | bias and a live 15M break exist, but the zone or the score is still missing — a candidate list, **not** a trade |

The status panel also prints the build stamp (`v4 · radar`) and `pubspec.yaml`
carries `4.0.0+4`, so the build installed on the phone is identifiable.

The scanner reports *why* it found nothing. The status line tells you which of
the two failure modes dominates across the 73 scanned coins:

- `N/73 coin-e 4H trend nei` — the higher timeframe has no confirmed structure
  break, so nothing is tradable by design
- `N coin-e 4H trend ache, kintu 15M trigger/zone mile nai` — bias exists but
  the 1H OB/FVG or the 15M trigger is missing

Below the empty state a **"kache kache eshechilo"** list shows each coin's
diagnosis and its score against the threshold, which is the data needed to
tune the filters instead of guessing.

## Directional sanity

An unbiased engine has to produce roughly as many BUYs as SELLs on symmetric
data. Two bugs broke that and are covered by the checks in `smt-mirror/`:

- the swing oscillator's warm-up state made the **first pivot of every window a
  low** (82 highs vs 147 lows per 120 series), which tilted the 4H bias bearish
- the 1H order-block bonus only fired for the side the bias already favoured

The engine now starts the oscillator unknown (82 / 91) and applies a structure
floor: the nearest valid order block decides which side is blocked. Verified on
regime-switching synthetic data — 7 BUY vs 9 SELL strict, 12 vs 13 watch.

## Backtest

The chart icon in the app bar opens a backtest screen: type a coin, hit **Run**,
and the app fetches 1000 bars of 4h/1h/15m, then walks the 15M series bar by bar
showing the engine only candles up to that bar (no look-ahead). Each signal is
followed to its stop or target and the screen reports:

- win rate, wins/losses, **total R** and average R per trade
- win rate for STRICT-only signals (higher quality subset)
- current win/loss streak and the full trade list

The screen refuses to be optimistic: with fewer than 20 decided trades it says
so explicitly, and trades still running are reported as `open` rather than
being folded into the win rate. The backtest pulls ~40 days of 15M history by
paging Binance klines (1000 rows per request) and degrades the 4H bias window
from 400 to 200 to 120 bars when a listing is younger than that.

Read the **total R**, not the win rate: at 2R targets a 40% win rate is
profitable, while a 60% win rate at 1R can still lose. A sample of a few dozen
trades is directional evidence, not proof.

## Signal output

- Direction (BUY / SELL) and confidence score
- Entry, stop loss, take profit, risk:reward, expected move
- Confirmation list and the structure of each timeframe
- Auto-rescan every 5 minutes, pull-to-refresh, rescan button

## Build

The repo contains only `lib/main.dart` + `pubspec.yaml`; the Android project is
generated in CI.

```
flutter create . --org com.smartmoney --project-name smart_money_trader --platforms android
flutter pub get
flutter build apk --release
```

GitHub Actions builds the release APK on every push to `main` and on pull requests
(`Actions → Build APK → artifacts → smart-money-trader-apk`).

## Data sources

Binance is geo-blocked (HTTP 451) in many regions, VPNs included. The scanner
therefore walks a feed chain until one answers:

1. **Binance** — `api.binance.com`, `api1..3`, `data-api.binance.vision`
2. **Bybit** — `api.bybit.com/v5/market`
3. **OKX** — `www.okx.com/api/v5/market`
4. **MEXC** — `api.mexc.com/api/v3`

The first feed that returns tickers is reused for that scan's candles; feeds that
fail are skipped for 3 minutes so a blocked venue cannot add timeouts to every
request. A pair that only exists on Binance simply yields one skipped coin. The
feed actually in use is shown next to the progress message (`15 signal ready
(Bybit)`).

## Notes

- If every feed is blocked the app says so and keeps the auto-retry timer on.
- No API keys, no account — public market data only.
- Technical analysis only — not financial advice.
