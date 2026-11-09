"""
Python mirror of the Dart engine in lib/main.dart.

Kept inside the repository on purpose: the previous copy lived outside the
workspace snapshot and was lost. If it is not in git, it does not exist.

Two sites are mirrored, because they are the two places a change can land:
  - multiTF  : builds the live score  (STRICT threshold 60 / WATCH 40)
  - analyze  : per-timeframe structure, order blocks, FVGs, EQH/EQL

`swings()` is verified against the naive O(n*len) form in test_mirror.py.
"""
import math

SWING_LEN = 50
INTERNAL_LEN = 5
STRICT = 60.0
WATCH = 40.0
TIGHT_STOP = False   # measured: tightening the stop to the 15M swing made net worse
MIN_RR = 1.5
MAX_STOP_PCT = 8.0    # measured: capping at 2.5% cut the only net-positive bucket


# --------------------------------------------------------------------- helpers
def atr(c, period=14):
    if len(c) < 2:
        return 0.0
    n = min(period, len(c) - 1)
    s = 0.0
    for i in range(len(c) - n, len(c)):
        s += max(c[i]['high'] - c[i]['low'],
                 abs(c[i]['high'] - c[i - 1]['close']),
                 abs(c[i]['low'] - c[i - 1]['close']))
    return s / n


def swings(c, length=SWING_LEN):
    """LUX pivot state machine. Oscillator starts UNKNOWN, not 0.

    Rolling max/min: the naive per-bar window scan is 42M max()/min() calls per
    walk and made measurement unusable. test_mirror.py proves this form equals
    the naive one on random series.
    """
    pts = []
    if len(c) < length + 2:
        return pts
    os_state = None
    win_hi = win_lo = None
    for n in range(1, len(c)):
        hi, lo = c[n]['high'], c[n]['low']
        if win_hi is None:
            win_hi, win_lo = hi, lo
            for i in range(max(0, n - length + 1), n):
                if c[i]['high'] > win_hi:
                    win_hi = c[i]['high']
                if c[i]['low'] < win_lo:
                    win_lo = c[i]['low']
        else:
            if hi > win_hi:
                win_hi = hi
            if lo < win_lo:
                win_lo = lo
            out = n - length
            if out >= 0:
                if c[out]['high'] >= win_hi:
                    win_hi = max(c[i]['high'] for i in range(out + 1, n + 1))
                if c[out]['low'] <= win_lo:
                    win_lo = min(c[i]['low'] for i in range(out + 1, n + 1))
        prev = os_state
        if n - length >= 0:
            if c[n - length]['high'] > win_hi:
                os_state = 0
            elif c[n - length]['low'] < win_lo:
                os_state = 1
        if os_state is None or prev is None:
            continue
        if os_state == 0 and prev != 0:
            pts.append({'price': c[n - length]['high'], 'index': n - length, 'type': 'high'})
        if os_state == 1 and prev != 1:
            pts.append({'price': c[n - length]['low'], 'index': n - length, 'type': 'low'})
    return pts


def last_unbroken_high(pts):
    h = [p for p in pts if p['type'] == 'high']
    return h[-1] if h else None


def last_unbroken_low(pts):
    l = [p for p in pts if p['type'] == 'low']
    return l[-1] if l else None


def structure_ob(c, from_index, to_index, bullish, atr_value):
    best = other = None
    best_index = from_index
    for i in range(to_index - 1, from_index, -1):
        if c[i]['high'] - c[i]['low'] >= atr_value * 2:
            continue
        if bullish:
            if best is None or c[i]['high'] > best:
                best, other, best_index = c[i]['high'], c[i]['low'], i
        else:
            if best is None or c[i]['low'] < best:
                best, other, best_index = c[i]['low'], c[i]['high'], i
    if best is None or other is None:
        return None
    return {'high': best if bullish else max(best, other),
            'low': min(best, other) if bullish else best,
            'type': 'bullish' if bullish else 'bearish', 'index': best_index}


# LUX's orderBlockMitigationInput defaults to High/Low: an order block dies when
# price trades *through* it, not merely when a candle closes beyond it. The app
# shipped the CLOSE variant, which keeps blocks alive longer and therefore emits
# more signals. MITIGATION selects which one to measure.
MITIGATION = 'highlow'  # LUX default, shipped from v13 | 'close' = the old rule


