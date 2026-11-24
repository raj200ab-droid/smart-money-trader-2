"""
Measure v15's "prefer the 15M swing as the stop when it is closer".

All four STRICT cards on the v14 device screenshot showed RR 1:2.00 exactly,
with 3.2-5.8% stops. That means the kMinRR gate never once accepted the 15M
swing target: the stop came from 1H structure (OB/FVG high) while the target
came from a 15M swing, and a 15M swing is almost never 1.5x a 1H stop away.

So since v10 the structural target has been dead code on these signals, and
every trade was a mechanical 2R. TIGHT_STOP fixes the horizon mismatch by
letting the 15M swing act as the stop when it is tighter than the 1H block.

Run: python3 tool/mirror/measure_tight_stop.py
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


def job(args):
    name, regime, seed = args
    mirror.TIGHT_STOP = (name == 'tight')
    c4, c1, c15 = gen(seed, regime=regime)
    return name, regime, mirror.walk(c4, c1, c15, tp_mode='swing')


def stats(trs):
    trs = [t for t in trs if t['outcome'] != 'OPEN']
    if not trs:
        return None
    risk = [abs(t['sl'] - t['entry']) / t['entry'] * 100 for t in trs]
    net = [(t['r'] if t['outcome'] == 'TP' else -1.0) - COST_PCT / r
           for t, r in zip(trs, risk)]
    rr = [abs(t['tp'] - t['entry']) / abs(t['sl'] - t['entry']) for t in trs]
    return {
        'n': len(trs),
        'wr': 100 * sum(1 for t in trs if t['outcome'] == 'TP') / len(trs),
        'gross': sum(t['r'] if t['outcome'] == 'TP' else -1.0 for t in trs),
        'net': sum(net),
        'avg': st.mean(net),
        'se': st.stdev(net) / len(net) ** 0.5 if len(net) > 1 else 0.0,
        'medianRR': sorted(rr)[len(rr) // 2],
        'fallbackPct': 100 * sum(1 for r in rr if abs(r - 2.0) < 0.02) / len(rr),
        'avgStop': st.mean(risk),
    }


if __name__ == '__main__':
    tasks = [(n, r, s) for n in ('loose', 'tight') for r in REGIMES for s in range(12)]
    out = {n: [] for n in ('loose', 'tight')}
    per = {n: {r: [] for r in REGIMES} for n in ('loose', 'tight')}
    with ProcessPoolExecutor(max_workers=2) as ex:
        for i, (name, reg, tr) in enumerate(ex.map(job, tasks, chunksize=4), 1):
            out[name] += tr
            per[name][reg] += tr
            if i % 48 == 0:
                print(f'  {i}/{len(tasks)}', flush=True)

    print(f'\n15M-swing stop when tighter, cost {COST_PCT}%, closed only\n')
    print(f"{'variant':8s} {'n':>5s} {'WR':>7s} {'gross':>8s} {'net':>8s} {'avgStop':>8s} {'2R-fallback':>12s}")
    for n in ('loose', 'tight'):
        d = stats(out[n])
        print(f"{n:8s} {d['n']:5d} {d['wr']:6.1f}% {d['gross']:+8.1f} {d['net']:+8.1f} "
              f"{d['avgStop']:7.2f}% {d['fallbackPct']:11.0f}%")

    print('\nper regime (net R)')
    for reg in REGIMES:
        a, b = stats(per['loose'][reg]), stats(per['tight'][reg])
        if a and b:
            print(f"  {reg:9s} loose {a['net']:+7.1f}R   tight {b['net']:+7.1f}R   "
                  f"delta {b['net'] - a['net']:+7.1f}R   "
                  f"(2R-fallback {a['fallbackPct']:.0f}% -> {b['fallbackPct']:.0f}%)")
