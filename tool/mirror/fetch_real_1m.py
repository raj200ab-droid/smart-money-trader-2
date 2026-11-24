"""
Download REAL Binance spot 1-minute klines from GitHub, then aggregate to 3M.

Why this file exists
--------------------
Every number in NOTES.md up to v18.1 was measured on synthetic random walks.
A random walk has no trend persistence, no volatility clustering, no session
structure and no volume/price relationship -- and the 3-minute scalping rules
are precisely a bet on those things. Measuring them on noise does not tell you
whether they work, it tells you what noise does (answer: nothing, or worse).

So: real 1-minute candles, from the public archive at
`github.com/parshant231234-eng/<SYMBOL>-Historical-Data`, laid out as

    <SYMBOL>-Historical-Data/1m/<YYYY>/<MM>/<SYMBOL>_1m_<YYYY>-<MM>.csv

Only GitHub is reachable from this sandbox, which is why the archive matters:
the exchange APIs themselves are blocked.

The cache lives OUTSIDE the repository (default /tmp/klines) because 200 MB of
CSV is not source code. Nothing here is needed at runtime by the app; it is a
measurement harness.

Usage
    python3 tool/mirror/fetch_real_1m.py --symbols ETHUSDT,BNBUSDT --months 2026-06:2026-11
    python3 tool/mirror/fetch_real_1m.py --preset liquid --months 2026-05:2026-11
"""
import argparse
import csv
import io
import os
import subprocess
import sys

REPO = '{sym}-Historical-Data'
CACHE = os.environ.get('KLINES_CACHE', '/tmp/klines')
OWNER = 'parshant231234-eng'

# Liquid Binance spot pairs that exist in the archive. A scalp universe in the
# app is 400 coins ranked by movement, so a measurement sample should include
# both the majors (thin relative movement) and the movers.
PRESETS = {
    'majors': ['BTCUSDT', 'ETHUSDT', 'BNBUSDT', 'XRPUSDT', 'BCHUSDT', 'LTCUSDT',
               'ADAUSDT', 'SOLUSDT', 'DOGEUSDT', 'TRXUSDT'],
    'liquid': ['ETHUSDT', 'BNBUSDT', 'XRPUSDT', 'BCHUSDT', 'DOTUSDT',
               'ATOMUSDT', 'NEARUSDT', 'UNIUSDT', 'ETCUSDT', 'XLMUSDT',
               'ALGOUSDT', 'VETUSDT', 'EOSUSDT', 'AAVEUSDT', 'MKRUSDT',
               'INJUSDT', 'SUIUSDT', 'APTUSDT', 'SEIUSDT', 'ARBUSDT',
               'TIAUSDT', 'LDOUSDT', 'ENSUSDT', 'FETUSDT'],
    'movers': ['PEPEUSDT', 'SHIBUSDT', 'BONKUSDT', 'WIFUSDT', 'FLOKIUSDT',
               'GALAUSDT', 'SANDUSDT', 'MANAUSDT', 'AXSUSDT', 'CHZUSDT',
               'ENJUSDT', 'GMTUSDT', 'JASMYUSDT', 'DENTUSDT', 'SCUSDT',
               'IOSTUSDT', 'CELRUSDT', 'ONEUSDT', 'ZILUSDT', 'BANDUSDT'],
}


def month_list(a, b):
    """Inclusive 'YYYY-MM' range as a list."""
    ya, ma = map(int, a.split('-'))
    yb, mb = map(int, b.split('-'))
    out = []
    while (ya, ma) <= (yb, mb):
        out.append(f'{ya:04d}-{ma:02d}')
        ma += 1
        if ma > 12:
            ma, ya = 1, ya + 1
    return out


def path_for(sym, month):
    y, m = month.split('-')
    return f'1m/{y}/{m}/{sym}_1m_{month}.csv'


