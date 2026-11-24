"""
Which 3-minute scalping rule pays the fee?  (v2 -- with controls)

Design notes, because the numbers are worthless without them
------------------------------------------------------------
1. PAIRED. Every variant sees the identical candle path. Comparisons are
   therefore about the rule, not about a luckier market.

2. COST CHARGED PER TRADE, from that trade's own stop width:

       cost_R = 0.25% / (stop % of price)

   A 1.2% stop pays 0.21R of fee. This is why the shipped single3m mode lost
   -259.9R net while looking positive gross: the fee is not a constant, it is
   inversely proportional to the stop, and a 3M stop is narrow by construction.

3. A RANDOM-ENTRY CONTROL with the same stop / target / time stop / direction
   mix. If a rule cannot beat coin-flip entries taken in the same trend
   direction, the rule is not a signal, it is a coin flip with extra steps.
   This is the honest test, and it is the one most "3M strategy" backtests skip.

4. BOOTSTRAP CI on net R per trade. The same rule on different seeds is one
   sample; a ±0.05R difference with an ±0.30R error bar is not a result.

5. Synthetic volume is noise in this harness (the generator draws it
   independently of price), so the volume gate is tested BOTH on and off and
   never used to explain a win.

Run: python3 tool/mirror/measure_3m_scalp.py [seeds] [minutes] [block]
     block=1 -> also run the slower sweep grid
"""
import os
import random
import statistics as st
import sys
from concurrent.futures import ProcessPoolExecutor

sys.path.insert(0, os.path.dirname(__file__))
import mirror3m as m3
from measure_tp import gen_3m

REGIMES = ['mixed', 'trend', 'range', 'volatile']


# ------------------------------------------------------------------ control
def walk_random(c, seed=0, rr=2.0, stop_mult=1.5, hold=m3.TIME_STOP,
                max_trades=4000, trend_only=True):
    """Same mechanics, entries chosen by a coin flip.

    Direction is drawn from the EMA stack when `trend_only` (so the control is
    not handicapped by fighting the trend -- that would flatter the real rule
    for the wrong reason), else it is a plain 50/50.
    """
    s = m3.Series(c)
    rnd = random.Random(seed)
    n = len(c)
    trades = []
    i = s.warm
    while i < n - 1:
        if trend_only:
            up = s.e9[i] > s.e21[i] > s.e50[i]
            dn = s.e9[i] < s.e21[i] < s.e50[i]
            if not (up or dn):
                i += 1
                continue
            is_buy = up
        else:
            is_buy = rnd.random() < 0.5
        px = c[i]['close']
        a = s.atr[i]
        if a <= 0 or px <= 0:
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
        if risk <= 0:
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
        if len(trades) >= max_trades:
            break
    return trades


# ------------------------------------------------------------------ stats
def boot_ci(vals, iters=2000, seed=7):
    """95% CI of the MEAN, by resampling (the trade distribution is fat-tailed)."""
    if len(vals) < 20:
        return (float('nan'), float('nan'))
    rnd = random.Random(seed)
    n = len(vals)
    means = []
    for _ in range(iters):
        means.append(sum(rnd.choice(vals) for _ in range(n)) / n)
    means.sort()
    return means[int(iters * 0.025)], means[int(iters * 0.975)]


def stats(trs):
    if not trs:
        return None
    cost = [m3.COST_PCT / 100.0 * t['entry'] / t['risk'] for t in trs]
    gross = [t['r'] for t in trs]
    net = [g - c for g, c in zip(gross, cost)]
    lo, hi = boot_ci(net)
    return {'n': len(trs), 'wr': sum(1 for g in gross if g > 0) / len(trs) * 100,
            'gross': sum(gross), 'net': sum(net),
            'net_avg': sum(net) / len(trs), 'lo': lo, 'hi': hi,
            'cost': sum(cost) / len(trs),
            'stop': sum(t['risk'] / t['entry'] * 100 for t in trs) / len(trs)}


