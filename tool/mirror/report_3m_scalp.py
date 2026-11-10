"""
Final number for the shipped 3M scalp mode, with the concentration check.

Configuration under test (what will go into lib/main.dart as TradeMode.scalp3m):

    trend    EMA9 > EMA21 > EMA50
    entry    close < EMA21, RSI(14) in [30,55], close > open   (mirror for sells)
    gate     ATR(14)% >= 0.80 on the 3M bar   -- the fee filter, not a tweak
    stop     min(5-bar low, entry - 1.5*ATR), reject if stop < 0.35%
    target   3R, 60-bar (3-hour) time stop, one trade at a time
    cost     0.25% round trip, charged per trade

Reported: gross/net in percent of price, trade count, win rate, and the same
figure with the two largest contributors removed. A result that dies when two
coins are removed is a two-coin result, and the release note has to say so.

Run: python3 tool/mirror/report_3m_scalp.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import fetch_real_1m as F
import mirror3m as m3
from measure_real_3m_fee import gross_pct
from measure_real_3m_exits import walk_exit

GATE = 0.80
FEE = 0.25
PERIODS = [('2026-02', '2026-07', 'TRAIN Feb-Jul'), ('2026-08', '2026-11', 'TEST Aug-Nov')]


def run_one(sym, rng):
    c = F.load_series(sym, F.month_list(*rng))
    if len(c) < 3000:
        return []
    s = m3.Series(c)
    return walk_exit(c, s, entry_kind='pullback', exit_kind='rr', rr=3.0,
                     trail_mult=2.0, hold=60, atr_pct_gate=GATE,
                     min_stop_pct=0.35)


def line(name, trs):
    if not trs:
        return f"{name:26s} no trades"
    wr = sum(1 for t in trs if t['r'] > 0) / len(trs) * 100
    g = gross_pct(trs)
    net = g - FEE * len(trs)
    per = net / len(trs)
    avg_stop = sum(t['risk'] / t['entry'] * 100 for t in trs) / len(trs)
    cost = FEE / avg_stop
    return (f"{name:26s} n {len(trs):5d}  WR {wr:5.1f}%  stop {avg_stop:5.2f}%  "
            f"fee {cost:.2f}R  gross {g:+8.1f}%  net {net:+8.1f}%  "
            f"net/trade {per:+.3f}%")


if __name__ == '__main__':
    syms = sorted({f.split('_1m_')[0] for f in os.listdir(F.CACHE)
                   if f.endswith('.csv')})
    print(f"shipped config: pullback, gate ATR%>={GATE}, stop 1.5xATR, R:R 3, "
          f"hold 60 bars, fee {FEE}% round trip")
    print(f"symbols {len(syms)}")
    for a, b, label in PERIODS:
        per_sym = {}
        for sym in syms:
            trs = run_one(sym, (a, b))
            if trs:
                per_sym[sym] = trs
        allt = [t for v in per_sym.values() for t in v]
        if not allt:
            continue
        print()
        print("=" * 118)
        print(f"{label}")
        print("=" * 118)
        print(line('ALL symbols', allt))
        # concentration check: drop the two biggest contributors
        ranked = sorted(per_sym.items(),
                        key=lambda kv: -(gross_pct(kv[1]) - FEE * len(kv[1])))
        top2 = [k for k, _ in ranked[:2]]
        kept = [t for k, v in per_sym.items() if k not in top2 for t in v]
        print(line(f'without {top2[0][:-4]}+{top2[1][:-4]}', kept))
        print(line(f'  ({top2[0]}, alone)', per_sym[top2[0]]))
        print(line(f'  ({top2[1]}, alone)', per_sym[top2[1]]))
        pos = sum(1 for k, v in per_sym.items()
                  if gross_pct(v) - FEE * len(v) > 0)
        print(f"\n   positive on {pos}/{len(per_sym)} symbols; "
              f"median symbol net "
              f"{sorted(gross_pct(v) - FEE * len(v) for v in per_sym.values())[len(per_sym)//2]:+.1f}%")
