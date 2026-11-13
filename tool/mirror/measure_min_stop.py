"""
Should a stop narrower than the round-trip fee be rejected?

Device evidence (v17.3, scalp mode, STRICT SELL 90%):

    SOL   entry 85.1900  SL 85.5086  -> stop 0.374%  TP 0.748%
    BCH   entry 236.5000 SL 237.3304 -> stop 0.351%  TP 0.702%

At the 0.25% round trip the app models, the fee is 67-71% of ONE R. A 2R
winner returns 0.75% gross and 0.50% net -- the card says +0.75%, the account
sees two thirds of it.

A 0.5% floor is the obvious response. It is also a RULE, so it gets measured
before it ships: it can only remove trades, and the trades it removes might be
the good ones (that is exactly what happened with the fresh-BOS filter, which
cost 24.4R).

Variants: no floor, 0.3%, 0.5%, 0.8%.

Run: python3 tool/mirror/measure_min_stop.py [seeds]
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
FLOORS = [0.0, 0.3, 0.5, 0.8]


def job(args):
    regime, seed = args
    out = {}
    for mode, genfn in (('swing', gen), ('scalp', gen_scalp)):
        a, b, c = genfn(seed, regime=regime)
        for floor in FLOORS:
            out[(mode, floor)] = mirror.walk(
                a, b, c, tp_mode='swing', min_stop_pct=floor)
    return regime, out


def refusal_report(trades, floors):
    """The only honest way to read a filter on a stateful walk.

    walk() takes one trade at a time and blocks re-entry while a position is
    open, so adding a floor does not simply delete trades -- it shifts every
    later entry, and comparing two totals reads a different market rather than
    a better rule. (Measured: the naive comparison said +24R; the truth is
    +21.6R from a different mechanism, and the two only agreed by accident.)

    So: take the trades the CURRENT engine actually takes, and ask what the
    sub-floor ones were worth. "If these had not existed" is a property of each
    trade, not of the walk.
    """
    print(f"\n{'floor':>6s} {'refused':>8s} {'their gross':>12s} "
          f"{'their net':>11s} {'net without them':>17s}")
    base_net = sum(x[2] for x in trades)
    for f in floors:
        ref = [x for x in trades if x[0] < f]
        keep = sum(x[2] for x in trades if x[0] >= f)
        print(f'{f:5.1f}% {len(ref):8d} {sum(x[1] for x in ref):+12.1f} '
              f'{sum(x[2] for x in ref):+11.1f} {keep:+17.1f}')
    print(f'\nbaseline net R (no floor): {base_net:+.1f}')


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
        'per': sum(gross) / len(gross),
    }


if __name__ == '__main__':
    seeds = int(sys.argv[1]) if len(sys.argv) > 1 else 6
    tasks = [(r, s) for r in REGIMES for s in range(seeds)]
    res = {}
    per = {}
    with ProcessPoolExecutor(max_workers=2) as ex:
        for i, (reg, out) in enumerate(ex.map(job, tasks, chunksize=1), 1):
            for k, v in out.items():
                res.setdefault(k, []).extend(v)
                per.setdefault(k, {}).setdefault(reg, []).extend(v)
            if i % 8 == 0:
                print(f'  {i}/{len(tasks)}', flush=True)

    for mode in ('scalp', 'swing'):
        print(f'\n{mode.upper()} horizons -- minimum stop, cost {COST_PCT}% '
              f'round trip, {seeds} seeds x 4 regimes\n')
        print(f"{'minStop':8s} {'n':>5s} {'WR':>7s} {'gross':>9s} {'net':>9s} "
              f"{'R/trade':>9s} {'avgStop':>8s}")
        base = None
        for floor in FLOORS:
            d = stats(res[(mode, floor)])
            label = 'none' if floor == 0 else f'{floor:.1f}%'
            if not d:
                print(f'{label:8s} no trades')
                continue
            if base is None:
                base = d
            print(f"{label:8s} {d['n']:5d} {d['wr']:6.1f}% {d['gross']:+9.1f} "
                  f"{d['net']:+9.1f} {d['per']:+9.3f} {d['avgStop']:7.2f}%")
        # Totals from different floors are NOT comparable: each walk is a
        # different sequence of entries. The honest read is the refusal report.
        rows = [(abs(t['sl'] - t['entry']) / t['entry'] * 100,
                 (t['r'] if t['outcome'] == 'TP' else -1.0),
                 (t['r'] if t['outcome'] == 'TP' else -1.0)
                 - COST_PCT / (abs(t['sl'] - t['entry']) / t['entry'] * 100))
                for t in res[(mode, 0.0)] if t['outcome'] != 'OPEN']
        print('\n  what a floor would refuse, from the no-floor trade list:')
        refusal_report(rows, FLOORS[1:])
        print('\n  (the totals above are NOT comparable -- each floor runs a\n'
              '   different sequence of entries; see refusal_report)')

        print('\n  per regime (net R)')
        for reg in REGIMES:
            row = f'    {reg:9s}'
            for floor in FLOORS:
                d = stats(per[(mode, floor)][reg])
                row += f'{d["net"]:+8.1f} ' if d else '     n/a '
            print(row)