def row(name, s):
    if s is None:
        return f"{name:30s} no trades"
    star = ''
    if s['lo'] == s['lo']:      # not nan
        star = '  CI>0' if s['lo'] > 0 else ('  CI<0' if s['hi'] < 0 else '')
    return (f"{name:30s} n {s['n']:5d}  WR {s['wr']:5.1f}%  "
            f"gross {s['gross']:+8.1f}R  net {s['net']:+8.1f}R  "
            f"net/tr {s['net_avg']:+.3f} [{s['lo']:+.3f},{s['hi']:+.3f}]{star:<5s} "
            f"cost {s['cost']:.2f}R  stop {s['stop']:.2f}%")


def job(args):
    regime, seed, minutes = args
    c, _, _ = gen_3m(seed, minutes=minutes, regime=regime)
    out = {}
    for v in ('ignite', 'pullback', 'bandrev', 'both'):
        for vol in (1.0, 1.5):
            out[('rule', v, vol)] = m3.walk3m(c, variant=v, vol_mult=vol)
    for stop in (1.0, 1.5, 2.0):
        for rr in (1.5, 2.0, 3.0):
            for be in (0.0, 1.0):
                key = ('sweep', 'pullback', stop, rr, be)
                out[key] = m3.walk3m(c, variant='pullback', stop_mult=stop,
                                     rr=rr, be_at=be)
                key2 = ('sweep', 'both', stop, rr, be)
                out[key2] = m3.walk3m(c, variant='both', stop_mult=stop,
                                      rr=rr, be_at=be)
    out[('ctrl', 'trend', 2.0)] = walk_random(c, seed=seed, rr=2.0)
    out[('ctrl', 'trend', 3.0)] = walk_random(c, seed=seed + 99, rr=3.0)
    out[('ctrl', 'coinf', 2.0)] = walk_random(c, seed=seed + 7, rr=2.0,
                                              trend_only=False)
    return out


def main():
    seeds = int(sys.argv[1]) if len(sys.argv) > 1 else 4
    minutes = int(sys.argv[2]) if len(sys.argv) > 2 else 20000
    tasks = [(r, s, minutes) for r in REGIMES for s in range(seeds)]
    acc = {}
    with ProcessPoolExecutor(max_workers=4) as ex:
        for out in ex.map(job, tasks, chunksize=1):
            for k, trs in out.items():
                acc.setdefault(k, []).extend(trs)

    print("=" * 150)
    print(f"3M SCALP RULES  |  {seeds} seeds x 4 regimes, {minutes} 1M bars each, "
          f"cost {m3.COST_PCT}% round trip charged per trade from its own stop")
    print("=" * 150)
    for v in ('ignite', 'pullback', 'bandrev', 'both'):
        for vol in (1.0, 1.5):
            tag = 'volume ON ' if vol > 1.0 else 'volume off'
            print(row(f"{v} ({tag})", stats(acc.get(('rule', v, vol), []))))

    print()
    print("CONTROLS -- same stop/target/time stop, entries chosen at random")
    print(row("random entries, with trend", stats(acc.get(('ctrl', 'trend', 2.0), []))))
    print(row("random entries, rr 3.0", stats(acc.get(('ctrl', 'trend', 3.0), []))))
    print(row("coin-flip direction", stats(acc.get(('ctrl', 'coinf', 2.0), []))))

    print()
    print("SWEEP -- ranked by net R (stop x R:R x break-even)")
    ranked = []
    for k, trs in acc.items():
        if k[0] != 'sweep':
            continue
        s = stats(trs)
        if s:
            ranked.append((k, s))
    ranked.sort(key=lambda kv: -kv[1]['net'])
    for k, s in ranked[:14]:
        _, v, stop, rr, be = k
        print(row(f"{v} stop{stop:.1f} rr{rr:.1f} be{int(be)}", s))
    print()
    print("worst five:")
    for k, s in ranked[-5:]:
        _, v, stop, rr, be = k
        print(row(f"{v} stop{stop:.1f} rr{rr:.1f} be{int(be)}", s))


if __name__ == '__main__':
    main()
