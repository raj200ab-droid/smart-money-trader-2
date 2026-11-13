"""
3M scalping rules, measured on REAL Binance spot 1-minute candles.

The earlier harness (measure_3m_scalp.py) used synthetic random walks. That is
enough to prove a bug, and useless for a strategy: a random walk has no
momentum persistence, so every trend rule loses to its own fee there. This runs
the same rules on ~4 months of real 1-minute candles aggregated to 3M, for a
book of liquid Binance pairs, and reports:

  * gross and NET R (fee charged per trade from that trade's own stop width)
  * a same-mechanics random-entry control on the SAME candles
  * a bootstrap 95% CI on net R per trade
  * the stop-width sweep, because stop width IS the fee model

Data cache: /tmp/klines (outside the repo). See fetch_real_1m.py.

Run: python3 tool/mirror/measure_real_3m.py [--months 2026-08:2026-11]
"""
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(__file__))
import fetch_real_1m as F
import mirror3m as m3

VARIANTS = ['ignite', 'pullback', 'bandrev', 'both']


def boot_ci(vals, iters=2000, seed=7):
    if len(vals) < 25:
        return (float('nan'), float('nan'))
    rnd = random.Random(seed)
    n = len(vals)
    means = []
    for _ in range(iters):
        means.append(sum(rnd.choice(vals) for _ in range(n)) / n)
    means.sort()
    return means[int(iters * .025)], means[int(iters * .975)]


def stats(trs):
    if not trs:
        return None
    cost = [m3.COST_PCT / 100.0 * t['entry'] / t['risk'] for t in trs]
    gross = [t['r'] for t in trs]
    net = [g - c for g, c in zip(gross, cost)]
    lo, hi = boot_ci(net)
    return {'n': len(trs), 'wr': sum(1 for g in gross if g > 0) / len(trs) * 100,
            'gross': sum(gross), 'net': sum(net), 'net_avg': sum(net) / len(trs),
            'lo': lo, 'hi': hi, 'cost': sum(cost) / len(trs),
            'stop': sum(t['risk'] / t['entry'] * 100 for t in trs) / len(trs),
            'tp': sum(1 for t in trs if t['outcome'] == 'TP'),
            'sl': sum(1 for t in trs if t['outcome'] == 'SL'),
            'time': sum(1 for t in trs if t['outcome'] == 'TIME')}


def row(name, s):
    if s is None:
        return f"{name:34s} no trades"
    star = ''
    if s['lo'] == s['lo']:
        star = ' CI>0' if s['lo'] > 0 else (' CI<0' if s['hi'] < 0 else '')
    return (f"{name:34s} n {s['n']:5d}  WR {s['wr']:5.1f}%  "
            f"gross {s['gross']:+8.1f}R  net {s['net']:+8.1f}R  "
            f"net/tr {s['net_avg']:+.3f} [{s['lo']:+.3f},{s['hi']:+.3f}]{star:<5s} "
            f"cost {s['cost']:.2f}R  stop {s['stop']:.2f}%  "
            f"TP/SL/T {s['tp']}/{s['sl']}/{s['time']}")


