"""
One clean report for the v10 rules (minimum reward:risk + maximum stop).

Correctness notes that earlier drafts of this measurement got wrong:
  * only CLOSED trades count; a trade still open is not a loss
  * a loser is -1R, a winner is +its own R -- t['r'] is always positive

Gross = R terms. Net = gross - cost_r, where the app's kCostPct = 0.25% round
trip becomes cost_r = 0.25 / stop_pct, so wide stops dilute the fee and narrow
stops are eaten by it.

Run: python3 tool/mirror/measure_rr_report.py
"""
import os
import sys
import statistics as st
from concurrent.futures import ProcessPoolExecutor

sys.path.insert(0, os.path.dirname(__file__))
from measure_rr import VARIANTS, job

REGIMES = ['mixed', 'trend', 'range', 'volatile']
COST_PCT = 0.25


def closed_only(trs):
    return [t for t in trs if t['outcome'] != 'OPEN']


def rr(t):
    d = abs(t['sl'] - t['entry'])
    return abs(t['tp'] - t['entry']) / d if d > 0 else 0.0


def stop_pct(t):
    return abs(t['sl'] - t['entry']) / t['entry'] * 100.0


def cost_r(t):
    s = stop_pct(t)
    return COST_PCT / s if s > 0 else 0.0


def net(t):
    return (t['r'] if t['outcome'] == 'TP' else -1.0) - cost_r(t)


def line(trs, label):
    trs = closed_only(trs)
    n = len(trs)
    if n == 0:
        print(f'{label:26s} n=   0')
        return
    g = sum(t['r'] if t['outcome'] == 'TP' else -1.0 for t in trs)
    nets = [net(t) for t in trs]
    m = st.mean(nets)
    se = (st.stdev(nets) / n ** 0.5) if n > 1 else 0.0
    wr = 100.0 * sum(1 for t in trs if t['outcome'] == 'TP') / n
    print(f'{label:26s} n={n:4d} WR={wr:5.1f}%  gross={g:+7.1f}  net={sum(nets):+7.1f}  '
          f'avgNet={m:+.3f}  se={se:.3f}  '
          f'95%CI=[{m - 1.96 * se:+.3f},{m + 1.96 * se:+.3f}]')


if __name__ == '__main__':
    tasks = [(n, r, s) for n in VARIANTS for r in REGIMES for s in range(12)]
    out = {n: [] for n in VARIANTS}
    with ProcessPoolExecutor(max_workers=2) as ex:
        for i, (name, tr) in enumerate(ex.map(job, tasks, chunksize=4), 1):
            out[name] += tr
            if i % 48 == 0:
                print(f'  {i}/{len(tasks)}', flush=True)

    print(f'\n=== every variant, closed trades only, cost {COST_PCT}%/trade ===')
    for name in VARIANTS:
        line(out[name], name)

    print('\n=== OLD (what shipped) split by reward:risk ===')
    for lo, hi, lab in [(0.0, 1.0, 'RR < 1  (bug trades)'),
                        (1.0, 1.5, 'RR 1.0 - 1.5'),
                        (1.5, 99.0, 'RR >= 1.5')]:
        line([t for t in out['OLD'] if lo <= rr(t) < hi], lab)

    print('\n=== OLD split by stop size ===')
    for lo, hi, lab in [(0.0, 2.5, 'stop <= 2.5%'), (2.5, 8.0, 'stop 2.5 - 8%')]:
        line([t for t in out['OLD'] if lo <= stop_pct(t) < hi], lab)

    print('\n=== RR+CAP split by stop size (what the cap keeps) ===')
    for lo, hi, lab in [(0.0, 1.5, 'stop <= 1.5%'), (1.5, 2.5, 'stop 1.5 - 2.5%')]:
        line([t for t in out['RR+CAP'] if lo <= stop_pct(t) < hi], lab)
