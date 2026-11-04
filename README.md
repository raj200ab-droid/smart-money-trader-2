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

## Notes

- Binance may be geo-blocked; the app rotates through several API mirrors and
  shows a retry message if all fail.
- Technical analysis only — not financial advice.
