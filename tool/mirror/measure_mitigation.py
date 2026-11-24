"""
Measure LUX's order-block mitigation (High/Low) against the shipped CLOSE rule.

LUX orderBlockMitigationInput defaults to High/Low: a block dies when price
*wickes through* it. The app shipped CLOSE, which keeps blocks alive until a
candle actually closes beyond them -- so more blocks stay 'active' and more
setups find a zone to lean on.

Both variants run on identical synthetic candles. Closed trades only, 0.25%
round-trip cost, cost_r = 0.25 / stop_pct.

Run: python3 tool/mirror/measure_mitigation.py
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
VARIANTS = ['close', 'highlow']


def job(args):
    name, regime, seed = args
    mirror.MITIGATION = name
    c4, c1, c15 = gen(seed, regime=regime)
    return name, mirror.walk(c4, c1, c15, tp_mode='swing')


def line(trs, label):
    trs = [t for t in trs if t['outcome'] != 'OPEN']
    n = len(trs)
    if n == 0:
        print(f'{label:10s} n=   0   (no trades)')
        return
    risk_pct = [abs(t['sl'] - t['entry']) / t['entry'] * 100 for t in trs]
    net = [(t['r'] if t['outcome'] == 'TP' else -1.0) - COST_PCT / r
           for t, r in zip(trs, risk_pct)]
    gross = sum(t['r'] if t['outcome'] == 'TP' else -1.0 for t in trs)
    m = st.mean(net)
    se = st.stdev(net) / n ** 0.5 if n > 1 else 0.0
    wr = 100 * sum(1 for t in trs if t['outcome'] == 'TP') / n
    print(f'{label:10s} n={n:4d}  WR={wr:5.1f}%  gross={gross:+7.1f}R  '
          f'net={sum(net):+7.1f}R  avgNet={m:+.3f}  se={se:.3f}  '
          f'CI=[{m - 1.96 * se:+.3f},{m + 1.96 * se:+.3f}]')


if __name__ == '__main__':
    tasks = [(n, r, s) for n in VARIANTS for r in REGIMES for s in range(12)]
    out = {n: [] for n in VARIANTS}
    with ProcessPoolExecutor(max_workers=2) as ex:
        for i, (name, tr) in enumerate(ex.map(job, tasks, chunksize=4), 1):
            out[name] += tr
            if i % 48 == 0:
                print(f'  {i}/{len(tasks)}', flush=True)

    print(f'\norder-block mitigation, cost {COST_PCT}%/trade, closed only\n')
    for k in VARIANTS:
        line(out[k], k)

    a = len([t for t in out['close'] if t['outcome'] != 'OPEN'])
    b = len([t for t in out['highlow'] if t['outcome'] != 'OPEN'])
    if a:
        print(f'\nsignal count: close {a} -> highlow {b}  '
              f'({(b - a) / a * 100:+.1f}%)')
    else:
        print('\nclose variant produced no closed trades')