def active_obs(obs, c):
    out = []
    for o in obs:
        broken = False
        for i in range(o['index'] + 1, len(c)):
            if MITIGATION == 'highlow':
                # bearish block lives below price; it dies when price wicks above
                # its high. bullish block dies when price wicks below its low.
                if o['type'] == 'bearish' and c[i]['high'] > o['high']:
                    broken = True
                    break
                if o['type'] == 'bullish' and c[i]['low'] < o['low']:
                    broken = True
                    break
            else:
                if o['type'] == 'bearish' and c[i]['close'] < o['low']:
                    broken = True
                    break
                if o['type'] == 'bullish' and c[i]['close'] > o['high']:
                    broken = True
                    break
        if not broken:
            out.append(o)
    return out


def fvgs(c):
    raw, deltas = [], []
    if len(c) < 4:
        return raw
    for i in range(2, len(c)):
        prev2, prev1, cur = c[i - 2], c[i - 1], c[i]
        delta = (prev1['close'] - prev1['open']) / prev1['open'] * 100 if prev1['open'] > 0 else 0.0
        deltas.append(abs(delta))
        thr = sum(deltas) / len(deltas) * 2
        if cur['low'] > prev2['high'] and prev1['close'] > prev2['high'] and delta > thr:
            raw.append({'high': cur['low'], 'low': prev2['high'], 'type': 'bullish', 'index': i})
        if cur['high'] < prev2['low'] and prev1['close'] < prev2['low'] and -delta > thr:
            raw.append({'high': prev2['low'], 'low': cur['high'], 'type': 'bearish', 'index': i})
    active = []
    for f in raw:
        filled = False
        for i in range(f['index'] + 1, len(c)):
            if f['type'] == 'bullish' and c[i]['low'] < f['low']:
                filled = True
            if f['type'] == 'bearish' and c[i]['high'] > f['high']:
                filled = True
            if filled:
                break
        if not filled:
            active.append(f)
    return active


def trend_of(pts):
    highs = [p for p in pts if p['type'] == 'high']
    lows = [p for p in pts if p['type'] == 'low']
    if len(highs) < 2 or len(lows) < 2:
        return 0
    if highs[-1]['price'] > highs[-2]['price'] and lows[-1]['price'] > lows[-2]['price']:
        return 1
    if highs[-1]['price'] < highs[-2]['price'] and lows[-1]['price'] < lows[-2]['price']:
        return -1
    return 0


def _pattern(pts, pivot_index, bullish):
    t = trend_of([p for p in pts if p['index'] < pivot_index])
    if bullish and t < 0:
        return 'CHoCH'
    if not bullish and t > 0:
        return 'CHoCH'
    return 'BOS'


def breaks(c, pts, length=SWING_LEN, bars_back=30):
    out = []
    if len(c) < 3:
        return out
    highs = [p for p in pts if p['type'] == 'high']
    lows = [p for p in pts if p['type'] == 'low']
    cur_high = cur_low = None
    high_broken = low_broken = False
    for k in range(max(1, len(c) - bars_back), len(c)):
        for p in highs:
            if p['index'] + length <= k and (cur_high is None or p['index'] > cur_high['index']):
                cur_high, high_broken = p, False
        for p in lows:
            if p['index'] + length <= k and (cur_low is None or p['index'] > cur_low['index']):
                cur_low, low_broken = p, False
        px, prev = c[k]['close'], c[k - 1]['close']
        if cur_high and not high_broken and prev <= cur_high['price'] < px:
            high_broken = True
            out.append({'event': 'BULLISH', 'bar': k, 'pivot': cur_high,
                        'pattern': _pattern(pts, cur_high['index'], True)})
        if cur_low and not low_broken and prev >= cur_low['price'] > px:
            low_broken = True
            out.append({'event': 'BEARISH', 'bar': k, 'pivot': cur_low,
                        'pattern': _pattern(pts, cur_low['index'], False)})
    return out


def equal_highs(pts, atr_value, threshold=0.5):
    highs = [p for p in pts if p['type'] == 'high']
    if len(highs) < 2 or atr_value <= 0:
        return False
    a, b = highs[-1]['price'], highs[-2]['price']
    return (max(a, b) - min(a, b)) < atr_value * threshold


def equal_lows(pts, atr_value, threshold=0.5):
    lows = [p for p in pts if p['type'] == 'low']
    if len(lows) < 2 or atr_value <= 0:
        return False
    a, b = lows[-1]['price'], lows[-2]['price']
    return (max(a, b) - min(a, b)) < atr_value * threshold


def vol_spike(c):
    if len(c) < 21:
        return False
    avg = sum(c[i]['volume'] for i in range(len(c) - 20, len(c) - 1)) / 19
    return avg > 0 and c[-1]['volume'] > avg * 1.5


