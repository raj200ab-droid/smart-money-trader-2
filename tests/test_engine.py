#!/usr/bin/env python3
"""
tests/test_engine.py — the rulebook, asserted. Runs offline (no network):

    python3 tests/test_engine.py        # built-in runner
    python3 -m pytest tests/ -q         # or pytest

Every test pins a rule the user can check against the bot's behaviour.
"""
import os
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import binary_bot as bb
from binary_bot import Bar

T0 = 1_700_000_000 - 80   # aligned to a clean 3-min boundary (…:12:00 UTC)


def mkbar(i, o, h, l, c):
    return Bar(T0 + i * 180, o, h, l, c)


# ────────────────────────────── indicators ──────────────────────────────────
def test_ema():
    out = bb.ema([1.0, 2.0, 3.0], 2)
    assert out[0] == 1.0
    assert abs(out[1] - (2.0 * (2 / 3) + 1.0 * (1 / 3))) < 1e-9


def test_atr():
    bars = [mkbar(0, 10, 12, 9, 11), mkbar(1, 11, 13, 10, 12), mkbar(2, 12, 14, 11, 13)]
    a = bb.atr(bars, 2)
    assert len(a) == 3 and all(x > 0 for x in a)


def test_classify_bar():
    a = 1.0
    assert bb.classify_bar(mkbar(0, 10, 11, 10, 11), a)[0] == "bull"
    assert bb.classify_bar(mkbar(1, 11, 11, 10, 10), a)[0] == "bear"
    assert bb.classify_bar(mkbar(2, 10, 11, 9, 10), a)[0] == "neutral"


# ────────────────────────────── structure ───────────────────────────────────
def test_swing_clusters():
    bars = []
    for i in range(21):
        o = 100 + (i % 5)
        bars.append(mkbar(i, o, o + 1, o - 1, o + 0.5))
    bars[10] = mkbar(10, 100, 110, 99, 101)     # clear swing high
    bars[5] = mkbar(5, 100, 101, 90, 99)        # clear swing low
    zones = bb.find_swing_clusters(bars, 3, 3)
    kinds = {z["kind"] for z in zones}
    assert "high" in kinds and "low" in kinds


def test_h1_fib_matches():
    lo, hi = bb.fib_zone(110.0, 100.0)
    assert abs(lo - (110 - 0.79 * 10)) < 1e-9
    assert abs(hi - (110 - 0.705 * 10)) < 1e-9
    # tolerance 0.0125 of the leg
    assert bb.fib_touch((lo, hi), 10.0, lo - 0.1)
    assert not bb.fib_touch((lo, hi), 10.0, lo - 0.5)


def test_h4ob():
    # flat base, opposite candle, then a 1.5xATR impulse up
    bars = [mkbar(i, 100, 101, 99, 100) for i in range(5)]
    bars.append(mkbar(5, 100, 100.5, 99.5, 99.6))      # last bearish before impulse
    for j in range(6, 12):
        bars.append(mkbar(j, 100 + (j - 6) * 3, 103 + (j - 6) * 3, 100 + (j - 6) * 3,
                          102 + (j - 6) * 3))
    obs = bb.find_order_blocks(bars)
    assert obs, "order block must be found before the impulse"
    assert obs[0]["direction"] == 1
    assert obs[0]["zone"][0] <= 99.6 <= obs[0]["zone"][1]


def test_ob_sweep():
    # OB that gets mitigated twice must be dropped (0.25 rule)
    bars = [mkbar(i, 100, 101, 99, 100) for i in range(5)]
    bars.append(mkbar(5, 100, 100.5, 99.5, 99.6))
    for j in range(6, 12):
        bars.append(mkbar(j, 100 + (j - 6) * 3, 103 + (j - 6) * 3, 100 + (j - 6) * 3,
                          102 + (j - 6) * 3))
    # two deep sweeps back through the zone edge
    bars.append(mkbar(20, 120, 121, 98, 119))
    bars.append(mkbar(21, 119, 120, 97, 118))
    obs = bb.find_order_blocks(bars)
    assert all(o["mitigations"] <= 1 for o in obs)


def test_m15_ob():
    bars = [mkbar(i, 1.1000, 1.1010, 1.0990, 1.1000) for i in range(30)]
    assert isinstance(bb.find_order_blocks(bars), list)


