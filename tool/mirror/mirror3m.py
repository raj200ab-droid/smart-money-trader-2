"""
Python mirror of the 3-minute scalping engine (TradeMode.scalp3m).

Why this file exists as its own module
--------------------------------------
`single3m` fed ONE 3M series into all three engine slots (bias / zone /
trigger). That is not a scalping strategy, it is the swing engine pointed at a
shorter clock, and it double counts: one structure break contributes +30 (bias)
and +25 (OB) and +20 (trigger). §29 measured it at +105.2R gross, -259.9R net.

This module deliberately does NOT reuse that scoring. A 3-minute scalp needs
three readings that cannot be the same candle counted three times:

    trend   -- EMA(9) vs EMA(21) vs EMA(50). Direction only. +0/+1/-1.
    entry   -- where in the recent range price is, and whether the pullback is
               exhausted (RSI) -- i.e. "is this a good PRICE", not "which way".
    trigger -- a fresh expansion: close beyond the prior 20-bar extreme with
               volume behind it, or a band touch and reversal.

Three gates, three different questions. No gate can be satisfied by the same
event that satisfies another.

The fee is the whole story at 3M
--------------------------------
Round trip costs 0.25% of price. Expressed in R:

    cost_R = 0.25 / (stop width in %)

A 0.5% stop pays 0.50R of fee per trade, so the win rate has to beat the
barrier odds by a mile. A 2% stop pays 0.125R. This is why every variant here
has an ATR% floor: on a 3M bar, a coin that moves less than ~0.8% cannot pay
the fee no matter how good the signal is. That filter is not cosmetic, it is
the edge test.
"""
import math

COST_PCT = 0.25          # round trip, in percent of price
TIME_STOP = 20           # max bars held (1 hour on 3M)


# --------------------------------------------------------------------- helpers
def ema_series(values, period):
    if len(values) < period:
        return []
    k = 2.0 / (period + 1)
    out = [sum(values[:period]) / period]
    for v in values[period:]:
        out.append(v * k + out[-1] * (1 - k))
    return out


def rsi_series(closes, period=14):
    """Wilder RSI. Returns one value per close from index `period` on."""
    if len(closes) <= period:
        return []
    gains = losses = 0.0
    for i in range(1, period + 1):
        d = closes[i] - closes[i - 1]
        gains += max(d, 0.0)
        losses += max(-d, 0.0)
    ag, al = gains / period, losses / period
    out = [100.0 if al == 0 else 100 - 100 / (1 + ag / al)]
    for i in range(period + 1, len(closes)):
        d = closes[i] - closes[i - 1]
        ag = (ag * (period - 1) + max(d, 0.0)) / period
        al = (al * (period - 1) + max(-d, 0.0)) / period
        out.append(100.0 if al == 0 else 100 - 100 / (1 + ag / al))
    return out


def atr_series(c, period=14):
    """True range averaged over `period`, aligned to the tail (`len(c)-period`)."""
    n = len(c)
    if n <= period:
        return []
    tr = [c[0]['high'] - c[0]['low']]
    for i in range(1, n):
        tr.append(max(c[i]['high'] - c[i]['low'],
                      abs(c[i]['high'] - c[i - 1]['close']),
                      abs(c[i]['low'] - c[i - 1]['close'])))
    out = [sum(tr[1:period + 1]) / period]
    for i in range(period + 1, n):
        out.append((out[-1] * (period - 1) + tr[i]) / period)
    return out


def rolling_extreme(c, period):
    """Highest high / lowest low of the `period` bars BEFORE each bar.

    Causal by construction: bar i's value is built from i-period..i-1, so a
    breakout test at bar i cannot see bar i itself.
    """
    hi, lo = [], []
    for i in range(len(c)):
        a = max(0, i - period)
        if a >= i:
            hi.append(None)
            lo.append(None)
            continue
        hi.append(max(x['high'] for x in c[a:i]))
        lo.append(min(x['low'] for x in c[a:i]))
    return hi, lo


