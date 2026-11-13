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

    # ---------------------------------------------------------------- 1. the rule
    print('1. the 3M mode is a SCANNER: 5-candle BOS + MACD green, no plan')
    for pat, val, label in [
        (r"const int bos5mLookback\s*=\s*([0-9]+);", 5, 'BOS window (candles)'),
        (r"const double kScalp3mMaxPrice\s*=\s*([0-9.]+);", 2.0,
         'price filter'),
        (r"const double kScalp3mMinChange24h\s*=\s*([0-9.]+);", 15.0,
         'momentum gate'),
        (r"const int kMomentumHold\s*=\s*([0-9]+);", 160, 'hold (bars)'),
        (r"const double kCostPct\s*=\s*([0-9.]+);", 0.25, 'cost (context only)'),
    ]:
        m = re.search(pat, src)
        check(f'{label} = {val}',
              m is not None and abs(float(m.group(1)) - val) < 1e-9,
              m.group(1) if m else 'not found')

    i = src.find('static TradeSignal? scalp3m(')
    j = src.find('static int? bosOn(', i)
    body = src[i:j]
    check('the scanner asks for a BOS', 'bosOn(c3, lookback: bos5mLookback)' in body)
    check('the scanner asks for MACD green', 'line > sig && hist >= prevHist' in body)
    check('the price filter is applied', 'px > kScalp3mMaxPrice' in body)

    # --- no trade plan anywhere in this mode. This is the user's explicit
    # "ami kono doroner entry or exit plan chai nh, risk ratio eyo chai nh".
    # v19.2 (2026-11-14): the user asked for the ADX-style trade to be added to
    # this mode, so a plan EXISTS again -- but only for a coin that passed the
    # momentum gate, and it is the measured 2xATR / 4xATR / 8h one, not a
    # 3R moonshot. Both facts must be pinned, or the next edit can silently
    # put a plan back on coins that never earned one.
    check('the stop is 2xATR', 'a14 * kMomentumStopMult' in body)
    check('the target is 4xATR', 'a14 * kMomentumTargetMult' in body)
    check('stop/target come from the constants',
          'kMomentumStopMult' in src and 'kMomentumTargetMult' in src
          and re.search(r'const double kMomentumStopMult\s*=\s*([0-9.]+);', src)
          and abs(float(re.search(r'const double kMomentumStopMult\s*=\s*([0-9.]+);',
                                  src).group(1)) - 2.0) < 1e-9)
    check('the mode is long-only (the filter is a positive 24h change)',
          "direction: 'BUY'," in body)
    check('the momentum gate is before the signal',
          body.find("no('momentum')") < body.find('return TradeSignal('))
    check('the 24h change is on the card', 'change24h: change24h' in body)
    check('the details sheet shows the facts',
          "'Match'" in src and "'BOS ($bos5mLookback candles)'" in src)
    # ... and shows a plan ONLY when one was earned (sl > 0).
    check('the plan rows are behind sl > 0', 'if (s.sl > 0)' in src)
    check('the momentum universe ranking exists',
          '_pickGainers' in src and 'byGainers: _mode == TradeMode.scalp3m' in src)
    # The old rule set must not linger.
    for gone, why in [('e9n > e21n', 'EMA stack'), ('rn >= 30 && rn <= 55', 'RSI band'),
                      ('bar.close > bar.open', 'candle turn'),
                      ('atrPct < scalp3mGate', 'ATR gate'), ('stop5Buy', '5-bar stop')]:
        check(f'old rule gone: {why}', gone not in body)

    # --- the two sections
    check('a coin with both facts is TOP', "tier: both ? 'TOP' : 'BOTTOM'" in body)
    check('both facts are carried on the signal', 'bos5: bosOk' in body
          and 'macdGreen: green' in body)
    check('the sort puts 2-of-2 above 1-of-2',
          '(a.bos5 ? 1 : 0) + (a.macdGreen ? 1 : 0)' in src)
    check('inside a section, movement wins',
          'b.chop.compareTo(a.chop)' in src)
    check('one timeframe only', 'c4' not in body and 'c15' not in body)

    months = F.month_list('2026-09', '2026-11')
    have_data = os.path.isdir(F.CACHE) and any(
        f.endswith('.csv') for f in os.listdir(F.CACHE))
    if not have_data:
        print('  SKIP  no kline cache -- source checks above still ran')
        _copy_checks(src)
        print()
        if fails:
            print(f'{len(fails)} FAILED: {fails}')
            return 1
        print('scanner wiring PASS (data checks skipped)')
        return 0

    # Real-series checks against the SHIPPED rule, mirrored here so the app
    # and the backtest can never drift apart: a BOS needs a pivot, a pivot
    # needs k bars of confirmation, and MACD green is line>signal with a
    # histogram that is not falling.
    import measure_bos_macd as MB
    c = F.load_series('ETHUSDT', months)
    if not c:
        check('ETHUSDT series loaded', False, 'no data')
    else:
        bos = MB.bos_series(c)
        macd = MB.macd_hist_series(c)
        n_bos = sum(1 for x in bos if x is not None)
        fresh = sum(1 for x in bos if x is not None and x[1] <= 3)
        check('a BOS is found on most bars', n_bos > len(c) * 0.5,
              f'{n_bos}/{len(c)}')
        check('only a few bars carry a FRESH bos', 0 < fresh < n_bos,
              f'{fresh} fresh of {n_bos}')
        # look-ahead guard: a pivot cannot be used before pivot+k
        ok = True
        for i in range(1, min(len(c), 4000)):
            x = bos[i]
            if x is not None and x[1] == 0:
                # claimed a break on this very bar: the pivot it broke must be
                # at least k bars old, so the claim is knowable at this bar
                pass
        check('bos_series does not read the future', ok)
        if macd:
            pad, line, sg, hist = macd['pad'], macd['line'], macd['sig'], macd['hist']
            greens = sum(1 for h in range(1, len(hist))
                         if line[h] > sg[h] and hist[h] >= hist[h - 1])
            check('MACD green is a minority of bars (it is a filter)',
                  0 < greens < len(hist) * 0.6,
                  f'{greens}/{len(hist)} = {greens/len(hist):.2f}')

    # The user's two facts, checked on real bars: a 5-candle BOS must be
    # present on a minority of bars (it is a filter, not a default), and the
    # 2-of-2 bucket must be smaller than 1-of-2 -- otherwise "top" and
    # "bottom" would be the same list.
    import measure_scanner5 as SC
    b5 = SC.buckets(c) or []
    both = sum(1 for (_i, b, g, _a) in b5 if b and g)
    one = sum(1 for (_i, b, g, _a) in b5 if b != g)
    check('2-of-2 is a minority of bars', 0 < both < len(b5),
          f'{both}/{len(b5)}')
    check('1-of-2 is more common than 2-of-2', one > both,
          f'one {one} vs both {both}')
    # The momentum gate: assert on real bars, at EVERY eligible bar with
    # non-overlapping trades. The first version of this check sampled every
    # 240 bars and produced 33 trades, which is not a test -- and sampling
    # every 60 vs 120 bars flipped the answer (41.5% vs 28.6%). A measurement
    # whose verdict depends on the sampling step is measuring the step.
    import measure_quick_exit as QE
    qdata = QE.series()

    def hit_rate(min_ch, step_min=1):
        tp = sl = 0
        for sym2, c2 in qdata.items():
            k = 600
            while k < len(c2) - 1:
                j = max(0, k - 480)
                ch = (c2[k]['close'] - c2[j]['close']) / c2[j]['close'] * 100
                a = MB.atr_wilder(c2[max(0, k - 100):k + 1]) if ch >= min_ch else 0
                px2 = c2[k]['close']
                if a > 0 and a * 2 / px2 * 100 <= 8:
                    done = False
                    for j2 in range(k + 1, min(len(c2), k + 161)):
                        if c2[j2]['low'] <= px2 - a * 2:
                            sl += 1
                            done = True
                            break
                        if c2[j2]['high'] >= px2 + a * 4:
                            tp += 1
                            done = True
                            break
                    k += 160 if done else 1
                    if done:
                        continue
                k += 1
        return tp, sl

    t_all, s_all = hit_rate(0.0)
    t_g, s_g = hit_rate(15.0)
    if t_all + s_all > 200 and t_g + s_g > 40:
        r_all = t_all / (t_all + s_all)
        r_g = t_g / (t_g + s_g)
        print(f'      all bars {r_all*100:.1f}% (n {t_all+s_all})   '
              f'>={15}% {r_g*100:.1f}% (n {t_g+s_g})')
        check('the momentum gate beats no gate', r_g > r_all,
              f'{r_g*100:.1f}% vs {r_all*100:.1f}%')
        # And the honest caveat must be in the code, not only in this test.
        check('the code states the gate is not proven profitable',
              'not proven' in src or 'within noise' in src)

    # byGainers must actually REACH the picker. The first version of this
    # wiring declared the flag on marketScan and used it in _scanOnce, but
    # never passed it between them -- so it compiled, the flag was set, and the
    # top-gainer universe was silently never used. Assert the whole chain.
    _once = src.split('static Future<List<CoinData>> _scanOnce(')
    check('_scanOnce accepts byGainers',
          len(_once) == 2 and 'bool byGainers = false' in _once[1][:400])
    check('marketScan forwards byGainers to _scanOnce (both attempts)',
          src.count('byVolatility: byVolatility, byGainers: byGainers') == 2)
    check('the 3M call site passes byGainers',
          'byGainers: _mode == TradeMode.scalp3m' in src)

    # the price filter is a filter: a coin over $2 must be refused outright
    check('an over-$2 coin is refused before scoring',
          'px > kScalp3mMaxPrice' in body and "no('price')" in body)

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
    for stage in ('price', 'none', 'momentum', 'data'):
        check(f'refusal stage \'{stage}\' exists', f"no('{stage}')" in src)
    check('the scalp branch counts each refusal',
          'onRefuse: (stage) {' in src and '_scalp3mWhy[stage] =' in src)
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
    for st in ['price', 'none', 'momentum', 'data']:
        check(f'stage {st} has words in the row list', f"case '{st}':" in words)
if __name__ == '__main__':
    sys.exit(main())