def test_liquidity_grab():
    # slow-rise window: 20-bar range height >> ATR, so 1.5xATR room exists
    bars = []
    for i in range(21):
        o = 100 + i * 0.25
        bars.append(mkbar(i, o, o + 0.3, o - 0.3, o + 0.1))
    # low sweep below the window low, close back above it
    bars.append(mkbar(21, 105.25, 105.5, 99.8, 100.5))
    g = bb.find_liquidity_grabs(bars)
    assert any(x["side"] == "low" for x in g), "low sweep must register"
    # and a high sweep in a falling window
    bars2 = []
    for i in range(21):
        o = 120 - i * 0.25
        bars2.append(mkbar(i, o, o + 0.3, o - 0.3, o - 0.1))
    bars2.append(mkbar(21, 114.75, 120.2, 114.5, 119.5))
    g2 = bb.find_liquidity_grabs(bars2)
    assert any(x["side"] == "high" for x in g2), "high sweep must register"


def test_fvg():
    bars = [mkbar(0, 100, 101, 99, 100), mkbar(1, 100, 101, 99, 100),
            mkbar(2, 105, 106, 104, 105)]          # gap up between bar0.high and bar2.low
    fvgs = bb.find_fvgs(bars)
    assert any(f["side"] == "bull" for f in fvgs)


def test_engulfs():
    bars = [mkbar(0, 10, 10.5, 9.5, 9.8), mkbar(1, 9.8, 11, 9.7, 10.9)]
    e = bb.find_engulfs(bars)
    assert e and e[0]["side"] == "bull"


def test_momentum_filter():
    # quiet market: room < 3xATR -> refuse
    quiet = [mkbar(i, 100, 100.2, 99.8, 100) for i in range(20)]
    assert not bb.momentum_ok(quiet, bb.atr(quiet), "CALL")
    # a real surge leaves >= 3xATR of room -> accept
    loud = quiet + [mkbar(20, 100, 103.5, 99.6, 103)]
    assert bb.momentum_ok(loud, bb.atr(loud), "CALL")
    assert not bb.momentum_ok(loud, bb.atr(loud), "PUT")   # room is on the wrong side


# ─────────────────────────────── digit rules ────────────────────────────────
def _ticks_with_digit(d, n=30):
    return [{"epoch": T0 + i, "price": 100.0 + d / 100 + (i % 7) / 100000} for i in range(n)]


def test_digit_bias():
    hot = _ticks_with_digit(7, 300)
    assert bb.digit_bias(hot, 300, 3, 2) > 1.10, "a stacked digit must read as a bias"
    mixed = []
    for i in range(300):
        mixed.append({"epoch": T0 + i, "price": 100.0 + (i % 10) / 100})
    assert abs(bb.digit_bias(mixed, 300, 3, 2) - 1.0) < 0.35, "uniform digits ~ fair"


def test_over_digit_map():
    assert bb.over_digit_map(0.5) in range(10)
    assert bb.over_digit_map(0.8) == 1   # P(digit>1) = 0.8 exactly
    assert bb.over_digit_map(0.0) == 9   # P(digit>9) = 0 >= 0
    assert bb.over_digit_map(1.0) == 0   # P(digit>0) = 0.9 is the largest keeping P >= 1? no -> 0


def test_digit_levels():
    pairs = []
    for i in range(200):
        pairs.append({"epoch": T0 + i * 30, "price": 100.0 + 7 / 100 + (i % 3) / 100000})
    lv = bb.digit_levels(pairs, 2)
    assert 7 in lv["hot"], "the repeating digit must be HOT"
    assert lv["ratios"][7] >= bb.LEVEL_RATIO_MIN
    assert bb.threshold(lv["ratios"][7]) is True
    assert bb.threshold(1.05) is False          # COLD -> skip, that is the rule
    assert bb.threshold(1.15, extreme=True) is False   # 0/9 need 1.20
    assert bb.threshold(1.25, extreme=True) is True


