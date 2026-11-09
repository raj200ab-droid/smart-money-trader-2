"""
Prove the v11 universe rules in Python before trusting the Dart port.

The Dart side is `_isListed` / `selectUniverse` / `_pick` in lib/main.dart. This
file mirrors those three functions and asserts the properties the user asked
for: a 300-coin scan must actually hand 300 coins to the engine whenever the
exchange lists enough pairs, and must report an honest shortfall when it does
not.

Run: python3 tool/mirror/test_universe.py
"""
import random

PREFERRED_VOLUME = 5_000_000
SKIP = {
    'USDCUSDT', 'FDUSDUSDT', 'TUSDUSDT', 'BUSDUSDT', 'DAIUSDT', 'USDPUSDT',
    'EURUSDT', 'GBPUSDT', 'AEURUSDT', 'USDEUSDT', 'PYUSDUSDT', 'USD1USDT',
    'XUSDUSDT',
}
LEVERAGED = ('UPUSDT', 'DOWNUSDT', 'BULLUSDT', 'BEARUSDT', '3LUSDT', '3SUSDT')


def is_listed(symbol, price):
    """Mirror of MarketData._isListed: pair *shape* only, no volume rule."""
    if not symbol.endswith('USDT'):
        return False
    if symbol == 'USDTUSDT':
        return False
    if symbol in SKIP:
        return False
    if any(symbol.endswith(s) for s in LEVERAGED):
        return False
    return price > 0


def select_universe(all_coins, target):
    """Mirror of MarketData.selectUniverse: strong tier first, then quiet."""
    listed = [c for c in all_coins if is_listed(c['symbol'], c['price'])]
    strong = [c for c in listed if c['volume'] > PREFERRED_VOLUME]
    if len(strong) >= target:
        return strong
    weak = sorted(
        (c for c in listed if c['volume'] <= PREFERRED_VOLUME),
        key=lambda c: -c['volume'],
    )
    out = list(strong)
    seen = {c['symbol'] for c in strong}
    for c in weak:
        if len(out) >= target:
            break
        if c['symbol'] not in seen:
            seen.add(c['symbol'])
            out.append(c)
    return out


def pick(universe, gainers, losers):
    """Mirror of MarketData._pick, including the v11 shortfall fill."""
    gain = sorted((c for c in universe if c['pct'] > 0), key=lambda c: -c['pct'])
    lose = sorted((c for c in universe if c['pct'] < 0), key=lambda c: c['pct'])
    out, seen = [], set()
    for c in gain[:gainers]:
        if c['symbol'] not in seen:
            seen.add(c['symbol'])
            out.append(c)
    for c in lose[:losers]:
        if c['symbol'] not in seen:
            seen.add(c['symbol'])
            out.append(c)
    want = gainers + losers
    if len(out) < want:
        rest = sorted(
            (c for c in universe if c['symbol'] not in seen),
            key=lambda c: -abs(c['pct']),
        )
        for c in rest:
            if len(out) >= want:
                break
            if c['symbol'] not in seen:
                seen.add(c['symbol'])
                out.append(c)
    return out


def coin(symbol, price=1.0, volume=1e6, pct=1.0):
    return {'symbol': symbol, 'price': price, 'volume': volume, 'pct': pct}


def snapshot(n_pairs=460, seed=7):
    """A Binance-shaped ticker list: USDT pairs plus non-USDT noise."""
    rnd = random.Random(seed)
    rows = []
    for i in range(n_pairs):
        rows.append(coin(
            symbol=f'C{i}USDT',
            price=0.0 if i % 97 == 0 else rnd.uniform(1e-6, 500),
            volume=rnd.choice([0.0,
                               rnd.uniform(1e4, 4e6),
                               rnd.uniform(4e6, 3e8)]),
            pct=rnd.uniform(-25, 25),
        ))
    for i in range(2000):
        rows.append(coin(symbol=f'X{i}BTC', pct=rnd.uniform(-5, 5)))
    return rows


def check(name, cond, detail=''):
    status = 'PASS' if cond else 'FAIL'
    print(f'  {status}  {name}{("  " + detail) if detail else ""}')
    return cond


def main():
    ok = True
    for target in (300, 400):
        ok &= check_target(target)
    print()
    print('all universe tests PASS' if ok else 'SOME TESTS FAILED')
    return 0 if ok else 1


def check_target(target):
    ok = True
    print(f'universe rules (target {target})')

    rows = snapshot()
    listed = [c for c in rows if is_listed(c['symbol'], c['price'])]
    strong = [c for c in listed if c['volume'] > PREFERRED_VOLUME]
    universe = select_universe(rows, target)
    picked = pick(universe, target // 2, target // 2)

    ok &= check('only USDT pairs are listed',
                all(c['symbol'].endswith('USDT') for c in listed))
    ok &= check('stablecoins excluded',
                not any(c['symbol'] in SKIP for c in listed))
    ok &= check('zero-price rows excluded',
                all(c['price'] > 0 for c in listed))
    ok &= check('strong tier is a subset of listed',
                all(c in listed for c in strong))
    ok &= check(f'{target} coins are selected', len(universe) == target,
                f'{len(listed)} listed -> {len(strong)} strong -> {len(universe)}')
    ok &= check(f'{target} coins reach the engine', len(picked) == target,
                f'{len(picked)} picked')

    # the old behaviour, for contrast
    old_picked = pick(strong, target // 2, target // 2)
    print(f'        v10 behaviour on the same snapshot: {len(old_picked)} analysed')

    # a quiet market must still reach 300 when enough pairs are listed
    quiet = [coin(f'Q{i}USDT', 1.0, rnd_vol, -abs(0.1 + i * 0.01))
             for i, rnd_vol in enumerate(random.Random(3).uniform(1e4, 1e6)
                                         for _ in range(400))]
    quiet_picked = pick(select_universe(quiet, target), target // 2, target // 2)
    ok &= check(f'quiet day still reaches {target}', len(quiet_picked) == target,
                f'{len(quiet_picked)} picked')

    # a small exchange must report an honest shortfall, not invent coins
    small = [coin(f'T{i}USDT', 1.0, 1e5, (i % 5) - 2) for i in range(80)]
    small_picked = pick(select_universe(small, target), target // 2, target // 2)
    ok &= check('small exchange reports the truth', len(small_picked) == 80,
                f'{len(small_picked)} picked from 80 listed')

    # leveraged tokens must never appear
    lev = [coin('BTCUPUSDT'), coin('ETH3LUSDT'), coin('BTCUSDT')]
    lev_picked = pick(select_universe(lev, target), target // 2, target // 2)
    ok &= check('leveraged tokens never selected',
                [c['symbol'] for c in lev_picked] == ['BTCUSDT'])

    print()
    return ok


if __name__ == '__main__':
    raise SystemExit(main())