def buy_zone(obs, px):
    best = None
    for o in obs:
        if o['type'] != 'bullish' or o['high'] > px * 1.005 or o['low'] < px * 0.94:
            continue
        if best is None or o['high'] > best['high']:
            best = o
    return best


def sell_zone(obs, px):
    best = None
    for o in obs:
        if o['type'] != 'bearish' or o['low'] < px * 0.995 or o['high'] > px * 1.06:
            continue
        if best is None or o['low'] < best['low']:
            best = o
    return best


def nearest_ob(obs, px):
    best, best_d = None, math.inf
    for o in obs:
        d = o['low'] - px if px < o['low'] else (px - o['high'] if px > o['high'] else 0.0)
        if d < best_d:
            best_d, best = d, o
    return best


def zone_of(a):
    if a['premium'] <= 0:
        return 'Unknown'
    if a['swingHigh'] and a['close'] > a['swingHigh']['price']:
        return 'Breakout'
    if a['swingLow'] and a['close'] < a['swingLow']['price']:
        return 'Breakdown'
    if a['close'] > a['premium']:
        return 'Premium'
    if a['close'] < a['discount']:
        return 'Discount'
    return 'Equilibrium'


# --------------------------------------------------------------------- analyze
def analyze(c, tf='15M'):
    pts = swings(c)
    internal = swings(c, INTERNAL_LEN)
    last_high = last_unbroken_high(pts)
    last_low = last_unbroken_low(pts)
    recent = breaks(c, pts, bars_back=len(c) - 1)
    trend = trend_of(pts)
    if recent:
        trend = 1 if recent[-1]['event'] == 'BULLISH' else -1

    atr200 = atr(c, 200)
    atr_per = atr(c)
    swing_atr = atr200 if atr200 > 0 else atr_per

    last_break = recent[-1] if recent else None
    internal_last = breaks(c, internal, INTERNAL_LEN, bars_back=6)
    internal_last = internal_last[-1] if internal_last else None
    internal_fresh = internal_last is not None and len(c) - 1 - internal_last['bar'] <= 4

    obs = []
    for b in recent:
        ob = structure_ob(c, b['pivot']['index'], b['bar'], b['event'] == 'BULLISH', swing_atr)
        if ob and not any(o['index'] == ob['index'] and o['type'] == ob['type'] for o in obs):
            obs.append(ob)
    active = active_obs(obs, c)
    eqh = equal_highs(internal, swing_atr)
    eql = equal_lows(internal, swing_atr)

    premium = equilibrium = discount = 0.0
    if last_high and last_low and last_high['price'] > last_low['price']:
        up, dn = last_high['price'], last_low['price']
        premium = 0.95 * up + 0.05 * dn
        equilibrium = 0.525 * up + 0.475 * dn
        discount = 0.95 * dn + 0.05 * up

    return {
        'timeframe': tf, 'trend': trend, 'close': c[-1]['close'], 'atr': atr_per,
        'obs': active, 'fvgs': fvgs(c), 'eqh': eqh, 'eql': eql,
        'premium': premium, 'equilibrium': equilibrium, 'discount': discount,
        'swingHigh': last_high, 'swingLow': last_low,
        'breakEvent': last_break['event'] if last_break else '',
        'breakPattern': last_break['pattern'] if last_break else '',
        'breakLevel': last_break['pivot']['price'] if last_break else c[-1]['close'],
        'breakAge': -1 if last_break is None else len(c) - 1 - last_break['bar'],
        'internalFresh': internal_fresh,
        'internalEvent': internal_last['event'] if internal_last else '',
    }


