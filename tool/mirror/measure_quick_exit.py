"""
Can the ADX trade from the user's screenshot be repeated on purpose?

The screenshot (2026-11-14) is one completed round trip:

    BUY   670 ADX @ 0.0477   31.9590 USDT   taker 0.100%
    SELL  669 ADX @ 0.0479   32.0451 USDT   maker 0.100%
    price  +0.419%   fee -0.200%   net +0.219%  =  +0.070 USDT

That is the template the user wants the 3M mode to reproduce: a small move,
taken quickly, that still clears the fee. The first version of this rule (v19.0)
used a 3xATR stop and a 3R target -- a 0.8-1.2% move -- and lost 2 751R. This
one is the opposite: exit at ~2.5x ATR with a ~1x ATR stop.

THE UNIVERSE MATTERS MORE THAN THE RULE
---------------------------------------
The user's own instruction: "tumi top gain coin gula besi use korba filter er
jonno". The app's 3M scan ranks by 24h RANGE and takes the top 200 up + top 200
down. If the edge only exists among the biggest movers, measuring on a random
12 coins would report the wrong answer in both directions. So this harness:

  1. ranks all pairs every 6 hours by 24h range, exactly like `_pickVolatile`
  2. measures the rule ONLY on the top 200 -- and, for comparison, on the
     bottom half, which is the control group

Exit variants are swept, because the screenshot's "+0.42%" is a fact about one
trade and not a target anyone can hit on purpose.

Run: python3 tool/mirror/measure_quick_exit.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import measure_bos_macd as MB
import measure_scanner5 as SC

CACHE = MB.CACHE
TOP_N = 200          # scanTarget ~/ 2 up + ~/ 2 down


def series():
    out = {}
    for f in sorted(os.listdir(CACHE)):
        if not f.endswith('_1m_2026-09.csv'):
            continue
        sym = f.split('_1m_')[0]
        c = MB.F.load_series(sym, ['2026-09', '2026-10', '2026-11'], minutes=3)
        if len(c) > 5000:
            out[sym] = c
    return out


def range24(c, i):
    """24h range as a percentage of price, the app's `_pickVolatile` score."""
    lo = max(0, i - 480)                     # 480 x 3M = 24h
    hi_px = max(x['high'] for x in c[lo:i + 1])
    lo_px = min(x['low'] for x in c[lo:i + 1])
    px = c[i]['close']
    return (hi_px - lo_px) / px * 100 if px > 0 else 0.0


def ranked_snapshots(data, step=120):
    """Every `step` bars (6 hours): the ranking the app would have used."""
    snaps = []
    for t in range(600, 32000, step):
        rows = []
        for sym, c in data.items():
            if t < len(c):
                rows.append((range24(c, t), sym, t))
        rows.sort(reverse=True)
        snaps.append(rows)
    return snaps


def trade(c, i, stop_mult, target_mult, hold, fee_pct, be_at=0.0):
    """Enter at close, stop at `stop_mult` ATR, exit at `target_mult` ATR.

    Fee is charged as the user actually pays it: `fee_pct` of notional for the
    round trip, converted to R against this trade's own risk.
    """
    entry = c[i]['close']
    a = MB.atr_wilder(c[max(0, i - 100):i + 1])
    if a <= 0:
        return None
    risk = a * stop_mult
    stop_pct = risk / entry * 100
    if stop_pct <= 0 or stop_pct > 8:
        return None
    # A risk under the fee level cannot ever pay for itself.
    if stop_pct < fee_pct * 1.5:
        return None
    reward = a * target_mult
    buy = True                                  # scanner is long-only: MACD green
    tp = entry + reward
    sl = entry - risk
    fee_r = fee_pct / stop_pct
    moved = False
    for j in range(i + 1, min(len(c), i + 1 + hold)):
        b = c[j]
        if b['low'] <= sl:
            return (-1.0 if not moved else 0.0) - fee_r
        if b['high'] >= tp:
            return reward / risk - fee_r
        if be_at and not moved and b['high'] >= entry + risk * be_at:
            sl, moved = entry, True
    k = min(len(c) - 1, i + hold)
    return (c[k]['close'] - entry) / risk - fee_r


