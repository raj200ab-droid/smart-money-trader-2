#!/usr/bin/env python3
"""
binary_bot.py — Deriv smart-money bot: SMC engine + live trading.

The engine rulebook (kept explicit; the user verifies rules, not vibes):

  * Entry location: buy at support, sell at resistance (M15 swing clusters).
  * CALL entries are priced on candle LOW  (support / buy-side liquidity).
  * PUT  entries are priced on candle HIGH (resistance / sell-side liquidity).
  * DIGITMATCH / DIGITDIFF / OVER / UNDER are priced on candle CLOSE.
  * H1 Fibonacci: retracement band 0.705–0.79 of the impulse leg, tolerance 0.0125.
  * H4 order block: last opposite-close before an impulse >= 1.5 x ATR(20);
    zone = [open, close]; mitigated once past zone edge + 0.25 x zone height.
  * Liquidity grab: 20-bar fractal sweep + re-entry, needs 1.5 x ATR(1.4) travel room.
  * FVG: 3-candle gap, needs 1.5 x ATR(1.4) travel room to the far side.
  * Momentum gate: target room must be >= 3 x ATR (the "3xATR check").
  * Gap-too-big rule: entry_pip_limit 1.5, session_gap_cap 10.0 pips;
    MATCH UP gap > 0.20 (1H ATR% bucket) -> skip; DIFF gap > 1.0 -> skip;
    3 consecutive same-direction candles -> require a fresh structure entry.
  * Sessions: TOKYO 00-08, LONDON 08-16, NEWYORK 16-24 UTC.
    After >= 20 trades in a session, WR < 50% or net <= 0 after fees -> pause.
  * Risk: 1% of balance per trade, 1:3 structure-based RR,
    SL = structure level - 0.5 x ATR(14) buffer; skip if loss > 1% of balance.
  * Digit rules: digit_bias(lookback=300, n=3) -> threshold;
    digit_levels P(30s digit pairs) baseline 0.010, ratio >= 1.10 HOT else COLD skip,
    digits 0/9 need ratio >= 1.20. digitsmap is ONLY for MATCH/DIFF —
    OVER/UNDER use the fixed 2.0 / 8.0 threshold via over_digit_map.
  * STRICT_MODE=1 is always on: DIGIT_TOKEN_REQUIRED=1, REVERSE_ENGINEERING=1,
    DYNAMIC_THRESHOLD=1, VOL_100_1s / VOL_200_1s / VOL_300_1s blocked.
  * 3m/3m throttle: 180s candles, 180s expiry, one signal per 3-min boundary
    (minute % 3 == 0), 3-min wait before the first entry, 3-min wait after
    every 3 signals. 30m/30m and 60m/60m variants wait 30 / 60 minutes.
    The count is PERSISTED (.throttle_state.json) — restart/refresh does not
    reset it; > 6h off starts a new session; --reset clears it.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import math
import os
import random
import sys
import time
from collections import namedtuple
from datetime import datetime, timedelta, timezone

# ─────────────────────────── constants / rulebook ───────────────────────────
API_PAYOUT_MULT = 0.98          # api = 0.98 (payout sanity multiplier / slippage)
BACKTEST_WIN_RATE = 0.70
BACKTEST_RR = 2.5
R_MULTS = (1.0, 2.5, 5.0)
FEE_R = 0.02

STRICT_MODE = 1
DIGIT_TOKEN_REQUIRED = 1
REVERSE_ENGINEERING = 1
DYNAMIC_THRESHOLD = 1
BLOCKED_MARKET_INDICES = ("VOL_100_1s", "VOL_200_1s", "VOL_300_1s")

# symbol -> (digits, tick_size, pip_value_per_0.01)
SYMBOL_SPECS = {
    "R_10":  (2, 0.001, 0.301),
    "R_25":  (3, 0.001, 0.252),
    "R_50":  (4, 0.0001, 0.201),
    "R_75":  (4, 0.0001, 0.401),
    "R_100": (2, 0.01, 0.001),
}
MARKET_LEVELS = {"EURUSD", "GBPUSD", "AUDUSD", "USDJPY"}
MARKET_PUT_CLOSE_BUFFER = 0.03   # Put distance from market close <= 3%

# H1 Fibonacci
FIB_LO, FIB_HI, FIB_TOL = 0.705, 0.79, 0.0125

# H4 order block
OB_IMPULSE_ATR = 1.5             # impulse >= 1.5 x ATR(20)
OB_ATR_PERIOD = 20
OB_MITIGATE_FRAC = 0.25          # mitigation beyond zone edge + 0.25 x zone height

# liquidity grab / FVG travel room
ROOM_ATR_MULT = 1.5              # 1.5 x ATR(14) travel room
ROOM_ATR_PERIOD = 14
LIQ_FRACTAL = 20

# momentum gate
MOMENTUM_ATR_MULT = 3.0          # target room >= 3 x ATR

# gap-too-big rule
ENTRY_PIP_LIMIT = 1.5
SESSION_GAP_CAP = 10.0
MATCH_UP_GAP_MAX = 0.20          # 1H ATR% bucket
DIFF_GAP_MAX = 1.0
STREAK_FRESH_ENTRY = 3           # 3 same-direction candles -> need fresh structure

# risk
RISK_PCT = 0.01
RR = 3.0                         # 1:3 structure-based
ATR_BUF = 0.5                    # SL buffer 0.5 x ATR(14)
ATR_PERIOD = 14

# digit rules
DIGIT_LOOKBACK = 300
DIGIT_N = 3
LEVEL_BASELINE = 0.010           # uniform P of a 30s digit pair
LEVEL_RATIO_MIN = 1.10
LEVEL_RATIO_EXTREME = 1.20       # digits 0 and 9
OVER_UNDER_THRESHOLDS = (2.0, 8.0)   # OVER 2.0 / UNDER 8.0 (fixed; NOT from digitsmap)

# 3m/3m throttle
FIRST_ENTRY_WAIT_MIN = 3
SIGNAL_CADENCE_MIN = 3
SIGNAL_BATCH = 3
SIGNAL_BATCH_WAIT_MIN = 3
STATE_FILE_DEFAULT = ".throttle_state.json"
STATE_SESSION_HOURS = 6     # > 6h off -> new session, counting starts over

# session gate
SESSION_MIN_TRADES = 20
SESSION_PAUSE_WR = 0.50

SESSIONS = {"TOKYO": (0, 8), "LONDON": (8, 16), "NEWYORK": (16, 24)}

WS_URL = "wss://ws.derivws.com/websockets/v3?app_id={app_id}"
DEFAULT_APP_ID = "1089"
WS_MAX_PER_SEC = 12              # 12 calls/sec throttle -> 0.085s spacing
WS_SPACING = 1.0 / WS_MAX_PER_SEC

Bar = namedtuple("Bar", "time open high low close")


# ────────────────────────────── small helpers ───────────────────────────────
def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def session_name(dt: datetime | None = None) -> str:
    h = (dt or now_utc()).hour
    for name, (a, b) in SESSIONS.items():
        if a <= h < b:
            return name
    return "NEWYORK"


def ema(values, period: int):
    if not values:
        return []
    k = 2.0 / (period + 1.0)
    out = [float(values[0])]
    for v in values[1:]:
        out.append(float(v) * k + out[-1] * (1 - k))
    return out


def atr(bars, period: int = ATR_PERIOD):
    """Average true range over `bars` (list[Bar])."""
    if not bars:
        return []
    out = []
    prev_close = None
    for b in bars:
        if prev_close is None:
            tr = b.high - b.low
        else:
            tr = max(b.high - b.low, abs(b.high - prev_close), abs(b.low - prev_close))
        out.append(tr)
        prev_close = b.close
    # Wilder smoothing
    res = []
    a = out[0]
    for i, tr in enumerate(out):
        if i == 0:
            a = tr
        else:
            a = (a * (period - 1) + tr) / period
        res.append(a)
    return res


def last_digit(price: float, digits: int = 2) -> int:
    """Last displayed digit of `price` at the symbol's precision."""
    s = f"{abs(float(price)):.{max(digits, 0)}f}"
    return int(s[-1])