# --------------------------------------------------------------------- multiTF
def multi_tf(c4, c1, c15, relaxed=False, tp_mode='swing', tp_pct=1.05):
    """Mirror of Engine.multiTF.

    tp_mode='swing' reproduces the app: TP is the 15M swing high/low when it is
    beyond entry, else 2R. tp_mode='pct' is the 1.05% variant under test.
    """
    if len(c4) < 60 or len(c1) < 60 or len(c15) < 60:
        return None
    t4, t1, t15 = analyze(c4, '4H'), analyze(c1, '1H'), analyze(c15, '15M')
    px = c15[-1]['close']
    if px <= 0:
        return None

    bull4, bear4 = t4['trend'] > 0, t4['trend'] < 0
    buy = sell = 0.0

    if bull4:
        buy += 30
    if bear4:
        sell += 30

    buy_ob, sell_ob = buy_zone(t1['obs'], px), sell_zone(t1['obs'], px)
    near = nearest_ob(t1['obs'], px)
    bull_blocked = near is not None and near['type'] == 'bearish' and px >= near['low'] * 0.99
    bear_blocked = near is not None and near['type'] == 'bullish' and px <= near['high'] * 1.01

    if bull4 and buy_ob:
        buy += 25
    if bear4 and sell_ob:
        sell += 25

    bull_fvg = any(f['type'] == 'bullish' and f['high'] <= px * 1.005 and f['low'] > px * 0.94
                   for f in t1['fvgs'])
    bear_fvg = any(f['type'] == 'bearish' and f['low'] >= px * 0.995 and f['high'] < px * 1.06
                   for f in t1['fvgs'])
    if bull4 and bull_fvg:
        buy += 20 if buy_ob is None else 10
    if bear4 and bear_fvg:
        sell += 20 if sell_ob is None else 10

    trigger_bull = t15['breakEvent'] == 'BULLISH' and px > t15['breakLevel']
    trigger_bear = t15['breakEvent'] == 'BEARISH' and px < t15['breakLevel']
    if trigger_bull:
        buy += 20
    if trigger_bear:
        sell += 20
    if relaxed:
        if not trigger_bull and t15['internalFresh'] and t15['internalEvent'] == 'BULLISH':
            buy += 20
            trigger_bull = True
        if not trigger_bear and t15['internalFresh'] and t15['internalEvent'] == 'BEARISH':
            sell += 20
            trigger_bear = True

    if t15['internalFresh'] or vol_spike(c15):
        if bull4 and vol_spike(c15):
            buy += 5
        elif bear4 and vol_spike(c15):
            sell += 5

    zone_now = zone_of(t1)
    if zone_now == 'Premium':
        buy -= 25
    if zone_now == 'Discount':
        sell -= 25
    if zone_now == 'Breakout' and bull4:
        buy += 5
    if zone_now == 'Breakdown' and bear4:
        sell += 5

    atr1 = t1['atr'] if t1['atr'] > 0 else px * 0.01
    threshold = WATCH if relaxed else STRICT

    def build(direction, score):
        entry = px
        if direction == 'BUY':
            if buy_ob:
                mid = (buy_ob['high'] + buy_ob['low']) / 2
                if (px - mid) / px <= 0.02:
                    entry = mid
                sl = buy_ob['low'] - atr1 * 0.25
            elif bull_fvg:
                gap = [f for f in t1['fvgs'] if f['type'] == 'bullish'
                       and f['high'] <= px * 1.005 and f['low'] > px * 0.94][-1]
                sl = gap['low'] - atr1 * 0.25
            elif t15['swingLow']:
                sl = t15['swingLow']['price'] - atr1 * 0.25
            else:
                sl = px - atr1 * 2
            # v15: risk and reward on the same horizon. If the 15M swing low is
            # tighter than the 1H block, use it -- otherwise a 15M swing target
            # can never sit 1.5x a 1H stop away and the target always falls back
            # to a mechanical 2R.
            if TIGHT_STOP and t15['swingLow']:
                tight = t15['swingLow']['price'] - atr1 * 0.25
                if entry > tight > sl:
                    sl = tight
            if sl >= entry:
                sl = entry - atr1
            risk = entry - sl
            if risk <= 0 or risk / entry > MAX_STOP_PCT / 100.0:
                return None
            if tp_mode == 'pct':
                tp = entry * (1 + tp_pct / 100.0)
            else:
                swing = t15['swingHigh']['price'] if t15['swingHigh'] else -1e18
                # OLD dart rule (v9, shipped): any swing beyond entry, >= 0.5%
                # away. That is what produced SOL RR 1:0.28 and ETH RR 1:0.11.
                # MIN_RR then enforces the v10 fix on top of the same rule.
                if swing <= entry * 1.005:
                    swing = -1e18
                tp = swing if swing >= entry + risk * MIN_RR else entry + risk * 2
        else:
            if sell_ob:
                mid = (sell_ob['high'] + sell_ob['low']) / 2
                if (mid - px) / px <= 0.02:
                    entry = mid
                sl = sell_ob['high'] + atr1 * 0.25
            elif bear_fvg:
                gap = [f for f in t1['fvgs'] if f['type'] == 'bearish'
                       and f['low'] >= px * 0.995 and f['high'] < px * 1.06][-1]
                sl = gap['high'] + atr1 * 0.25
            elif t15['swingHigh']:
                sl = t15['swingHigh']['price'] + atr1 * 0.25
            else:
                sl = px + atr1 * 2
            if TIGHT_STOP and t15['swingHigh']:
                tight = t15['swingHigh']['price'] + atr1 * 0.25
                if entry < tight < sl:
                    sl = tight
            if sl <= entry:
                sl = entry + atr1
            risk = sl - entry
            if risk <= 0 or risk / entry > MAX_STOP_PCT / 100.0:
                return None
            if tp_mode == 'pct':
                tp = entry * (1 - tp_pct / 100.0)
            else:
                swing = t15['swingLow']['price'] if t15['swingLow'] else 1e18
                if swing >= entry * 0.995:      # OLD dart rule, as shipped in v9
                    swing = 1e18
                tp = swing if swing <= entry - risk * MIN_RR else entry - risk * 2
        return {'direction': direction, 'entry': entry, 'sl': sl, 'tp': tp,
                'score': score, 'tier': 'WATCH' if relaxed else 'STRICT',
                'zone': zone_now}

    if buy >= threshold and bull4 and not bear4 and trigger_bull and not bull_blocked and buy > sell:
        return build('BUY', buy)
    if sell >= threshold and bear4 and not bull4 and trigger_bear and not bear_blocked and sell > buy:
        return build('SELL', sell)
    return None


