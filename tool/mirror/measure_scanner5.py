"""
Measure the SCANNER the user specified on 2026-11-11 (second revision).

    "ei mode a just 3 minutes timeframe a analyse korba j 5 candle er modhe a
     bos hoyse a ki nh r macd a green ace a ki nh. Jodi 2 tai mil takhe a tahole
     top a asbe oii coin gula r jodi just 1 ta match kore a tahole a niche a
     asbe coin gula. Besi up-down kore a sei coin gula opur er dikh a takhbe.
     Just 2 dollars er nice a j coin gula ace a sei gula filter korba.
     R kono kisu add korba nh, ami kono doroner entry or exit plan chai nh."

So: no entry, no stop, no target, no R:R. A coin is scored on two independent
3M facts:

    BOS     -- a break of structure within the last 5 bars   (bos__5m5)
    MACD    -- line above signal and histogram not falling    (green__now)

    2 of 2  -> top section
    1 of 2  -> bottom section
    0 of 2  -> not a signal (the "quiet" list, where the refusal is named)

Ordering inside each section: movement first (ATR% per bar, descending), then
the user's price filter -- coins above $2 are dropped entirely.

No exit is invented, so nothing here can be "profitable" or not; what CAN be
measured is what each bucket tends to do next. That is reported honestly below
(hit rate of +1 ATR before -1 ATR, and the plain forward return), because a
scanner that only ever shows the same bucket is worth knowing about.

Run: python3 tool/mirror/measure_scanner5.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import measure_bos_macd as MB

CACHE = MB.CACHE
MAX_AGO = 5        # user: "5 candle er modhe a bos hoyse"


def bos5_series(c, lookback=MAX_AGO, k=2):
    """MB.bos_series already tracks bars-since-BOS; this just applies the
    user's 5-candle window instead of the v19 3-bar window."""
    raw = MB.bos_series(c, k=k)
    # the freshness window is applied at read time, not inside bos_series
    return raw


def buckets(c):
    """Per bar: (bos_ok, macd_ok) for the last closed bar."""
    bos = MB.bos_series(c)
    macd = MB.macd_hist_series(c)
    if macd is None:
        return None
    pad, line, sg, hist = macd['pad'], macd['line'], macd['sig'], macd['hist']
    out = []
    atr = {}
    for i in range(120, len(c)):
        st = bos[i]
        b = 1 if (st is not None and st[1] <= MAX_AGO) else 0
        h = i - pad
        g = 1 if (1 <= h < len(hist) and line[h] > sg[h]
                  and hist[h] >= hist[h - 1]) else 0
        if i not in atr:
            a = MB.atr_wilder(c[max(0, i - 100):i + 1])
            px = c[i]['close']
            atr[i] = (a / px * 100) if (a > 0 and px > 0) else 0.0
        out.append((i, b, g, atr[i]))
    return out


def forward(c, i, atr_abs, bars=10):
    """What the NEXT `bars` bars did, with no invented exit.

    Reports two things the user can feel without a risk plan:
      * forward return in % over the window
      * did price touch +1 ATR before -1 ATR (a coin-flip style "moved up
        first" measure), using the same bar-close entry the scanner sees
    """
    px = c[i]['close']
    n = len(c)
    end = min(n - 1, i + bars)
    if end <= i:
        return None
    hi = max(c[j]['high'] for j in range(i + 1, end + 1))
    lo = min(c[j]['low'] for j in range(i + 1, end + 1))
    up_first = None
    for j in range(i + 1, end + 1):
        hit_up = c[j]['high'] >= px + atr_abs
        hit_dn = c[j]['low'] <= px - atr_abs
        if hit_up and hit_dn:
            up_first = 0.5          # same bar: no honest ordering
            break
        if hit_up:
            up_first = 1.0
            break
        if hit_dn:
            up_first = 0.0
            break
    return {'ret': (c[end]['close'] - px) / px * 100,
            'hi': (hi - px) / px * 100, 'lo': (lo - px) / px * 100,
            'up_first': up_first}


