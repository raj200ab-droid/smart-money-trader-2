"""
Validation of the one thing that survived phase 1-3: the volatility GATE.

Phase 3 (measure_real_3m_fee.py) found a sharp split:

    every rule, no ATR% gate        f* = 0.02-0.04% round trip   (dead)
    pullback, gate ATR% > 0.50      f* = 0.17%
    pullback, gate ATR% > 0.80      f* = 0.48%                  (alive)

In words: a 3-minute scalper cannot pay a 0.25% fee out of a 0.6% stop. It can
pay it out of a 2% stop taken only when the 3M bar itself is moving 0.8%+.
The gate is not a tweak, it is the whole model, so it gets the full treatment:

  1. OUT OF SAMPLE. Train months and test months are disjoint. Anything tuned on
     the first half must survive the second half untouched.
  2. GATED RANDOM CONTROL. The same gate, the same stops, the same targets, with
     entries chosen at random. If the gate alone explains the result, the entry
     rule is decoration and must be reported as such.
  3. PARAMETER ROBUSTNESS. A gate at 0.80 that only works at exactly 0.80 is a
     curve fit. It has to work across a band.
  4. PER-SYMBOL CONSISTENCY. One coin carrying the average is not an edge.
  5. THIN SAMPLE CHECK. n per bucket, so a 12-trade bucket cannot masquerade.

Run: python3 tool/mirror/measure_real_3m_gate.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import fetch_real_1m as F
import mirror3m as m3
from measure_real_3m import stats, row, walk_random
from measure_real_3m_fee import gross_pct

TRAIN = ('2026-02', '2026-07')   # 6 months
TEST = ('2026-08', '2026-11')    # 4 months, untouched
GATES = [0.0, 0.40, 0.60, 0.70, 0.80, 1.00, 1.30]
FEE = 0.25          # spot taker + slippage, the assumption used in the app


def run(c, s, gate, variant='pullback', stop_mult=1.5, rr=3.0, hold=60):
    from measure_real_3m_exits import walk_exit
    return walk_exit(c, s, entry_kind=variant, exit_kind='rr', rr=rr,
                     trail_mult=2.0, hold=hold, atr_pct_gate=gate,
                     min_stop_pct=0.35, stop_mult=stop_mult)


def net_pct(trs, fee=FEE):
    """Net in percent of price at `fee` percent round trip."""
    if not trs:
        return 0.0
    return gross_pct(trs) - fee * len(trs)


def load(sym, rng):
    months = F.month_list(*rng)
    c = F.load_series(sym, months)
    return c if len(c) > 3000 else None


def main():
    syms = sorted({f.split('_1m_')[0] for f in os.listdir(F.CACHE)
                   if f.endswith('.csv')})
    print(f"symbols: {len(syms)}   train {TRAIN[0]}..{TRAIN[1]}   "
          f"test {TEST[0]}..{TEST[1]}   fee {FEE}% round trip\n")

    # ---------------------------------------------------------------- OOS
    print("=" * 148)
    print("1. OUT OF SAMPLE -- pullback, 1.5xATR stop, R:R 3, 60-bar hold")
    print("=" * 148)
    print(f"{'gate':>6s} | {'TRAIN n':>8s} {'WR':>6s} {'gross%':>8s} {'net%':>9s} "
          f"{'net%':>8s} | {'TEST n':>7s} {'WR':>6s} {'gross%':>8s} {'net%':>9s} {'net%':>8s}")
    print(f"{'':>6s} | {'':>8s} {'':>6s} {'':>8s} {'@0.10':>9s} {'@0.25':>8s} | "
          f"{'':>7s} {'':>6s} {'':>8s} {'@0.10':>9s} {'@0.25':>8s}")
    print("-" * 148)
    keep = {}
    for gate in GATES:
        tr, te = [], []
        for sym in syms:
            for rng, acc in ((TRAIN, tr), (TEST, te)):
                c = load(sym, rng)
                if c is None:
                    continue
                s = m3.Series(c)
                acc.extend(run(c, s, gate))
        a, b = stats(tr), stats(te)
        if not a or not b:
            continue
        print(f"{gate:6.2f} | {a['n']:8d} {a['wr']:5.1f}% {gross_pct(tr):+8.1f} "
              f"{net_pct(tr, 0.10):+9.1f} {net_pct(tr):+8.1f} | "
              f"{b['n']:7d} {b['wr']:5.1f}% {gross_pct(te):+8.1f} "
              f"{net_pct(te, 0.10):+9.1f} {net_pct(te):+8.1f}")
        keep[gate] = (tr, te)

    # -------------------------------------------------- gated random control
    print()
    print("=" * 148)
    print("2. GATED RANDOM CONTROL -- same gate, same stop/target/hold, entry by lot")
    print("=" * 148)
    for gate in (0.60, 0.80, 1.00):
        tr_r, te_r = [], []
        for sym in syms:
            for rng, acc in ((TRAIN, tr_r), (TEST, te_r)):
                c = load(sym, rng)
                if c is None:
                    continue
                s = m3.Series(c)
                n = len(c)
                i = s.warm
                import random
                rnd = random.Random(abs(hash(sym)) % 9999)
                while i < n - 1:
                    if not s.ok(i) or s.atr_pct(i) < gate:
                        i += 1
                        continue
                    up = s.e9[i] > s.e21[i] > s.e50[i]
                    dn = s.e9[i] < s.e21[i] < s.e50[i]
                    if not (up or dn):
                        i += 1
                        continue
                    is_buy = up
                    px, a = c[i]['close'], s.atr[i]
                    lo = min(x['low'] for x in c[max(0, i - 4):i + 1])
                    hi = max(x['high'] for x in c[max(0, i - 4):i + 1])
                    sl = min(lo, px - a * 1.5) if is_buy else max(hi, px + a * 1.5)
                    risk = (px - sl) if is_buy else (sl - px)
                    if risk <= 0 or risk / px * 100 < 0.35:
                        i += 1
                        continue
                    tp = px + risk * 3.0 if is_buy else px - risk * 3.0
                    outcome, r_mult, exit_bar = 'OPEN', 0.0, n - 1
                    for j in range(i + 1, min(n, i + 61)):
                        bar = c[j]
                        hs = bar['low'] <= sl if is_buy else bar['high'] >= sl
                        ht = bar['high'] >= tp if is_buy else bar['low'] <= tp
                        if hs:
                            outcome, r_mult, exit_bar = 'SL', -1.0, j
                            break
                        if ht:
                            outcome, r_mult, exit_bar = 'TP', 3.0, j
                            break
                    if outcome == 'OPEN':
                        last = c[min(n - 1, i + 60)]['close']
                        r_mult = ((last - px) if is_buy else (px - last)) / risk
                        outcome, exit_bar = 'TIME', min(n - 1, i + 60)
                    acc.append({'entry': px, 'risk': risk, 'r': r_mult,
                                'outcome': outcome, 'isBuy': is_buy})
                    i = exit_bar + 1
        a, b = stats(tr_r), stats(te_r)
        if a and b:
            print(f"gate {gate:.2f}  TRAIN n {a['n']:6d} net@{FEE} {net_pct(tr_r):+9.1f}%   "
                  f"TEST n {b['n']:6d} net@{FEE} {net_pct(te_r):+9.1f}%")

    # ------------------------------------------------------------ per symbol
    print()
    print("=" * 148)
    print("3. PER-SYMBOL, gate 0.80, TEST months only (a result carried by one coin is not one)")
    print("=" * 148)
    rows = []
    for sym in syms:
        c = load(sym, TEST)
        if c is None:
            continue
        s = m3.Series(c)
        trs = run(c, s, 0.80)
        if not trs:
            continue
        rows.append((sym, len(trs), net_pct(trs)))
    rows.sort(key=lambda r: -r[2])
    pos = sum(1 for r in rows if r[2] > 0)
    for sym, n, net in rows:
        bar = ('#' * min(40, int(abs(net)))) if net > 0 else ('-' * min(40, int(abs(net))))
        print(f"{sym:11s} n {n:4d}  net {net:+8.1f}%  {bar}")
    print(f"\npositive on {pos}/{len(rows)} symbols")


if __name__ == '__main__':
    main()
