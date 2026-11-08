"""
Cost-aware view of the same three variants.

The app charges kCostPct = 0.25% of entry per round trip. In R units that is
     cost_r = 0.25 / stop_pct
so a wide stop dilutes the cost and a narrow stop is eaten by it. This script
reports gross and net totalR per variant and per RR bucket.

Run: python3 tool/mirror/measure_rr_split.py --cost
"""
import os
import sys
import statistics as st
from concurrent.futures import ProcessPoolExecutor

sys.path.insert(0, os.path.dirname(__file__))
from measure_rr import VARIANTS, job

REGIMES = ['mixed', 'trend', 'range', 'volatile']
COST_PCT = 0.25


def stop_pct(t):
    return abs(t['sl'] - t['entry']) / t['entry'] * 100.0


def cost_r(t):
    s = stop_pct(t)
    return COST_PCT / s if s > 0 else 0.0


def gross(t):
    return t['r'] if t['outcome'] == 'TP' else -1.0


def line(trs, label):
    n = len(trs)
    if n == 0:
        print(f'{label:26s} n=   0')
        return
    g = sum(gross(t) for t in trs)
    net = [gross(t) - cost_r(t) for t in trs]
    m = st.mean(net)
    se = (st.stdev(net) / n ** 0.5) if n > 1 else 0.0
    wr = 100.0 * sum(1 for t in trs if t['outcome'] == 'TP') / n
    avg_cost = st.mean(cost_r(t) for t in trs)
    print(f'{label:26s} n={n:4d} WR={wr:5.1f}%  gross={g:+7.1f}  net={sum(net):+7.1f}  '
          f'avgR={m:+.3f} se={se:.3f}  avgCost={avg_cost:.3f}R')


if __name__ == '__main__':
    tasks = [(n, r, s) for n in VARIANTS for r in REGIMES for s in range(12)]
    out = {n: [] for n in VARIANTS}
    with ProcessPoolExecutor(max_workers=2) as ex:
        for i, (name, tr) in enumerate(ex.map(job, tasks, chunksize=4), 1):
            out[name] += tr
            if i % 48 == 0:
                print(f'  {i}/{len(tasks)}', flush=True)

    def rr(t):
        d = abs(t['sl'] - t['entry'])
        return abs(t['tp'] - t['entry']) / d if d > 0 else 0.0

    print(f'\n=== OLD split by reward:risk (cost {COST_PCT}% round trip) ===')
    for lo, hi, lab in [(0.0, 1.0, 'RR < 1  (bug trades)'),
                        (1.0, 1.5, 'RR 1.0 - 1.5'),
                        (1.5, 99.0, 'RR >= 1.5')]:
        line([t for t in out['OLD'] if lo <= rr(t) < hi], lab)

    print('\n=== OLD split by stop size ===')
    for lo, hi, lab in [(0.0, 2.5, 'stop <= 2.5%'), (2.5, 8.0, 'stop 2.5 - 8%')]:
        line([t for t in out['OLD'] if lo <= stop_pct(t) < hi], lab)

    print('\n=== variants overall, net of cost ===')
    for name in VARIANTS:
        line(out[name], name)
