"""
Where do the 3M scalps die? A funnel, condition by condition, on real candles.

v18.2 makes 0.4 signals per 400-coin scan. The gate is not the only suspect: at
gate 0.80 the pullback still removes 95% of what survives. This counts each
condition independently and jointly, so the next change is aimed at the real
bottleneck instead of at whichever filter looks tidiest.

    gate        ATR% >= G
    trend       EMA9 > EMA21 > EMA50   (or the mirror)
    side        price on the pullback side of EMA21
    rsi         RSI in band
    bar         bar closes in the trade direction
    stop        stop width accepted

Run: python3 tool/mirror/measure_3m_funnel.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import fetch_real_1m as F
import mirror3m as m3

MONTHS = ('2026-09', '2026-11')
GATE = 0.80


def main():
    syms = sorted({f.split('_1m_')[0] for f in os.listdir(F.CACHE)
                   if f.endswith('.csv')})
    months = F.month_list(*MONTHS)

    names = ['gate', 'trend', 'side', 'rsi', 'bar', 'stop']
    count = {n: 0 for n in names}
    total = 0
    # joint counts for the progressively relaxed entry variants
    combos = {
        'trend only':             ['gate', 'trend', 'stop'],
        'trend+bar':              ['gate', 'trend', 'bar', 'stop'],
        'trend+side':             ['gate', 'trend', 'side', 'stop'],
        'trend+side+rsi':         ['gate', 'trend', 'side', 'rsi', 'stop'],
        'trend+side+bar':         ['gate', 'trend', 'side', 'bar', 'stop'],
        'all (v18.2)':            ['gate', 'trend', 'side', 'rsi', 'bar', 'stop'],
    }
    joint = {k: 0 for k in combos}

    for sym in syms:
        c = F.load_series(sym, months)
        if len(c) < 3000:
            continue
        s = m3.Series(c)
        for i in range(s.warm, s.n - 1):
            total += 1
            px = c[i]['close']
            a = s.atr[i]
            if not a or a <= 0 or px <= 0:
                continue
            ok = {}
            ok['gate'] = s.atr_pct(i) >= GATE
            up = s.e9[i] > s.e21[i] > s.e50[i]
            dn = s.e9[i] < s.e21[i] < s.e50[i]
            ok['trend'] = up or dn
            buy_side = px < s.e21[i]
            sell_side = px > s.e21[i]
            ok['side'] = (up and buy_side) or (dn and sell_side)
            r = s.rsi[i]
            ok['rsi'] = (up and 30 <= r <= 55) or (dn and 45 <= r <= 70)
            green = c[i]['close'] > c[i]['open']
            red = c[i]['close'] < c[i]['open']
            ok['bar'] = (up and green) or (dn and red)
            lo = min(x['low'] for x in c[max(0, i - 4):i + 1])
            hi = max(x['high'] for x in c[max(0, i - 4):i + 1])
            sl = min(lo, px - a * 1.5) if up else max(hi, px + a * 1.5)
            risk = abs(sl - px)
            ok['stop'] = risk > 0 and 0.35 <= risk / px * 100 <= 8
            if not ok['gate']:
                continue
            for n in names:
                if ok[n]:
                    count[n] += 1
            for k, conds in combos.items():
                if all(ok[x] for x in conds):
                    joint[k] += 1

    print(f"symbols {len(syms)}, months {months[0]}..{months[-1]}, "
          f"{total} bars, gate {GATE}\n")
    print("Condition pass rate, measured INSIDE gate-passing bars:")
    base = count['gate']
    print(f"  bars passing the gate          {base:7d}  ({base / total * 100:5.2f}% of all)")
    for n in names[1:]:
        print(f"  ...also pass {n:16s} {count[n]:7d}  ({count[n] / base * 100:5.1f}% of gated)")
    print()
    print("Joint pass rates -> signals per 400-coin scan:")
    for k in combos:
        v = joint[k]
        print(f"  {k:18s} {v:7d} bars  {v / total * 100:6.3f}%  "
              f"-> {v / total * 400:6.2f} per scan")


if __name__ == '__main__':
    main()
