"""
The question the numbers force: what fee would a 3M scalper need to break even?

Phase 1 and 2 (measure_real_3m*.py) showed every 3M structure losing money on
real Binance candles. The cause is arithmetic, not a bad indicator:

    cost_R per trade = fee_round_trip / (stop width as a fraction of price)

A 3M ATR on a liquid pair is 0.1-0.4% of price. A 1.5x ATR stop is therefore
0.15-0.6% wide. If the round trip costs 0.25% -- Binance spot's realistic
taker+taker with slippage -- then the fee alone is 0.4R to 1.7R PER TRADE. The
gross edge of any 3M structure measured here is at most a few percent of R.

This file solves for the break-even fee directly:

    net(f) = gross_R - f * sum(100 * entry / risk)      [f in percent]
    f*     = gross_R / sum(100 * entry / risk)

f* is the round-trip fee at which that rule is exactly flat. If f* is below the
fee the user actually pays, the rule cannot work no matter how it is tuned, and
the app should say so instead of printing a confident percentage.

Run: python3 tool/mirror/measure_real_3m_fee.py [--quick]
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import fetch_real_1m as F
import mirror3m as m3
from measure_real_3m import stats, row
from measure_real_3m_exits import walk_exit

# Round-trip costs, in percent of notional.
FEES = {
    'spot 0.10+0.10': 0.200,
    'spot 0.125+0.125': 0.250,   # what the app has assumed since v17
    'futures taker 0.05+0.05': 0.100,
    'futures 0.02+0.02': 0.040,
    'maker 0.01+0.01': 0.020,
}


def gross_pct(trs):
    """Total move captured, in PERCENT of price (not R).

    One trade worth +1R on a stop that sat 0.6% below entry earned 0.6% of
    price. Summing `r * stop_pct` across trades is therefore the total percent
    the rule captured, which is the same unit the fee is quoted in.
    """
    return sum(t['r'] * (t['risk'] / t['entry'] * 100.0) for t in trs)


def units(trs):
    """(gross percent, total notional percent) for a trade list.

    Each trade risks a 100% notional position, so the fee paid per trade is
    `fee_pct` percent of price, and `gross - fee * n_trades` is the net in
    percent-of-price. f* is where that crosses zero.
    """
    g = gross_pct(trs)
    return g, float(len(trs))


def breakeven_fee(trs):
    """f*, in percent round trip, from the trades themselves."""
    if not trs:
        return None
    g, n = units(trs)
    return g / n if n else None


def net_at(trs, fee_pct):
    """Net, in percent of price, at a given round-trip fee."""
    if not trs:
        return None
    g, n = units(trs)
    return g - fee_pct * n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--months', default='2026-08:2026-11')
    ap.add_argument('--symbols', default='')
    ap.add_argument('--quick', action='store_true')
    a = ap.parse_args()
    months = F.month_list(*a.months.split(':'))
    if a.symbols:
        syms = [x.strip().upper() for x in a.symbols.split(',') if x.strip()]
    else:
        syms = sorted({f.split('_1m_')[0] for f in os.listdir(F.CACHE)
                       if f.endswith('.csv')})
    if a.quick:
        syms = syms[:6]

    combos = [
        ('pullback', 'rr', 2.0, 0.0, 20, 0.0),
        ('pullback', 'rr', 3.0, 0.0, 60, 0.0),
        ('pullback', 'trail', 0.0, 2.0, 60, 0.0),
        ('ignite', 'rr', 2.0, 0.0, 20, 0.0),
        ('ignite', 'trail', 0.0, 2.0, 60, 0.0),
        # volatility gates: only scalp bars where 3M ATR% is itself large
        ('pullback', 'rr', 3.0, 0.0, 60, 0.50),
        ('pullback', 'trail', 0.0, 2.0, 60, 0.50),
        ('ignite', 'trail', 0.0, 2.0, 60, 0.50),
        ('pullback', 'rr', 3.0, 0.0, 60, 0.80),
        ('ignite', 'trail', 0.0, 2.0, 60, 0.80),
    ]

    acc = {}
    for sym in syms:
        c = F.load_series(sym, months)
        if len(c) < 3000:
            continue
        s = m3.Series(c)
        for entry, ekind, rr, trail, hold, gate in combos:
            key = (entry, ekind, rr, trail, hold, gate)
            trs = walk_exit(c, s, entry_kind=entry, exit_kind=ekind,
                            rr=rr or 2.0, trail_mult=trail or 2.0, hold=hold,
                            atr_pct_gate=gate, min_stop_pct=0.35)
            acc.setdefault(key, []).extend(trs)

    hdr = f"{'rule':40s}{'n':>6s}{'WR':>7s}{'stop%':>7s}{'gross%':>9s}" \
          + ''.join(f"{k:>22s}" for k in FEES) + f"{'f* (breakeven)':>16s}"
    print(f"symbols {len(syms)}, months {months[0]}..{months[-1]}")
    print(hdr)
    print("-" * len(hdr))
    ranked = []
    for k, trs in acc.items():
        st = stats(trs)
        if not st:
            continue
        ranked.append((k, trs, st))
    ranked.sort(key=lambda kv: -(breakeven_fee(kv[1]) or -99))
    for k, trs, st in ranked:
        entry, ekind, rr, trail, hold, gate = k
        name = f"{entry} {ekind}{('%.0f' % rr) if rr else ''}" \
               f"{(' trail%.0f' % trail) if trail else ''} h{hold}" \
               f"{(' atr>%.2f' % gate) if gate else ''}"
        fstar = breakeven_fee(trs)
        cells = ''.join(f"{net_at(trs, f):+22.1f}" for f in FEES.values())
        print(f"{name:40s}{st['n']:6d}{st['wr']:6.1f}%{st['stop']:7.2f}"
              f"{gross_pct(trs):+9.2f}{cells}{fstar:15.3f}%")

    print()
    print("f* is the round-trip fee at which the rule is flat. Binance spot taker")
    print("is ~0.20% round trip and futures taker ~0.10% (0.05% x 2), so a rule")
    print("whose f* sits below 0.10% cannot pay for itself on either market.")


if __name__ == '__main__':
    main()
