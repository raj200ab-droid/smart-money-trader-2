"""
At a FIXED gate, which entry filters are worth their rarity?

v18.2 shipped gate 0.80 + pullback, which fires 0.4 times per 400-coin scan.
Separating the two multipliers shows the gate is not the bottleneck by itself:
at gate 0.80 the gate passes only ~4% of bars, and the pullback then removes
95% of what survives. Two rare filters in series.

So: hold the gate at 0.80 and vary ONLY the entry condition, then hold the gate
at 0.55 and vary it again. The question is not "which filter is best" but
"which filter earns its rarity", i.e. does net% per trade improve by more than
the hit rate falls.

Run: python3 tool/mirror/measure_3m_entry_filters.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import fetch_real_1m as F
import mirror3m as m3
from measure_real_3m_fee import gross_pct

MONTHS = ('2026-09', '2026-11')
COST = m3.COST_PCT


def rsi_band(rn, lo, hi):
    return lo <= rn <= hi


def decide(s, i, kind):
    """Entry conditions only; the gate and the stop/target stay identical."""
    if not s.ok(i):
        return None
    px = s.c[i]['close']
    a = s.atr[i]
    if a <= 0 or px <= 0:
        return None
    up = s.e9[i] > s.e21[i] > s.e50[i]
    dn = s.e9[i] < s.e21[i] < s.e50[i]
    bar = s.c[i]
    r = s.rsi[i]
    green = bar['close'] > bar['open']
    red = bar['close'] < bar['open']
    vol_ok = s.c[i]['volume'] > s.vavg[i] * 1.5 if s.vavg[i] else False
    buy = sell = False
    if kind == 'pullback':                 # v18.2 as shipped
        buy = up and px < s.e21[i] and 30 <= r <= 55 and green
        sell = dn and px > s.e21[i] and 45 <= r <= 70 and red
    elif kind == 'trend_any':              # any bar, trend aligned
        buy, sell = up, dn
    elif kind == 'trend_green':            # trend + bar in trend direction
        buy, sell = up and green, dn and red
    elif kind == 'trend_pull_loose':       # under EMA9, RSI just under 60
        buy = up and px < s.e9[i] and r < 60 and green
        sell = dn and px > s.e9[i] and r > 40 and red
    elif kind == 'pullback_wide':          # v18.2 with wider RSI band
        buy = up and px < s.e21[i] and 20 <= r <= 65 and green
        sell = dn and px > s.e21[i] and 35 <= r <= 80 and red
    elif kind == 'breakout':               # new 20-bar extreme with the trend
        buy = up and px > s.dhi[i]
        sell = dn and px < s.dlo[i]
    elif kind == 'ema_reclaim':            # close back above EMA9 in an uptrend
        prev = s.c[i - 1]['close']
        buy = up and s.e9[i - 1] is not None and prev < s.e9[i - 1] and px > s.e9[i]
        sell = dn and s.e9[i - 1] is not None and prev > s.e9[i - 1] and px < s.e9[i]
    elif kind == 'rsi_swing':              # RSI crosses back out of oversold
        pr = s.rsi[i - 1]
        buy = up and pr is not None and pr < 35 <= r
        sell = dn and pr is not None and pr > 65 >= r
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
    if risk <= 0 or risk / px * 100 < 0.35:
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


KINDS = ['pullback', 'trend_any', 'trend_green', 'trend_pull_loose',
         'pullback_wide', 'breakout', 'ema_reclaim', 'rsi_swing']


def main():
    syms = sorted({f.split('_1m_')[0] for f in os.listdir(F.CACHE)
                   if f.endswith('.csv')})
    months = F.month_list(*MONTHS)
    print(f"symbols {len(syms)}, months {months[0]}..{months[-1]}, fee {COST}%")
    data = {}
    for sym in syms:
        c = F.load_series(sym, months)
        if len(c) >= 3000:
            data[sym] = (c, m3.Series(c))
    bars = sum(s.n - s.warm for _, s in data.values())

    for gate in (0.80, 0.55):
        print()
        print("=" * 118)
        print(f"GATE {gate:.2f} -- entry filter varied, everything else fixed")
        print("=" * 118)
        hdr = (f"{'entry':18s}{'n':>7s}{'hits/1000':>11s}{'WR':>7s}"
               f"{'net%':>10s}{'net%/trade':>12s}{'per scan':>10s}")
        print(hdr)
        print('-' * len(hdr))
        ranked = []
        for kind in KINDS:
            trs = []
            for sym, (c, s) in data.items():
                trs.extend(walk(c, s, kind, gate))
            if not trs:
                print(f"{kind:18s}{0:7d}")
                continue
            n = len(trs)
            wr = sum(1 for t in trs if t['r'] > 0) / n * 100
            net = gross_pct(trs) - COST * n
            hits = n / bars * 1000
            ranked.append((net / n, kind, n, hits, wr, net))
        for per, kind, n, hits, wr, net in sorted(ranked, reverse=True):
            print(f"{kind:18s}{n:7d}{hits:11.2f}{wr:6.1f}%{net:+10.1f}"
                  f"{per:+12.3f}{hits * 400 / 1000:10.2f}")


if __name__ == '__main__':
    main()
