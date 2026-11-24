"""
Measure the requested fixed 1.05% take profit against the current swing/2R TP.

Run: python3 tool/mirror/measure_tp.py

No exchange access in this sandbox, so the data is synthetic with four regimes.
That proves which way the change moves the numbers; it does not prove an edge.
"""
import os
import random
import sys
from concurrent.futures import ProcessPoolExecutor

sys.path.insert(0, os.path.dirname(__file__))
import mirror
from mirror import summarise

T4 = 4 * 3600 * 1000
T1 = 3600 * 1000
T15 = 15 * 60 * 1000


def gen(seed, n15=4200, regime='mixed'):
    rnd = random.Random(seed)
    start = 1730000000000
    start -= start % T4
    drift, vol = {'trend': (0.00006, 0.004), 'range': (0.0, 0.004),
                  'volatile': (0.00002, 0.012), 'mixed': (0.00004, 0.006)}[regime]
    px, path = 100.0, []
    for i in range(n15):
        if regime == 'mixed' and i % 700 == 0:
            drift = rnd.choice([-0.00008, 0.0, 0.00008])
            vol = rnd.choice([0.003, 0.006, 0.011])
        big = (i % (T4 // T15)) in (0, 1)
        r = rnd.gauss(drift, vol) * (1.6 if big else 0.45)
        new = max(0.01, px * (1 + r))
        path.append({'open': px,
                     'high': max(px, new) * (1 + abs(rnd.gauss(0, vol * 0.25))),
                     'low': min(px, new) * (1 - abs(rnd.gauss(0, vol * 0.25))),
                     'close': new, 'volume': abs(rnd.gauss(1000, 400)) + 1})
        px = new

    def bucket(series, step):
        out, cur = [], None
        for idx, k in enumerate(series):
            b = ((start + idx * T15) // step) * step
            if cur is None or cur['openTime'] != b:
                cur = {'openTime': b, 'closeTime': b + step - 1, 'open': k['open'],
                       'high': k['high'], 'low': k['low'], 'close': k['close'],
                       'volume': k['volume']}
                out.append(cur)
            else:
                cur['high'] = max(cur['high'], k['high'])
                cur['low'] = min(cur['low'], k['low'])
                cur['close'] = k['close']
                cur['volume'] += k['volume']
        return out

    return bucket(path, T4), bucket(path, T1), bucket(path, T15)


def gen_scalp(seed, n5=9000, regime='mixed'):
    """Same generator, bucketed to the scalp horizons: 30M / 15M / 5M.

    Identical price path and volatility regimes -- only the bucket sizes
    change, so a swing-vs-scalp comparison is not confounded by a different
    market.
    """
    T30 = 30 * 60 * 1000
    T5 = 5 * 60 * 1000
    rnd = random.Random(seed)
    start = 1730000000000
    start -= start % T30
    drift, vol = {'trend': (0.00006, 0.004), 'range': (0.0, 0.004),
                  'volatile': (0.00002, 0.012), 'mixed': (0.00004, 0.006)}[regime]
    px, path = 100.0, []
    for i in range(n5):
        if regime == 'mixed' and i % 2100 == 0:
            drift = rnd.choice([-0.00008, 0.0, 0.00008])
            vol = rnd.choice([0.003, 0.006, 0.011])
        r = rnd.gauss(drift, vol)
        new = max(0.01, px * (1 + r))
        path.append({'open': px,
                     'high': max(px, new) * (1 + abs(rnd.gauss(0, vol * 0.25))),
                     'low': min(px, new) * (1 - abs(rnd.gauss(0, vol * 0.25))),
                     'close': new, 'volume': abs(rnd.gauss(1000, 400)) + 1})
        px = new

    def bucket(series, step):
        out, cur = [], None
        for idx, k in enumerate(series):
            b = ((start + idx * T5) // step) * step
            if cur is None or cur['openTime'] != b:
                cur = {'openTime': b, 'closeTime': b + step - 1, 'open': k['open'],
                       'high': k['high'], 'low': k['low'], 'close': k['close'],
                       'volume': k['volume']}
                out.append(cur)
            else:
                cur['high'] = max(cur['high'], k['high'])
                cur['low'] = min(cur['low'], k['low'])
                cur['close'] = k['close']
                cur['volume'] += k['volume']
        return out

    return bucket(path, T30), bucket(path, T15), bucket(path, T5)


def gen_3m(seed, minutes=27000, regime='mixed'):
    """Same volatility regime, bucketed to 3-minute candles.

    The other generators step 5 minutes at a time, and 5 does not divide 3: a
    5-minute bar bucketed into 3-minute buckets produces bars that are labelled
    3M but span 5 minutes of price action. So this builds its own 1-minute path
    (all of 3/5/15/30 divide 1) and buckets that.

    Per-minute volatility is the 5-minute figure divided by sqrt(5), so the
    annualised volatility matches the other generators and a 3M-vs-scalp
    comparison is not confounded by a quieter market.

    Returns (3M, 3M, 3M): the single-timeframe mode feeds one series into all
    three engine slots.
    """
    T3 = 3 * 60 * 1000
    T1 = 60 * 1000
    rnd = random.Random(seed)
    start = 1730000000000
    start -= start % T3
    drift5, vol5 = {'trend': (0.00006, 0.004), 'range': (0.0, 0.004),
                    'volatile': (0.00002, 0.012),
                    'mixed': (0.00004, 0.006)}[regime]
    drift, vol = drift5 / 5.0, vol5 / (5 ** 0.5)
    px, path = 100.0, []
    for i in range(minutes):
        if regime == 'mixed' and i % 1050 == 0:      # ~2100 5M steps
            drift = rnd.choice([-0.00008, 0.0, 0.00008]) / 5.0
            vol = rnd.choice([0.003, 0.006, 0.011]) / (5 ** 0.5)
        r = rnd.gauss(drift, vol)
        new = max(0.01, px * (1 + r))
        path.append({'open': px,
                     'high': max(px, new) * (1 + abs(rnd.gauss(0, vol * 0.25))),
                     'low': min(px, new) * (1 - abs(rnd.gauss(0, vol * 0.25))),
                     'close': new, 'volume': abs(rnd.gauss(200, 80)) + 1})
        px = new

    out, cur = [], None
    for idx, k in enumerate(path):
        b = ((start + idx * T1) // T3) * T3
        if cur is None or cur['openTime'] != b:
            cur = {'openTime': b, 'closeTime': b + T3 - 1, 'open': k['open'],
                   'high': k['high'], 'low': k['low'], 'close': k['close'],
                   'volume': k['volume']}
            out.append(cur)
        else:
            cur['high'] = max(cur['high'], k['high'])
            cur['low'] = min(cur['low'], k['low'])
            cur['close'] = k['close']
            cur['volume'] += k['volume']
    return out, out, out


def job(args):
    regime, seed, mode, pct = args
    c4, c1, c15 = gen(seed, regime=regime)
    return (mode, pct), mirror.walk(c4, c1, c15, tp_mode=mode, tp_pct=pct)


if __name__ == '__main__':
    random.seed(1)
    regimes = ['mixed', 'trend', 'range', 'volatile']
    variants = [('swing', 1.05, 'current (15M swing / 2R)'),
                ('pct', 1.05, 'fixed TP 1.05%'),
                ('pct', 0.50, 'fixed TP 0.50%'),
                ('pct', 2.00, 'fixed TP 2.00%')]
    tasks = [(r, s, m, p) for r in regimes for s in range(12) for m, p, _ in variants]
    out = {(m, p): [] for m, p, _ in variants}
    with ProcessPoolExecutor(max_workers=2) as ex:
        for (key, trades) in ex.map(job, tasks, chunksize=4):
            out[key] += trades

    def line(name, su):
        return (f"{name:26s} trades {su['trades']:3d}  closed {su['closed']:3d}  "
                f"WR {su['winRate']:5.1f}%  totalR {su['totalR']:+7.1f}  "
                f"avgR {su['avgR']:+.3f}  B/S {su['buys']}/{su['sells']}")

    print("=" * 100)
    print("PAIRED, identical candles: 12 series x 4 regimes")
    print("=" * 100)
    for m, p, label in variants:
        su = summarise(out[(m, p)])
        print(line(label, su))
    print()
    print("R:R implied by a FIXED 1.05% target (stop is OB+0.25ATR, ~1.2 ATR(1H)):")
    for atr_pct in (0.45, 0.90, 1.80, 3.00):
        risk = 1.2 * atr_pct
        print(f"   ATR(1H)={atr_pct:.2f}%  risk={risk:.2f}%  ->  "
              f"reward:risk = {1.05/risk:.2f}   breakeven WR = "
              f"{1/(1+1.05/risk)*100:5.1f}%")
    print()
    print("with 0.30R costs:")
    for m, p, label in variants:
        su = summarise(out[(m, p)], cost_r=0.30)
        print(line(label, su))