def main():
    data = MB.load_all()
    if not data:
        print('no data -- run fetch_real_1m.py first')
        return 1
    print(f'{len(data)} symbols, {sum(len(c) for c in data.values()):,} '
          f'3M bars, BOS window {MAX_AGO} candles\n')

    agg = {(2, 1, 1): [], (1, 1, 0): [], (1, 0, 1): [], (0, 0, 0): []}
    for sym, c in data.items():
        bs = buckets(c)
        if not bs:
            continue
        for (i, b, g, atrp) in bs:
            f = forward(c, i, MB.atr_wilder(c[max(0, i - 100):i + 1]))
            if f is None:
                continue
            agg[(b + g, b, g)].append(f)

    print('1. how the scan splits (each bar is one observation)')
    print(f"{'bucket':<26} {'bars':>7} {'% of scan':>10}")
    tot = sum(len(v) for v in agg.values())
    for key, label in (((2, 1, 1), '2 of 2  (BOS + MACD)'),
                       ((1, 1, 0), '1 of 2  (BOS only)'),
                       ((1, 0, 1), '1 of 2  (MACD only)'),
                       ((0, 0, 0), '0 of 2  (neither)')):
        n = len(agg[key])
        print(f'{label:<26} {n:>7} {n / tot * 100:>9.1f}%')

    print('\n2. what each bucket did over the next 10 bars (30 min), '
          'no exit assumed')
    print(f"{'bucket':<26} {'bars':>7} {'avg ret%':>9} {'+1ATR first':>12}")
    for key, label in (((2, 1, 1), '2 of 2  (BOS + MACD)'),
                       ((1, 1, 0), '1 of 2  (BOS only)'),
                       ((1, 0, 1), '1 of 2  (MACD only)'),
                       ((0, 0, 0), '0 of 2  (neither)')):
        rows = agg[key]
        if not rows:
            continue
        ret = sum(r['ret'] for r in rows) / len(rows)
        uf = [r['up_first'] for r in rows if r['up_first'] is not None]
        u = sum(uf) / len(uf) * 100 if uf else float('nan')
        print(f'{label:<26} {len(rows):>7} {ret:>8.3f}% {u:>11.1f}%')

    print('\n   (up_first = share of bars that touched +1 ATR before -1 ATR;')
    print('    50% means no directional edge at all -- a coin toss)')

    print('\n3. how many coins land in the TOP section per scan')
    print('   (the user sees "top" vs "bottom"; this is how big "top" is)')
    # Per SCAN means: at one timestamp, how many of the coins qualify. The
    # first version of this counted per symbol, so the maximum was always 1 and
    # the answer looked like "the top is always empty" -- which is a fact about
    # the loop, not about the market.
    per_time = {}
    for sym, c in data.items():
        bs = buckets(c)
        if not bs:
            continue
        for (i, b, g, _a) in bs:
            t = c[i]['openTime'] // (30 * 60 * 1000)   # 30-min buckets
            slot = per_time.setdefault(t, [0, 0])
            slot[1] += 1
            if b and g:
                slot[0] += 1
    if per_time:
        tops = [v[0] for v in per_time.values()]
        sizes = [v[1] for v in per_time.values()]
        avg_top = sum(tops) / len(tops)
        print(f'   {len(tops)} sampled scans of ~{sum(sizes)/len(sizes):.0f} coins')
        print(f'   average TOP-section coins: {avg_top:.2f} '
              f'(max {max(tops)})')
        print(f'   scans with an EMPTY top: '
              f'{sum(1 for x in tops if x == 0) / len(tops) * 100:.0f}%')
        print(f'   -> on a 400-coin scan that is roughly '
              f'{avg_top / (sum(sizes)/len(sizes)) * 400:.0f} coins on top, '
              f'the rest below.')

    return 0


if __name__ == '__main__':
    sys.exit(main())
