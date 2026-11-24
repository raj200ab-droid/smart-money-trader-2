"""
Out-of-sample check for the gate level, now that frequency is a requirement.

v18.2 shipped gate 0.80 because it had the best break-even fee. It also fires
0.41 times per 400-coin scan, which on a phone looks broken (device screenshot:
0 signals from 400 coins).

measure_3m_entry_filters.py then showed the entry filter is not the redundant
one: at both gates, pullback is the ONLY entry with a positive edge, and every
relaxed entry (trend_any, trend_green, breakout, ema reclaim) loses money. So
the only lever that buys frequency without deleting the edge is the gate.

This walks the gate down on disjoint months and reports what each step costs:

    hits per 400-coin scan  (does the screen live?)
    net % per trade         (does it still pay the fee?)

Run: python3 tool/mirror/measure_3m_gate_oos.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import fetch_real_1m as F
import mirror3m as m3
from measure_real_3m_fee import gross_pct
from measure_real_3m_exits import walk_exit

TRAIN = ('2026-09', '2026-10')
TEST = ('2026-11', '2026-11')
GATES = [0.30, 0.40, 0.50, 0.55, 0.65, 0.80]


def run(range_, gate):
    syms = sorted({f.split('_1m_')[0] for f in os.listdir(F.CACHE)
                   if f.endswith('.csv')})
    months = F.month_list(*range_)
    trades, bars = [], 0
    for sym in syms:
        c = F.load_series(sym, months)
        if len(c) < 2000:
            continue
        s = m3.Series(c)
        bars += s.n - s.warm
        trades.extend(walk_exit(c, s, entry_kind='pullback', exit_kind='rr',
                                rr=3.0, trail_mult=2.0, hold=60,
                                atr_pct_gate=gate, min_stop_pct=0.35))
    return trades, bars


def main():
    print(f"{'gate':>6s} | {'TRAIN n':>8s}{'net%':>9s}{'net/tr':>9s}{'scan':>7s} "
          f"| {'TEST n':>7s}{'net%':>9s}{'net/tr':>9s}{'scan':>7s}")
    print('-' * 76)
    for gate in GATES:
        tr, br = run(TRAIN, gate)
        te, be = run(TEST, gate)
        def cols(t, b):
            if not t:
                return f"{0:8d}{0.0:+9.1f}{0.0:+9.3f}{0.0:7.2f}", \
                       f"{0:7d}{0.0:+9.1f}{0.0:+9.3f}{0.0:7.2f}"
            n = len(t)
            net = gross_pct(t) - m3.COST_PCT * n
            return (f"{n:8d}{net:+9.1f}{net / n:+9.3f}{n / b * 1000 * 400 / 1000:7.2f}",
                    f"{n:7d}{net:+9.1f}{net / n:+9.3f}{n / b * 1000 * 400 / 1000:7.2f}")
        c1, _ = cols(tr, br)
        _, c2 = cols(te, be)
        print(f"{gate:6.2f} | {c1} | {c2}")
    print()
    print("scan = expected signals per 400-coin scan (one 3M bar).")
    print("TRAIN = Sep+Oct 2026, TEST = Nov 2026, disjoint.")


if __name__ == '__main__':
    main()
