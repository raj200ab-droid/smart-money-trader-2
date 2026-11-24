"""
Does requiring a FRESH BOS (instead of "price still holding beyond a pivot that
broke at any time") change the edge?

The device showed `5M bullish break 21 bar age`: the trigger was 105 minutes old.
The user wants confirmation at the break itself, not an old break that price is
still sitting above. This measures that change before it goes anywhere near the
app.

Variants, all on scalp horizons (30M/15M/5M) so the 5M trigger is the one being
tested:

  holding   -- shipped behaviour: break event + price beyond the level, no age cap
  fresh0    -- break must be on the most recent CLOSED bar
  fresh1    -- break up to 1 closed bar old
  fresh2    -- break up to 2 closed bars old

The rule only ever REMOVES signals (it adds a condition), so every variant is a
subset of `holding` at entry-time. Fewer trades is not automatically worse: the
question is what the removed trades were worth. Cost is charged per trade, so
the report shows gross and net separately -- a subset with a higher win rate can
still be worse in R if it removes the winners.

Run: python3 tool/mirror/measure_fresh_bos.py
"""
import os
import sys
import statistics as st
from concurrent.futures import ProcessPoolExecutor

sys.path.insert(0, os.path.dirname(__file__))
import mirror
from measure_tp import gen_scalp

REGIMES = ['mixed', 'trend', 'range', 'volatile']
COST_PCT = 0.25
VARIANTS = [('holding', False, 0), ('fresh0', True, 0),
            ('fresh1', True, 1), ('fresh2', True, 2)]


def job(args):
    regime, seed = args
    a, b, c = gen_scalp(seed, regime=regime)
    out = {}
    for name, fo, fb in VARIANTS:
        out[name] = mirror.walk(a, b, c, tp_mode='swing',
                                fresh_only=fo, fresh_bars=fb)
    return regime, out


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
    seeds = int(sys.argv[1]) if len(sys.argv) > 1 else 8
    tasks = [(r, s) for r in REGIMES for s in range(seeds)]
    res = {name: [] for name, _, _ in VARIANTS}
    per = {name: {r: [] for r in REGIMES} for name, _, _ in VARIANTS}

    with ProcessPoolExecutor(max_workers=2) as ex:
        for i, (reg, out) in enumerate(ex.map(job, tasks, chunksize=1), 1):
            for name in res:
                res[name] += out[name]
                per[name][reg] += out[name]
            if i % 8 == 0:
                print(f'  {i}/{len(tasks)}', flush=True)

    print(f'\nscalp horizons 30M/15M/5M -- fresh-BOS requirement, '
          f'cost {COST_PCT}% round trip, {seeds} seeds x 4 regimes\n')
    print(f"{'variant':9s} {'n':>5s} {'WR':>7s} {'gross':>9s} {'net':>9s} "
          f"{'R/trade':>9s} {'avgStop':>8s}")
    base = None
    for name, _, _ in VARIANTS:
        d = stats(res[name])
        if not d:
            print(f'{name:9s} no trades')
            continue
        if base is None:
            base = d
        print(f"{name:9s} {d['n']:5d} {d['wr']:6.1f}% {d['gross']:+9.1f} "
              f"{d['net']:+9.1f} {d['per']:+9.3f} {d['avgStop']:7.2f}%")

    print('\nper regime (net R)')
    hdr = '  ' + f"{'regime':10s}" + ''.join(f'{n:>10s}' for n, _, _ in VARIANTS)
    print(hdr)
    for reg in REGIMES:
        row = f'  {reg:10s}'
        for name, _, _ in VARIANTS:
            d = stats(per[name][reg])
            row += f"{d['net']:+9.1f} " if d else '      n/a '
        print(row)

    print('\ndelta vs holding (net R, negative = worse)')
    for name, _, _ in VARIANTS[1:]:
        d = stats(res[name])
        if d and base:
            print(f'  {name:9s} {d["net"] - base["net"]:+8.1f}R   '
                  f'{d["n"] - base["n"]:+5d} trades')
