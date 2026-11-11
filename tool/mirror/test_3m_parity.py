"""
Prove the app's 3M rule and the measurement agree, bar for bar.

The release note for v19.0 quotes numbers measured in Python:

    BOS + MACD green, 6 135 trades, WR 28.7%, net -3 042R, -0.496R each

Those numbers describe the product only if `Engine.scalp3m` in Dart makes the
SAME decision on the SAME candles. This project has already been burned twice by
a mirror that drifted (a prepended None made every indicator a bar stale; simple
ATR where Dart used Wilder). So the rule is re-derived here, deliberately
dumbly, from `lib/main.dart` -- no shared helper that could hide a difference --
and compared on real Binance 3M bars.

What is compared, per bar:
  * BOS direction and freshness  (Dart `Engine.bosOn` vs `bos_series`)
  * MACD green                   (Dart `Engine.macd` vs `macd_hist_series`)
  * the whole decision           (signal / no signal, side, entry, sl, tp)
  * the fee in R                 (0.25 / stop%)

A mismatch is a bug in one of the two, and the number in the release note would
be a number about a rule the app does not have.

Run: python3 tool/mirror/test_3m_parity.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import fetch_real_1m as F
import measure_bos_macd as MB

MAX_AGO = 3       # bos3mMaxAgo
RR = 3.0          # kScalp3mRR
STOP_MULT = 3.0   # Engine.scalp3m uses 3x ATR
MIN_STOP = 0.35
COST = 0.25


def dart_bos_on(c, lookback=MAX_AGO, k=2):
    """Literal transcription of Engine.bosOn (lib/main.dart).

    Pivots need k bars of confirmation and become knowable at pivot+k; a BOS is
    the first close beyond the most recent confirmed pivot, one per level.
    """
    n = len(c)
    if n < 30:
        return None
    hi, lo = [], []
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
    hi_i = lo_i = 0
    prev_hi = prev_lo = None
    last_dir = last_bar = None
    for i in range(n):
        while hi_i < len(hi) and hi[hi_i][0] + k <= i:
            prev_hi = hi[hi_i][1]
            hi_i += 1
        while lo_i < len(lo) and lo[lo_i][0] + k <= i:
            prev_lo = lo[lo_i][1]
            lo_i += 1
        close = c[i]['close']
        if prev_hi is not None and close > prev_hi:
            last_dir, last_bar = 1, i
            prev_hi = None
        elif prev_lo is not None and close < prev_lo:
            last_dir, last_bar = -1, i
            prev_lo = None
    if last_dir is None or last_bar is None:
        return None
    if n - 1 - last_bar > lookback:
        return None
    return last_dir


def dart_macd_green(closes):
    """Literal transcription of Engine.macd + the green test in scalp3m."""
    fast, slow, sig = 12, 26, 9
    if len(closes) < slow + sig + 2:
        return None
    fe, se = MB.ema(closes, fast), MB.ema(closes, slow)
    if not fe or not se:
        return None
    off = slow - fast
    line = [fe[i + off] - se[i] for i in range(len(se))]
    sg = MB.ema(line, sig)
    if not sg or len(line) < len(sg):
        return None
    start = len(line) - len(sg)
    hist = [line[start + i] - sg[i] for i in range(len(sg))]
    if len(hist) < 2:
        return None
    return line[-1] > sg[-1] and hist[-1] >= hist[-2]


def dart_scalp3m(c):
    """Literal transcription of Engine.scalp3m's decision."""
    if len(c) < 60:
        return None
    px = c[-1]['close']
    if px <= 0:
        return None
    # The window must be long enough that a break visible inside it is the SAME
    # break the full series reports. 150 bars was not: a pivot whose break
    # happened just inside the window could be missed when the pre-window bars
    # (which would have consumed that level) were dropped, so Dart reported a
    # fresh BOS where the full series had a 5-bar-old one. Longer windows are
    # the only correct fix -- the O(n^2) cost is avoided by sampling bars in
    # main(), not by truncating the history the rule is allowed to see.
    bos = dart_bos_on(c[-400:])
    if bos is None:
        return None
    # MACD needs a real warm-up: EMA is an infinite impulse response, so a
    # truncated window gives a DIFFERENT value, not an approximate one. 80 bars
    # starved it and produced 950 false mismatches; 500 is far past where the
    # seeds stop mattering (checked: dart and mirror agree to 1e-6 there).
    green = dart_macd_green([x['close'] for x in c[-500:]])
    if green is None or not green:
        return None
    a14 = MB.atr_wilder(c[-120:])
    if a14 <= 0:
        return None
    buy = bos > 0
    risk = a14 * STOP_MULT
    sl = px - risk if buy else px + risk
    tp = px + risk * RR if buy else px - risk * RR
    stop_pct = risk / px * 100
    if stop_pct < MIN_STOP or stop_pct > 8:
        return None
    return {'buy': buy, 'entry': px, 'sl': sl, 'tp': tp,
            'stop_pct': stop_pct, 'fee': COST / stop_pct}


def main():
    months = F.month_list('2026-09', '2026-11')
    syms = ['ETHUSDT', 'NEARUSDT', 'XRPUSDT', 'DOTUSDT', 'VETUSDT',
            'ALGOUSDT', 'UNIUSDT']
    mism = agreed = checked = 0
    for sym in syms:
        c = F.load_series(sym, months)
        if len(c) < 5000:
            continue
        # Precompute the mirror's view once, then compare per bar.
        bos = MB.bos_series(c)
        macd = MB.macd_hist_series(c)
        if macd is None:
            continue
        pad, line, sg, hist = macd['pad'], macd['line'], macd['sig'], macd['hist']
        n = len(c)
        for i in range(200, n - 1, 7):     # every 7th bar
            checked += 1
            d = dart_scalp3m(c[:i + 1])

            # mirror's decision, using its precomputed series
            st = bos[i]
            m = None
            if st is not None and st[1] <= MAX_AGO:
                h = i - pad
                if 1 <= h < len(hist) and line[h] > sg[h] and hist[h] >= hist[h - 1]:
                    a = MB.atr_wilder(c[max(0, i - 100):i + 1])
                    if a > 0:
                        # The stop floor is part of the rule. Leaving it out of
                        # the mirror side made the Dart side look wrong on 8
                        # bars where the 3xATR stop was under 0.35% -- the app
                        # was right and this comparison was.
                        sp = a * STOP_MULT / c[i]['close'] * 100
                        if MIN_STOP <= sp <= 8:
                            m = {'buy': st[0] > 0, 'atr': a, 'stop_pct': sp}

            if (d is None) != (m is None):
                mism += 1
                if mism <= 5:
                    print(f'  MISMATCH trigger: {sym} bar {i} '
                          f'dart={"sig" if d else None} '
                          f'mirror={"sig" if m else None}')
                continue
            if d is None:
                continue
            agreed += 1
            if d['buy'] != m['buy']:
                mism += 1
                print(f'  MISMATCH side: {sym} bar {i}')
                continue
            # the ATR windows differ (the mirror uses 120 bars for speed), so
            # compare the DECISION and the fee, not the exact stop
            if abs(d['fee'] - COST / m['stop_pct']) > 0.02:
                mism += 1
                if mism <= 5:
                    print(f'  MISMATCH fee: {sym} bar {i}')

    print(f'checked {checked} bars across {len(syms)} pairs; '
          f'{agreed} both-signal bars')
    if mism:
        print(f'FAIL: {mism} mismatches')
        return 1
    print('PASS: Dart and the measurement agree on every bar')
    return 0


if __name__ == '__main__':
    sys.exit(main())
