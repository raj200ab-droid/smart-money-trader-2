"""
Split the OLD rule's trades by reward:risk to see whether the RR<1 trades
(the live bug: SOL RR 1:0.28, ETH RR 1:0.11) actually lose money.

Run: python3 tool/mirror/measure_rr_split.py
"""
import os
import sys
import statistics as st
from concurrent.futures import ProcessPoolExecutor

sys.path.insert(0, os.path.dirname(__file__))
from measure_rr import VARIANTS, job

REGIMES = ['mixed', 'trend', 'range', 'volatile']


def line(trs, label):
    rs = [t['r'] for t in trs]
    n = len(rs)
    if n == 0:
        print(f'{label:24s} n=   0')
        return
    m = st.mean(rs)
    sd = st.stdev(rs) if n > 1 else 0.0
    se = sd / (n ** 0.5)
    wr = 100.0 * sum(1 for r in rs if r > 0) / n
    print(f'{label:24s} n={n:4d}  WR={wr:5.1f}%  avgR={m:+.3f}  '
          f'se={se:.3f}  95%CI=[{m - 1.96 * se:+.3f},{m + 1.96 * se:+.3f}]  totalR={sum(rs):+.1f}')


if __name__ == '__main__':
    for name in VARIANTS:
        print(f'variant {name}: minRR={VARIANTS[name][0]} maxStop={VARIANTS[name][1]}%')
    print()

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

    print('\n=== OLD (the rule that shipped) split by reward:risk ===')
    for lo, hi, lab in [(0.0, 1.0, 'RR < 1  (bug trades)'),
                        (1.0, 1.5, 'RR 1.0 - 1.5'),
                        (1.5, 99.0, 'RR >= 1.5')]:
        line([t for t in out['OLD'] if lo <= rr(t) < hi], lab)

    print('\n=== OLD split by stop size ===')
    for lo, hi, lab in [(0.0, 2.5, 'stop <= 2.5%'), (2.5, 8.0, 'stop 2.5 - 8%')]:
        line([t for t in out['OLD'] if lo <= abs(t['sl'] - t['entry']) / t['entry'] * 100 < hi], lab)

    print('\n=== variants overall ===')
    for name in VARIANTS:
        line(out[name], name)
