"""
Second-phase search: can ANY exit structure pay a 0.25% round trip on real 3M?

Phase 1 (measure_real_3m.py) established the arithmetic problem: on liquid
Binance pairs a 3M ATR is ~0.1-0.35% of price, so a 1.5x ATR stop is 0.2-0.5%
wide -- and the fee is 0.25% of price. In R terms that is

    cost_R = 0.25 / stop_pct  ->  0.5R to 1.2R of cost per trade

A fixed 2R target then needs a win rate above (1 + cost_R) / 3, i.e. 50-73%.
No 3M signal hits that. So this file stops assuming a fixed target and asks the
three questions that actually change the arithmetic:

  1. EXIT. Does letting the trade run (ATR trailing stop) capture enough to
     justify the fee, compared with a hard 2R?
  2. SELECTION. Does restricting entries to high-volatility bars (top decile
     of ATR%) move cost_R down enough to matter?
  3. HOLD. Is 20 bars the wrong time horizon for a 3M scalp?

Every number is net of the fee, charged from each trade's own stop width.

Run: python3 tool/mirror/measure_real_3m_exits.py [--quick]
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import fetch_real_1m as F
import mirror3m as m3
from measure_real_3m import stats, row, walk_random


def walk_exit(c, s, entry_kind='pullback', exit_kind='rr', rr=2.0,
              stop_mult=1.5, trail_mult=2.0, hold=20, atr_pct_gate=0.0,
              min_stop_pct=0.0, vol_mult=1.0):
    """One walk, parameterised by entry rule, exit rule and volatility gate.

    exit_kind:
        'rr'       fixed R multiple target         (phase-1 behaviour)
        'trail'    ATR trailing stop, no target
        'rr_trail' fixed target, but stop trails once 1R is banked
    """
    n = len(c)
    trades = []
    i = s.warm
    # volatility gate threshold from the ATR% distribution up to i (causal)
    while i < n - 1:
        if not s.ok(i):
            i += 1
            continue
        sig = m3.signal3m(s, i, variant=entry_kind, rr=rr, atr_floor=0.0,
                          vol_mult=vol_mult, stop_mult=stop_mult,
                          min_stop_pct=min_stop_pct)
        if sig is None:
            i += 1
            continue
        if atr_pct_gate > 0 and sig['atr_pct'] < atr_pct_gate:
            i += 1
            continue
        is_buy = sig['direction'] == 'BUY'
        entry, risk, sl = sig['entry'], sig['risk'], sig['sl']
        tp = sig['tp']
        a = s.atr[i]
        outcome, r_mult, exit_bar = 'OPEN', 0.0, n - 1
        best = entry
        for j in range(i + 1, min(n, i + 1 + hold)):
            bar = c[j]
            if is_buy:
                hit_sl = bar['low'] <= sl
                best = max(best, bar['high'])
                hit_tp = bar['high'] >= tp if exit_kind == 'rr' else False
            else:
                hit_sl = bar['high'] >= sl
                best = min(best, bar['low'])
                hit_tp = bar['low'] <= tp if exit_kind == 'rr' else False
            if hit_sl:
                outcome = 'SL'
                r_mult = (sl - entry) / risk if is_buy else (entry - sl) / risk
                exit_bar = j
                break
            if hit_tp:
                outcome, r_mult, exit_bar = 'TP', abs(tp - entry) / risk, j
                break
            # trailing logic
            if exit_kind in ('trail', 'rr_trail'):
                if is_buy:
                    new_sl = max(sl, best - a * trail_mult)
                else:
                    new_sl = min(sl, best + a * trail_mult)
                if exit_kind == 'rr_trail':
                    # only start trailing once the trade is at least 1R up
                    in_profit = ((best - entry) if is_buy else (entry - best)) >= risk
                    if not in_profit:
                        new_sl = sl
                sl = new_sl
        if outcome == 'OPEN':
            last = c[min(n - 1, i + hold)]['close']
            r_mult = ((last - entry) if is_buy else (entry - last)) / risk
            outcome, exit_bar = 'TIME', min(n - 1, i + hold)
        trades.append({**sig, 'outcome': outcome, 'r': r_mult,
                       'exitBar': exit_bar, 'isBuy': is_buy})
        i = exit_bar + 1
    return trades


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
        syms = syms[:5]

    combos = []
    for entry in ('pullback', 'ignite'):
        for exit_kind, rr, trail in (('rr', 2.0, 0), ('rr', 3.0, 0),
                                     ('trail', 0, 2.0), ('trail', 0, 3.0),
                                     ('rr_trail', 3.0, 2.0)):
            for hold in (20, 60):
                combos.append((entry, exit_kind, rr, trail, hold, 0.0))
    # volatility-gated variants of the most promising shapes
    for gate in (0.25, 0.50):
        for entry in ('pullback', 'ignite'):
            combos.append((entry, 'trail', 0, 2.0, 60, gate))
            combos.append((entry, 'rr', 3.0, 0, 60, gate))

    acc = {}
    for sym in syms:
        c = F.load_series(sym, months)
        if len(c) < 3000:
            continue
        s = m3.Series(c)
        for combo in combos:
            entry, ekind, rr, trail, hold, gate = combo
            key = (entry, ekind, rr, trail, hold, gate)
            trs = walk_exit(c, s, entry_kind=entry, exit_kind=ekind, rr=rr,
                            trail_mult=trail or 2.0, hold=hold,
                            atr_pct_gate=gate, min_stop_pct=0.35)
            acc.setdefault(key, []).extend(trs)
        acc.setdefault(('ctrl',), []).extend(
            walk_random(c, seed=abs(hash(sym)) % 5000, rr=2.0, min_stop_pct=0.35))

    print(f"symbols {len(syms)}, months {months[0]}..{months[-1]}, "
          f"exit structures x holds x volatility gates, fee {m3.COST_PCT}%")
    print("=" * 152)
    ranked = []
    for k, trs in acc.items():
        if k[0] == 'ctrl':
            continue
        st = stats(trs)
        if st:
            ranked.append((k, st))
    ranked.sort(key=lambda kv: -kv[1]['net_avg'])
    for k, st in ranked[:18]:
        entry, ekind, rr, trail, hold, gate = k
        name = f"{entry} {ekind}{('%.0f' % rr) if rr else ''}" \
               f"{(' trail%.0f' % trail) if trail else ''} h{hold}" \
               f"{(' atr>%.2f' % gate) if gate else ''}"
        print(row(name, st))
    print()
    print(row('RANDOM ENTRY control', stats(acc.get(('ctrl',), []))))


if __name__ == '__main__':
    main()