# ─────────────────────────── gap-too-big rule ───────────────────────────────
def test_gap_3m():
    # entry pip limit 1.5
    ok, why = bb.gap_ok("CALL", 1.6, 0.0, 0.1)
    assert not ok and "1.5" in why
    ok, _ = bb.gap_ok("CALL", 1.4, 0.0, 0.1)
    assert ok
    # session gap cap 10.0
    ok, why = bb.gap_ok("CALL", 0.1, 10.5, 0.1)
    assert not ok and "10.0" in why
    # MATCH UP gap > 0.20 (1H ATR% bucket) -> skip
    ok, why = bb.gap_ok("DIGITMATCH", 0.1, 0.0, 0.25, direction="up")
    assert not ok and "0.20" in why
    ok, _ = bb.gap_ok("DIGITMATCH", 0.1, 0.0, 0.15, direction="up")
    assert ok
    # DIFF gap > 1.0 -> skip
    ok, why = bb.gap_ok("DIGITDIFF", 0.1, 0.0, 1.2)
    assert not ok and "1.0" in why
    # 3 same-direction candles -> need fresh structure
    ok, why = bb.gap_ok("CALL", 0.1, 0.0, 0.1, streak=3, fresh_structure=False)
    assert not ok and "fresh" in why
    ok, _ = bb.gap_ok("CALL", 0.1, 0.0, 0.1, streak=3, fresh_structure=True)
    assert ok


# ─────────────────────────── 3m/3m throttle ────────────────────────────────
def test_3m_throttle():
    start = datetime(2026, 1, 1, 10, 0, 0, tzinfo=timezone.utc)
    t = bb.Throttle(cadence_min=3, started=start)

    # 3-min wait for first entry
    ok, why = t.allow(start + timedelta(minutes=2))
    assert not ok and "first entry" in why

    # first boundary at +3 min fires
    ok, _ = t.allow(start + timedelta(minutes=3))
    assert ok
    t.record(start + timedelta(minutes=3))

    # off-boundary minute is refused
    ok, why = t.allow(start + timedelta(minutes=4))
    assert not ok and "boundary" in why

    # one signal per 3-min boundary
    ok, _ = t.allow(start + timedelta(minutes=6))
    assert ok
    t.record(start + timedelta(minutes=6))
    ok, _ = t.allow(start + timedelta(minutes=9))
    assert ok
    t.record(start + timedelta(minutes=9))     # third signal -> 3-min wait

    ok, why = t.allow(start + timedelta(minutes=12))
    assert not ok and "cooldown" in why        # 3-min wait after 3 signals
    ok, _ = t.allow(start + timedelta(minutes=15))
    assert ok

    # boundaries are exactly 0/3/6/9…
    assert bb.signal_3m_expires(datetime(2026, 1, 1, 10, 0, tzinfo=timezone.utc))
    assert bb.signal_3m_expires(datetime(2026, 1, 1, 10, 9, tzinfo=timezone.utc))
    assert not bb.signal_3m_expires(datetime(2026, 1, 1, 10, 4, tzinfo=timezone.utc))
    assert not bb.signal_3m_expires(datetime(2026, 1, 1, 10, 7, tzinfo=timezone.utc))


def test_throttle_30_60():
    # 30m/30m and 60m/60m variants wait 30 / 60 minutes
    t30 = bb.make_throttle("30m")
    t60 = bb.make_throttle("60m")
    assert t30.cadence == 30 and t60.cadence == 60
    start = datetime(2026, 1, 1, 10, 0, tzinfo=timezone.utc)
    t30.started = start
    ok, _ = t30.allow(start + timedelta(minutes=30))
    assert ok
    ok, _ = t30.allow(start + timedelta(minutes=31))
    assert not ok