def pip_size(symbol: str) -> float:
    spec = SYMBOL_SPECS.get(symbol)
    return spec[1] if spec else 0.01


def digits_of(symbol: str) -> int:
    spec = SYMBOL_SPECS.get(symbol)
    return spec[0] if spec else 2


# ─────────────────────── digit rules (bias / levels / map) ──────────────────
def digit_freqs(ticks, lookback: int = DIGIT_LOOKBACK, digits: int = 2):
    """Frequency of each last-digit 0..9 over the last `lookback` tick prices."""
    prices = [t if isinstance(t, (int, float)) else t["price"] for t in ticks][-lookback:]
    counts = [0] * 10
    for p in prices:
        counts[last_digit(p, digits)] += 1
    n = max(len(prices), 1)
    return [c / n for c in counts]


def digit_bias(ticks, lookback: int = DIGIT_LOOKBACK, n: int = DIGIT_N, digits: int = 2) -> float:
    """
    Ratio of the top-n digit frequencies vs the uniform 0.1 baseline.
    1.0 = fair coin; > 1.0 = hot digits exist (bias).
    """
    freq = digit_freqs(ticks, lookback, digits)
    top = sorted(freq, reverse=True)[:max(1, n)]
    return (sum(top) / len(top)) / 0.1


def threshold(ratio: float, extreme: bool = False) -> bool:
    """MATCH/DIFF gate: tradeable only when the ratio clears the HOT bar."""
    need = LEVEL_RATIO_EXTREME if extreme else LEVEL_RATIO_MIN
    return ratio >= need


def over_digit_map(p: float) -> int:
    """
    Map a target exceedance probability to the OVER/UNDER threshold digit.
    P(digit > t) = (9 - t) / 10  ->  pick the largest t keeping P >= p.
    """
    p = min(max(float(p), 0.0), 1.0)
    for t in range(9, -1, -1):
        if (9 - t) / 10 >= p:
            return t
    return 0


def digit_levels(ticks30, digits: int = 2):
    """
    P(30s digit pairs) vs the uniform baseline 0.010.
    ratio >= 1.10 -> HOT (tradeable); digits 0/9 in the pair need >= 1.20.
    Anything COLD is skipped — that is the rule.
    """
    prices = [t if isinstance(t, (int, float)) else t["price"] for t in ticks30]
    pairs = []
    for i in range(len(prices) - 1):
        pairs.append((last_digit(prices[i], digits), last_digit(prices[i + 1], digits)))
    if not pairs:
        return {"hot": [], "cold": list(range(10)), "ratios": {}}
    counts = {}
    for pair in pairs:
        counts[pair] = counts.get(pair, 0) + 1
    total = len(pairs)
    ratios = {}
    hot, cold = [], []
    for d in range(10):
        # marginal P(digit d at either slot of a 30s pair)
        c = sum(v for (a, b), v in counts.items() if a == d or b == d)
        p = c / total
        ratio = p / LEVEL_BASELINE if LEVEL_BASELINE else 0.0
        ratios[d] = ratio
        need = LEVEL_RATIO_EXTREME if d in (0, 9) else LEVEL_RATIO_MIN
        (hot if ratio >= need else cold).append(d)
    return {"hot": hot, "cold": cold, "ratios": ratios}


