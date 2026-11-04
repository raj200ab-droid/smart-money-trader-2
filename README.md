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