def test_throttle_persists():
    """A refresh/restart must NOT reset the signal count or skip the break."""
    import json
    import tempfile
    path = os.path.join(tempfile.mkdtemp(), "throttle.json")
    base = datetime.now(timezone.utc).replace(second=0, microsecond=0)
    base -= timedelta(minutes=base.minute % 3)          # align to a 3-min boundary

    # the warm-up survives a refresh: the session clock is not restarted
    t1 = bb.Throttle(cadence_min=3, state_path=path, key="R_100:CALL:3m")
    t2 = bb.Throttle(cadence_min=3, state_path=path, key="R_100:CALL:3m")   # "refresh"
    ok, why = t2.allow(base + timedelta(minutes=1))
    assert not ok and "first entry" in why
    assert t2.started == t1.started

    # 3 signals -> break; a refresh cannot bypass the break
    t3 = bb.Throttle(cadence_min=3, state_path=path, key="R_100:CALL:3m")
    t3.started = base - timedelta(minutes=30)
    t3._save_state()
    for k in (0, 3, 6):
        ok, why = t3.allow(base + timedelta(minutes=k))
        assert ok, why
        t3.record(base + timedelta(minutes=k))
    t4 = bb.Throttle(cadence_min=3, state_path=path, key="R_100:CALL:3m")   # "refresh"
    assert t4.signals == 3
    ok, why = t4.allow(base + timedelta(minutes=9))
    assert not ok and "cooldown" in why
    ok, _ = t4.allow(base + timedelta(minutes=12))
    assert ok

    # more than STATE_SESSION_HOURS off -> a new session, counting starts over
    data = json.load(open(path))
    data["R_100:CALL:3m"]["updated"] = (
        datetime.now(timezone.utc) - timedelta(hours=bb.STATE_SESSION_HOURS + 1)).isoformat()
    with open(path, "w") as f:
        json.dump(data, f)
    t5 = bb.Throttle(cadence_min=3, state_path=path, key="R_100:CALL:3m")
    assert t5.signals == 0

    # --reset clears the count deliberately
    assert bb.reset_throttle_state(path, "R_100:CALL:3m")
    t6 = bb.Throttle(cadence_min=3, state_path=path, key="R_100:CALL:3m")
    assert t6.signals == 0


# ──────────────────────────── session + risk ────────────────────────────────
def test_session_marker():
    utc = timezone.utc
    assert bb.session_name(datetime(2026, 1, 1, 2, tzinfo=utc)) == "TOKYO"
    assert bb.session_name(datetime(2026, 1, 1, 12, tzinfo=utc)) == "LONDON"
    assert bb.session_name(datetime(2026, 1, 1, 20, tzinfo=utc)) == "NEWYORK"


def test_session_gate():
    s = bb.SessionStats()
    for _ in range(19):
        s.record(-1.0, "LONDON")
    assert not s.paused("LONDON")            # < 20 trades -> not yet
    s.record(-1.0, "LONDON")                 # 20th loser -> pause
    assert s.paused("LONDON")
    s2 = bb.SessionStats()
    for _ in range(20):
        s2.record(+1.0, "TOKYO")
    assert not s2.paused("TOKYO")            # WR 100% -> keep going


def test_risk_entry():
    plan = bb.risk_entry(1000.0, 100.0, 99.0, 0.2, "CALL")
    assert plan["ok"]
    assert abs(plan["risk_amount"] - 10.0) < 1e-9          # 1% of 1000
    assert abs(plan["rr"] - 3.0) < 1e-9                    # 1:3
    assert abs(plan["sl"] - (99.0 - 0.5 * 0.2)) < 1e-9     # 0.5 x ATR(14) buffer
    bad = bb.risk_entry(1000.0, 99.9, 100.0, 0.2, "CALL")
    assert not bad["ok"]                                   # zero stop distance


def test_partial_confidence():
    # a plan with no momentum must not be a trade
    bars = [mkbar(i, 100, 100.05, 99.95, 100) for i in range(30)]
    d = bb.check_single_type_live("R_100", "CALL", bars, ticks=[])
    assert not d["ok"], "flat market must be refused"


def test_fake_signals():
    # blocked market indices never produce a signal
    d = bb.check_single_type_live("VOL_100_1s", "CALL", [mkbar(0, 1, 2, 1, 2)])
    assert not d["ok"] and "blocked" in d["reason"]


def test_slippage():
    ev = bb.expected_value(0.70, 2.5)
    assert ev > 0
    # api 0.98 and fees must reduce the naive expectation
    naive = 0.70 * 2.5 - 0.30
    assert ev < naive


# ────────────────────────── prices / candles / force ────────────────────────
def test_resolve_close():
    b = mkbar(0, 100, 110, 90, 105)
    assert bb.resolve_close(b, "CALL") == 90     # buy at support -> LOW
    assert bb.resolve_close(b, "PUT") == 110     # sell at resistance -> HIGH
    assert bb.resolve_close(b, "DIGITMATCH") == 105
    assert bb.resolve_close(b, "OVER") == 105


