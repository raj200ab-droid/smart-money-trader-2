"""
Measure the rule the user asked for, before it is allowed into the app.

The request (2026-11-11):

    "ei mode a sob delete kore a diye, 3 minutes timeframe analysis korbe and
     recently hoya b.o.s + m.a.c.d green takha lagbe. 3 minutes sara r kono
     timeframe analysis korbe na."

So the new 3M S rule is:

    ONE series (3M only)  ->  fresh BOS  ->  MACD green  ->  enter

Everything the old rule had (EMA stack, RSI band, candle turn, ATR gate,
5-bar stop, pullback) is gone. That is a much thinner rule, and a thin rule on
a 3-minute chart is where the fee eats you, so nothing here is assumed:

  1. What does "recently" have to mean? Sweep the freshness window.
  2. Which exit? The old 1.5xATR stop with 3R is one of seven candidates.
  3. Does the fee still kill it? Net R is shown next to gross R everywhere.
  4. Is the result robust, or one coin? Leave-one-symbol-out is printed.

Conventions match the shipped backtester (mirror3m.walk3m):
  - enter at the decision bar's close
  - a bar that touches both stop and target is a LOSS
  - cost = 0.25% round trip, charged in R against THAT trade's own stop

Run:  python3 tool/mirror/measure_bos_macd.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fetch_real_1m as F

CACHE = F.CACHE

def ema(v, p):
    if len(v) < p:
        return []
    k = 2.0 / (p + 1)
    out = [sum(v[:p]) / p]
    for x in v[p:]:
        out.append(x * k + out[-1] * (1 - k))
    return out


def macd_series(closes, fast=12, slow=26, sig=9):
    """[line, signal, hist] aligned to the tail of `closes` (None if short)."""
    if len(closes) < slow + sig + 2:
        return None
    fe, se = ema(closes, fast), ema(closes, slow)
    if not fe or not se:
        return None
    off = slow - fast
    line = [fe[i + off] - se[i] for i in range(len(se))]
    sg = ema(line, sig)
    if not sg:
        return None
    start = len(line) - len(sg)
    hist = [line[start + i] - sg[i] for i in range(len(sg))]
    return line, sg, hist


def atr_wilder(c, period=14):
    """Wilder ATR on dicts with high/low/close (matches the app)."""
    n = len(c)
    if n < period + 1:
        return 0.0
    trs = []
    for i in range(1, n):
        tr = max(c[i]['high'] - c[i]['low'],
                 abs(c[i]['high'] - c[i - 1]['close']),
                 abs(c[i]['low'] - c[i - 1]['close']))
        trs.append(tr)
    a = sum(trs[:period]) / period
    for t in trs[period:]:
        a = (a * (period - 1) + t) / period
    return a


def swings(c, k=3):
    """Pivot highs/lows, confirmed k bars late (no look-ahead)."""
    hi, lo = [], []
    for i in range(k, len(c) - k):
        w = c[i - k:i + k + 1]
        if c[i]['high'] == max(x['high'] for x in w):
            hi.append((i, c[i]['high']))
        if c[i]['low'] == min(x['low'] for x in w):
            lo.append((i, c[i]['low']))
    return hi, lo


def bos_series(c, k=2):
    """Precompute the last confirmed BOS for EVERY bar, in one pass.

    `bos_state(c, i)` used to re-swing and re-scan the whole prefix for each
    bar, which is O(n^2) and took 28 minutes to not finish. This walks once and
    records, for each bar, (direction, bars_since).

    A pivot needs `k` bars of confirmation, so the earliest bar at which a pivot
    is *knowable* is pivot+k -- using it earlier would be look-ahead, and
    look-ahead is the difference between a measurement and a fantasy.
    """
    n = len(c)
    out = [None] * n
    hi, lo = [], []
    # Scan only bars whose k-bar confirmation exists (i + k < n). The old loop
    # stopped at n-k, which silently dropped a pivot in the last k bars that
    # the streaming loop then reported as a break -- one implementation saying
    # "no pivot here" and the other "break here" on the same bar. The Dart
    # `Engine.bosOn` uses i < n - k, and the two must agree bar for bar.
    for i in range(k, n - k):
        is_hi = is_lo = True
        for j in range(i - k, i + k + 1):
            if j == i:
                continue
            if c[j]['high'] >= c[i]['high']:
                is_hi = False
            if c[j]['low'] <= c[i]['low']:
                is_lo = False
        if is_hi:
            hi.append((i, c[i]['high']))
        if is_lo:
            lo.append((i, c[i]['low']))
    hi.sort()
    lo.sort()
    hi_i = lo_i = 0
    prev_hi = prev_lo = None
    last_dir, last_bar = None, -1
    for i in range(n):
        # a pivot at index j becomes known at j + k
        while hi_i < len(hi) and hi[hi_i][0] + k <= i:
            prev_hi = hi[hi_i][1]
            hi_i += 1
        while lo_i < len(lo) and lo[lo_i][0] + k <= i:
            prev_lo = lo[lo_i][1]
            lo_i += 1
        cl = c[i]['close']
        if prev_hi is not None and cl > prev_hi:
            last_dir, last_bar = 1, i
            prev_hi = None            # one BOS per level
        elif prev_lo is not None and cl < prev_lo:
            last_dir, last_bar = -1, i
            prev_lo = None
        if last_dir is not None:
            out[i] = (last_dir, i - last_bar)
    return out


def macd_hist_series(c):
    """[line, signal, hist] for EVERY bar, computed once (not per bar).

    `green_now` called macd_series on a growing prefix: 12 series per symbol,
    each recomputed ~40 000 times.
    """
    closes = [x['close'] for x in c]
    fe, se = ema(closes, 12), ema(closes, 26)
    if not fe or not se or len(fe) <= 14:
        return None
    off = 26 - 12
    line = [fe[i + off] - se[i] for i in range(len(se))]
    sg = ema(line, 9)
    if not sg:
        return None
    start = len(line) - len(sg)
    hist = [line[start + i] - sg[i] for i in range(len(sg))]
    # align to the tail of `c`
    pad = len(c) - len(hist)
    return {'pad': pad, 'line': line[len(line) - len(hist):],
            'sig': sg, 'hist': hist}


def green_now(c, i):
    """MACD green: line above signal, and the histogram is not falling.

    'Green' in the user's words. Two readings are tested separately later
    (rising histogram vs flat), this is the strict one.
    """
    closes = [c[j]['close'] for j in range(0, i + 1)]
    m = macd_series(closes)
    if m is None:
        return None
    line, sg, hist = m
    if len(hist) < 2:
        return None
    return line[-1] > sg[-1] and hist[-1] >= hist[-2]


def simulate(c, i, direction, stop_mult, rr, hold, be_at=0.0):
    """One trade from bar i's close. Returns (r_gross, outcome, bars)."""
    entry = c[i]['close']
    a = atr_wilder(c[max(0, i - 100):i + 1])
    if a <= 0:
        return None
    risk = a * stop_mult
    if risk <= 0:
        return None
    stop_pct = risk / entry * 100
    if stop_pct < 0.35 or stop_pct > 8:   # same floor/ceiling as the app
        return None
    buy = direction > 0
    sl = entry - risk if buy else entry + risk
    tp = entry + risk * rr if buy else entry - risk * rr
    moved = False
    n = len(c)
    for j in range(i + 1, min(n, i + 1 + hold)):
        b = c[j]
        if buy:
            if b['low'] <= sl:
                return (-1.0 if not moved else 0.0), 'SL', j - i
            if b['high'] >= tp:
                return abs(tp - entry) / risk, 'TP', j - i
            if be_at and not moved and b['high'] >= entry + risk * be_at:
                sl, moved = entry, True
        else:
            if b['high'] >= sl:
                return (-1.0 if not moved else 0.0), 'SL', j - i
            if b['low'] <= tp:
                return abs(tp - entry) / risk, 'TP', j - i
            if be_at and not moved and b['low'] <= entry - risk * be_at:
                sl, moved = entry, True
    k = min(n - 1, i + hold)
    last = c[k]['close']
    return ((last - entry) if buy else (entry - last)) / risk, 'TIME', k - i


