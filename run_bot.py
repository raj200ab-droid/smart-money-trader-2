#!/usr/bin/env python3
"""
run_bot.py — scan-loop driver for binary_bot.py.

`--timeframe 3m --expiry 3m` (the 3m/3m option) follows these rules:

  1. 180-second (3-min) candles.
  2. 180-second (3-min) contract expiry.
  3. 3-min wait before the first entry after start (warm-up).
  4. One signal per 3-min boundary only (minute % 3 == 0 → 0/3/6/9…),
     so at most one signal every 3 minutes.
  5. After every 3 signals → 3-min wait (cooldown).
  6. The 30m/30m and 60m/60m variants wait 30 / 60 minutes instead.

  Plus the engine rulebook (gap-too-big 1.5 / 10.0, session gate, 1% risk,
  1:3 RR, digit HOT/COLD) — see binary_bot.py's module docstring.

Examples:
    python3 run_bot.py --timeframe 3m --expiry 3m --sym R_100 --type CALL
    python3 run_bot.py --timeframe 3m --expiry 3m --check --json
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timedelta, timezone

import binary_bot as bb


GRANULARITY = {"1m": 60, "3m": 180, "5m": 300, "15m": 900}


def parse_args(argv=None):
    p = argparse.ArgumentParser(description="binary_bot scan loop")
    p.add_argument("--timeframe", default="3m", choices=["1m", "3m", "5m", "15m"])
    p.add_argument("--expiry", default="3m", help="3m / 30m / 60m — sets the wait cadence")
    p.add_argument("--interval", type=int, default=300, help="seconds between scans")
    p.add_argument("--timeout", type=int, default=24 * 3600, help="total run seconds")
    p.add_argument("--scans", type=int, default=0, help="stop after N scans (0 = forever)")
    p.add_argument("--sym", "--symbol", dest="symbol", default="R_100")
    p.add_argument("--type", dest="contract_type", default="CALL")
    p.add_argument("--check", action="store_true", help="dry-run: print decisions, never buy")
    p.add_argument("--session-tz", default="UTC")
    p.add_argument("--contract-type", dest="contract_type_alt", default=None,
                   help="alias of --type (one type only — no fallback between types)")
    p.add_argument("--derive-both", action="store_true",
                   help="derive CALL and PUT decisions for the report (still trades one type)")
    p.add_argument("--probe-gaps", action="store_true", help="report gap diagnostics")
    p.add_argument("--no-cache", action="store_true")
    p.add_argument("--session-warm", type=int, default=300, help="seconds of history warm-up")
    p.add_argument("--json", action="store_true", help="one JSON line per scan")
    return p.parse_args(argv)


def gap_diagnostics(bars, contract_type: str) -> dict:
    """The gap-too-big rule, reported: entry pip limit 1.5, session gap cap 10.0."""
    if len(bars) < 2:
        return {"gap_pips": 0.0, "session_gap": 0.0, "ok": True, "reason": "ok"}
    gap = bars[-1].open - bars[-2].close
    session_gap = bars[-1].close - bars[0].open
    a = bb.atr(bars, bb.ATR_PERIOD)
    atr_pct = (a[-1] / bars[-1].close * 100) if bars[-1].close else 0.0
    streak = 0
    for b in reversed(bars[:-1]):
        if (b.close - b.open) > 0:
            streak += 1
        else:
            break
    ok, reason = bb.gap_ok(contract_type, abs(gap) / bb.pip_size("R_100"),
                           abs(session_gap) / bb.pip_size("R_100"), atr_pct,
                           direction="up" if gap > 0 else "down", streak=streak,
                           fresh_structure=False if streak >= bb.STREAK_FRESH_ENTRY else True)
    return {"gap_pips": round(gap / bb.pip_size("R_100"), 3),
            "session_gap": round(session_gap / bb.pip_size("R_100"), 3),
            "atr_pct_1h": round(atr_pct, 3), "streak": streak, "ok": ok, "reason": reason}


def scan_once(ws, args, throttle, stats: bb.SessionStats) -> dict:
    gran = GRANULARITY.get(args.timeframe, 180)
    bars = bb.fetch_option_candles(ws, args.symbol, timeframe=args.timeframe,
                                   granularity=gran, count=500,
                                   contract_type=args.contract_type, cache=not args.no_cache)
    ticks = bb.fetch_option_ticks(ws, args.symbol, count=300,
                                  contract_type=args.contract_type, cache=not args.no_cache)
    now = datetime.now(timezone.utc)
    decision = bb.check_single_type_live(args.symbol, args.contract_type, bars,
                                         ticks=ticks, now=now, throttle=throttle)
    line = {
        "ts": now.isoformat(timespec="seconds"),
        "symbol": args.symbol,
        "type": args.contract_type,
        "timeframe": args.timeframe,
        "expiry": args.expiry,
        "session": bb.session_name(now),
        "decision": decision,
    }
    if args.probe_gaps:
        line["gap"] = gap_diagnostics(bars, args.contract_type)
    if args.derive_both:
        for ct in ("CALL", "PUT"):
            t2 = bb.Throttle(cadence_min=throttle.cadence, started=throttle.started)
            line[ct.lower()] = bb.check_single_type_live(args.symbol, ct, bars,
                                                         ticks=ticks, now=now, throttle=t2)
    if stats.paused():
        line["decision"] = {"ok": False, "reason": "session paused (WR < 50% or net <= 0)"}
    return line


def run(argv=None) -> int:
    args = parse_args(argv)
    ct = args.contract_type_alt or args.contract_type
    args.contract_type = ct.upper()
    throttle = bb.make_throttle(args.expiry)
    stats = bb.SessionStats()
    started = time.time()
    scans = 0

    async def _loop():
        ws = bb.DerivWS(token=os.environ.get("DERIV_TOKEN", ""))
        await ws.connect()
        try:
            while True:
                line = scan_once(ws, args, throttle, stats)
                if args.json:
                    print(json.dumps(line), flush=True)
                else:
                    d = line["decision"]
                    status = "SIGNAL" if d.get("ok") else "skip"
                    print(f"{line['ts']} {line['symbol']} {line['type']} "
                          f"{line['timeframe']}/{line['expiry']} [{status}] {d.get('reason', '')}",
                          flush=True)
                scans += 1
                if args.scans and scans >= args.scans:
                    break
                if args.timeout and (time.time() - started) >= args.timeout:
                    break
                time.sleep(args.interval)
        finally:
            await ws.close()

    import asyncio
    asyncio.get_event_loop().run_until_complete(_loop())
    return 0


if __name__ == "__main__":
    sys.exit(run())
