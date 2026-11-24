"""
Frequency vs expectancy: the 3M scalp as shipped fires 0.41 times per 400-coin
scan, which is indistinguishable from "broken" on a phone.

The device screenshot (v18.2, 400 coins, 0 signals) is the evidence: the gate
alone leaves ~4% of bars eligible, and the pullback filter on top of it removes
95% of what is left. Two rare filters in series multiply.

This measures, per entry variant and per gate level, BOTH things that matter:

    hits per 1000 bars   -> will the screen ever show anything
    net % per trade      -> does it pay the fee

and reports them together, because either one alone is a lie. A rule with 0.4
signals per scan is useless; a rule with 40 signals that loses 0.3% a trade is
worse than useless.

Run: python3 tool/mirror/measure_3m_freq.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import fetch_real_1m as F
import mirror3m as m3
from measure_real_3m_fee import gross_pct
from measure_real_3m_exits import walk_exit

GATES = [0.25, 0.40, 0.55, 0.80]
VARIANTS = ['pullback', 'ignite', 'both', 'bandrev']
MONTHS = ('2026-09', '2026-11')


def main():
    syms = sorted({f.split('_1m_')[0] for f in os.listdir(F.CACHE)
                   if f.endswith('.csv')})
    months = F.month_list(*MONTHS)
    print(f"symbols {len(syms)}, months {months[0]}..{months[-1]}, "
          f"fee {m3.COST_PCT}% round trip\n")
    hdr = (f"{'variant':10s}{'gate':>6s}{'n':>7s}{'zeroBars%':>11s}"
           f"{'hits/1000':>10s}{'WR':>7s}{'net%':>9s}{'net%/trade':>12s}"
           f"{'per 400-coin scan':>19s}")
    print(hdr)
    print('-' * len(hdr))
    rows = []
    for variant in VARIANTS:
        for gate in GATES:
            trades, bars = [], 0
            for sym in syms:
                c = F.load_series(sym, months)
                if len(c) < 3000:
                    continue
                s = m3.Series(c)
                bars += s.n - s.warm
                trades.extend(walk_exit(c, s, entry_kind=variant, exit_kind='rr',
                                        rr=3.0, trail_mult=2.0, hold=60,
                                        atr_pct_gate=gate, min_stop_pct=0.35))
            if not trades:
                continue
            n = len(trades)
            wr = sum(1 for t in trades if t['r'] > 0) / n * 100
            net = gross_pct(trades) - m3.COST_PCT * n
            hits = n / bars * 1000
            rows.append((variant, gate, n, wr, net, net / n, hits))
            print(f"{variant:10s}{gate:6.2f}{n:7d}{'':>11s}{hits:10.2f}{wr:6.1f}%"
                  f"{net:+9.1f}{net / n:+12.3f}{hits * 400 / 1000:19.2f}")
    print()
    print("per 400-coin scan = expected signals in ONE 3M bar across 400 coins.")
    print("Anything under ~1.0 means most scans show an empty screen.")


if __name__ == '__main__':
    main()