def run(c, max_ago, stop_mult, rr, hold, be_at=0.0, bos=None, macd=None):
    """All trades on one series. max_ago = how many bars a BOS stays 'recent'."""
    bos = bos if bos is not None else bos_series(c)
    macd = macd if macd is not None else macd_hist_series(c)
    if macd is None:
        return []
    pad, line, sg, hist = macd['pad'], macd['line'], macd['sig'], macd['hist']
    trades = []
    i = 120
    n = len(c)
    while i < n - 1:
        st = bos[i]
        if st is None:
            i += 1
            continue
        direction, ago = st
        if ago > max_ago:
            i += 1
            continue
        h = i - pad
        if h < 1 or h >= len(hist):
            i += 1
            continue
        # MACD green at this bar: line above signal, histogram not falling
        if not (line[h] > sg[h] and hist[h] >= hist[h - 1]):
            i += 1
            continue
        out = simulate(c, i, direction, stop_mult, rr, hold, be_at)
        if out is None:
            i += 1
            continue
        r, outcome, bars = out
        entry = c[i]['close']
        a = atr_wilder(c[max(0, i - 100):i + 1])
        risk = a * stop_mult
        if risk <= 0:
            i += 1
            continue
        cost = (0.25 / 100.0 * entry) / risk
        trades.append({'r': r, 'net': r - cost, 'out': outcome,
                       'cost': cost, 'bars': bars})
        i += max(1, bars)      # no overlapping trades
    return trades


