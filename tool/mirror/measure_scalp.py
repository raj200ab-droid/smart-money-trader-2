"""
Measure scalp mode (30M bias / 15M zones / 5M trigger) against swing
(4H / 1H / 15M) on identical price paths.

Every rule, weight, gate, stop and target is identical between the two -- only
the horizons differ. So this answers one question: does the same engine, applied
to shorter timeframes, produce a better or worse edge?

Note on cost: scalping trades more often and holds for less. The 0.25% round
trip is fixed, but the stop is smaller, so the SAME fee eats a much larger share
of each R. That is exactly what this measures -- report cost_r per trade.

Run: python3 tool/mirror/measure_scalp.py
"""
import os
import sys
import statistics as st
from concurrent.futures import ProcessPoolExecutor

sys.path.insert(0, os.path.dirname(__file__))
import mirror
from measure_tp import gen, gen_scalp

REGIMES = ['mixed', 'trend', 'range', 'volatile']
COST_PCT = 0.25
MODES = ['swing', 'scalp']


def job(args):
    mode, regime, seed = args
    if mode == 'swing':
        a, b, c = gen(seed, regime=regime)
    else:
        a, b, c = gen_scalp(seed, regime=regime)
    return mode, regime, mirror.walk(a, b, c, tp_mode='swing')


def stats(trs):
    trs = [t for t in trs if t['outcome'] != 'OPEN']
    if not trs:
        return None
    risk = [abs(t['sl'] - t['entry']) / t['entry'] * 100 for t in trs]
    gross = [t['r'] if t['outcome'] == 'TP' else -1.0 for t in trs]
    net = [g - COST_PCT / r for g, r in zip(gross, risk)]
    return {
        'n': len(trs),
        'wr': 100 * sum(1 for t in trs if t['outcome'] == 'TP') / len(trs),
        'gross': sum(gross),
        'net': sum(net),
        'avgStop': st.mean(risk),
        'avgCost': st.mean(COST_PCT / r for r in risk),
    }


if __name__ == '__main__':
    tasks = [(m, r, s) for m in MODES for r in REGIMES for s in range(12)]
    out = {m: [] for m in MODES}
    per = {m: {r: [] for r in REGIMES} for m in MODES}
    with ProcessPoolExecutor(max_workers=2) as ex:
        for i, (mode, reg, tr) in enumerate(ex.map(job, tasks, chunksize=4), 1):
            out[mode] += tr
            per[mode][reg] += tr
            if i % 48 == 0:
                print(f'  {i}/{len(tasks)}', flush=True)

    print(f'\nscalp vs swing, identical rules, cost {COST_PCT}% round trip\n')
    print(f"{'mode':7s} {'n':>5s} {'WR':>7s} {'gross':>8s} {'net':>8s} "
          f"{'avgStop':>8s} {'cost/trade':>11s}")
    for m in MODES:
        d = stats(out[m])
        if d:
            print(f"{m:7s} {d['n']:5d} {d['wr']:6.1f}% {d['gross']:+8.1f} "
                  f"{d['net']:+8.1f} {d['avgStop']:7.2f}% {d['avgCost']:10.3f}R")
        else:
            print(f'{m:7s} no trades')

    print('\nper regime (net R)')
    for reg in REGIMES:
        a, b = stats(per['swing'][reg]), stats(per['scalp'][reg])
        sa = f"{a['net']:+7.1f}" if a else '   n/a '
        sb = f"{b['net']:+7.1f}" if b else '   n/a '
        na = a['n'] if a else 0
        nb = b['n'] if b else 0
        print(f'  {reg:9s} swing {sa} ({na:3d})   scalp {sb} ({nb:3d})')
