"""
Does the engine work on ONE timeframe?

The ask: a 3-minute mode that analyses only 3M candles and fires as soon as a
candle closes. The engine wants three series (bias / zone / trigger), so a
single-timeframe mode feeds the same 3M series into all three slots.

That is not a cosmetic change. When bias, zone and trigger are the same series,
one structure break counts three times:

    bias      +30   <- 3M trend
    zone OB   +25   <- 3M order block
    zone FVG  +20   <- 3M fair value gap
    trigger   +20   <- 3M break
    volume     +5
    ----------------
             = 100, and the STRICT gate is 60

So a single timeframe can clear the gate on its own evidence. Whether that is
informative or just a doubled count is a question for data, not opinion.

This measures, on identical price paths:
  single3M   -- 3M into all three slots (the requested mode)
  scala      -- 30M/15M/5M, the shipped scalp stack, for contrast
  swing      -- 4H/1H/15M, for contrast

All with the 0.5% minimum stop from v17.4 and a 0.25% round trip, closed trades
only.

Run: python3 tool/mirror/measure_single_tf.py [seeds]
"""
import os
import sys
import statistics as st
from concurrent.futures import ProcessPoolExecutor

sys.path.insert(0, os.path.dirname(__file__))
import mirror
from measure_tp import gen, gen_scalp, gen_3m

REGIMES = ['mixed', 'trend', 'range', 'volatile']
COST_PCT = 0.25


def job(args):
    regime, seed = args
    out = {}
    for name, genfn in (('single3M', gen_3m), ('scalp', gen_scalp),
                        ('swing', gen)):
        a, b, c = genfn(seed, regime=regime)
        out[name] = mirror.walk(a, b, c, tp_mode='swing')
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
        'avgCost': st.mean(COST_PCT / r for r in risk),
    }


if __name__ == '__main__':
    seeds = int(sys.argv[1]) if len(sys.argv) > 1 else 8
    tasks = [(r, s) for r in REGIMES for s in range(seeds)]
    res = {k: [] for k in ('single3M', 'scalp', 'swing')}
    per = {k: {r: [] for r in REGIMES} for k in res}
    with ProcessPoolExecutor(max_workers=2) as ex:
        for i, (reg, out) in enumerate(ex.map(job, tasks, chunksize=1), 1):
            for k, v in out.items():
                res[k] += v
                per[k][reg] += v
            if i % 8 == 0:
                print(f'  {i}/{len(tasks)}', flush=True)

    print(f'\nsingle 3M vs the multi-timeframe stacks, cost {COST_PCT}% round '
          f'trip, {seeds} seeds x 4 regimes\n')
    print(f"{'mode':9s} {'n':>5s} {'WR':>7s} {'gross':>9s} {'net':>9s} "
          f"{'R/trade':>9s} {'avgStop':>8s} {'cost/trade':>11s}")
    for k in ('single3M', 'scalp', 'swing'):
        d = stats(res[k])
        if not d:
            print(f'{k:9s} no trades')
            continue
        print(f"{k:9s} {d['n']:5d} {d['wr']:6.1f}% {d['gross']:+9.1f} "
              f"{d['net']:+9.1f} {d['gross']/d['n']:+9.3f} {d['avgStop']:7.2f}% "
              f"{d['avgCost']:10.3f}R")

    print('\nper regime (net R)')
    print(f"  {'regime':10s}" + ''.join(f'{k:>11s}' for k in
                                        ('single3M', 'scalp', 'swing')))
    for reg in REGIMES:
        row = f'  {reg:10s}'
        for k in ('single3M', 'scalp', 'swing'):
            d = stats(per[k][reg])
            row += f'{d["net"]:+10.1f} ' if d else '       n/a '
        print(row)

    d3 = stats(res['single3M'])
    if d3:
        print(f"\nsingle3M: {d3['n']} trades, gross {d3['gross']:+.1f}R, "
              f"net {d3['net']:+.1f}R")
        print('The mode is only worth shipping if gross is positive and the '
              'fee is the only thing making it negative -- otherwise the '
              'signals themselves are wrong.')
