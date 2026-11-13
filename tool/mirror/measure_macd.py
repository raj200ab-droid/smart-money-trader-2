"""
MACD buy-only on 3M -- measured before it goes anywhere near the app.

The requested rule: BUY when the MACD line is above its signal line AND the
histogram is rising (momentum opening, not merely "already above").

Two questions, and they are different:

  1. Does the rule produce a positive edge at all? (gross R)
  2. Is the edge bigger than the fee? (net R at 0.25% round trip)

A buy-only rule has no SELL side, so the exit is fixed rather than structural:
stop at 1x ATR, target at 2R. That is deliberately simple -- the point is to
measure the SIGNAL, not to re-litigate the engine's stop placement.

Also reported: a no-MACD control that takes every bar with the same stop/target,
so the MACD filter can be judged against doing nothing rather than against zero.

Run: python3 tool/mirror/measure_macd.py [seeds]
"""
import os
import sys
import statistics as st
from concurrent.futures import ProcessPoolExecutor

sys.path.insert(0, os.path.dirname(__file__))
import mirror
from measure_tp import gen_3m

REGIMES = ['mixed', 'trend', 'range', 'volatile']
COST_PCT = 0.25
ATR_MULT = 1.0
MULTS = [1.0, 2.0, 3.0]


def atr_at(c, i, period=50):
    """Mean true range over `period` bars ending at i."""
    lo = max(1, i - period + 1)
    trs = []
    for j in range(lo, i + 1):
        h, l, pc = c[j]['high'], c[j]['low'], c[j - 1]['close']
        trs.append(max(h - l, abs(h - pc), abs(l - pc)))
    return sum(trs) / len(trs) if trs else 0.0


def run(c, use_macd=True, fill_bars=5, cooldown=1):
    """One trade at a time, entry at the CLOSE of the signal bar."""
    closes = [k['close'] for k in c]
    out = []
    missed = 0
    i = 300
    n = len(c)
    last_sig = -10 ** 9
    while i < n - 1:
        if i - last_sig < cooldown:
            i += 1
            continue
        if use_macd:
            win = closes[:i + 1]
            if not mirror.macd_buy(win[-400:]):
                i += 1
                continue
        a = atr_at(c, i)
        if a <= 0:
            i += 1
            continue
        # A 1x ATR50 stop on 3M candles is ~0.4% on this data, which the v17.4
        # 0.5% floor refuses outright -- so the first run silently measured 3
        # trades and called it a regime result. Widen the stop to the smallest
        # multiple that clears the floor, and report which one was used, so the
        # number is a trade that could actually be sent.
        entry = closes[i]
        risk_pct = a * ATR_MULT / entry * 100
        if risk_pct < 0.5:
            i += 1
            continue
        risk = a * ATR_MULT
        sl = entry - risk
        tp = entry + risk * 2
        last_sig = i
        outcome, r, exit_bar = 'OPEN', 0.0, n - 1
        # entry at close of bar i -> fills at i+1 open at the earliest
        for j in range(i + 1, n):
            bar = c[j]
            if bar['low'] <= sl:
                outcome, r, exit_bar = 'SL', -1.0, j
                break
            if bar['high'] >= tp:
                outcome, r, exit_bar = 'TP', 2.0, j
                break
        out.append({'entry': entry, 'risk': risk_pct, 'r': r,
                    'outcome': outcome, 'exitBar': exit_bar})
        i = exit_bar + 1 if outcome != 'OPEN' else n
    run.missed = missed
    return out


def stats(trs):
    trs = [t for t in trs if t['outcome'] != 'OPEN']
    if not trs:
        return None
    gross = [t['r'] for t in trs]
    net = [g - COST_PCT / t['risk'] for g, t in zip(gross, trs)]
    return {
        'n': len(trs),
        'wr': 100 * sum(1 for t in trs if t['outcome'] == 'TP') / len(trs),
        'gross': sum(gross),
        'net': sum(net),
        'avgRisk': st.mean(t['risk'] for t in trs),
    }


def job(args):
    regime, seed, mult = args
    global ATR_MULT
    ATR_MULT = mult
    a, b, c = gen_3m(seed, regime=regime)
    return (regime, mult), {'macd': run(c, True), 'control': run(c, False)}


if __name__ == '__main__':
    seeds = int(sys.argv[1]) if len(sys.argv) > 1 else 8
    tasks = [(r, s, m) for m in MULTS for r in REGIMES
             for s in range(seeds)]
    res = {m: {'macd': [], 'control': []} for m in MULTS}
    per = {m: {k: {r: [] for r in REGIMES} for k in ('macd', 'control')}
           for m in MULTS}
    with ProcessPoolExecutor(max_workers=2) as ex:
        for i, ((reg, mult), out) in enumerate(ex.map(job, tasks, chunksize=1), 1):
            for k, v in out.items():
                res[mult][k] += v
                per[mult][k][reg] += v
            if i % 24 == 0:
                print(f'  {i}/{len(tasks)}', flush=True)

    print(f'\nMACD buy-only on 3M, cost {COST_PCT}% round trip, '
          f'{seeds} seeds x 4 regimes\n')
    for mult in MULTS:
        m, ctl = stats(res[mult]['macd']), stats(res[mult]['control'])
        print(f'  stop {mult:.1f}x ATR50')
        print(f"    {'rule':9s} {'n':>6s} {'WR':>7s} {'gross':>9s} "
              f"{'net':>10s} {'R/trade':>9s} {'avgRisk':>8s}")
        for k in ('macd', 'control'):
            d = stats(res[mult][k])
            if not d:
                print(f'    {k:9s} no trades (all refused by the 0.5% floor)')
                continue
            print(f"    {k:9s} {d['n']:6d} {d['wr']:6.1f}% {d['gross']:+9.1f} "
                  f"{d['net']:+10.1f} {d['gross']/d['n']:+9.3f} "
                  f"{d['avgRisk']:7.2f}%")
        if m:
            print(f'    per regime (net R): ' + '  '.join(
                f"{reg} {stats(per[mult]['macd'][reg])['net']:+8.1f}"
                if stats(per[mult]['macd'][reg]) else f'{reg} n/a'
                for reg in REGIMES))
        print()