def fetch(sym, month, force=False):
    """Download one month of 1-minute candles. Returns local path or None."""
    os.makedirs(CACHE, exist_ok=True)
    dst = os.path.join(CACHE, f'{sym}_1m_{month}.csv')
    if os.path.exists(dst) and os.path.getsize(dst) > 1000 and not force:
        return dst
    ghpath = f'repos/{OWNER}/{REPO.format(sym=sym)}/contents/{path_for(sym, month)}'
    try:
        r = subprocess.run(['gh', 'api', ghpath, '-H', 'Accept: application/vnd.github.raw'],
                           capture_output=True, timeout=120)
    except subprocess.TimeoutExpired:
        return None
    if r.returncode != 0 or len(r.stdout) < 1000:
        return None
    with open(dst, 'wb') as f:
        f.write(r.stdout)
    return dst


def read_csv(path):
    """Rows as (open_ms, open, high, low, close, volume)."""
    rows = []
    with open(path, newline='') as f:
        rd = csv.DictReader(f)
        for r in rd:
            try:
                rows.append((int(r['timestamp']), float(r['open']),
                             float(r['high']), float(r['low']), float(r['close']),
                             float(r['volume'])))
            except (KeyError, ValueError):
                continue
    rows.sort()
    return rows


def aggregate(rows, minutes, gap_policy='split'):
    """Aggregate 1-minute rows into `minutes`-minute candles.

    A gap (delisted minutes, exchange downtime) must NOT be silently glued:
    the aggregate is split when the expected next minute is missing, so no
    candle spans a hole in the data.
    """
    step = minutes * 60 * 1000
    out = []
    cur = None
    expected = None
    for (t, o, h, l, c, v) in rows:
        bucket = (t // step) * step
        if cur is not None and expected is not None and t != expected and gap_policy == 'split':
            out.append(cur)
            cur = None
        if cur is None or cur['openTime'] != bucket:
            if cur is not None:
                out.append(cur)
            cur = {'openTime': bucket, 'closeTime': bucket + step - 1,
                   'open': o, 'high': h, 'low': l, 'close': c, 'volume': v}
        else:
            cur['high'] = max(cur['high'], h)
            cur['low'] = min(cur['low'], l)
            cur['close'] = c
            cur['volume'] += v
        expected = t + 60 * 1000
    if cur is not None:
        out.append(cur)
    return out


def load_series(sym, months, minutes=3):
    """Concatenate the cached months into one continuous `minutes`-minute series.

    Each month is read separately because the archive stores one file per month;
    continuity across the month boundary is checked, not assumed.
    """
    rows = []
    for m in months:
        p = os.path.join(CACHE, f'{sym}_1m_{m}.csv')
        if os.path.exists(p):
            rows.extend(read_csv(p))
    if not rows:
        return []
    rows.sort()
    # de-duplicate on timestamp (months can overlap by a bar)
    dedup, last = [], None
    for r in rows:
        if last is not None and r[0] == last:
            continue
        dedup.append(r)
        last = r[0]
    return aggregate(dedup, minutes)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--symbols', default='')
    ap.add_argument('--preset', default='', choices=sorted(PRESETS))
    ap.add_argument('--months', default='2026-05:2026-11')
    ap.add_argument('--force', action='store_true')
    a = ap.parse_args()

    syms = [s.strip().upper() for s in a.symbols.split(',') if s.strip()]
    if a.preset:
        syms += PRESETS[a.preset]
    if not syms:
        syms = PRESETS['liquid']
    m_from, m_to = a.months.split(':')
    months = month_list(m_from, m_to)

    ok, miss = 0, []
    for s in syms:
        got = 0
        for m in months:
            if fetch(s, m, force=a.force):
                got += 1
        if got:
            ok += 1
            print(f'{s:12s} {got}/{len(months)} months')
        else:
            miss.append(s)
    print(f'\ncached {ok} symbols in {CACHE}')
    if miss:
        print('missing everywhere:', ' '.join(miss))


if __name__ == '__main__':
    main()