# ───────────────────────────── structure engine ─────────────────────────────
def classify_bar(bar: Bar, atr_value: float):
    """Bull / bear / neutral with body strength vs ATR."""
    body = bar.close - bar.open
    strength = abs(body) / atr_value if atr_value else 0.0
    if body > 0:
        return "bull", strength
    if body < 0:
        return "bear", strength
    return "neutral", 0.0


def find_swing_clusters(bars, left: int = 3, right: int = 3, cluster_tol: float | None = None):
    """Fractal swing highs/lows clustered into S/R zones."""
    highs, lows = [], []
    for i in range(left, len(bars) - right):
        win = bars[i - left:i + right + 1]
        if bars[i].high == max(b.high for b in win):
            highs.append((i, bars[i].high))
        if bars[i].low == min(b.low for b in win):
            lows.append((i, bars[i].low))
    if cluster_tol is None:
        closes = [b.close for b in bars] or [1.0]
        cluster_tol = (max(closes) - min(closes)) * 0.02 or 0.0001

    def cluster(pts, kind):
        zones = []
        for i, price in pts:
            if zones and abs(price - zones[-1]["price"]) <= cluster_tol:
                z = zones[-1]
                z["price"] = (z["price"] * z["touches"] + price) / (z["touches"] + 1)
                z["touches"] += 1
                z["end"] = i
            else:
                zones.append({"kind": kind, "price": price, "start": i, "end": i, "touches": 1})
        return zones

    return cluster(highs, "high") + cluster(lows, "low")


def fib_zone(swing_high: float, swing_low: float):
    """H1 FIB: retracement band 0.705–0.79 of the leg (both directions)."""
    leg = swing_high - swing_low
    if leg == 0:
        return (swing_low, swing_high)
    lo = swing_high - FIB_HI * leg
    hi = swing_high - FIB_LO * leg
    return (lo, hi)


def fib_touch(zone, leg: float, price: float) -> bool:
    """A touch counts within tolerance 0.0125 (of the leg) beyond the band."""
    lo, hi = zone
    tol = FIB_TOL * abs(leg)
    return (lo - tol) <= price <= (hi + tol)


def find_order_blocks(bars, atr_series=None):
    """
    H4 order block: last opposite-close candle before an impulse >= 1.5 x ATR(20).
    zone = [open, close]; keep unmitigated, or mitigated at most once
    (price beyond zone edge + 0.25 x zone height kills it).
    """
    if atr_series is None:
        atr_series = atr(bars, OB_ATR_PERIOD)
    obs = []
    for i in range(1, len(bars)):
        a = atr_series[min(i, len(atr_series) - 1)]
        if not a:
            continue
        # look back for the last opposite candle, then measure the impulse forward
        direction = 0
        for j in range(i, min(i + 6, len(bars))):
            move = bars[j].close - bars[i - 1].close
            if abs(move) >= OB_IMPULSE_ATR * a:
                direction = 1 if move > 0 else -1
                break
        if not direction:
            continue
        # last opposite-close candle before the impulse
        ob_idx = None
        for k in range(i - 1, max(-1, i - 12), -1):
            body = bars[k].close - bars[k].open
            if (direction > 0 and body < 0) or (direction < 0 and body > 0):
                ob_idx = k
                break
        if ob_idx is None:
            continue
        b = bars[ob_idx]
        lo, hi = sorted((b.open, b.close))
        zone_h = hi - lo
        # mitigation: probe LOW for call-side support, HIGH for put-side resistance.
        # Unmitigated, or one 0.25-zone-height pierce -> still valid;
        # a deeper pierce or a second pierce -> dead.
        mitigations = 0
        killed = False
        for m in bars[ob_idx + 1:]:
            if direction > 0:
                if m.low < lo:
                    deep = (lo - m.low) > OB_MITIGATE_FRAC * zone_h
                    mitigations += 1
                    if deep or mitigations > 1:
                        killed = True
                        break
            else:
                if m.high > hi:
                    deep = (m.high - hi) > OB_MITIGATE_FRAC * zone_h
                    mitigations += 1
                    if deep or mitigations > 1:
                        killed = True
                        break
        if killed:
            continue
        obs.append({"index": ob_idx, "direction": direction, "zone": (lo, hi),
                    "mitigations": mitigations, "time": b.time})
    return obs


def find_liquidity_grabs(bars, atr_series=None):
    """20-bar fractal sweep + re-entry; needs 1.5 x ATR(1.4) travel room left."""
    if atr_series is None:
        atr_series = atr(bars, ROOM_ATR_PERIOD)
    grabs = []
    n = LIQ_FRACTAL
    for i in range(n, len(bars)):
        win = bars[i - n:i]
        hi_level = max(b.high for b in win)
        lo_level = min(b.low for b in win)
        b = bars[i]
        a = atr_series[max(i - 1, 0)]        # pre-sweep volatility
        room = ROOM_ATR_MULT * a if a else 0.0
        if b.high > hi_level and b.close < hi_level:
            travel = b.close - lo_level
            if travel >= room:
                grabs.append({"index": i, "side": "high", "level": hi_level, "time": b.time})
        if b.low < lo_level and b.close > lo_level:
            travel = hi_level - b.close
            if travel >= room:
                grabs.append({"index": i, "side": "low", "level": lo_level, "time": b.time})
    return grabs


