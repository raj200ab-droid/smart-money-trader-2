"""
Measure the two rules added in v10: minimum reward:risk and maximum stop size.

Run: python3 tool/mirror/measure_rr.py

Paired on identical synthetic candles. Three variants:
  OLD   : target = any 15M swing beyond entry, stop capped at 8%
  RR    : target = 15M swing only if >= 1.5R, else 2R   (stop cap still 8%)
  RR+CAP: the above, and stops wider than 2.5% are rejected
"""
import os
import sys
import random
from concurrent.futures import ProcessPoolExecutor

sys.path.insert(0, os.path.dirname(__file__))
import mirror
from mirror import summarise
from measure_tp import gen

VARIANTS = {'OLD': (0.0, 8.0), 'RR': (1.5, 8.0), 'RR+CAP': (1.5, 2.5)}


def job(args):
    name, regime, seed = args
    min_rr, max_stop = VARIANTS[name]
    mirror.MIN_RR, mirror.MAX_STOP_PCT = min_rr, max_stop
    c4, c1, c15 = gen(seed, regime=regime)
    return name, mirror.walk(c4, c1, c15, tp_mode='swing')


if __name__ == '__main__':
    random.seed(1)
    regimes = ['mixed', 'trend', 'range', 'volatile']
    tasks = [(n, r, s) for n in VARIANTS for r in regimes for s in range(12)]
    out = {n: [] for n in VARIANTS}
    with ProcessPoolExecutor(max_workers=2) as ex:
        for i, (name, tr) in enumerate(ex.map(job, tasks, chunksize=4), 1):
            out[name] += tr
            if i % 36 == 0:
                print(f'  {i}/{len(tasks)}', flush=True)

    print()
    print('=' * 92)
    print(f"{'variant':9s} {'trades':>7s} {'closed':>7s} {'WR':>7s} {'totalR':>8s} {'avgR':>7s} {'minRR':>6s} {'maxStop':>7s}")
    for name, (min_rr, max_stop) in VARIANTS.items():
        su = summarise(out[name])
        print(f"{name:9s} {su['trades']:7d} {su['closed']:7d} {su['winRate']:6.1f}% "
              f"{su['totalR']:+8.1f} {su['avgR']:+7.3f} {min_rr:6.1f} {max_stop:6.1f}%")

    print()
    print('worst trade each variant was willing to ship (RR of the first bad one):')
    for name in VARIANTS:
        bad = sorted(out[name], key=lambda t: t['r'])[:1]
        rrs = [abs(t['tp'] - t['entry']) / abs(t['sl'] - t['entry'])
               for t in out[name] if abs(t['sl'] - t['entry']) > 0]
        if rrs:
            print(f"  {name:9s} n={len(rrs):4d}  min RR {min(rrs):.2f}  "
                  f"median RR {sorted(rrs)[len(rrs)//2]:.2f}  max RR {max(rrs):.2f}")