class Series:
    """All indicators the 3M rules need, computed once, causally.

    Index i in each array refers to bar i, using only bars <= i. That is what a
    live chart shows at the close of bar i, so reading it in a walk-forward loop
    is not look-ahead.
    """

    def __init__(self, c, atr_period=14, rsi_period=14):
        self.c = c
        self.n = len(c)
        closes = [x['close'] for x in c]
        # EMA(n) first value belongs to bar n-1; ATR(n) and RSI(n) first value
        # belongs to bar n. The alignment below must use those, not n+1: the
        # earlier version prepended one None too many, which silently made every
        # indicator one bar stale. Stale is still causal, but it is NOT the rule
        # the app runs, and a measurement of a different rule is not evidence.
        self.e9 = self._align(ema_series(closes, 9), 9 - 1)
        self.e21 = self._align(ema_series(closes, 21), 21 - 1)
        self.e50 = self._align(ema_series(closes, 50), 50 - 1)
        self.e20 = self._align(ema_series(closes, 20), 20 - 1)
        self.atr = self._align(atr_series(c, atr_period), atr_period)
        self.rsi = self._align(rsi_series(closes, rsi_period), rsi_period)
        self.dhi, self.dlo = rolling_extreme(c, 20)
        # volume average of the 20 bars BEFORE i
        self.vavg = []
        for i in range(self.n):
            a = max(0, i - 20)
            if i - a < 5:
                self.vavg.append(None)
            else:
                self.vavg.append(sum(x['volume'] for x in c[a:i]) / (i - a))
        self.warm = max(60, 55)

    @staticmethod
    def _align(series, lead):
        """Right-align a tail series onto bar indices (None before warm-up).

        `lead` is the index of the source bar the series' first value belongs to.
        """
        out = [None] * lead
        out.extend(series)
        return out

    def ok(self, i):
        return (i >= self.warm and self.atr[i] and self.e9[i] and self.e21[i]
                and self.e50[i] and self.rsi[i] and self.dhi[i] is not None
                and self.vavg[i])

    def atr_pct(self, i):
        px = self.c[i]['close']
        return (self.atr[i] / px * 100) if px > 0 else 0.0


# --------------------------------------------------------------------- signals
def signal3m(s, i, variant='ignite', rr=2.0, atr_floor=0.8, vol_mult=1.5,
             stop_mult=1.5, be_at=0.0, min_stop_pct=0.0, max_stop_pct=100.0):
    """One decision at the close of bar i. Returns a dict or None.

    No limit orders anywhere: entry is the close of the decision bar, which is
    always reachable, so the v18.0 fill bug cannot recur here.
    """
    if not s.ok(i):
        return None
    px = s.c[i]['close']
    a = s.atr[i]
    if a <= 0 or px <= 0:
        return None
    if s.atr_pct(i) < atr_floor:
        return None                      # fee is unpayable on this coin
    up = s.e9[i] > s.e21[i] > s.e50[i]
    dn = s.e9[i] < s.e21[i] < s.e50[i]
    vol_ok = s.c[i]['volume'] > s.vavg[i] * vol_mult
    r = s.rsi[i]

    buy = sell = None
    if variant == 'ignite':
        # Trend already up, price takes out the prior 20-bar high with volume.
        # Momentum ignition: buying the expansion, not the dip.
        if up and px > s.dhi[i] and vol_ok and r < 80:
            buy = True
        if dn and px < s.dlo[i] and vol_ok and r > 20:
            sell = True
    elif variant == 'pullback':
        # Trend up, price has pulled back under the fast EMA and RSI has cooled,
        # and THIS bar turns up. Entry is therefore cheaper than a breakout:
        # the same 2R target is closer in price terms, and the fee is a smaller
        # fraction of the move.
        if up and px < s.e21[i] and 30 <= r <= 55 and s.c[i]['close'] > s.c[i]['open']:
            buy = True
        if dn and px > s.e21[i] and 45 <= r <= 70 and s.c[i]['close'] < s.c[i]['open']:
            sell = True
    elif variant == 'bandrev':
        # Counter-trend exhaustion at the band, but only WITH the 50-EMA
        # direction. Buying a flush in an uptrend.
        band_lo = s.e20[i] - 2.0 * a
        band_hi = s.e20[i] + 2.0 * a
        if px > s.e50[i] and px < band_lo and r < 32 and s.c[i]['close'] > s.c[i]['open']:
            buy = True
        if px < s.e50[i] and px > band_hi and r > 68 and s.c[i]['close'] < s.c[i]['open']:
            sell = True
    elif variant == 'both':
        # Whichever of ignite / pullback fires first, in trend direction only.
        if up and ((px > s.dhi[i] and vol_ok and r < 80) or
                   (px < s.e21[i] and 30 <= r <= 55 and s.c[i]['close'] > s.c[i]['open'])):
            buy = True
        if dn and ((px < s.dlo[i] and vol_ok and r > 20) or
                   (px > s.e21[i] and 45 <= r <= 70 and s.c[i]['close'] < s.c[i]['open'])):
            sell = True

    if buy is None and sell is None:
        return None
    is_buy = buy is True

    # ---- stop: outside the recent micro-swing, and never tighter than
    # `stop_mult` ATR. The floor is the fee model: a 1.5x ATR stop pays ~0.17R
    # of cost, a 0.5x ATR stop pays 0.5R before the trade does anything.
    if is_buy:
        lo = min(x['low'] for x in s.c[max(0, i - 4):i + 1])
        sl = min(lo, px - a * stop_mult)
        risk = px - sl
        if risk <= 0:
            return None
        if be_at and risk / a > 3.0:
            return None                  # stop too far for a scalp
        tp = px + risk * rr
    else:
        hi = max(x['high'] for x in s.c[max(0, i - 4):i + 1])
        sl = max(hi, px + a * stop_mult)
        risk = sl - px
        if risk <= 0:
            return None
        if be_at and risk / a > 3.0:
            return None
        tp = px - risk * rr

    # Fee-aware stop bounds. The round trip costs 0.25% of price; a stop of
    # width W% therefore pays 0.25/W R of cost. Refusing stops narrower than
    # `min_stop_pct` is a direct statement about the fee, not a preference.
    stop_pct = risk / px * 100.0
    if stop_pct < min_stop_pct or stop_pct > max_stop_pct:
        return None

    return {'direction': 'BUY' if is_buy else 'SELL', 'entry': px, 'sl': sl,
            'tp': tp, 'risk': risk, 'bar': i, 'atr_pct': s.atr_pct(i),
            'be': px + risk * be_at if (be_at and is_buy) else
                  (px - risk * be_at if be_at else 0.0)}