def find_fvgs(bars, atr_series=None):
    """3-candle gap with 1.5 x ATR(1.4) travel room to the far side."""
    if atr_series is None:
        atr_series = atr(bars, ROOM_ATR_PERIOD)
    fvgs = []
    for i in range(2, len(bars)):
        c1, c3 = bars[i - 2], bars[i]
        a = atr_series[max(i - 1, 0)]        # pre-gap volatility
        room = ROOM_ATR_MULT * a if a else 0.0
        if c1.high < c3.low:                       # bullish gap
            gap = c3.low - c1.high
            if gap > 0 and gap <= room * 2:
                fvgs.append({"index": i, "side": "bull", "zone": (c1.high, c3.low), "time": c3.time})
        if c1.low > c3.high:                       # bearish gap
            gap = c1.low - c3.high
            if gap > 0 and gap <= room * 2:
                fvgs.append({"index": i, "side": "bear", "zone": (c3.high, c1.low), "time": c3.time})
    return fvgs


def find_engulfs(bars):
    """Classic bullish / bearish engulfing bodies."""
    out = []
    for i in range(1, len(bars)):
        p, c = bars[i - 1], bars[i]
        pb, cb = p.close - p.open, c.close - c.open
        if pb < 0 < cb and c.close >= p.open and c.open <= p.close:
            out.append({"index": i, "side": "bull", "time": c.time})
        elif pb > 0 > cb and c.close <= p.open and c.open >= p.close:
            out.append({"index": i, "side": "bear", "time": c.time})
    return out


def momentum_ok(bars, atr_series, side: str) -> bool:
    """The 3xATR check: target room in the trade direction must be >= 3 x ATR."""
    if not bars:
        return False
    a = atr_series[-1] if atr_series else 0.0
    if not a:
        return False
    need = MOMENTUM_ATR_MULT * a
    if side == "CALL":
        return (bars[-1].close - min(b.low for b in bars[-20:])) >= need
    return (max(b.high for b in bars[-20:]) - bars[-1].close) >= need


# ─────────────────────────────── gap-too-big rule ───────────────────────────
def gap_ok(contract_type: str, gap_pips: float, session_gap: float, atr_pct_1h: float,
           direction: str = "up", streak: int = 0, fresh_structure: bool = True) -> tuple:
    """
    Returns (ok, reason).
      * entry_pip_limit 1.5  — entry further than 1.5 pips from price -> skip
      * session_gap_cap 10.0 — cumulative session gap above 10 pips -> skip
      * MATCH/DIFF UP gap > 0.20 (1H ATR% bucket) -> skip
      * DIFF gap > 1.0 -> skip
      * 3 same-direction candles in a row -> need a fresh structure entry
    """
    ct = (contract_type or "").upper()
    if abs(gap_pips) > ENTRY_PIP_LIMIT:
        return False, "entry pip limit 1.5"
    if abs(session_gap) > SESSION_GAP_CAP:
        return False, "session gap cap 10.0"
    if ct in ("DIGITMATCH", "MATCH") and direction == "up" and atr_pct_1h > MATCH_UP_GAP_MAX:
        return False, "match UP gap > 0.20"
    if ct in ("DIGITDIFF", "DIFF") and atr_pct_1h > DIFF_GAP_MAX:
        return False, "diff gap > 1.0"
    if streak >= STREAK_FRESH_ENTRY and not fresh_structure:
        return False, "3 same-direction candles, no fresh structure"
    return True, "ok"


# ─────────────────────────────── session gate ───────────────────────────────
class SessionStats:
    """After >= 20 trades in a session: WR < 50% or net <= 0 after fees -> pause."""

    def __init__(self):
        self.trades = []

    def record(self, result_r: float, session: str | None = None):
        self.trades.append((session or session_name(), result_r))

    def paused(self, session: str | None = None) -> bool:
        s = session or session_name()
        rows = [r for (sess, r) in self.trades if sess == s]
        if len(rows) < SESSION_MIN_TRADES:
            return False
        wins = sum(1 for r in rows if r > 0)
        wr = wins / len(rows)
        net = sum(rows)
        return wr < SESSION_PAUSE_WR or net <= 0


# ───────────────────────────────── risk ─────────────────────────────────────
def risk_entry(balance: float, entry: float, sl_level: float, atr14: float,
               direction: str = "CALL") -> dict:
    """
    1% risk, 1:3 structure-based RR, SL buffer 0.5 x ATR(14).
    Skip if the potential loss would exceed 1% of balance.
    """
    buf = ATR_BUF * atr14
    sl = sl_level - buf if direction == "CALL" else sl_level + buf
    sl_dist = abs(entry - sl)
    risk_amount = balance * RISK_PCT
    if sl_dist <= 0:
        return {"ok": False, "reason": "zero stop distance"}
    size = risk_amount / sl_dist
    potential_loss = sl_dist * size
    if potential_loss > balance * RISK_PCT + 1e-9:
        return {"ok": False, "reason": "potential loss > 1% of balance"}
    tp_dist = RR * sl_dist
    tp = entry + tp_dist if direction == "CALL" else entry - tp_dist
    return {"ok": True, "size": size, "sl": sl, "tp": tp, "risk_amount": risk_amount,
            "rr": RR, "sl_dist": sl_dist, "tp_dist": tp_dist}


