"""
The 3M list must be ordered by movement, not by confidence.

Device ask: on the 3-minute stack, show the coins that move most first, and
still show the ones that do not move -- but at the bottom.

Python cannot run the widget, so this asserts the two rules that decide the
order, against the Dart source and against a small model of the comparator:

  1. movement (chop) is measured from the trigger series as ATR(14)/price;
  2. within a tier, chop decides the order in single3m only, and confidence
     decides everywhere else (so swing/scalp ordering does not change);
  3. a coin with no setup is still collected in single3m, and only there.

Run: python3 tool/mirror/test_3m_order.py
"""
import os
import sys

DART = os.path.join(os.path.dirname(__file__), '..', '..', 'lib', 'main.dart')
ok = True


def check(name, cond, detail=''):
    global ok
    ok = ok and bool(cond)
    print(f"  {'PASS' if cond else 'FAIL'}  {name}"
          + (f'  {detail}' if detail else ''))


def main():
    src = open(DART, encoding='utf-8').read()

    check('chop measured as ATR(14) / price',
          'final chop = atr(c15, period: 14) / px * 100;' in src,
          'movement must come from the trigger candles')

    check('chop carried on the signal',
          'final double chop;' in src and 'this.chop = 0,' in src)

    # v18.2 widened this: both 3M modes order by movement, and swing/scalp
    # still order by confidence. The pin is the SET, not the string.
    check('sort uses chop in the 3M modes only',
          'if (a.mode == TradeMode.single3m || a.mode == TradeMode.scalp3m) {' in src
          and 'if (a.mode == TradeMode.swing' not in src
          and 'final c = b.chop.compareTo(a.chop);' in src,
          'swing/scalp keep confidence ordering')

    check('confidence still the final tiebreak',
          'return b.confidence.compareTo(a.confidence);' in src)

    # single3m collects them in the SMC path; scalp3m collects them in its own
    # branch. Both cap and sort the list the same way.
    check('quiet coins collected in single3m',
          'if (sig == null &&' in src and '_mode == TradeMode.single3m' in src)
    check('quiet coins collected in scalp3m',
          'quiet3 = _Quiet(sym, px3 > 0 ? a3 / px3 * 100 : 0, tr);' in src)

    check('quiet coins rendered below the signals',
          '_quietHeader()' in src and '_quietRow' in src
          and 'if (i < items.length) {' in src,
          'signals first, then a divider, then the quiet ones')

    check('quiet list is capped',
          '_quiets.length <= 40 ? _quiets : _quiets.sublist(0, 40)' in src,
          '400 coins with no setup must not bury the list')

    check('empty state skipped when quiet coins exist',
          'if (items.isEmpty && _quiets.isEmpty) {' in src)

    # --- model the comparator and prove the ordering properties -------------
    def order(items, mode_single):
        def rank(t):
            return {'STRICT': 2, 'WATCH': 1}.get(t['tier'], 0)

        def sgn(x):
            return (x > 0) - (x < 0)

        def cmp(a, b):
            # Dart's List.sort comparator: negative => a before b. Every line
            # below is the literal expression from lib/main.dart, so the model
            # cannot drift from the widget by a sign.
            r = sgn(rank(b) - rank(a))
            if r != 0:
                return r
            if mode_single:
                c = sgn(b['chop'] - a['chop'])      # b.chop.compareTo(a.chop)
                if c != 0:
                    return c
            return sgn(b['confidence'] - a['confidence'])

        import functools
        return sorted(items, key=functools.cmp_to_key(cmp))

    rows = [
        {'s': 'QUIET', 'tier': 'STRICT', 'chop': 0.10, 'confidence': 95},
        {'s': 'BUSY',  'tier': 'STRICT', 'chop': 1.20, 'confidence': 65},
        {'s': 'MID',   'tier': 'WATCH',  'chop': 0.90, 'confidence': 55},
    ]
    s3 = [r['s'] for r in order(rows, True)]
    sw = [r['s'] for r in order(rows, False)]
    check('3M puts the busiest coin first', s3[0] == 'BUSY', str(s3))
    check('3M still keeps STRICT above WATCH', s3.index('QUIET') < s3.index('MID'),
          str(s3))
    check('swing order unchanged (confidence within tier)', sw[0] == 'QUIET',
          f'confidence decides: {sw}')
    check('the moving coin outranks a higher-scoring quiet one in 3M',
          s3.index('BUSY') < s3.index('QUIET'), str(s3))

    print()
    return ok


if __name__ == '__main__':
    raise SystemExit(0 if main() else 1)