def walk_random(c, seed=0, rr=2.0, stop_mult=1.5, hold=m3.TIME_STOP,
                min_stop_pct=0.0, trend_only=True):
    """Same stop/target/time stop, direction from the EMA stack, entry by lot."""
    s = m3.Series(c)
    rnd = random.Random(seed)
    n = len(c)
    trades = []
    i = s.warm
    while i < n - 1:
        up = s.e9[i] > s.e21[i] > s.e50[i]
        dn = s.e9[i] < s.e21[i] < s.e50[i]
        if trend_only and not (up or dn):
            i += 1
            continue
        is_buy = up if trend_only else rnd.random() < 0.5
        px, a = c[i]['close'], s.atr[i]
        if not a or a <= 0 or px <= 0:
            i += 1
            continue
        if is_buy:
            lo = min(x['low'] for x in c[max(0, i - 4):i + 1])
            sl = min(lo, px - a * stop_mult)
            risk = px - sl
            tp = px + risk * rr
        else:
            hi = max(x['high'] for x in c[max(0, i - 4):i + 1])
            sl = max(hi, px + a * stop_mult)
            risk = sl - px
            tp = px - risk * rr
        if risk <= 0 or risk / px * 100 < min_stop_pct:
            i += 1
            continue
        outcome, r_mult, exit_bar = 'OPEN', 0.0, n - 1
        for j in range(i + 1, min(n, i + 1 + hold)):
            bar = c[j]
            hit_sl = bar['low'] <= sl if is_buy else bar['high'] >= sl
            hit_tp = bar['high'] >= tp if is_buy else bar['low'] <= tp
            if hit_sl:
                outcome, r_mult, exit_bar = 'SL', -1.0, j
                break
            if hit_tp:
                outcome, r_mult = 'TP', abs(tp - px) / risk
                exit_bar = j
                break
        if outcome == 'OPEN':
            last = c[min(n - 1, i + hold)]['close']
            r_mult = ((last - px) if is_buy else (px - last)) / risk
            outcome, exit_bar = 'TIME', min(n - 1, i + hold)
        trades.append({'entry': px, 'risk': risk, 'r': r_mult, 'outcome': outcome,
                       'isBuy': is_buy, 'atr_pct': s.atr_pct(i), 'bar': i})
        i = exit_bar + 1
    return trades


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--months', default='2026-08:2026-11')
    ap.add_argument('--symbols', default='')
    ap.add_argument('--quick', action='store_true')
    a = ap.parse_args()
    m_from, m_to = a.months.split(':')
    months = F.month_list(m_from, m_to)

    if a.symbols:
        syms = [s.strip().upper() for s in a.symbols.split(',') if s.strip()]
    else:
        syms = sorted({f.split('_1m_')[0] for f in os.listdir(F.CACHE)
                       if f.endswith('.csv')})
    if a.quick:
        syms = syms[:6]
    print(f"symbols: {len(syms)}  months: {months[0]}..{months[-1]}  "
          f"fee {m3.COST_PCT}% round trip")

    acc = {}
    per_sym = []
    for sym in syms:
        c = F.load_series(sym, months)
        if len(c) < 3000:
            continue
        s = m3.Series(c)
        line = {'sym': sym, 'bars': len(c)}
        for v in VARIANTS:
            trs = m3.walk3m(c, variant=v, series=s, atr_floor=0.0,
                            vol_mult=1.0, min_stop_pct=0.35)
            acc.setdefault(('rule', v), []).extend(trs)
            st = stats(trs)
            line[v] = st
        # controls on the same candles
        cr = walk_random(c, seed=hash(sym) % 1000, rr=2.0, min_stop_pct=0.35)
        acc.setdefault(('ctrl', 'rand'), []).extend(cr)
        line['ctrl'] = stats(cr)
        # stop-width sweep for the best rule shape
        for stop in (0.75, 1.0, 1.5, 2.0, 3.0):
            for mn in (0.35, 0.60):
                key = ('sweep', 'pullback', stop, mn)
                t2 = m3.walk3m(c, variant='pullback', series=s, stop_mult=stop,
                               atr_floor=0.0, vol_mult=1.0, min_stop_pct=mn)
                acc.setdefault(key, []).extend(t2)
                key3 = ('sweep', 'ignite', stop, mn)
                t3 = m3.walk3m(c, variant='ignite', series=s, stop_mult=stop,
                               atr_floor=0.0, vol_mult=1.0, min_stop_pct=mn)
                acc.setdefault(key3, []).extend(t3)
        per_sym.append(line)
        if len(per_sym) % 4 == 0:
            print(f"  ... {len(per_sym)} symbols done", flush=True)

    print()
    print("=" * 152)
    print("RULES on REAL 3M candles (entry at close, 20-bar time stop, stop 1.5xATR, "
          "R:R 2.0, min stop 0.35%)")
    print("=" * 152)
    for v in VARIANTS:
        print(row(v, stats(acc.get(('rule', v), []))))
    print(row('RANDOM ENTRY control', stats(acc.get(('ctrl', 'rand'), []))))

    print()
    print("=" * 152)
    print("STOP-WIDTH SWEEP  (the fee is 0.25%/stop-width R, so this IS the cost model)")
    print("=" * 152)
    ranked = []
    for k, trs in acc.items():
        if k[0] != 'sweep':
            continue
        st = stats(trs)
        if st:
            ranked.append((k, st))
    ranked.sort(key=lambda kv: -kv[1]['net_avg'])
    for k, st in ranked[:16]:
        _, v, stop, mn = k
        print(row(f"{v} stop{stop:.2f}ATR min{mn:.2f}%", st))
    print()
    print("worst five:")
    for k, st in ranked[-5:]:
        _, v, stop, mn = k
        print(row(f"{v} stop{stop:.2f}ATR min{mn:.2f}%", st))

    print()
    print("=" * 152)
    print("PER-SYMBOL net R (pullback, default settings)")
    print("=" * 152)
    for line in sorted(per_sym, key=lambda d: -(d['pullback']['net'] if d['pullback'] else 0)):
        p, ig, ct = line['pullback'], line['ignite'], line['ctrl']
        def q(x):
            return f"{x['net']:+7.1f}" if x else '      -'
        print(f"{line['sym']:10s} bars {line['bars']:6d}  pullback {q(p)}  "
              f"ignite {q(ig)}  random {q(ct)}")


if __name__ == '__main__':
    main()
