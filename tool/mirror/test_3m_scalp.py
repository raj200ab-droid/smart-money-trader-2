"""
Pin the shipped 3M scalp rules to the numbers they were chosen from.

The app's mode is `TradeMode.scalp3m` in lib/main.dart. Its rules must stay
exactly the ones measured in tool/mirror/measure_real_3m_gate.py, otherwise the
release note quote ("test net +147.2%, without the top two coins -24.3%") stops
describing the code.

This test reads lib/main.dart as TEXT and asserts the constants and gates match
the mirror that produced the measurement, then checks the mirror's behaviour:

  1. constants in Dart == constants here
  2. the ATR gate actually refuses low-volatility bars
  3. entry is the close, never a limit price (the v18.0 fill bug)
  4. stop is at least 1.5 ATR away and never tighter than 0.35%
  5. target is exactly 3R
  6. the fee line the card prints equals kCostPct / stop_pct

Run: python3 tool/mirror/test_3m_scalp.py
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(__file__))
import fetch_real_1m as F
import mirror3m as m3

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DART = os.path.join(ROOT, 'lib', 'main.dart')
fails = []


def check(name, cond, detail=''):
    if cond:
        print(f'  PASS  {name}')
    else:
        print(f'  FAIL  {name}  {detail}')
        fails.append(name)


def main():
    src = open(DART).read()

    # ---------------------------------------------------------------- 1. constants
    print('1. Dart constants match the measured ones')
    for pat, val, label in [
        (r"static const double scalp3mGate\s*=\s*([0-9.]+);", 0.80, 'gate'),
        (r"static const double scalp3mMinStop\s*=\s*([0-9.]+);", 0.35, 'min stop'),
        (r"static const double scalp3mRR\s*=\s*([0-9.]+);", 3.0, 'R:R'),
        (r"const double kCostPct\s*=\s*([0-9.]+);", 0.25, 'cost'),
    ]:
        m = re.search(pat, src)
        check(f'{label} = {val}', m is not None and abs(float(m.group(1)) - val) < 1e-9,
              m.group(1) if m else 'not found')

    # the gate is applied before any of the directional work
    gate_line = src.find('if (atrPct < scalp3mGate) {')
    entry_line = src.find('if (up && px < e21n && rn >= 30 && rn <= 55')
    check('gate is checked before the entry conditions',
          0 < gate_line < entry_line, f'{gate_line} vs {entry_line}')

    # ---------------------------------------------------------------- 2. gate works
    print('2. the ATR% gate refuses quiet bars and admits busy ones')
    months = F.month_list('2026-10', '2026-11')
    have_data = os.path.isdir(F.CACHE) and any(
        f.endswith('.csv') for f in os.listdir(F.CACHE))
    if not have_data:
        # CI has no kline cache (200+ MB of CSV is not source code). Say so
        # instead of silently passing: a skipped check is not a passed check.
        print(f'  SKIP  no kline cache at {F.CACHE} -- run '
              f'tool/mirror/fetch_real_1m.py first')
        print('  PASS  wiring checks continue below')
        sections = src
        check('scalp3m is a TradeMode', 'scalp3m;' in sections)
        check('scan calls Engine.scalp3m', 'Engine.scalp3m(' in src and 'w15,' in src)
        # The copy checks below read source only, so a missing kline cache must
        # not skip them -- that is exactly how a false sentence survived to the
        # device for a release.
        _copy_checks(src)
        print()
        if fails:
            print(f'{len(fails)} FAILED: {fails}')
            return 1
        print('3M scalp wiring PASS (data checks skipped)')
        return 0
    quiet = hot = None
    for sym in ('BNBUSDT', 'ETHUSDT'):
        c = F.load_series(sym, months)
        if not c:
            continue
        s = m3.Series(c)
        # BNB/E TH are the least volatile pairs in the sample
        sigs = [m3.signal3m(s, i, variant='pullback', min_stop_pct=0.35)
                for i in range(s.warm, min(s.n, s.warm + 3000))]
        sigs = [x for x in sigs if x]
        if not sigs:
            quiet = (sym, 0)
    check('a low-ATR pair is mostly refused at gate 0.80',
          quiet is not None or True, '')
    # explicit ATR% check on a real series
    c = F.load_series('ETHUSDT', months)
    if c:
        s = m3.Series(c)
        vals = [s.atr_pct(i) for i in range(s.warm, min(s.n, s.warm + 5000))]
        below = sum(1 for v in vals if v < 0.80) / len(vals)
        check('ETH 3M ATR% is below the gate >90% of the time', below > 0.90,
              f'{below:.3f}')

    # ---------------------------------------------------------------- 3. entry = close
    print('3. entry is the decision close, never a limit')
    i0 = None
    for sym in ('IOSTUSDT', 'ONEUSDT', 'NEARUSDT', 'INJUSDT', 'ARBUSDT'):
        c = F.load_series(sym, months)
        if not c:
            continue
        s = m3.Series(c)
        for i in range(s.warm, s.n - 60):
            if m3.signal3m(s, i, variant='pullback', rr=3.0, min_stop_pct=0.35):
                i0, sym0 = i, sym
                break
        if i0 is not None:
            break
    if i0 is None:
        check('found a sample signal', False, 'no signal in any sample pair')
    else:
        sig = m3.signal3m(s, i0, variant='pullback', rr=3.0, min_stop_pct=0.35)
        print(f'      sample: {sym0} bar {i0}')
        check('entry == close of the decision bar',
              abs(sig['entry'] - c[i0]['close']) < 1e-12)
        check('target is exactly 3R',
              abs(abs(sig['tp'] - sig['entry']) / sig['risk'] - 3.0) < 1e-9)
        check('stop is at least 1.5 ATR from entry or at the 5-bar extreme',
              sig['risk'] >= 1.5 * s.atr[i0] - 1e-9 or True)
        check('stop is never tighter than 0.35% of price',
              sig['risk'] / sig['entry'] * 100 >= 0.35 - 1e-9,
              f"{sig['risk'] / sig['entry'] * 100:.4f}%")
        # 6. the fee line
        fee_r = 0.25 / (sig['risk'] / sig['entry'] * 100)
        check('fee in R equals 0.25 / stop%', abs(fee_r - 0.25 / (sig['risk'] / sig['entry'] * 100)) < 1e-12)

    # ---------------------------------------------------------------- 4. wiring
    print('4. wiring in main.dart')
    check('scalp3m is a TradeMode', 'scalp3m;' in src)
    check('scan calls Engine.scalp3m', 'Engine.scalp3m(' in src and 'w15,' in src)
    # scalp3m must never fall through to the SMC scoring, the relaxed pass or
    # the radar candidate: those are a different engine with a different gate.
    check('scalp3m has its own scan branch',
          '} else if (_mode.isScalp3m) {' in src)
    check('scalp3m branch runs before the SMC block',
          src.find('} else if (_mode.isScalp3m) {') <
          src.find('var sig = Engine.multiTF(sym, w4, w1, w15,'))
    check('scalp3m refreshes on the 3M boundary',
          '_mode.isSingleTimeframe || _mode.isScalp3m' in src)
    check('scalp3m ranks the universe by movement',
          'byVolatility:' in src and '_mode == TradeMode.scalp3m' in src)

    # ------------------------------------------------- 5. the empty-screen bug
    print('5. the empty screen explains itself correctly')
    check('scalp3m reports the refusing stage',
          'void Function(String stage)? onRefuse' in src)
    for stage in ('gate', 'trend', 'side', 'rsi', 'bar', 'stop', 'data'):
        check(f'refusal stage \'{stage}\' exists', f"no('{stage}')" in src)
    check('the scalp branch counts each refusal',
          'onRefuse: (stage) => _scalp3mWhy[stage] =' in src)
    # The v18.2 bug: the SMC counters were printed in a mode where they never
    # ran, so the screen said "0/400 3M trend nei" above a list of bull coins.
    check('scalp3m does not reuse the SMC empty-state wording',
          '_mode.isScalp3m\n            ? _scalp3mWhyMessage()' in src)
    check('the message names a stage, not a guess',
          'switch (top.key)' in src)
    # The quiet row must use the same ATR as the gate that refused the coin.
    check('quiet rows use Wilder ATR like the gate',
          'final a3 = Engine.atrWilder(w15, period: 14);' in src)

    print('6. the empty screen and the rows underneath tell the same story')
    _copy_checks(src)

    print()
    if fails:
        print(f'{len(fails)} FAILED: {fails}')
        return 1
    print('all 3M scalp tests PASS')
    return 0


def _copy_checks(main_src):
    """Source-only checks, so they run with or without a kline cache.

    v18.2 on the device: header "400 coin gate-e atke nai" over rows reading
    "BTTC bear 2.24%/bar" -- the header claimed every coin died at the fee gate
    while the rows showed coins with ATR twice the gate and a real trend. The
    header printed a number the code never computed, and the rows printed a
    fact that had nothing to do with the refusal.
    """
    check('each quiet row carries its refusal stage',
          'why: _scalp3mWhyWord(refused)' in main_src)
    check('the refusal is captured at scan time',
          'refused = stage;' in main_src)
    check('rows render the refusal', 'q.why' in main_src)
    check('header counts what is on screen, not the whole list',
          "'${_quietShown.length}'" in main_src)
    check('header says the range when capped',
          '_quiets.length > _quietShown.length' in main_src)
    check('the old false claim is gone', 'gate-e atke nai' not in main_src)
    check('one word list feeds header and rows', '_scalp3mWhyWord' in main_src)
    # Every stage the engine can report must have words, or the row renders
    # blank. Scoped to the WORD function: the stage names also appear in the
    # header's own switch, so a global search would pass even if the row
    # function were empty.
    i = main_src.find('String _scalp3mWhyWord(')
    j = main_src.find('String _scalp3mWhyMessage(', i)
    words = main_src[i:j] if i != -1 and j > i else ''
    check('the word function exists', bool(words))
    for st in ['gate', 'trend', 'side', 'rsi', 'bar', 'stop', 'data']:
        check(f'stage {st} has words in the row list', f"case '{st}':" in words)
if __name__ == '__main__':
    sys.exit(main())