def walk3m(c, variant='ignite', rr=2.0, atr_floor=0.8, vol_mult=1.5,
           stop_mult=1.5, be_at=0.0, hold=TIME_STOP, max_trades=4000,
           series=None, min_stop_pct=0.0, max_stop_pct=100.0):
    """Walk forward on ONE 3M series. Enter at the decision bar's close.

    A bar that touches both the stop and the target counts as a loss, same
    convention as the shipped backtester. `series` lets a caller reuse one
    precomputed indicator set across variants (it is the expensive part).
    """
    s = series if series is not None else Series(c)
    n = len(c)
    trades = []
    i = s.warm
    while i < n - 1:
        sig = signal3m(s, i, variant=variant, rr=rr, atr_floor=atr_floor,
                       vol_mult=vol_mult, stop_mult=stop_mult, be_at=be_at,
                       min_stop_pct=min_stop_pct, max_stop_pct=max_stop_pct)
        if sig is None:
            i += 1
            continue
        is_buy = sig['direction'] == 'BUY'
        sl, tp, entry, risk = sig['sl'], sig['tp'], sig['entry'], sig['risk']
        moved_to_be = False
        outcome, r_mult, exit_bar = 'OPEN', 0.0, n - 1
        for j in range(i + 1, min(n, i + 1 + hold)):
            bar = c[j]
            hit_sl = bar['low'] <= sl if is_buy else bar['high'] >= sl
            hit_tp = bar['high'] >= tp if is_buy else bar['low'] <= tp
            if hit_sl:
                outcome, exit_bar = 'SL', j
                r_mult = -1.0 if sl == sig['sl'] else 0.0
                break
            if hit_tp:
                outcome, r_mult = 'TP', abs(tp - entry) / risk
                exit_bar = j
                break
            # move the stop to break-even once the trade is 1R in profit
            if be_at and not moved_to_be:
                if (is_buy and bar['high'] >= entry + risk) or \
                        ((not is_buy) and bar['low'] <= entry - risk):
                    sl = entry
                    moved_to_be = True
        if outcome == 'OPEN':
            # time stop: book whatever the trade is worth at the last held bar
            last = c[min(n - 1, i + hold)]['close']
            r_mult = ((last - entry) if is_buy else (entry - last)) / risk
            outcome, exit_bar = 'TIME', min(n - 1, i + hold)
        trades.append({**sig, 'outcome': outcome, 'r': r_mult,
                       'exitBar': exit_bar, 'isBuy': is_buy})
        i = exit_bar + 1
        if len(trades) >= max_trades:
            break
    return trades


def summarise3m(trades):
    """Gross and net R. Cost is charged per trade from ITS OWN stop width."""
    closed = [t for t in trades if t['outcome'] != 'OPEN']
    if not closed:
        return None
    def cost_r(t):
        return (COST_PCT / 100.0 * t['entry']) / t['risk']
    gross = [t['r'] for t in closed]
    net = [t['r'] - cost_r(t) for t in closed]
    wins = [t for t in closed if t['r'] > 0]
    n = len(closed)
    return {
        'n': n,
        'wr': len(wins) / n * 100,
        'gross': sum(gross),
        'net': sum(net),
        'gross_avg': sum(gross) / n,
        'net_avg': sum(net) / n,
        'tp': sum(1 for t in closed if t['outcome'] == 'TP'),
        'sl': sum(1 for t in closed if t['outcome'] == 'SL'),
        'time': sum(1 for t in closed if t['outcome'] == 'TIME'),
        'cost': sum(cost_r(t) for t in closed) / n,
        'stop_pct': sum(t['risk'] / t['entry'] * 100 for t in closed) / n,
        'atr_pct': sum(t['atr_pct'] for t in closed) / n,
        'buys': sum(1 for t in closed if t['isBuy']),
        'sells': sum(1 for t in closed if not t['isBuy']),
    }