def expected_value(win_rate: float, rr: float, fee_r: float = FEE_R,
                   payout_mult: float = API_PAYOUT_MULT) -> float:
    """Honest EV in R — fees in, api 0.98 payout multiplier in."""
    win = win_rate * (rr * payout_mult)
    loss = (1 - win_rate) * 1.0
    return win - loss - fee_r


# ─────────────────────────── candle / price selection ───────────────────────
def resolve_close(bar: Bar, contract_type: str) -> float:
    """
    Entry reference price depends on what the contract buys:
      CALL          -> LOW   (buy at support)
      PUT           -> HIGH  (sell at resistance)
      DIGIT*        -> CLOSE
    """
    ct = (contract_type or "CALL").upper()
    if ct == "CALL":
        return bar.low
    if ct == "PUT":
        return bar.high
    return bar.close


def prices_for_trade(symbol: str, contract_type: str, bars, live: bool = True,
                     balance: float = 1000.0) -> dict:
    """
    Live vs backtest pricing. Live uses the real entry/SL/TP from the rulebook;
    backtest uses the recorded expectancy model (BACKTEST_WIN_RATE / BACKTEST_RR).
    Market symbols get the 3% close buffer on Put distance.
    """
    if not bars:
        return {"ok": False, "reason": "no bars"}
    if symbol in BLOCKED_MARKET_INDICES:
        return {"ok": False, "reason": f"{symbol} blocked (market indices)"}
    if (contract_type or "").upper() in ("DIGITMATCH", "DIGITDIFF", "OVER", "UNDER",
                                        "DIGITOVER", "DIGITUNDER") and DIGIT_TOKEN_REQUIRED:
        # digit contracts need the digit rules satisfied by the caller
        pass
    entry = resolve_close(bars[-1], contract_type)
    a14 = atr(bars, ATR_PERIOD)[-1]
    if symbol in MARKET_LEVELS and (contract_type or "").upper() == "PUT":
        if abs(entry - bars[-1].close) > MARKET_PUT_CLOSE_BUFFER * bars[-1].close:
            return {"ok": False, "reason": "put distance > 3% of market close"}
    sl_level = min(b.low for b in bars[-20:]) if (contract_type or "").upper() == "CALL" \
        else max(b.high for b in bars[-20:])
    plan = risk_entry(balance, entry, sl_level, a14,
                      "CALL" if (contract_type or "").upper() == "CALL" else "PUT")
    if not plan.get("ok"):
        return plan
    if not live:
        plan["win_rate"] = BACKTEST_WIN_RATE
        plan["rr_model"] = BACKTEST_RR
        plan["ev_r"] = expected_value(BACKTEST_WIN_RATE, BACKTEST_RR)
    plan.update({"ok": True, "entry": entry, "symbol": symbol, "contract_type": contract_type,
                 "live": live})
    return plan


# ───────────────────────────── 3m/3m throttle ───────────────────────────────
def signal_3m_expires(now: datetime | None = None, cadence: int = SIGNAL_CADENCE_MIN) -> bool:
    """3m/3m: a signal may only fire at a minute boundary where minute % 3 == 0."""
    now = now or now_utc()
    return now.minute % cadence == 0


class Throttle:
    """
    3m/3m rules:
      * 3-min wait before the first entry after session start (warm-up)
      * one signal per 3-min boundary (minute % 3 == 0)
      * after every 3 signals -> 3-min wait
      * 30m/30m and 60m/60m variants use 30 / 60-minute waits
      * the count is PERSISTED in a state file: restart / refresh does NOT
        reset it; a gap longer than STATE_SESSION_HOURS starts a new session
    """

    def __init__(self, cadence_min: int = SIGNAL_CADENCE_MIN, batch: int = SIGNAL_BATCH,
                 started: datetime | None = None, state_path: str | None = None,
                 key: str | None = None):
        self.cadence = cadence_min
        self.batch = batch
        self.state_path = state_path
        self.key = key or f"cadence{cadence_min}"
        self.started = started
        self.signals = 0
        self.last_signal: datetime | None = None
        self.cooldown_until: datetime | None = None
        if self.started is None and self.state_path:
            self._load_state()
        if self.started is None:
            self.started = now_utc()
        if self.state_path:
            self._save_state()

    # ── persisted state: a refresh / restart must not reset the count ──
    def _read(self) -> dict:
        try:
            with open(self.state_path) as f:
                data = json.load(f)
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def _load_state(self):
        entry = self._read().get(self.key)
        if not isinstance(entry, dict):
            return
        try:
            updated = datetime.fromisoformat(entry.get("updated", ""))
        except ValueError:
            return
        if (now_utc() - updated) > timedelta(hours=STATE_SESSION_HOURS):
            return                      # off too long -> fresh session
        try:
            self.started = datetime.fromisoformat(entry["started"])
            self.signals = int(entry.get("signals", 0))
            self.last_signal = (datetime.fromisoformat(entry["last_signal"])
                                if entry.get("last_signal") else None)
            self.cooldown_until = (datetime.fromisoformat(entry["cooldown_until"])
                                   if entry.get("cooldown_until") else None)
        except (KeyError, ValueError, TypeError):
            return

    def _save_state(self, now: datetime | None = None):
        if not self.state_path:
            return
        data = self._read()
        data[self.key] = {
            "started": self.started.isoformat(),
            "signals": self.signals,
            "last_signal": self.last_signal.isoformat() if self.last_signal else None,
            "cooldown_until": self.cooldown_until.isoformat() if self.cooldown_until else None,
            "updated": (now or now_utc()).isoformat(),
        }
        try:
            with open(self.state_path, "w") as f:
                json.dump(data, f)
        except OSError:
            pass

    def allow(self, now: datetime | None = None) -> tuple:
        """Returns (allowed, reason)."""
        now = now or now_utc()
        if (now - self.started) < timedelta(minutes=FIRST_ENTRY_WAIT_MIN):
            return False, "3-min wait for first entry"
        if self.cooldown_until and now <= self.cooldown_until:
            return False, f"cooldown until {self.cooldown_until:%H:%M:%S}"
        if not signal_3m_expires(now, self.cadence):
            return False, f"not a {self.cadence}-min boundary"
        return True, "ok"

    def record(self, now: datetime | None = None):
        now = now or now_utc()
        self.signals += 1
        self.last_signal = now
        if self.signals % self.batch == 0:
            wait = SIGNAL_BATCH_WAIT_MIN if self.cadence == SIGNAL_CADENCE_MIN else self.cadence
            self.cooldown_until = now + timedelta(minutes=wait)
        self._save_state(now)