def run(data, snaps, pool, stop_mult, target_mult, hold, fee_pct,
        pool_n=TOP_N):
    trades = []
    for rows in snaps:
        picked = {s for (_r, s, _t) in
                  (rows[:pool_n] if pool == 'top' else rows[-pool_n:])}
        for sym in picked:
            c = data[sym]
            i = next(t for (_r, s, t) in rows if s == sym)
            r = trade(c, i, stop_mult, target_mult, hold, fee_pct)
            if r is not None:
                trades.append(r)
    return trades


def summarise(rs):
    if not rs:
        return None
    wins = sum(1 for r in rs if r > 0)
    return {'n': len(rs), 'net': sum(rs), 'avg': sum(rs) / len(rs),
            'wr': wins / len(rs) * 100}


def main():
    data = series()
    if not data:
        print('no data')
        return 1
    print(f'{len(data)} pairs, '
          f'{sum(len(c) for c in data.values()):,} 3M bars')
    snaps = ranked_snapshots(data)
    print(f'{len(snaps)} snapshots (one per 6h), top {TOP_N} by 24h range\n')

    print('1. which pool the rule should scan  '
          '(stop 1xATR, target 2.5xATR, 40 bars, fee 0.20%)')
    print(f"{'pool':<10} {'trades':>7} {'WR%':>6} {'netR':>9} {'avgR':>7}")
    # With only 24 pairs the "top 200" IS every pair, so top and bottom would be
    # identical and the comparison would prove nothing. Use halves for this
    # sample and say so, rather than printing a pretty number that means nothing.
    pool_n = min(TOP_N, max(1, len(data) // 2))
    print(f'   (sample is {len(data)} pairs, so pool = top/bottom {pool_n})')
    for pool in ('top', 'bottom'):
        s = summarise(run(data, snaps, pool, 1.0, 2.5, 40, 0.20, pool_n))
        if s:
            print(f"{pool:<10} {s['n']:>7} {s['wr']:>6.1f} {s['net']:>9.1f} "
                  f"{s['avg']:>7.3f}")

    print('\n2. exit sweep on the TOP pool, fee 0.20% (what the user pays now)')
    print(f"{'stop':>5} {'target':>7} {'hold':>5} {'trades':>7} {'WR%':>6} "
          f"{'netR':>9} {'avgR':>7}")
    rows = []
    for stop_mult in (0.8, 1.0, 1.5):
        for target_mult in (1.5, 2.0, 2.5, 3.0):
            for hold in (20, 60):
                s = summarise(run(data, snaps, 'top', stop_mult, target_mult,
                                  hold, 0.20))
                if s:
                    rows.append((s['avg'], stop_mult, target_mult, hold, s))
                    print(f"{stop_mult:>5} {target_mult:>7} {hold:>5} "
                          f"{s['n']:>7} {s['wr']:>6.1f} {s['net']:>9.1f} "
                          f"{s['avg']:>7.3f}")
    if not rows:
        return 0
    rows.sort(reverse=True)
    best = rows[0]
    print(f"\n  best: stop {best[1]}xATR, target {best[2]}xATR, hold {best[3]} "
          f"-> {best[4]['avg']:+.3f}R avg over {best[4]['n']} trades")

    print('\n3. the same best variant at each fee level')
    print(f"{'fee':<18} {'trades':>7} {'avgR':>7} {'verdict':>12}")
    for fee, label in ((0.20, '0.20% (this acct)'), (0.15, '0.15% (BNB on)'),
                       (0.10, '0.10% (VIP1+BNB)'), (0.075, '0.075% (VIP2)')):
        s = summarise(run(data, snaps, 'top', best[1], best[2], best[3], fee))
        if s:
            verdict = 'POSITIVE' if s['avg'] > 0 else 'negative'
            print(f'{label:<18} {s["n"]:>7} {s["avg"]:>7.3f} {verdict:>12}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