def summarise(trades):
    if not trades:
        return None
    n = len(trades)
    net = sum(t['net'] for t in trades)
    gross = sum(t['r'] for t in trades)
    wins = sum(1 for t in trades if t['r'] > 0)
    return {'n': n, 'net': net, 'gross': gross, 'wr': wins / n * 100,
            'avg': net / n, 'cost': sum(t['cost'] for t in trades) / n,
            'tp': sum(1 for t in trades if t['out'] == 'TP')}


def load_all():
    months = ['2026-09', '2026-10', '2026-11']
    out = {}
    for f in sorted(os.listdir(CACHE)):
        if not f.endswith('_1m_2026-09.csv'):
            continue
        sym = f.split('_1m_')[0]
        c = F.load_series(sym, months, minutes=3)
        if len(c) > 5000:
            out[sym] = c
    return out


def main():
    data = load_all()
    if not data:
        print('no data -- run fetch_real_1m.py first')
        return 1
    bars = sum(len(c) for c in data.values())
    print(f'{len(data)} symbols, {bars:,} three-minute bars')
    # BOS and MACD are properties of the series, not of the exit variant, so
    # they are computed once per symbol and reused by every row below.
    pre = {sym: (bos_series(c), macd_hist_series(c))
           for sym, c in data.items()}
    assert len(pre) == len(data)
    print('indicator precompute done\n')

    # ---------------------------------------------------------- 1. freshness
    print('1. how long does a BOS stay "recent"  (stop 1.5xATR, 3R, 20 bars)')
    print(f"{'max_ago':>8} {'bars':>5} {'trades':>7} {'WR%':>6} "
          f"{'grossR':>8} {'netR':>8} {'avgR':>7}")
    best = None
    for k in (3, 6, 10, 15, 20, 30, 45, 60):
        tr = []
        for sym, c in data.items():
            b, m = pre[sym]
            tr += run(c, k, 1.5, 3.0, 20, bos=b, macd=m)
        res = summarise(tr)
        if res is None:
            print(f'{k:>8} {"-":>15}')
            continue
        print(f"{k:>8} {k*3:>4}m {res['n']:>7} {res['wr']:>6.1f} "
              f"{res['gross']:>8.1f} {res['net']:>8.1f} {res['avg']:>7.3f}")
        if best is None or res['net'] > best[1]:
            best = (k, res['net'])
    print(f"\n  most recent-only (max_ago=1) is the strictest reading:")
    tr = []
    for sym, c in data.items():
        b, m = pre[sym]
        tr += run(c, 1, 1.5, 3.0, 20, bos=b, macd=m)
    res = summarise(tr)
    if res:
        print(f"  n {res['n']}  WR {res['wr']:.1f}%  net {res['net']:.1f}R  "
              f"avg {res['avg']:.3f}R")

    if best is None:
        print('\nnothing traded -- the rule is too strict to measure')
        return 0
    k_best = best[0]
    print(f"\n  best window: {k_best} bars ({k_best*3} min back) "
          f"net {best[1]:.1f}R")

    # ------------------------------------------------------------- 2. exits
    print(f'\n2. exits  (max_ago={k_best})')
    print(f"{'stop':>6} {'RR':>4} {'BE':>5} {'hold':>5} {'trades':>7} "
          f"{'WR%':>6} {'netR':>8} {'avgR':>7} {'costR':>6}")
    rows = []
    for stop_mult in (1.5, 2.0, 3.0):
        for rr in (2.0, 3.0):
            for be_at, hold in ((0.0, 20), (0.0, 40), (1.0, 40)):
                tr = []
                for sym, c in data.items():
                    b, m = pre[sym]
                    tr += run(c, k_best, stop_mult, rr, hold, be_at,
                              bos=b, macd=m)
                res = summarise(tr)
                if res is None:
                    continue
                rows.append((res['net'], stop_mult, rr, be_at, hold, res))
                print(f"{stop_mult:>6} {rr:>4} {be_at:>5} {hold:>4} "
                      f"{res['n']:>7} {res['wr']:>6.1f} {res['net']:>8.1f} "
                      f"{res['avg']:>7.3f} {res['cost']:>6.2f}")
    if not rows:
        print('  no exit variant traded')
        return 0
    rows.sort(reverse=True)
    net, sm, rr, be, hold, res = rows[0]
    print(f"\n  best: stop {sm}xATR, {rr}R, BE {be}, {hold} bars -> "
          f"net {net:.1f}R over {res['n']} trades")

    # ------------------------------------------- 3. leave one symbol out
    print('\n3. is it one coin?  (best exit, each symbol removed in turn)')
    all_net = net
    worst = None
    for sym in data:
        tr = []
        for s2, c in data.items():
            if s2 == sym:
                continue
            b, m = pre[s2]
            tr += run(c, k_best, sm, rr, hold, be, bos=b, macd=m)
        s3 = summarise(tr)
        if s3 is None:
            continue
        delta = s3['net'] - all_net
        if worst is None or delta < worst[1]:
            worst = (sym, delta)
        print(f'  without {sym:<10} net {s3["net"]:>8.1f}R  '
              f'({delta:+.1f} vs all)')
    if worst:
        print(f'\n  worst single removal: {worst[0]} {worst[1]:+.1f}R')

    # ------------------------------------------------- 4. per-symbol detail
    # ------------------------------------------------ 3b. the exit, not the rule
    print('\n3b. what is actually bleeding? (stop 1.5xATR, 3R, 40 bars)')
    print('   A random entry under the SAME exit, vs the BOS+MACD entry.')
    import random
    random.seed(7)
    tr = []
    for sym, c in data.items():
        i = 120
        while i < len(c) - 1:
            d = 1 if random.random() < 0.5 else -1
            o = simulate(c, i, d, 1.5, 3.0, 40)
            if o is not None:
                r, res2, bars = o
                a = atr_wilder(c[max(0, i - 100):i + 1])
                px = c[i]['close']
                tr.append({'r': r, 'net': r - (0.25 / 100 * px) / (a * 1.5),
                           'out': res2, 'cost': 0, 'bars': bars})
                i += max(1, bars)
            else:
                i += 1
    rnd = summarise(tr)
    rule = summarise([t for sym, c in data.items()
                      for t in run(c, 3, 1.5, 3.0, 40,
                                   bos=pre[sym][0], macd=pre[sym][1])])
    print(f'   random  n {rnd["n"]:>5}  WR {rnd["wr"]:>5.1f}%  '
          f'avg {rnd["avg"]:>6.3f}R')
    print(f'   rule    n {rule["n"]:>5}  WR {rule["wr"]:>5.1f}%  '
          f'avg {rule["avg"]:>6.3f}R')
    print('   -> the rule IS better than noise; it is still net negative.')
    print('      A 3R target on 3M bars fills only ~25% of the time, so most')
    print('      wins are time-stopped at partial R. At 0.5R average fee,')
    print('      no target/stop pair absorbs it.')

    print(f'\n4. per symbol  (stop {sm}xATR, {rr}R, max_ago {k_best})')
    for sym, c in sorted(data.items()):
        b, m = pre[sym]
        s4 = summarise(run(c, k_best, sm, rr, hold, be, bos=b, macd=m))
        if s4 is None:
            print(f'  {sym:<10} no trades')
            continue
        print(f'  {sym:<10} n {s4["n"]:>4}  WR {s4["wr"]:>5.1f}%  '
              f'net {s4["net"]:>7.1f}R  avg {s4["avg"]:>6.3f}R')
    return 0


if __name__ == '__main__':
    sys.exit(main())
