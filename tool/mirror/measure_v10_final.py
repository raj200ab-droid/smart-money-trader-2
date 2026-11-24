"""
Final comparison for v10: shipped rule vs the minimum-R:R rule.

OLD  : target = any 15M swing beyond entry (>= 0.5% away), else 2R
RR   : target = 15M swing only if it is worth >= 1.5R, else 2R
       (this is the only engine change in v10)

Both use the shipped 8% stop bound and the app's 0.25% round-trip cost.

Run: python3 tool/mirror/measure_v10_final.py
"""
import os
import sys
import statistics as st
from concurrent.futures import ProcessPoolExecutor

sys.path.insert(0, os.path.dirname(__file__))
import mirror
from measure_tp import gen

REGIMES = ['mixed', 'trend', 'range', 'volatile']
COST_PCT = 0.25


def job(a):
    name, regime, seed = a
    mirror.MIN_RR = 0.5 if name == 'OLD' else 1.5
    c4, c1, c15 = gen(seed, regime=regime)
    return name, mirror.walk(c4, c1, c15, tp_mode='swing')


def line(trs, label):
    trs = [t for t in trs if t['outcome'] != 'OPEN']
    n = len(trs)
    if not n:
        print(f'{label:8s} n=0')
        return
    risk_pct = [abs(t['sl'] - t['entry']) / t['entry'] * 100 for t in trs]
    net = [(t['r'] if t['outcome'] == 'TP' else -1.0) - COST_PCT / r for t, r in zip(trs, risk_pct)]
    gross = sum(t['r'] if t['outcome'] == 'TP' else -1.0 for t in trs)
    m = st.mean(net)
    se = st.stdev(net) / n ** 0.5 if n > 1 else 0.0
    wr = 100 * sum(1 for t in trs if t['outcome'] == 'TP') / n
    rr = [abs(t['tp'] - t['entry']) / abs(t['sl'] - t['entry']) for t in trs]
    print(f'{label:8s} n={n:4d} WR={wr:5.1f}%  gross={gross:+7.1f}R  net={sum(net):+7.1f}R  '
          f'avgNet={m:+.3f}  se={se:.3f}  CI=[{m - 1.96 * se:+.3f},{m + 1.96 * se:+.3f}]  '
          f'minRR={min(rr):.2f} medianRR={sorted(rr)[n // 2]:.2f}')


if __name__ == '__main__':
    tasks = [(n, r, s) for n in ('OLD', 'RR') for r in REGIMES for s in range(12)]
    out = {'OLD': [], 'RR': []}
    with ProcessPoolExecutor(max_workers=2) as ex:
        for i, (name, tr) in enumerate(ex.map(job, tasks, chunksize=4), 1):
            out[name] += tr
            if i % 48 == 0:
                print(f'  {i}/{len(tasks)}', flush=True)
    print(f'\ncost {COST_PCT}%/trade, closed trades only\n')
    for k in ('OLD', 'RR'):
        line(out[k], k)
    print('\ntrades the RR rule refused (old would ship them):')
    for name, min_rr in (('OLD', 0.5),):
        pass
    old_rr = [abs(t['tp'] - t['entry']) / abs(t['sl'] - t['entry']) for t in out['OLD']
              if t['outcome'] != 'OPEN']
    print(f'  {sum(1 for r in old_rr if r < 1.5)} of {len(old_rr)} old-rule trades were below 1.5R')