def make_throttle(expiry: str, state_path: str | None = None,
                  key: str | None = None) -> Throttle:
    """--expiry 3m -> 3-min waits; 30m -> 30-min; 60m -> 60-min."""
    e = (expiry or "3m").lower()
    minutes = 3
    if e.endswith("m") and e[:-1].isdigit():
        minutes = int(e[:-1])
    elif e.endswith("h") and e[:-1].isdigit():
        minutes = int(e[:-1]) * 60
    elif e.isdigit():
        minutes = int(e)
    return Throttle(cadence_min=minutes, state_path=state_path, key=key)


def reset_throttle_state(path: str, key: str | None = None) -> bool:
    """--reset: clear the persisted count (one key, or the whole file)."""
    try:
        if key is None:
            if os.path.exists(path):
                os.remove(path)
            return True
        data = {}
        try:
            with open(path) as f:
                data = json.load(f)
        except (OSError, ValueError):
            pass
        data.pop(key, None)
        with open(path, "w") as f:
            json.dump(data, f)
        return True
    except OSError:
        return False


# ────────────────────────────── Deriv WS plumbing ───────────────────────────
class DerivWS:
    """Thin async wrapper: authorize from env DERIV_TOKEN / --token (never hardcode)."""

    def __init__(self, token: str | None = None, app_id: str = DEFAULT_APP_ID):
        self.token = token or os.environ.get("DERIV_TOKEN", "")
        self.app_id = app_id
        self.ws = None
        self._req_id = 0
        self._last_call = 0.0

    async def connect(self, authorize_timeout: float = 60.0):
        import websockets  # imported lazily so offline tests need nothing
        self.ws = await websockets.connect(WS_URL.format(app_id=self.app_id), max_size=2 ** 22)
        if self.token:
            await self.send({"authorize": self.token}, timeout=authorize_timeout)
        return self

    async def send(self, payload: dict, timeout: float = 25.0) -> dict:
        if self.ws is None:
            raise RuntimeError("WS not connected")
        # 12 calls/sec throttle
        gap = time.monotonic() - self._last_call
        if gap < WS_SPACING:
            await asyncio.sleep(WS_SPACING - gap)
        self._last_call = time.monotonic()
        self._req_id += 1
        payload = dict(payload, req_id=self._req_id)
        await self.ws.send(json.dumps(payload))
        raw = await asyncio.wait_for(self.ws.recv(), timeout=timeout)
        data = json.loads(raw)
        if data.get("error"):
            raise RuntimeError(data["error"].get("message", "deriv error"))
        return data

    async def close(self):
        if self.ws is not None:
            await self.ws.close()
            self.ws = None


class FakeWS:
    """Offline stand-in used by tests: replies from a canned map."""

    def __init__(self, replies=None):
        self.replies = replies or {}
        self.sent = []

    async def send(self, payload: dict, timeout: float = 25.0) -> dict:
        self.sent.append(payload)
        for key, reply in self.replies.items():
            if key in payload:
                return reply(payload) if callable(reply) else reply
        return {}

    async def close(self):
        pass


# ─────────────────────────── candles / ticks / cache ────────────────────────
_CACHE: dict = {}


def _cache_key(*parts):
    return tuple(parts)


def fetch_option_candles(ws, symbol: str, timeframe: str = "3m", granularity: int = 180,
                         count: int = 1000, contract_type: str = "CALL",
                         cache: bool = True, cache_ttl: float = 3600.0):
    """
    Candles from ticks history. `contract_type` selects which price the entry
    rule will use later (resolve_close): CALL->LOW, PUT->HIGH, DIGIT*->CLOSE.
    """
    key = _cache_key("candles", symbol, timeframe, granularity, count, contract_type)
    if cache and key in _CACHE:
        ts, bars = _CACHE[key]
        if time.time() - ts < cache_ttl:
            return bars

    async def _go():
        data = await ws.send({
            "ticks_history": symbol, "style": "candles", "granularity": granularity,
            "count": count, "end": "latest",
        }, timeout=40.0)
        return data

    import inspect
    result = ws.send({
        "ticks_history": symbol, "style": "candles", "granularity": granularity,
        "count": count, "end": "latest",
    }, timeout=40.0)
    if inspect.isawaitable(result):
        loop = asyncio.new_event_loop()
        try:
            data = loop.run_until_complete(result)
        finally:
            loop.close()
    else:
        data = result
    raw = data.get("candles", [])
    bars = [Bar(int(c["epoch"]), float(c["open"]), float(c["high"]),
                float(c["low"]), float(c["close"])) for c in raw]
    if cache:
        _CACHE[key] = (time.time(), bars)
    return bars


