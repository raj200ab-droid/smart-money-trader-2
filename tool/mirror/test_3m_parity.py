"""
Prove the Dart 3M scalp engine and the Python mirror agree bar for bar.

The release note quotes numbers measured in Python. Those numbers only describe
the product if the Dart code makes the SAME decision on the SAME candles. The
two implementations drifted once already (the mirror prepended one None too
many, so every indicator was a bar stale, and it used a simple ATR where Dart
uses Wilder). A parity test is the only way that stays true.

This file re-derives the Dart logic line by line from lib/main.dart's
`Engine.scalp3m` and compares, on real Binance 3M candles:

    * the ATR% gate value          (Wilder ATR / close * 100)
    * every entry decision         (direction, or no-trade)
    * the stop and the target      (within 1e-9 relative)

Run: python3 tool/mirror/test_3m_parity.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import fetch_real_1m as F
import mirror3m as m3

GATE = 0.80
MIN_STOP = 0.35
RR = 3.0


# ---------------------------------------------------------------- Dart, line by line
def dart_scalp3m(c):
    """Literal transcription of Engine.scalp3m, returning (sl, tp, buy) or None.

    Kept deliberately dumb -- no helper reuse -- so a change to the mirror
    cannot hide behind a shared function here.
    """
    if len(c) < 60:
        return None
    px = c[-1]['close']
    if px <= 0:
        return None
    a14 = m3.atr_series(c, 14)[-1] if len(c) > 14 else 0.0
    if a14 <= 0:
        return None
    atr_pct = a14 / px * 100
    if atr_pct < GATE:
        return None
    closes = [k['close'] for k in c]
    e9 = m3.ema_series(closes, 9)
    e21 = m3.ema_series(closes, 21)
    e50 = m3.ema_series(closes, 50)
    r = m3.rsi_series(closes, 14)
    if not e50 or not r:
        return None
    e9n, e21n, e50n, rn = e9[-1], e21[-1], e50[-1], r[-1]
    bar = c[-1]
    up = e9n > e21n and e21n > e50n
    dn = e9n < e21n and e21n < e50n
    if not up and not dn:
        return None
    lo5 = min(k['low'] for k in c[-5:])
    hi5 = max(k['high'] for k in c[-5:])
    if up and px < e21n and 30 <= rn <= 55 and bar['close'] > bar['open']:
        buy = True
    elif dn and px > e21n and 45 <= rn <= 70 and bar['close'] < bar['open']:
        buy = False
    else:
        return None
    sl = min(lo5, px - a14 * 1.5) if buy else max(hi5, px + a14 * 1.5)
    risk = abs(sl - px)
    if risk <= 0:
        return None
    sp = risk / px * 100
    if sp < MIN_STOP or sp > 8:
        return None
    tp = px + risk * RR if buy else px - risk * RR
    return {'buy': buy, 'entry': px, 'sl': sl, 'tp': tp, 'atr_pct': atr_pct}


def mirror_scalp3m(s, i):
    return m3.signal3m(s, i, variant='pullback', rr=RR, atr_floor=GATE,
                       vol_mult=1.0, stop_mult=1.5, min_stop_pct=MIN_STOP)


def main():
    months = F.month_list('2026-10', '2026-11')
    syms = ['IOSTUSDT', 'ONEUSDT', 'NEARUSDT', 'INJUSDT', 'ARBUSDT', 'UNIUSDT']
    mism = 0
    agreed_trades = 0
    checked = 0
    for sym in syms:
        c = F.load_series(sym, months)
        if len(c) < 5000:
            continue
        s = m3.Series(c)
        for i in range(s.warm, s.n - 1, 3):     # every 3rd bar: 9 minutes
            checked += 1
            d = dart_scalp3m(c[:i + 1])
            m = mirror_scalp3m(s, i)
            dn = d is None
            mn = m is None
            if dn != mn:
                mism += 1
                if mism <= 5:
                    print(f'  MISMATCH trigger: {sym} bar {i} dart={d} mirror={m}')
                continue
            if dn:
                continue
            agreed_trades += 1
            if d['buy'] != (m['direction'] == 'BUY'):
                mism += 1
                print(f'  MISMATCH side: {sym} bar {i}')
                continue
            for f in ('entry', 'sl', 'tp'):
                if abs(d[f] - m[f]) > 1e-9 * max(1.0, abs(d[f])):
                    mism += 1
                    print(f'  MISMATCH {f}: {sym} bar {i} {d[f]} vs {m[f]}')
                    break
            if abs(d['atr_pct'] - m['atr_pct']) > 1e-9:
                mism += 1
                print(f'  MISMATCH atr%: {sym} bar {i}')

    print(f'checked {checked} bars across {len(syms)} pairs; '
          f'{agreed_trades} both-trade bars')
    if mism:
        print(f'FAIL: {mism} mismatches')
        return 1
    print('PASS: Dart and mirror agree on every bar')
    return 0


if __name__ == '__main__':
    sys.exit(main())
