"""
The fixed 3M entry: drop the one condition the funnel proved is the killer.

Funnel result (390 948 real bars, gate 0.80, per 400-coin scan):

    trend only          14.59
    trend + bar          7.07
    trend + side         2.26     <- without the green-bar requirement
    trend + side + rsi   2.26     <- RSI band adds NOTHING (same count)
    trend + side + bar   0.41     <- adding "bar closes green" cuts 82%

So `bar` was doing the damage, and `rsi` was decoration. The v18.2 rule asked
for a pullback AND an already-turning candle, which is why it fired 0.4 times
per scan.

This measures the candidates with disjoint months, and reports frequency and
net together. It also re-tests the gate, because with a looser entry the gate
can stay strict and the screen can still live.

Run: python3 tool/mirror/measure_3m_fix.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import fetch_real_1m as F
import mirror3m as m3
from measure_real_3m_fee import gross_pct

TRAIN = ('2026-09', '2026-10')
TEST = ('2026-11', '2026-11')
GATES = [0.80, 0.65, 0.55, 0.40]
COST = m3.COST_PCT


def decide(s, i, kind, pull=0.21):
    if not s.ok(i):
        return None
    px = s.c[i]['close']
    a = s.atr[i]
    if a <= 0 or px <= 0:
        return None
    up = s.e9[i] > s.e21[i] > s.e50[i]
    dn = s.e9[i] < s.e21[i] < s.e50[i]
    if not (up or dn):
        return None
    bar = s.c[i]
    green = bar['close'] > bar['open']
    red = bar['close'] < bar['open']
    r = s.rsi[i]
    buy = sell = False
    if kind == 'side':            # pullback side only
        buy, sell = up and px < s.e21[i], dn and px > s.e21[i]
    elif kind == 'side_noext':    # ...and not extended far below
        buy = up and s.e21[i] * (1 - pull) < px < s.e21[i]
        sell = dn and s.e21[i] < px < s.e21[i] * (1 + pull)
    elif kind == 'side_rsi':      # side + RSI cooling
        buy = up and px < s.e21[i] and r < 60
        sell = dn and px > s.e21[i] and r > 40
    elif kind == 'side_turn':     # side + bar stops falling (not full green)
        prev = s.c[i - 1]['close']
        buy = up and px < s.e21[i] and px > prev
        sell = dn and px > s.e21[i] and px < prev
    else:
        return None
    if buy == sell:
        return None
    is_buy = buy
    if is_buy:
        lo = min(x['low'] for x in s.c[max(0, i - 4):i + 1])
        sl = min(lo, px - a * 1.5)
        risk = px - sl
        tp = px + risk * 3.0
    else:
        hi = max(x['high'] for x in s.c[max(0, i - 4):i + 1])
        sl = max(hi, px + a * 1.5)
        risk = sl - px
        tp = px - risk * 3.0
    if risk <= 0 or not (0.35 <= risk / px * 100 <= 8):
        return None
    return {'entry': px, 'risk': risk, 'sl': sl, 'tp': tp, 'buy': is_buy}


def walk(c, s, kind, gate, hold=60):
    trades = []
    n = len(c)
    i = s.warm
    while i < n - 1:
        if s.atr_pct(i) < gate:
            i += 1
            continue
        d = decide(s, i, kind)
        if d is None:
            i += 1
            continue
        is_buy, entry, sl, tp, risk = d['buy'], d['entry'], d['sl'], d['tp'], d['risk']
        outcome, r_mult, exit_bar = 'OPEN', 0.0, n - 1
        for j in range(i + 1, min(n, i + 1 + hold)):
            bar = c[j]
            hit_sl = bar['low'] <= sl if is_buy else bar['high'] >= sl
            hit_tp = bar['high'] >= tp if is_buy else bar['low'] <= tp
            if hit_sl:
                outcome, r_mult, exit_bar = 'SL', -1.0, j
                break
            if hit_tp:
                outcome, r_mult = 'TP', 3.0
                exit_bar = j
                break
        if outcome == 'OPEN':
            last = c[min(n - 1, i + hold)]['close']
            r_mult = ((last - entry) if is_buy else (entry - last)) / risk
            outcome, exit_bar = 'TIME', min(n - 1, i + hold)
        trades.append({'entry': entry, 'risk': risk, 'r': r_mult,
                       'outcome': outcome, 'isBuy': is_buy})
        i = exit_bar + 1
    return trades


def collect(range_, kind, gate):
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
        trades.extend(walk(c, s, kind, gate))
    return trades, bars


def fmt(t, b):
    if not t:
        return f"{0:6d}{0.0:+9.1f}{0.0:+9.3f}{0.0:8.2f}"
    n = len(t)
    net = gross_pct(t) - COST * n
    return f"{n:6d}{net:+9.1f}{net / n:+9.3f}{n / b * 400:8.2f}"


def main():
    hdr = (f"{'entry':12s}{'gate':>6s} | {'TRAIN n':>6s}{'net%':>9s}{'net/tr':>9s}"
           f"{'scan':>8s} | {'TEST n':>6s}{'net%':>9s}{'net/tr':>9s}{'scan':>8s}")
    print(hdr)
    print('-' * len(hdr))
    for kind in ('side', 'side_noext', 'side_rsi', 'side_turn'):
        for gate in GATES:
            tr, br = collect(TRAIN, kind, gate)
            te, be = collect(TEST, kind, gate)
            print(f"{kind:12s}{gate:6.2f} | {fmt(tr, br)} | {fmt(te, be)}")
    print()
    print("TRAIN = Sep+Oct 2026, TEST = Nov 2026 (disjoint).")
    print("scan = expected signals per 400-coin scan.")


if __name__ == '__main__':
    main()