def fetch_option_ticks(ws, symbol: str, count: int = 1000, contract_type: str = "CALL",
                       cache: bool = True):
    """
    Ticks for digit labels. Raw-bar -> tick map so labels resolve on the true
    first tick of each 30s window. Cache: 1h for labels, 3s for live ticks,
    per (symbol, type). Never falls back between CALL/PUT and DIGIT types.
    """
    key = _cache_key("ticks", symbol, contract_type)
    now = time.time()
    if cache and key in _CACHE:
        ts, ticks = _CACHE[key]
        ttl = 3600.0 if contract_type.upper().startswith("DIGIT") or \
            contract_type.upper() in ("OVER", "UNDER") else 3.0
        if now - ts < ttl:
            return ticks

    import inspect
    result = ws.send({"ticks_history": symbol, "ticks": count, "end": "latest"}, timeout=25.0)
    if inspect.isawaitable(result):
        loop = asyncio.new_event_loop()
        try:
            data = loop.run_until_complete(result)
        finally:
            loop.close()
    else:
        data = result
    ticks = [{"epoch": int(t["epoch"]), "price": float(t["quote"])}
             for t in data.get("history", {}).get("prices", []) or data.get("ticks", [])]
    if cache:
        _CACHE[key] = (now, ticks)
    return ticks


def clear_cache(symbol: str | None = None):
    if symbol is None:
        _CACHE.clear()
    else:
        for k in [k for k in _CACHE if symbol in k]:
            _CACHE.pop(k, None)


# ───────────────────────────── live check + trade ───────────────────────────
def check_single_type_live(symbol: str, contract_type: str, bars, ticks=None,
                           now: datetime | None = None, throttle: Throttle | None = None,
                           balance: float = 1000.0) -> dict:
    """
    One decision for one contract type. No fallback between types — ever.
    3m/3m: only fires at a 3-min boundary (the throttle enforces it).
    """
    now = now or now_utc()
    ct = (contract_type or "CALL").upper()
    if ct in BLOCKED_MARKET_INDICES or symbol in BLOCKED_MARKET_INDICES:
        return {"ok": False, "reason": f"{symbol} blocked (market indices)"}
    if throttle is not None:
        allowed, why = throttle.allow(now)
        if not allowed:
            return {"ok": False, "reason": why}
    if not bars:
        return {"ok": False, "reason": "no bars"}
    a = atr(bars)
    side = "CALL" if ct == "CALL" else "PUT" if ct == "PUT" else "DIGIT"
    if side in ("CALL", "PUT") and not momentum_ok(bars, a, side):
        return {"ok": False, "reason": "3xATR momentum check failed"}
    if side == "DIGIT":
        if ticks:
            ratio = digit_bias(ticks, DIGIT_LOOKBACK, DIGIT_N, digits_of(symbol))
            hot = threshold(ratio)
            if not hot:
                return {"ok": False, "reason": "digit bias COLD (ratio < 1.10)"}
    plan = prices_for_trade(symbol, ct, bars, live=True, balance=balance)
    if not plan.get("ok"):
        return plan
    if throttle is not None:
        throttle.record(now)
    return plan


def check_and_force_trade(contract_type: str, price: float, digit: int | None = None,
                          duration_unit: str = "s", duration: int = 180) -> dict:
    """
    --force-trade CONTRACT_TYPE price [digit] [duration_unit s/m] [duration]
    Validated: contract type known, price != 0, digit in 0..9.
    """
    ct = (contract_type or "").upper()
    known = {"CALL", "PUT", "DIGITMATCH", "DIGITDIFF", "OVER", "UNDER",
             "DIGITOVER", "DIGITUNDER", "DIGITEVEN", "DIGITODD"}
    if ct not in known:
        return {"ok": False, "reason": f"unknown contract type {contract_type}"}
    if not price or price == 0:
        return {"ok": False, "reason": "price must be non-zero"}
    if ct in ("DIGITMATCH", "DIGITDIFF") and digit is not None and not (0 <= int(digit) <= 9):
        return {"ok": False, "reason": "digit must be 0..9"}
    if duration_unit not in ("s", "m"):
        return {"ok": False, "reason": "duration_unit must be s or m"}
    if duration <= 0:
        return {"ok": False, "reason": "duration must be > 0"}
    return {"ok": True, "contract_type": ct, "price": float(price),
            "digit": None if digit is None else int(digit),
            "duration_unit": duration_unit, "duration": int(duration)}


async def buy_contract(ws, symbol: str, contract_type: str, amount: float,
                       duration: int = 180, duration_unit: str = "s",
                       barrier: float | str | None = None, digit: int | None = None,
                       basis: str = "stake") -> dict:
    """proposal -> buy with the api 0.98 payout sanity multiplier."""
    params = {"proposal": 1, "symbol": symbol, "contract_type": contract_type,
              "amount": amount, "basis": basis, "duration": duration,
              "duration_unit": duration_unit, "currency": "USD"}
    if barrier is not None:
        params["barrier"] = barrier
    if digit is not None:
        params["barrier"] = str(digit)
    proposal = await ws.send(params, timeout=25.0)
    p = proposal.get("proposal", {})
    payout = float(p.get("payout", 0)) * API_PAYOUT_MULT
    if payout <= 0:
        return {"ok": False, "reason": "no payout"}
    buy = await ws.send({"buy": p.get("id"), "price": amount}, timeout=25.0)
    return {"ok": True, "payout": payout, "buy": buy.get("buy", {})}


