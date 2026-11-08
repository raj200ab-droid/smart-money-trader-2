"""
Test data + equivalence checks for the mirror in mirror.py.

Run: python3 tool/mirror/test_mirror.py
Kept in the repo so the mirror cannot silently drift from lib/main.dart.
"""
import os
import random
import sys

import mirror

DART = os.path.join(os.path.dirname(__file__), '..', '..', 'lib', 'main.dart')


def test_swings_matches_naive():
    """The rolling-window swings() must equal the naive per-bar window scan."""
    def naive(c, length=mirror.SWING_LEN):
        pts = []
        if len(c) < length + 2:
            return pts
        state = None
        for n in range(1, len(c)):
            hi, lo = -1e18, 1e18
            for i in range(max(0, n - length + 1), n + 1):
                hi = max(hi, c[i]['high'])
                lo = min(lo, c[i]['low'])
            prev = state
            if n - length >= 0:
                if c[n - length]['high'] > hi:
                    state = 0
                elif c[n - length]['low'] < lo:
                    state = 1
            if state is None or prev is None:
                continue
            if state == 0 and prev != 0:
                pts.append(('high', n - length, c[n - length]['high']))
            if state == 1 and prev != 1:
                pts.append(('low', n - length, c[n - length]['low']))
        return pts

    rnd = random.Random(3)
    for trial in range(40):
        c, px = [], 100.0
        for _ in range(rnd.randint(300, 900)):
            n = px * (1 + rnd.gauss(0, 0.01))
            c.append({'open': px, 'high': max(px, n) * 1.002,
                      'low': min(px, n) * 0.998, 'close': n, 'volume': 1})
            px = n
        got = [(p['type'], p['index'], p['price']) for p in mirror.swings(c)]
        assert got == naive(c), f'swings drift on trial {trial}'
    print('  swings() == naive form: PASS (40 series)')


def test_mirror_is_the_dart_thresholds():
    """Thresholds are the ones in lib/main.dart; a silent change must fail here."""
    src = open(DART).read()
    assert "final threshold = relaxed ? 40.0 : 60.0;" in src, \
        'Dart thresholds changed: update mirror.STRICT/WATCH'
    assert 'static const int swingLen = 50;' in src
    assert 'static const int internalLen = 5;' in src
    assert mirror.STRICT == 60.0 and mirror.WATCH == 40.0
    assert mirror.SWING_LEN == 50 and mirror.INTERNAL_LEN == 5
    print('  thresholds match lib/main.dart: PASS')


def test_scores_add_up():
    """Score components must be the ones in the Dart scoring table."""
    src = open(DART).read()
    for frag in ('buy += 30;', 'buy += 25;', 'buy += 20;', 'buy += 5;',
                 'buy -= 25;'):
        assert frag in src, f'scoring fragment missing from Dart: {frag}'
    print('  scoring fragments present in Dart: PASS')


if __name__ == '__main__':
    print('mirror self-test')
    test_swings_matches_naive()
    test_mirror_is_the_dart_thresholds()
    test_scores_add_up()
    print('all mirror tests PASS')
    sys.exit(0)