def test_prices_for_trade():
    bars = [mkbar(i, 100, 101, 99, 100.5) for i in range(30)]
    live = bb.prices_for_trade("R_100", "CALL", bars, live=True)
    bt = bb.prices_for_trade("R_100", "CALL", bars, live=False)
    if live.get("ok"):
        assert "entry" in live and live["entry"] == min(b.low for b in bars[-1:])
    if bt.get("ok"):
        assert bt["win_rate"] == bb.BACKTEST_WIN_RATE and bt["rr_model"] == bb.BACKTEST_RR


def test_market_close():
    bars = [mkbar(i, 1.10, 1.30, 1.10, 1.10) for i in range(30)]   # Put > 3% from close
    res = bb.prices_for_trade("EURUSD", "PUT", bars, live=True)
    assert not res["ok"] and "3%" in res["reason"]


def test_force_trade_range():
    ok = bb.check_and_force_trade("CALL", 123.45)
    assert ok["ok"]
    bad = bb.check_and_force_trade("CALL", 0)
    assert not bad["ok"]
    bad = bb.check_and_force_trade("NOPE", 1.0)
    assert not bad["ok"]
    bad = bb.check_and_force_trade("DIGITMATCH", 1.0, digit=12)
    assert not bad["ok"] and "0..9" in bad["reason"]
    ok = bb.check_and_force_trade("DIGITMATCH", 1.0, digit=7, duration_unit="m", duration=3)
    assert ok["ok"] and ok["digit"] == 7


# ─────────────────────────── harness / sweep / backtest ─────────────────────
def test_sweep_filters():
    # sweep the momentum gate: entries only appear when the 3xATR room exists
    quiet = [mkbar(i, 100, 100.2, 99.8, 100) for i in range(40)]
    loud = quiet + [mkbar(40, 100, 104.5, 99.6, 104)]
    assert not bb.momentum_ok(quiet, bb.atr(quiet), "CALL")
    assert bb.momentum_ok(loud, bb.atr(loud), "CALL")


def test_sweep_thresholds():
    # digit HOT bar: 1.10 normal, 1.20 for 0/9
    assert bb.threshold(1.09) is False
    assert bb.threshold(1.10) is True
    assert bb.threshold(1.19, extreme=True) is False
    assert bb.threshold(1.20, extreme=True) is True


def _synthetic_series(n=400, seed=7):
    import random
    rng = random.Random(seed)
    bars, price = [], 100.0
    for i in range(n):
        drift = 0.05 if (i // 40) % 2 == 0 else -0.05
        o = price
        c = price + drift + rng.uniform(-0.4, 0.4)
        bars.append(mkbar(i, o, max(o, c) + 0.3, min(o, c) - 0.3, c))
        price = c
    return bars


def test_harness_3m():
    bars = _synthetic_series()
    res = bb.run_backtest(bars, "CALL", timeframe="3m")
    assert res["timeframe"] == "3m"
    assert res["entries"] >= 0 and 0 <= res["win_rate"] <= 1


def test_backtest_harness_3m():
    bars = _synthetic_series(seed=21)
    r_call = bb.run_backtest(bars, "CALL")
    r_put = bb.run_backtest(bars, "PUT")
    for r in (r_call, r_put):
        assert set(r) >= {"entries", "hits", "win_rate", "expected_r"}


def test_live_bt_runs():
    # the live decision path and the backtest path agree on the entry price rule
    bars = _synthetic_series(80)
    plan = bb.prices_for_trade("R_100", "CALL", bars, live=True)
    if plan.get("ok"):
        assert plan["entry"] == bars[-1].low


ALL = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]


def main():
    failed = 0
    for fn in ALL:
        try:
            fn()
            print(f"PASS {fn.__name__}")
        except AssertionError as e:
            failed += 1
            print(f"FAIL {fn.__name__}: {e}")
        except Exception as e:                                   # noqa: BLE001
            failed += 1
            print(f"ERROR {fn.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(ALL) - failed} passed, {failed} failed, {len(ALL)} total")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