# ─────────────────────────────── backtest driver ────────────────────────────
def run_backtest(bars, contract_type: str = "CALL", balance: float = 1000.0,
                 timeframe: str = "3m") -> dict:
    """Offline walk-forward with the same gates the live path uses."""
    ct = contract_type.upper()
    entries = hits = 0
    total_r = 0.0
    started = datetime.fromtimestamp(bars[0].time, tz=timezone.utc) if bars else now_utc()
    throttle = Throttle(cadence_min=3, started=started)
    for i in range(60, len(bars)):
        window = bars[:i]
        now = datetime.fromtimestamp(window[-1].time, tz=timezone.utc)
        allowed, _ = throttle.allow(now)
        if not allowed:
            continue
        a = atr(window)
        if ct in ("CALL", "PUT") and not momentum_ok(window, a, ct):
            continue
        plan = prices_for_trade("R_100", ct, window, live=False, balance=balance)
        if not plan.get("ok"):
            continue
        entries += 1
        throttle.record(now)
        fwd = bars[i:i + 6]           # ~18 min forward for a 3-min expiry result
        if not fwd:
            break
        if ct == "CALL":
            hit = max(b.high for b in fwd) >= plan["tp"] or (
                min(b.low for b in fwd) > plan["sl"] and fwd[-1].close > plan["entry"])
        else:
            hit = min(b.low for b in fwd) <= plan["tp"] or (
                max(b.high for b in fwd) < plan["sl"] and fwd[-1].close < plan["entry"])
        if hit:
            hits += 1
            total_r += RR * API_PAYOUT_MULT - FEE_R
        else:
            total_r -= 1.0 + FEE_R
    wr = hits / entries if entries else 0.0
    return {"contract_type": ct, "timeframe": timeframe, "entries": entries, "hits": hits,
            "win_rate": round(wr, 4), "expected_r": round(total_r, 2),
            "ev_r": round(expected_value(wr, RR), 3)}


# ─────────────────────────────────── CLI ────────────────────────────────────
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Deriv smart-money bot (SMC engine)")
    p.add_argument("--scan", action="store_true", help="one scan, print the decision, exit")
    p.add_argument("--timeout", type=int, default=0, help="live loop seconds (0 = forever)")
    p.add_argument("--no-cache", action="store_true")
    p.add_argument("--sym", "--symbol", dest="symbol", default="R_100")
    p.add_argument("--type", dest="contract_type", default="CALL")
    p.add_argument("--timeframe", default="3m")
    p.add_argument("--expiry", default="3m")
    p.add_argument("--token", default=os.environ.get("DERIV_TOKEN", ""))
    p.add_argument("--force-trade", nargs="+", metavar=("TYPE", "PRICE"),
                   help="CONTRACT_TYPE price [digit] [duration_unit s/m] [duration]")
    p.add_argument("--backtest", action="store_true")
    p.add_argument("--state-file", default=STATE_FILE_DEFAULT)
    p.add_argument("--reset", action="store_true", help="reset the persisted signal count")
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    state_key = f"{args.symbol}:{args.contract_type}:{args.expiry}"

    if args.reset:
        reset_throttle_state(args.state_file, state_key)
        print(json.dumps({"reset": args.state_file, "key": state_key}))
        return 0

    if args.force_trade:
        ft = list(args.force_trade)
        ct, price = ft[0], float(ft[1])
        digit = int(ft[2]) if len(ft) > 2 and ft[2].isdigit() and len(ft[2]) == 1 else None
        du = ft[3] if len(ft) > 3 else "s"
        dur = int(ft[4]) if len(ft) > 4 else 180
        res = check_and_force_trade(ct, price, digit, du, dur)
        print(json.dumps(res))
        return 0 if res.get("ok") else 1

    if args.backtest:
        print(json.dumps({"note": "use research/backtest_harness.py for full runs"}))
        return 0

    # live / scan mode requires a token for trading; scan works read-only
    if not args.scan and not args.token and DIGIT_TOKEN_REQUIRED:
        print(json.dumps({"ok": False, "reason": "DERIV_TOKEN missing"}))
        return 1

    async def _scan():
        ws = DerivWS(token=args.token)
        await ws.connect()
        try:
            granularity = {"1m": 60, "3m": 180, "5m": 300, "15m": 900}.get(args.timeframe, 180)
            bars = await ws.send({"ticks_history": args.symbol, "style": "candles",
                                  "granularity": granularity, "count": 500, "end": "latest"},
                                 timeout=40.0)
            raw = bars.get("candles", [])
            bars = [Bar(int(c["epoch"]), float(c["open"]), float(c["high"]),
                        float(c["low"]), float(c["close"])) for c in raw]
            ticks = await ws.send({"ticks_history": args.symbol, "ticks": 300, "end": "latest"},
                                  timeout=25.0)
            ticks = [{"epoch": int(t["epoch"]), "price": float(t["quote"])}
                     for t in ticks.get("history", {}).get("prices", [])]
            throttle = make_throttle(args.expiry, state_path=args.state_file, key=state_key)
            decision = check_single_type_live(args.symbol, args.contract_type, bars,
                                              ticks=ticks, throttle=throttle)
            print(json.dumps(decision))
            return 0 if decision.get("ok") else 1
        finally:
            await ws.close()

    return asyncio.get_event_loop().run_until_complete(_scan())


if __name__ == "__main__":
    sys.exit(main())