# ---------------------------------------------------------------- walk forward
def walk(c4, c1, c15, step=1, window=200, window4h=400, max_trades=200,
         tp_mode='swing', tp_pct=1.05):
    """Mirror of Backtester.run. No look-ahead, one trade at a time."""
    trades = []
    n = len(c15)
    if n <= window + 5:
        return trades
    open_until = -1
    last_signal_bar = -window

    def aligned(series, time, count):
        end = len(series)
        for i in range(len(series) - 1, -1, -1):
            if series[i].get('closeTime', 0) <= time:
                end = i + 1
                break
        return series[end - count:end] if end >= count else None

    for i in range(window, n - 1, step):
        if i <= open_until or i - last_signal_bar < 2:
            continue
        w15 = c15[i - window + 1:i + 1]
        w1 = aligned(c1, c15[i]['closeTime'], window)
        w4 = (aligned(c4, c15[i]['closeTime'], window4h)
              or aligned(c4, c15[i]['closeTime'], 200)
              or aligned(c4, c15[i]['closeTime'], 120))
        if w1 is None or w4 is None:
            continue
        sig = (multi_tf(w4, w1, w15, tp_mode=tp_mode, tp_pct=tp_pct)
               or multi_tf(w4, w1, w15, relaxed=True, tp_mode=tp_mode, tp_pct=tp_pct))
        if sig is None:
            continue
        is_buy = sig['direction'] == 'BUY'
        outcome, r_mult, exit_bar = 'OPEN', 0.0, n - 1
        for j in range(i + 1, n):
            bar = c15[j]
            hit_sl = bar['low'] <= sig['sl'] if is_buy else bar['high'] >= sig['sl']
            hit_tp = bar['high'] >= sig['tp'] if is_buy else bar['low'] <= sig['tp']
            if hit_sl:
                outcome, r_mult, exit_bar = 'SL', -1.0, j
                break
            if hit_tp:
                outcome = 'TP'
                r_mult = abs(sig['tp'] - sig['entry']) / abs(sig['sl'] - sig['entry'])
                exit_bar = j
                break
        trades.append({**sig, 'outcome': outcome, 'r': r_mult, 'exitBar': exit_bar,
                       'isBuy': is_buy})
        open_until = exit_bar if outcome != 'OPEN' else n
        last_signal_bar = i
        if len(trades) >= max_trades:
            break
    return trades


def summarise(trades, cost_r=0.0):
    closed = [t for t in trades if t['outcome'] != 'OPEN']
    wins = [t for t in closed if t['outcome'] == 'TP']
    total = sum((t['r'] if t['outcome'] == 'TP' else -1.0) - cost_r for t in closed)
    buys = sum(1 for t in trades if t['direction'] == 'BUY')
    return {'trades': len(trades), 'closed': len(closed),
            'open': len(trades) - len(closed), 'wins': len(wins),
            'losses': len(closed) - len(wins),
            'winRate': len(wins) / len(closed) * 100 if closed else 0.0,
            'totalR': total, 'avgR': total / len(closed) if closed else 0.0,
            'buys': buys, 'sells': len(trades) - buys}
