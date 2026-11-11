import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'gemini.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: K.bg,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const MyApp());
}

/// App-wide colours (GitHub dark palette).
/// Shown in the status panel so an old APK can be recognised on sight.
const String kBuild = 'v19.1 · 3M scanner, no trade plan';

/// App version reported in the UI so an installed build is identifiable.
///
/// MUST stay equal to `version:` in pubspec.yaml. It was a second, hand-kept
/// copy of the same fact and nothing checked the two agreed, so v17.1.0 shipped
/// an APK named `...-17.0.0-20.apk` while the code was `17.1.0+21`. The release
/// workflow now reads pubspec.yaml directly and `test_stamps` fails the build
/// if this line drifts again.
const String kVersionName = '19.1.0+33';


/// How the three timeframes are stacked.
///
/// [swing] is the original: 4H bias, 1H zones, 15M trigger.
/// [scalp] keeps every rule, score and gate identical and only swaps the
/// horizons -- 30M bias, 15M zones, 5M trigger. 10M was requested but no spot
/// exchange publishes a 10-minute candle (Binance/Bybit/OKX offer 3/15/30;
/// MEXC does not even offer 3M), so 5M stands in as the trigger.
enum TradeMode {
  swing,
  scalp,
  single3m,
  scalp3m;

  /// Timeframe that provides the bias.
  String get biasTf {
    if (this == TradeMode.swing) return '4H';
    if (this == TradeMode.scalp) return '30M';
    return '3M';
  }

  /// Timeframe that provides the order blocks, FVGs and premium/discount.
  String get zoneTf {
    if (this == TradeMode.swing) return '1H';
    if (this == TradeMode.scalp) return '15M';
    return '3M';
  }

  /// Timeframe that provides the live break trigger.
  String get triggerTf {
    if (this == TradeMode.swing) return '15M';
    if (this == TradeMode.scalp) return '5M';
    return '3M';
  }

  String get label {
    if (this == TradeMode.swing) return 'Swing';
    if (this == TradeMode.scalp) return 'Scalp';
    // The 3M rule is BOS + MACD on 3M bars only. "S" was the old scalp rule
    // set's suffix; keeping it would suggest the rule this build deleted is
    // still what runs.
    return this == TradeMode.single3m ? '3M' : '3M BOS';
  }

  /// True for the dedicated 3-minute scalping rules.
  ///
  /// This is NOT the same thing as [single3m]. `single3m` runs the swing engine
  /// with the 3M series fed into all three slots, which double counts one
  /// structure break as bias, zone and trigger. `scalp3m` uses its own rule
  /// set (`Engine.scalp3m`) built from three independent readings, and it
  /// lives and dies by one measured number: the ATR% gate.
  bool get isScalp3m => this == TradeMode.scalp3m;

  /// True when all three slots read the SAME series.
  ///
  /// This matters for honesty, not for scoring: with one series, "bias",
  /// "zone" and "trigger" are three readings of the same candles, so one
  /// structure break can contribute +30 and +25 and +20 at once. The score is
  /// still built from the same weights, but agreement between horizons -- the
  /// thing a multi-timeframe stack actually buys -- is absent by construction.
  /// The UI says so instead of letting the number imply otherwise.
  bool get isSingleTimeframe => biasTf == zoneTf && zoneTf == triggerTf;
}

/// Smallest stop, as a fraction of price, that is worth taking.
///
/// Measured, not chosen by taste. On the scalp stack (30M/15M/5M) with a 0.25%
/// round trip, 23 of 1323 trades carried a stop under 0.5%; those 23 were
/// worth **-74.7R net between them**, and one had a 0.075% stop, where the fee
/// alone is 3.35R. Refusing them moves net from -53.1R to +21.6R on the same
/// trade list.
///
/// Device evidence that started this: SOL at 0.374% and BCH at 0.351%, both
/// STRICT SELL 90%, both showing a +0.75% target that the fee eats a third of.
///
/// Swing is unaffected -- no swing trade in the sample had a stop under 1%
/// (the 1H zone plus 0.25 x ATR200 never gets that tight).
const double kMinStopPct = 0.005;

/// Minimum reward:risk a trade must be able to offer. The structure target
/// (15M swing) is accepted only at or above this; otherwise the target falls
/// back to 2R. Measured reason: a live SOL SELL shipped with risk 3.5% and
/// reward 0.98% (RR 1:0.28) because the old check only asked whether the swing
/// sat beyond entry.
const double kMinRR = 1.5;

/// How recent a 3M BOS must be to count as "recently hoya".
///
/// Measured: 3 bars (9 minutes) was the tightest window that still produced a
/// tradeable sample, and every wider window (up to 60 bars / 3 hours) lost
/// more, because a stale break is no longer the break you are trading.
const int bos5mLookback = 5;

/// 3M rule reward:risk (mirrors Engine.scalp3mRR).
const double kScalp3mRR = 3.0;

/// Coins priced above this are shown BELOW everything else, not excluded.
///
/// The user asked for expensive coins to appear "akdom niche" (at the very
/// bottom) -- a display rule. Excluding them would silently shrink the list,
/// which is the class of bug this project has spent several versions removing.
const double kScalp3mMaxPrice = 2.0;

/// Round-trip fee + spread assumption used only by the backtest report, in
/// percent of entry. 0.25% is roughly Binance spot taker (0.1% x 2) plus a
/// small spread on a liquid pair; illiquid alts are worse, which is why the
/// report prints the number instead of hiding it.
const double kCostPct = 0.25;

class K {
  static const Color bg = Color(0xFF0D1117);
  static const Color panel = Color(0xFF161B22);
  static const Color panel2 = Color(0xFF21262D);
  static const Color line = Color(0xFF30363D);
  static const Color green = Color(0xFF3FB950);
  static const Color red = Color(0xFFF85149);
  static const Color orange = Color(0xFFD29922);
  static const Color blue = Color(0xFF58A6FF);
  static const Color text = Color(0xFFE6EDF3);
  static const Color muted = Color(0xFF8B949E);
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Money Trader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.green,
        scaffoldBackgroundColor: K.bg,
        appBarTheme: const AppBarTheme(
          backgroundColor: K.panel,
          elevation: 0,
          centerTitle: false,
        ),
        fontFamily: 'Roboto',
      ),
      home: const HomeScreen(),
    );
  }
}

// =====================================================================
// MODELS
// =====================================================================

class Candle {
  Candle({
    required this.openTime,
    required this.closeTime,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  final int openTime;
  final int closeTime;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;

  factory Candle.fromJson(List<dynamic> j) => Candle(
        openTime: (j[0] as num).toInt(),
        open: double.parse(j[1].toString()),
        high: double.parse(j[2].toString()),
        low: double.parse(j[3].toString()),
        close: double.parse(j[4].toString()),
        volume: double.parse(j[5].toString()),
        closeTime: (j[6] as num).toInt(),
      );

  bool get isBullish => close > open;
  bool get isBearish => close < open;
  double get bodySize => (close - open).abs();
  double get range => high - low;
}

class CoinData {
  CoinData({
    required this.symbol,
    required this.lastPrice,
    required this.priceChangePercent,
    required this.highPrice,
    required this.lowPrice,
    required this.quoteVolume,
  });

  final String symbol;
  final double lastPrice;
  final double priceChangePercent;
  final double highPrice;
  final double lowPrice;
  final double quoteVolume;

  factory CoinData.fromJson(Map<String, dynamic> j) => CoinData(
        symbol: j['symbol'].toString(),
        lastPrice: double.parse(j['lastPrice'].toString()),
        priceChangePercent: double.parse(j['priceChangePercent'].toString()),
        highPrice: double.parse(j['highPrice'].toString()),
        lowPrice: double.parse(j['lowPrice'].toString()),
        quoteVolume: double.parse(j['quoteVolume'].toString()),
      );

  String get coin => symbol.replaceAll('USDT', '');
}

class OrderBlock {
  OrderBlock({
    required this.high,
    required this.low,
    required this.type,
    required this.index,
  });

  final double high;
  final double low;
  final String type; // 'bullish' | 'bearish'
  final int index;

  double get mid => (high + low) / 2;
}

class FVG {
  FVG({
    required this.high,
    required this.low,
    required this.type,
    required this.index,
  });

  final double high;
  final double low;
  final String type; // 'bullish' | 'bearish'
  final int index;

  double get mid => (high + low) / 2;
}

class SwingPoint {
  SwingPoint({required this.price, required this.index, required this.type});

  final double price;
  final int index;
  final String type; // 'high' | 'low'
}

/// One confirmed structure break (BOS / CHoCH) at [bar].
class StructureBreak {
  StructureBreak({
    required this.event,
    required this.bar,
    required this.pivot,
    required this.pattern,
  });

  final String event; // 'BULLISH' | 'BEARISH'
  final int bar;
  final SwingPoint pivot;
  final String pattern; // 'BOS' | 'CHoCH'
}

class TFAnalysis {
  TFAnalysis({
    required this.timeframe,
    required this.structure,
    required this.volumeSpike,
    required this.obs,
    required this.fvgs,
    required this.candles,
    required this.close,
    required this.atr,
    required this.trend,
    required this.swingHigh,
    required this.swingLow,
    required this.premium,
    required this.equilibrium,
    required this.discount,
    required this.eqh,
    required this.eql,
    required this.freshBreak,
    required this.breakPattern,
    required this.breakEvent,
    required this.internalFresh,
    required this.internalEvent,
    required this.breakLevel,
    required this.breakAge,
    required this.structureConflict,
  });

  final String timeframe;
  final String structure;
  final bool volumeSpike;
  final List<OrderBlock> obs;
  final List<FVG> fvgs;
  final List<Candle> candles;
  final double close;
  final double atr;

  /// 1 = bullish, -1 = bearish, 0 = unknown. Swing (not internal) trend.
  final int trend;

  /// Most recent confirmed swing high / low and its bar index.
  final SwingPoint? swingHigh;
  final SwingPoint? swingLow;

  /// Premium / equilibrium / discount bounds of the current swing range.
  final double premium;
  final double equilibrium;
  final double discount;

  /// Equal highs / equal lows (liquidity pools) with their price.
  final bool eqh;
  final bool eql;

  /// Break of structure happened within the last two bars.
  final bool freshBreak;
  final String breakPattern; // 'BOS' | 'CHoCH' | ''
  final String breakEvent; // 'BULLISH' | 'BEARISH' | ''

  /// Same, for the 5-bar internal structure.
  final bool internalFresh;
  final String internalEvent;

  /// Pivot price of the freshest swing break; price holding beyond it keeps
  /// the 15M trigger alive.
  final double breakLevel;

  /// Bars since that break (0 = the last closed bar).
  final int breakAge;

  /// True when the long-window scan inverted the local bias (possible trend
  /// exhaustion) — used as a warning, never to open a trade.
  final bool structureConflict;

  String get zoneOf {
    if (premium <= 0) return 'Unknown';
    if (swingHigh != null && close > swingHigh!.price) return 'Breakout';
    if (swingLow != null && close < swingLow!.price) return 'Breakdown';
    if (close > premium) return 'Premium';
    if (close < discount) return 'Discount';
    return 'Equilibrium';
  }
}

class TradeSignal {
  TradeSignal({
    required this.symbol,
    required this.direction,
    required this.price,
    required this.entry,
    required this.sl,
    required this.tp,
    required this.confidence,
    required this.confirmations,
    required this.time,
    required this.tf4h,
    required this.tf1h,
    required this.tf15m,
    required this.pattern,
    required this.zone,
    required this.eqh,
    required this.eql,
    required this.watch,
    required this.tier,
    this.thinVolume,
    this.bos5 = false,
    this.macdGreen = false,
    this.mode = TradeMode.swing,
    this.chop = 0,
  });

  final String symbol;
  final String direction; // 'BUY' | 'SELL'
  final double price; // price when the signal was produced
  final double entry;
  final double sl;
  final double tp;
  final double confidence;
  final List<String> confirmations;
  final DateTime time;
  final String tf4h;
  final String tf1h;
  final String tf15m;

  /// 'BOS' or 'CHoCH' — CHoCH is a reversal, BOS is a continuation.
  final String pattern;

  /// Where price sat inside the swing range when the signal fired.
  final String zone;

  /// Liquidity pools the engine saw (equal highs / equal lows).
  final bool eqh;
  final bool eql;

  /// True when only the relaxed (lower-conviction) pass produced this signal.
  final bool watch;

  /// True when the pair is in the quiet tier (below 5M USDT/day). The setup may
  /// be genuine, but a thin book means the entry and the stop can both slip by
  /// more than the edge. Such a signal is never printed as STRICT.
  final bool thinVolume;

  /// The two 3M facts this mode scores. Optional so no other mode has to know
  /// about them; the 3M scanner always sets both.
  final bool bos5;
  final bool macdGreen;

  /// Which horizon stack produced this signal, so the card labels the rows with
  /// the timeframes actually used (4H/1H/15M or 30M/15M/5M).
  final TradeMode mode;

  /// How much this coin actually moves per bar on the trigger timeframe,
  /// as ATR(14) over the last 14 bars expressed in percent of price.
  ///
  /// This is the only honest answer to "which coins are moving": a 3M signal on
  /// a coin that moves 0.15% a bar is not the same trade as one that moves
  /// 0.9% a bar, even when both score 70. It is measured from the same candles
  /// the decision used, so it cannot disagree with the signal.
  final double chop;

  /// True when this coin is in the bottom of the movement range -- shown, but
  /// sorted to the bottom so the busy coins come first.
  bool get isQuiet => chop < 0.30;

  /// 'STRICT' (full confluence), 'WATCH' (relaxed trigger/threshold) or
  /// 'RADAR' (bias and trigger present, zone or score still missing). RADAR is
  /// explicitly a candidate list, never a trade instruction.
  final String tier;

  bool get isRadar => tier == 'RADAR';

  /// Same setup, on a thin book: never STRICT. RADAR stays RADAR (it is already
  /// not a trade instruction); everything else becomes WATCH and is flagged so
  /// the card can say why.
  TradeSignal asThin() {
    if (thinVolume) return this;
    return TradeSignal(
      symbol: symbol,
      direction: direction,
      price: price,
      entry: entry,
      sl: sl,
      tp: tp,
      // A card the engine refused to call STRICT must not wear a number that
      // clears the STRICT gate. Device (v17.2): AAPLB read "75% WATCH" -- 15
      // points above the 60 gate -- because a STRICT 75 was demoted to WATCH
      // for a thin book and the score came along unchanged. v16 clamped the
      // relaxed path for exactly this reason; the thin path was missed.
      confidence: confidence > 59 ? 59 : confidence,
      confirmations: confirmations,
      time: time,
      tf4h: tf4h,
      tf1h: tf1h,
      tf15m: tf15m,
      pattern: pattern,
      zone: zone,
      eqh: eqh,
      eql: eql,
      watch: true,
      tier: tier == 'RADAR' ? 'RADAR' : 'WATCH',
      thinVolume: true,
      mode: mode,
      chop: chop,
    );
  }

  bool get isBuy => direction == 'BUY';

  double get profitPct => isBuy
      ? ((tp - entry) / entry) * 100
      : ((entry - tp) / entry) * 100;

  double get riskPct =>
      isBuy ? ((entry - sl) / entry) * 100 : ((sl - entry) / entry) * 100;

  double get rr => riskPct <= 0 ? 0 : profitPct / riskPct;

  String get coin => symbol.replaceAll('USDT', '');
}

// =====================================================================
// MARKET DATA  (Binance -> Bybit -> OKX -> MEXC fallback)
// =====================================================================

/// One exchange endpoint that can supply tickers and candles.
class _Feed {
  const _Feed(this.name, this.kind);

  final String name;
  final String kind; // 'binance' | 'bybit' | 'okx' | 'mexc'
}

class MarketData {
  static const List<_Feed> _feeds = <_Feed>[
    _Feed('Binance', 'binance'),
    _Feed('Bybit', 'bybit'),
    _Feed('OKX', 'okx'),
    _Feed('MEXC', 'mexc'),
  ];

  /// Feed name that produced the last successful scan (shown in the UI).
  static String activeFeed = '';

  /// Raw ticker rows the feed returned and how many survived `_isTradable`,
  /// so a small universe (e.g. 35 coins instead of 300) can be explained
  /// instead of looking like a broken scanner.
  static int lastRawTickers = 0;
  static int lastTradable = 0;
  static int lastPicked = 0;

  /// Feed each funnel number belongs to. A failed Binance attempt followed by a
  /// working OKX scan used to leave Binance's raw count on screen next to OKX's
  /// coin list.
  static String lastFunnelFeed = '';

  /// How many of `lastTradable` cleared the preferred 5M USDT/day floor. The
  /// difference is the quiet tier the universe was topped up from.
  static int lastStrong = 0;

  /// The listed pool *before* the 300 cap, and how many of those were strong.
  /// Without these the funnel can only ever print "300 listed", which says
  /// nothing about whether the exchange or our filter decided the universe.
  static int lastListed = 0;
  static int lastStrongPool = 0;

  /// Rows the feed returned for symbols it no longer trades (delisted /
  /// halted). Proves on screen that the exchange did send junk.
  static int lastDeadSymbols = 0;

  /// Cleared at the start of every scan so a stale number can never be read as
  /// this scan's result.
  static void resetFunnel() {
    lastRawTickers = 0;
    lastTradable = 0;
    lastPicked = 0;
    lastFunnelFeed = '';
    lastStrong = 0;
    lastListed = 0;
    lastStrongPool = 0;
    lastDeadSymbols = 0;
  }

  /// Feeds that just failed are skipped for a few minutes so a blocked
  /// exchange cannot add 15s of timeout to every one of the ~300 requests.
  static final Map<String, DateTime> _downUntil = <String, DateTime>{};

  static bool _isDown(_Feed f) {
    final until = _downUntil[f.name];
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _downUntil.remove(f.name);
      return false;
    }
    return true;
  }

  static void _markDown(_Feed f) {
    _downUntil[f.name] = DateTime.now().add(const Duration(minutes: 2));
  }

  static void _markUp(_Feed f) {
    _downUntil.remove(f.name);
  }

  /// Pairs that just failed to produce candles, and until when to skip them.
  ///
  /// One dead symbol costs five mirror attempts plus feed fallbacks. With 100
  /// coins that is tolerable; with 300 the same coin is retried on every scan
  /// forever. A pair that fails is left alone for a few scans, then retried
  /// once — so a genuinely relisted pair is not lost, and a dead one does not
  /// tax every scan.
  static final Map<String, DateTime> _pairDownUntil = <String, DateTime>{};
  static const Duration _pairCooldown = Duration(minutes: 15);

  static bool _pairDown(String sym) {
    final until = _pairDownUntil[sym];
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _pairDownUntil.remove(sym);
      return false;
    }
    return true;
  }

  static void _pairFail(String sym) {
    _pairDownUntil[sym] = DateTime.now().add(_pairCooldown);
    if (_pairDownUntil.length > 400) {
      final cold = _pairDownUntil.keys.first;
      _pairDownUntil.remove(cold);
    }
  }

  static const Duration _lag = Duration(
    milliseconds: 120,
  );

  /// Binance bills klines by `limit`: <=100 -> 1, <=500 -> 2, <=1000 -> 5.
  ///
  /// The spot per-IP budget is **6000 weight per minute** (raised from 1200 on
  /// 2023-08-25); the 1200 figure that still circulates applies to the order
  /// endpoints, not to market data. A 300-coin scan at weight 6/coin is 1800,
  /// so at the old 1200 assumption a fast scan looked 3.2x over budget and any
  /// request that failed took a coin with it.
  ///
  /// Even so the exchange is metered rather than trusted: every klines request
  /// takes a weighted slot from a rolling one-minute window. 4500/min leaves a
  /// real margin under 6000 for the ticker call, retries and mirrors, while
  /// still letting a cold 300-coin scan finish in about 30 seconds of budget
  /// instead of being paced to two minutes.
  static const int _weightPerMinute = 4500;
  static final List<MapEntry<DateTime, int>> _weightLog =
      <MapEntry<DateTime, int>>[];
  static Future<void>? _weightGate;

  /// Weight a klines request of `lim` bars costs on Binance.
  static int klinesWeight(int lim) {
    if (lim <= 100) return 1;
    if (lim <= 500) return 2;
    if (lim <= 1000) return 5;
    return 10;
  }

  /// Wait until `weight` fits inside the rolling one-minute budget.
  ///
  /// Serialised through [_weightGate] so concurrent workers cannot all read
  /// the same free space and overdraw it.
  static Future<void> reserveWeight(int weight) async {
    while (_weightGate != null) {
      await _weightGate;
    }
    final mine = _reserveInner(weight);
    _weightGate = mine;
    try {
      await mine;
    } finally {
      if (identical(_weightGate, mine)) _weightGate = null;
    }
  }

  static Future<void> _reserveInner(int weight) async {
    while (true) {
      final now = DateTime.now();
      _weightLog.removeWhere(
        (e) => now.difference(e.key) > const Duration(minutes: 1),
      );
      var used = 0;
      for (final e in _weightLog) {
        used += e.value;
      }
      if (used + weight <= _weightPerMinute) {
        _weightLog.add(MapEntry<DateTime, int>(now, weight));
        return;
      }
      // Sleep until the oldest entry falls out of the window.
      final oldest = _weightLog.first.key;
      final wait = oldest.add(const Duration(minutes: 1)).difference(now);
      await Future<void>.delayed(
        wait > const Duration(milliseconds: 50)
            ? wait
            : const Duration(milliseconds: 50),
      );
    }
  }

  /// Stablecoins / fiat / leveraged tokens that add no signal value.
  static const Set<String> _skip = <String>{
    'USDCUSDT',
    'FDUSDUSDT',
    'TUSDUSDT',
    'BUSDUSDT',
    'DAIUSDT',
    'USDPUSDT',
    'EURUSDT',
    'GBPUSDT',
    'AEURUSDT',
    'USDEUSDT',
    'PYUSDUSDT',
    'USD1USDT',
    'XUSDUSDT',
  };

  /// Binance's tokenized-stock products (bStocks, listed Oct 2026) are ordinary
  /// spot USDT symbols: exchangeInfo does not flag them, volume is real, and
  /// the delisted check passes. But a tokenized equity is not a crypto pair --
  /// it tracks a share price, gaps on the underlying market's hours, and a 5.8%
  /// structural stop on it is not comparable to one on SOL.
  ///
  /// They use a `B` suffix on the underlying ticker (NVDA -> NVDAB, MDBB,
  /// PENGB, UVXYB, BBB). Matching a suffix alone would be unsafe, so this is an
  /// explicit list, extended as Binance lists more.
  /// EVERY bStock Binance has listed, as of November 2026.
  ///
  /// This list started at 5 and has now been wrong on a device **twice**:
  /// v17.2 ranked Apple (AAPLB, 352.75) as a coin, and v17.3 ranked Strategy
  /// (MSTRB, 123.03) as a STRICT SELL at 90%. Both were genuine spot USDT
  /// pairs with real volume, so nothing in exchangeInfo or /ticker/24hr
  /// distinguishes them -- the name is the only signal.
  ///
  /// Binance adds batches every few weeks (5 at launch -> 44 by Nov 2026), so
  /// this is a snapshot and will go stale again. `test_universe.py` asserts
  /// this exact set, which at least makes the next batch a one-line change
  /// plus a failing test rather than another screenshot.
  static const Set<String> _tokenizedStocks = <String>{
    // 11 June 2026 launch
    'CRCLBUSDT', // Circle
    'MUBUSDT',   // Micron
    'NVDABUSDT', // NVIDIA
    'SNDKBUSDT', // SanDisk
    'TSLABUSDT', // Tesla
    'SPCXBUSDT', // SpaceX (after its Nasdaq debut)
    // 30 June 2026
    'MSFTBUSDT', // Microsoft
    'METABUSDT', // Meta
    'PLTRBUSDT', // Palantir
    'LITEBUSDT', // Lumentum
    'QQQBUSDT',  // Invesco QQQ Trust
    // July 2026
    'AMDBUSDT',   // AMD
    'EWYBUSDT',   // iShares MSCI South Korea ETF
    'INTCBUSDT',  // Intel
    'MSTRBUSDT',  // Strategy (MicroStrategy)
    'COINBUSDT',  // Coinbase
    'GOOGLBUSDT', // Alphabet
    'HOODBUSDT',  // Robinhood
    'IBMBUSDT',   // IBM
    'NOKIABUSDT', // Nokia
    // 29 July 2026
    'AAPLBUSDT',  // Apple
    'AMATBUSDT',  // Applied Materials
    'AMZNBUSDT',  // Amazon
    'BEBUSDT',    // Bloom Energy
    'DELLBUSDT',  // Dell
    'FLNCBUSDT',  // Fluence Energy
    'GSBUSDT',    // Goldman Sachs
    'PYPLBUSDT',  // PayPal
    'SMHBUSDT',   // VanEck Semiconductor ETF
    'SOXSBUSDT',  // Direxion Semiconductor Bear 3x ETF
    // 5 August 2026
    'ALABBUSDT',  // Astera Labs
    'ASMLBUSDT',  // ASML
    'ASTSBUSDT',  // AST SpaceMobile
    'BMNRBUSDT',  // Bitmine Immersion
    'COHRBUSDT',  // Coherent
    'CRDOBUSDT',  // Credo Technology
    'IRENBUSDT',  // IREN
    'NFLXBUSDT',  // Netflix
    'SMCIBUSDT',  // Super Micro Computer
    'USARBUSDT',  // USA Rare Earth
    // 14 October 2026
    'BBBUSDT',   // BlackBerry
    'MDBBUSDT',  // MongoDB
    'PENGBUSDT', // Penguin Solutions
    'UVXYBUSDT', // ProShares Ultra VIX Short-Term Futures ETF
  };

  /// Leveraged tokens end with UP/DOWN/BULL/BEAR/3L/3S *and* the base ticker
  /// they wrap was already listed. A bare suffix rule cannot tell `BTCUP` from
  /// `JUP`: Jupiter's USDT pair is `JUPUSDT`, which ends in `UPUSDT`, so the
  /// filter was silently dropping a real crypto pair from every scan. The fix
  /// is to strip the suffix and only treat it as leveraged when the remaining
  /// base is a listed symbol -- `BTC` exists, `J` does not.
  static const List<String> _leveragedSuffixes = <String>[
    'UPUSDT',
    'DOWNUSDT',
    'BULLUSDT',
    'BEARUSDT',
    '3LUSDT',
    '3SUSDT',
  ];

  /// The symbols the exchange reports as TRADING, filled by
  /// [_binanceLiveSymbols] and used to tell a leveraged token from a real
  /// ticker that happens to end in the same letters.
  static Set<String> _liveSymbols = <String>{};

  /// True when [symbol] is a leveraged token wrapper rather than a real pair.
  ///
  /// A bare suffix test is wrong: `JUPUSDT` (Jupiter) ends in `UPUSDT` and was
  /// silently dropped from every scan. A wrapper is only a wrapper when the
  /// base it wraps is itself a listed pair -- `BTCUP` wraps `BTC`, `JUP` does
  /// not wrap `J`. When the live set is unavailable the old conservative rule
  /// is kept, so a failed exchangeInfo call cannot flood the list.
  static bool _isLeveraged(String symbol) {
    for (final suffix in _leveragedSuffixes) {
      if (!symbol.endsWith(suffix)) continue;
      if (_liveSymbols.isEmpty) return true;
      // "JUPUSDT" - "UPUSDT" keeps "J";   "BTCUPUSDT" - "UPUSDT" keeps "BTC".
      final base = symbol.substring(0, symbol.length - suffix.length);
      return _liveSymbols.contains('${base}USDT');
    }
    return false;
  }

  static String baseOf(String symbol) => symbol.replaceAll('USDT', '');

  /// A pair may be *shaped* like a tradable USDT market. Volume is judged
  /// separately, in two tiers, so a quiet market cannot silently shrink the
  /// universe to a third of what the exchange offers.
  static bool _isListed(CoinData c) {
    if (!c.symbol.endsWith('USDT')) return false;
    if (c.symbol == 'USDTUSDT') return false;
    if (_skip.contains(c.symbol)) return false;
    if (_tokenizedStocks.contains(c.symbol)) return false;
    if (_isLeveraged(c.symbol)) return false;
    return c.lastPrice > 0;
  }

  /// Daily quote volume a pair needs to be preferred. Pairs below it are still
  /// usable: see [selectUniverse].
  static const double _preferredVolume = 5000000;

  /// How many coins a scan analyses. Binance lists ~400-500 USDT pairs and
  /// ~150-200 of those clear 5M USDT/day, so 400 is the largest number that can
  /// be filled honestly without reaching deep into the quiet tail.
  ///
  /// Cost at 400: weight 6/coin cold (2400 total), 4/coin warm. Measured
  /// against the 4500/min meter: ~90 s cold, ~60 s warm, inside the 5-minute
  /// refresh slot.
  static const int scanTarget = 400;

  /// Public alias so the scan loop can tell a thin book from a liquid one
  /// without duplicating the threshold.
  static double get preferredVolume => _preferredVolume;

  /// Two tiers, because the old hard 5M floor was the whole story behind
  /// "35 coins" on a 300-coin scan:
  ///
  ///  * tier 1 — every listed USDT pair above 5M USDT/day. Preferred, because
  ///    a 15M setup on a pair that trades $200k/day cannot be filled at the
  ///    shown price.
  ///  * tier 2 — the rest of the listed pairs, highest volume first. Only used
  ///    to reach [target] when tier 1 is short.
  ///
  /// The engine never sees a different candle or rule; it simply gets a full
  /// universe instead of a filtered remnant. A pair that fails to fetch its
  /// candles is still dropped by the caller.
  static List<CoinData> selectUniverse(List<CoinData> all, int target) {
    final listed = all.where(_isListed).toList();
    final strong = listed.where((c) => c.quoteVolume > _preferredVolume).toList();
    if (strong.length >= target) return strong;
    final weak = listed
        .where((c) => c.quoteVolume <= _preferredVolume)
        .toList()
      ..sort((a, b) => b.quoteVolume.compareTo(a.quoteVolume));
    final out = <CoinData>[...strong];
    final seen = strong.map((c) => c.symbol).toSet();
    for (final c in weak) {
      if (out.length >= target) break;
      if (seen.add(c.symbol)) out.add(c);
    }
    return out;
  }

  /// Coins with the widest 24h range, for the 3-minute stack.
  ///
  /// The 3M mode asks a different question from swing: not "what moved today",
  /// but "what is moving enough that a 3-minute hold can pay a 0.25% round
  /// trip". The 24h high-low range is the only movement figure the ticker
  /// carries, and it is the right one here -- a coin that closed flat but
  /// swung 8% inside the day is exactly the coin a 3M trader can work, while a
  /// coin that drifted up 6% in one smooth line is not.
  ///
  /// Selection only. The engine still applies every rule unchanged, and any
  /// coin that fails the 0.5% stop floor is refused there, not here.
  static List<CoinData> _pickVolatile(
      List<CoinData> all, int target) {
    final scored = all
        .map((c) => MapEntry(
            c,
            c.highPrice > 0 && c.lowPrice > 0
                ? (c.highPrice - c.lowPrice) / c.highPrice * 100
                : 0.0))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return scored.take(target).map((e) => e.key).toList();
  }

  /// Top gainers + top losers so both BUY and SELL setups can appear.
  ///
  /// Binance is geo-blocked in many regions; if every mirror fails we walk
  /// the other feeds, because each one exposes the same USDT pairs.
  static Future<List<CoinData>> marketScan({
    int gainers = scanTarget ~/ 2,
    int losers = scanTarget ~/ 2,
    bool byVolatility = false,
  }) async {
    var errors = <String>[];

    final attempt = await _scanOnce(gainers, losers, errors,
        byVolatility: byVolatility);
    if (attempt.isNotEmpty) return attempt;

    // Every feed is still cooling down after a failed scan (the skip window).
    // skip window). Waiting is free here: the scan itself takes minutes.
    if (_feeds.every(_isDown)) {
      await Future<void>.delayed(const Duration(seconds: 20));
      errors = <String>[];
      final retry = await _scanOnce(gainers, losers, errors,
          byVolatility: byVolatility);
      if (retry.isNotEmpty) return retry;
    }

    activeFeed = '';
    throw MarketDataException(errors.isEmpty ? 'no feed' : errors.join(' | '));
  }

  static Future<List<CoinData>> _scanOnce(
    int gainers,
    int losers,
    List<String> errors, {
    bool byVolatility = false,
  }) async {
    for (final feed in _feeds) {
      if (_isDown(feed)) {
        errors.add('${feed.name}: skipped (recently failed)');
        continue;
      }
      try {
        final all = await _tickers(feed);
        // The 5M USDT floor used to be applied inside the feed parser, which
        // is why a "300 coin" scan could only ever analyse ~36. Now the floor
        // is a *preference*: strong pairs first, quiet ones only to fill the
        // requested 300.
        final wanted = gainers + losers;
        // Measure the pool BEFORE capping it, otherwise the screen reports
        // "300 listed" every single time and hides whether the exchange sent
        // 450 pairs or 80.
        lastListed = all.length;
        lastStrongPool =
            all.where((c) => c.quoteVolume > _preferredVolume).length;
        final universe = selectUniverse(all, wanted);
        // A 3M scan is a movement question, not a movers question: rank by the
        // 24h range so the coins with something to trade are the ones fetched.
        final picked = byVolatility
            ? _pickVolatile(universe, wanted)
            : _pick(universe, gainers, losers);
        lastTradable = universe.length;
        lastPicked = picked.length;
        lastFunnelFeed = feed.name;
        lastStrong = universe.where((c) => c.quoteVolume > _preferredVolume).length;
        if (picked.isEmpty) {
          errors.add('${feed.name}: empty');
          _markDown(feed);
          continue;
        }
        _markUp(feed);
        activeFeed = feed.name;
        return picked;
      } catch (e) {
        _markDown(feed);
        errors.add('${feed.name}: ${_short(e)}');
      }
      await Future<void>.delayed(_lag);
    }
    return <CoinData>[];
  }

  static List<CoinData> _pick(List<CoinData> all, int gainers, int losers) {
    if (all.isEmpty) return <CoinData>[];

    final gain = all.where((c) => c.priceChangePercent > 0).toList()
      ..sort((a, b) => b.priceChangePercent.compareTo(a.priceChangePercent));
    final lose = all.where((c) => c.priceChangePercent < 0).toList()
      ..sort((a, b) => a.priceChangePercent.compareTo(b.priceChangePercent));

    final out = <CoinData>[];
    final seen = <String>{};
    for (final c in gain.take(gainers)) {
      if (seen.add(c.symbol)) out.add(c);
    }
    for (final c in lose.take(losers)) {
      if (seen.add(c.symbol)) out.add(c);
    }
    // A quiet day can leave fewer than `gainers` coins on the green side, which
    // silently returns e.g. 292 of an intended 300. Fill the shortfall from the
    // remaining movers (highest absolute move first) so the request is honoured.
    final want = gainers + losers;
    if (out.length < want) {
      final rest = all
          .where((c) => !seen.contains(c.symbol))
          .toList()
        ..sort((a, b) =>
            b.priceChangePercent.abs().compareTo(a.priceChangePercent.abs()));
      for (final c in rest) {
        if (out.length >= want) break;
        if (seen.add(c.symbol)) out.add(c);
      }
    }
    return out;
  }

  /// Closed 4H candles, kept between scans.
  ///
  /// A 4H bar cannot change once it has closed, so refetching 600 bars for
  /// every coin on every five minute scan is pure waste — and at 300 coins
  /// that waste is two thirds of the network traffic. Only the *closed* bars
  /// are cached (at most until the current 4H bar ends plus a margin); the bar
  /// that is still forming is rebuilt from the fresh 15M series, so the list
  /// handed to the engine is what Binance itself would have returned — windows,
  /// scoring and tiers are untouched. The first scan is cold, the rest reuse.
  static final Map<String, List<Candle>> _cache4h = <String, List<Candle>>{};
  static final Map<String, DateTime> _cache4hAt = <String, DateTime>{};
  /// Enough for a full 400-coin universe plus a margin. At 320 the cache
  /// evicted the coldest 4H series on a wide scan, so the second scan
  /// refetched them and the hit counter never warmed up; a cache smaller than
  /// the universe can never reach a useful hit rate by construction.
  static const int _cache4hMax = 460;
  /// Expire a little *early* rather than late: a 4H series that is one bar
  /// short has a hole in it, while refetching a minute too soon costs nothing.
  static const Duration _cacheEarlyExpiry = Duration(minutes: 1);
  static int cacheHits = 0;
  static int cacheMisses = 0;

  /// Counters are per scan; the status line shows them so a device build can
  /// prove the cache is doing its job instead of being silently cold.
  static void resetCacheStats() {
    cacheHits = 0;
    cacheMisses = 0;
  }

  static int get cached4h => _cache4h.length;

  static const int _ms4h = 4 * 60 * 60 * 1000;

  /// Bar span of a timeframe the cache is asked about.
  ///
  /// The cache was written when 4H was the only bias series, and every horizon
  /// and boundary in it was a hard-coded `_ms4h`. In scalp mode the bias is
  /// 30M, so `candles()` never took the cache branch at all and every scan
  /// refetched 400 x 400 30M bars -- the cache was silently dead in the one
  /// mode that needs it most (a scalp scan is the slowest one).
  static int _msSpan(String tf) {
    switch (tf) {
      case '5m':
        return 5 * 60 * 1000;
      case '15m':
        return 15 * 60 * 1000;
      case '30m':
        return 30 * 60 * 1000;
      case '1h':
        return 60 * 60 * 1000;
      case '4h':
      default:
        return _ms4h;
    }
  }

  /// True while no 4H bar has closed since the cache was written.
  ///
  /// The cache holds closed bars only, so the bar that was forming at fetch
  /// time is missing from it. That gap is harmless until the forming bar
  /// itself closes — at that moment the cache would be one bar short and has
  /// to be refetched. So the horizon is exactly: last closed bar + 2 x 4H.
  /// Cache key. The series differ per timeframe, so a symbol alone is not a
  /// key: switching to scalp mode writes 30M bars under the same symbol and
  /// would poison the 4H entries (and be poisoned by them).
  static String _cacheKey(String sym, String tf) => '$tf|$sym';

  /// A timeframe whose closed bars cannot change and whose forming bar can be
  /// rebuilt from the trigger series. Both bias timeframes qualify; the trigger
  /// and zone series are fetched fresh because their forming bar is the signal.
  static bool _isCacheable(String tf) => tf == '4h' || tf == '30m';

  static bool _cache4hFresh(String key) {
    final closedBar = _cache4h[key];
    if (closedBar == null || closedBar.isEmpty) return false;
    if (_cache4hAt[key] == null) return false;
    // The horizon is the cached series' own bar span, not 4H: a 30M bias cache
    // is one bar short as soon as its forming 30M bar closes, which is 30
    // minutes, not 4 hours.
    final span = _msSpan(key.split('|').first);
    final horizon = DateTime.fromMillisecondsSinceEpoch(
      closedBar.last.openTime + 2 * span,
    );
    return DateTime.now().isBefore(horizon.subtract(_cacheEarlyExpiry));
  }

  static List<Candle> _cache4hPut(String key, List<Candle> closed) {
    _cache4h.remove(key);
    _cache4h[key] = closed;
    _cache4hAt[key] = DateTime.now();
    // Dart maps keep insertion order, so the first key is the coldest.
    while (_cache4h.length > _cache4hMax) {
      final cold = _cache4h.keys.first;
      _cache4h.remove(cold);
      _cache4hAt.remove(cold);
    }
    return closed;
  }

  /// Merge cached closed 4H bars with the bar that is still forming in [c15].
  /// Only the tail is rebuilt, and only from data newer than the last closed
  /// 4H bar; every closed bar is passed through untouched.
  static List<Candle> _merge4h(
      List<Candle> closed, List<Candle> c15, int lim, int span) {
    final bars = <Candle>[];
    if (closed.isNotEmpty) {
      final lastClosedOpen = closed.last.openTime;
      // The next bar opens exactly one span after the closed one. The trigger
      // series divides the bias series evenly in both modes (16 x 15M in 4H,
      // 6 x 5M in 30M), so bucketing by openTime is exact either way.
      final boundary = lastClosedOpen + span;
      final keep = closed.length > lim - 1 ? lim - 1 : closed.length;
      bars.addAll(closed.sublist(closed.length - keep));
      final tailBars = c15.where((k) => k.openTime >= boundary).toList();
      if (tailBars.isNotEmpty) {
        double hi = tailBars.first.high;
        double lo = tailBars.first.low;
        double vol = 0;
        for (final k in tailBars) {
          if (k.high > hi) hi = k.high;
          if (k.low < lo) lo = k.low;
          vol += k.volume;
        }
        bars.add(Candle(
          openTime: boundary,
          closeTime: boundary + span - 1,
          open: tailBars.first.open,
          high: hi,
          low: lo,
          close: tailBars.last.close,
          volume: vol,
        ));
      }
    }
    return bars;
  }

  /// [liveFrom] is the freshly fetched 15M series of the same coin. It is how
  /// the 4H cache rebuilds the bar that is still forming without a second
  /// request. Callers that cannot supply it get a fresh 4H series (the cache is
  /// an optimisation, never a different answer).
  static Future<List<Candle>> candles(
    String sym,
    String tf,
    int lim, {
    List<Candle>? liveFrom,
    bool scan = false,
  }) async {
    // Deep history (backtest) is an explicit user action for one coin: never
    // served from the scan cache and never blocked by a scan cooldown.
    final deep = lim > 1000;
    if (!deep && _pairDown(sym)) throw MarketDataException('candles $sym');
    if (deep) return _fetchCandles(sym, tf, lim);

    // Cache any bias series that is fetched with a fresh trigger series behind
    // it. Only the bias call passes liveFrom, so this is exactly that call.
    if (liveFrom != null && _isCacheable(tf)) {
      final key = _cacheKey(sym, tf);
      final span = _msSpan(tf);
      final closed = _cache4h[key];
      if (closed != null && _cache4hFresh(key)) {
        final merged = _merge4h(closed, liveFrom, lim, span);
        // The cache holds only CLOSED bars, so it is by construction one bar
        // short of what the exchange returns. Demanding >= lim here made every
        // single scan a miss (device: "4H cache 0/0+36"), which refetched
        // 36 x 600 bars every five minutes. A cache that can still satisfy the
        // engine's window is a hit.
        if (merged.length >= lim - 1) {
          cacheHits++;
          return merged;
        }
      }
      cacheMisses++;
      final fresh = await _fetchCandles(sym, tf, lim, lockedToScanFeed: scan);
      if (fresh.length >= lim) {
        // Keep every bar except the one that is still forming; that one is
        // rebuilt from fresh 15M data, so nothing served from here is stale.
        _cache4hPut(key, fresh.sublist(0, fresh.length - 1));
      }
      return fresh;
    }
    return _fetchCandles(sym, tf, lim, lockedToScanFeed: scan);
  }

  /// A live 15M series must have a bar that closed recently. A delisted pair
  /// (GALUSDT on Binance spot) still answers /klines — with bars from the day
  /// it was delisted. The engine cannot tell the difference: five confirmations
  /// computed on year-old candles look exactly like five on today's. So the
  /// scan rejects any series whose newest bar is older than this.
  static const Duration _maxBarAge = Duration(hours: 6);

  /// True when [c] is a live series for [tf]: the newest bar must end within
  /// [_maxBarAge]. 4H is given a whole bar plus slack because the bar that is
  /// still forming is expected to be missing from the cache.
  static bool isLive(List<Candle> c, String tf) {
    if (c.isEmpty) return false;
    final newestEnd = c.last.closeTime;
    final age = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(newestEnd));
    final slack = tf == '4h' ? const Duration(hours: 10) : _maxBarAge;
    return age < slack;
  }

  static Future<List<Candle>> _fetchCandles(
    String sym,
    String tf,
    int lim, {
    bool lockedToScanFeed = false,
  }) async {
    // Deep history: Binance can page it, the other feeds cannot.
    if (lim > 1000) {
      try {
        final deep = await _binancePaged(sym, tf, lim);
        if (deep.length >= 400) return deep;
      } catch (_) {}
    }

    // A symbol must be priced by ONE venue. Falling back to OKX candles for a
    // Binance-listed pair means the signal is computed on a different market's
    // price series than the ticker it was ranked from, and the card still says
    // "(Binance)". Cross-venue candles also have different scales: Binance GAL
    // traded at 2.54 while the same ticker elsewhere could be far off.
    //
    // So the scan only accepts candles from the feed that produced the
    // universe. If that feed cannot serve the pair, the pair is dropped and
    // counted — never silently answered by a different exchange.
    // `lockedToScanFeed` is false for the explicit one-coin backtest and for
    // deep (paged) history, where Binance is the only venue that can serve the
    // request and cross-venue is not a risk because the user asked for one
    // specific chart.
    final full = _feedOrder();
    var order = full;
    if (lockedToScanFeed && activeFeed.isNotEmpty) {
      order = full.where((f) => f.name == activeFeed).toList();
      if (order.isEmpty) order = full.where((f) => f.name == activeFeed).toList();
    } else {
      order = full.where((f) => !_isDown(f)).toList();
      if (order.isEmpty) order = full;
    }

    for (final feed in order) {
      try {
        final c = await _candles(feed, sym, tf, lim);
        if (c.length >= 40) {
          _markUp(feed);
          return c;
        }
        // Feed answered but has no data for this pair: Binance-only listing.
        throw MarketDataException('no data');
      } catch (_) {
        // A single missing pair must not kill the whole feed; only the
        // 451 / network style failures make a feed unusable.
      }
      await Future<void>.delayed(_lag);
    }
    _pairFail(sym);
    throw MarketDataException('candles $sym');
  }

  /// Prefer the feed that already worked for the ticker call.
  static List<_Feed> _feedOrder() {
    final primary = _feeds.where((f) => f.name == activeFeed);
    final rest = _feeds.where((f) => f.name != activeFeed);
    return <_Feed>[...primary, ...rest];
  }

  static String _short(Object e) {
    var m = e.toString().replaceAll('\n', ' ');
    if (m.length > 60) m = m.substring(0, 60);
    return m;
  }

  static Future<dynamic> _getJson(String url) async {
    final http.Response r;
    try {
      r = await http
          .get(Uri.parse(url), headers: const <String, String>{
        'Accept': 'application/json',
      })
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw MarketDataException('timeout');
    } on http.ClientException {
      throw MarketDataException('no internet');
    } on SocketException {
      throw MarketDataException('no internet');
    }
    if (r.statusCode == 451) {
      throw MarketDataException('geo-blocked (451)');
    }
    if (r.statusCode != 200) {
      throw MarketDataException('HTTP ${r.statusCode}');
    }
    return json.decode(r.body);
  }

  // ---------------------------------------------------------------- tickers

  static Future<List<CoinData>> _tickers(_Feed feed) async {
    switch (feed.kind) {
      case 'binance':
        return _binanceTickers();
      case 'bybit':
        return _bybitTickers();
      case 'okx':
        return _okxTickers();
      case 'mexc':
        return _mexcTickers();
      default:
        throw MarketDataException('unknown feed');
    }
  }

  static const List<String> _binanceMirrors = <String>[
    'https://api.binance.com/api/v3',
    'https://api1.binance.com/api/v3',
    'https://api2.binance.com/api/v3',
    'https://api3.binance.com/api/v3',
    'https://data-api.binance.vision/api/v3',
  ];

  /// Symbols Binance itself reports as TRADING on spot.
  ///
  /// /ticker/24hr keeps returning rows for pairs that are no longer tradable
  /// (and for delisted ones it serves the last snapshot), so a ticker list on
  /// its own is not a list of live markets. /exchangeInfo is the authority: a
  /// symbol is live only when status == 'TRADING' and it is not a leveraged
  /// token. Cached for the process, and a failure to fetch it degrades to the
  /// ticker list rather than killing the scan.
  static Set<String>? _binanceTrading;

  static Future<Set<String>> _binanceLiveSymbols() async {
    final cached = _binanceTrading;
    if (cached != null && cached.isNotEmpty) return cached;
    Object? last;
    for (final base in _binanceMirrors) {
      try {
        final data = await _getJson('$base/exchangeInfo') as Map<String, dynamic>;
        final rows = (data['symbols'] as List<dynamic>?) ?? <dynamic>[];
        final live = <String>{};
        for (final r in rows) {
          final m = r as Map<String, dynamic>;
          if (m['status']?.toString() != 'TRADING') continue;
          if (m['quoteAsset']?.toString() != 'USDT') continue;
          if (m['isSpotTradingAllowed'] == false) continue;
          live.add(m['symbol'].toString());
        }
        if (live.isNotEmpty) {
          _binanceTrading = live;
          _liveSymbols = live;
          return live;
        }
      } catch (e) {
        last = e;
      }
    }
    if (last != null) {
      // Do not poison the cache: a transient failure must not shrink the next
      // scan. Fall back to "no filter" and let the freshness check catch stale
      // pairs instead.
      return <String>{};
    }
    return <String>{};
  }

  static Future<List<CoinData>> _binanceTickers() async {
    Object? last;
    for (final base in _binanceMirrors) {
      try {
        final data = await _getJson('$base/ticker/24hr') as List<dynamic>;
        lastRawTickers = data.length;
        // Only symbols Binance calls TRADING. Without this the list contains
        // pairs it no longer runs — GALUSDT being the live example: delisted
        // from spot, still returned by /ticker/24hr, and it produced a STRICT
        // BUY at 2.5420 while the real Binance chart the user opened showed
        // GALA at 0.00153.
        final live = await _binanceLiveSymbols();
        final parsed = data
            .map((e) => CoinData.fromJson(e as Map<String, dynamic>))
            .toList();
        final list =
            parsed.where((c) => live.isEmpty || live.contains(c.symbol)).toList();
        // Count only pairs that LOOK tradable to us (USDT, not a stablecoin,
        // not leveraged) but that Binance no longer marks TRADING. Comparing
        // the whole ticker list against a USDT-only live set counted BNBBTC,
        // ETHTRY and every other quote asset as "delisted" -- on the device
        // that printed 3227 of 3745, i.e. 86%, which no exchange does.
        lastDeadSymbols = live.isEmpty
            ? 0
            : parsed.where((c) => _isListed(c) && !live.contains(c.symbol)).length;
        if (list.isNotEmpty) return list;
      } catch (e) {
        last = e;
      }
    }
    throw MarketDataException('binance ${last ?? 'empty'}');
  }

  /// Bybit spot tickers (24h stats).
  static Future<List<CoinData>> _bybitTickers() async {
    final resp = await _getJson(
      'https://api.bybit.com/v5/market/tickers?category=spot',
    ) as Map<String, dynamic>;
    final result = resp['result'] as Map<String, dynamic>?;
    final rows = (result?['list'] as List<dynamic>?) ?? <dynamic>[];
    lastRawTickers = rows.length;
    final out = <CoinData>[];
    for (final row in rows) {
      final m = row as Map<String, dynamic>;
      final symbol = m['symbol']?.toString() ?? '';
      if (!symbol.endsWith('USDT')) continue;
      final price = _d(m['lastPrice']);
      double pct;
      if (m['price24hPcnt'] != null) {
        pct = _d(m['price24hPcnt']) * 100;
      } else {
        final prev = _d(m['prevPrice24h']);
        pct = prev > 0 ? (price - prev) / prev * 100 : 0;
      }
      final coin = CoinData(
        symbol: symbol,
        lastPrice: price,
        priceChangePercent: pct,
        highPrice: _d(m['highPrice24h']),
        lowPrice: _d(m['lowPrice24h']),
        quoteVolume: _d(m['turnover24h']),
      );
      if (_isListed(coin)) out.add(coin);
    }
    return out;
  }

  /// OKX spot tickers, symbol format BTC-USDT.
  static Future<List<CoinData>> _okxTickers() async {
    final resp = await _getJson(
      'https://www.okx.com/api/v5/market/tickers?instType=SPOT',
    ) as Map<String, dynamic>;
    final rows = (resp['data'] as List<dynamic>?) ?? <dynamic>[];
    lastRawTickers = rows.length;
    final out = <CoinData>[];
    for (final row in rows) {
      final m = row as Map<String, dynamic>;
      final inst = m['instId']?.toString() ?? '';
      if (!inst.endsWith('-USDT')) continue;
      final open = _d(m['open24h']);
      final px = _d(m['last']);
      // OKX `volCcy24h` is BASE-currency volume (BTC, not USDT). Comparing it
      // against a 5M USDT floor silently removed almost every pair, which is
      // how a 300-coin scan became 35 coins on the device. Multiply by price to
      // get quote volume; `vol24h` (already quote) is used when present.
      final volCcy = _d(m['volCcy24h']);
      final volQuote = _d(m['vol24h']);
      final quoteVolume = volQuote > 0 ? volQuote : volCcy * px;
      final coin = CoinData(
        symbol: '${inst.split('-').first}USDT',
        lastPrice: px,
        priceChangePercent: open > 0 ? (px - open) / open * 100 : 0,
        highPrice: _d(m['high24h']),
        lowPrice: _d(m['low24h']),
        quoteVolume: quoteVolume,
      );
      if (_isListed(coin)) out.add(coin);
    }
    return out;
  }

  /// MEXC spot tickers.
  static Future<List<CoinData>> _mexcTickers() async {
    final data = await _getJson(
      'https://api.mexc.com/api/v3/ticker/24hr',
    ) as List<dynamic>;
    lastRawTickers = data.length;
    final out = <CoinData>[];
    for (final row in data) {
      final m = row as Map<String, dynamic>;
      final coin = CoinData(
        symbol: m['symbol']?.toString() ?? '',
        lastPrice: _d(m['lastPrice']),
        priceChangePercent: _d(m['priceChangePercent']),
        highPrice: _d(m['highPrice']),
        lowPrice: _d(m['lowPrice']),
        quoteVolume: _d(m['quoteVolume']),
      );
      if (_isListed(coin)) out.add(coin);
    }
    return out;
  }

  // ---------------------------------------------------------------- candles

  static Future<List<Candle>> _candles(
    _Feed feed,
    String sym,
    String tf,
    int lim,
  ) async {
    switch (feed.kind) {
      case 'binance':
        return _binanceCandles(sym, tf, lim);
      case 'bybit':
        return _bybitCandles(sym, tf, lim);
      case 'okx':
        return _okxCandles(sym, tf, lim);
      case 'mexc':
        return _mexcCandles(sym, tf, lim);
      default:
        throw MarketDataException('unknown feed');
    }
  }

  static Future<List<Candle>> _binanceCandles(
    String sym,
    String tf,
    int lim,
  ) async {
    Object? last;
    for (final base in _binanceMirrors) {
      try {
        // Take a slot from the rolling weight budget before asking. Only the
        // Binance path is metered; the other feeds have their own limits and
        // are used precisely when Binance is unavailable.
        await reserveWeight(klinesWeight(lim));
        final data = await _getJson(
          '$base/klines?symbol=$sym&interval=$tf&limit=$lim',
        ) as List<dynamic>;
        final list = data
            .map((e) => Candle.fromJson(e as List<dynamic>))
            .toList();
        if (list.isNotEmpty) return list;
      } catch (e) {
        last = e;
      }
    }
    throw MarketDataException('binance ${last ?? 'empty'}');
  }

  /// Binance caps klines at 1000 rows per request, so anything longer is
  /// stitched together from several pages walking backwards in time.
  /// Used by the backtest, where a 1000-bar sample is only ten days.
  static Future<List<Candle>> _binancePaged(
    String sym,
    String tf,
    int lim,
  ) async {
    Object? last;
    for (final base in _binanceMirrors) {
      try {
        final out = <Candle>[];
        int? endTime;
        while (out.length < lim) {
          final page = lim - out.length > 1000 ? 1000 : lim - out.length;
          final url = '$base/klines?symbol=$sym&interval=$tf&limit=$page'
              '${endTime == null ? '' : '&endTime=$endTime'}';
          final data = await _getJson(url) as List<dynamic>;
          if (data.isEmpty) break;
          final batch =
              data.map((e) => Candle.fromJson(e as List<dynamic>)).toList();
          out.insertAll(0, batch);
          endTime = batch.first.openTime - 1;
          if (batch.length < page) break; // start of the listing
          await Future<void>.delayed(_lag);
        }
        if (out.isNotEmpty) return out;
      } catch (e) {
        last = e;
      }
    }
    throw MarketDataException('binance paged ${last ?? 'empty'}');
  }

  static String _bybitInterval(String tf) {
    switch (tf) {
      case '3m':
        return '3';
      case '5m':
        return '5';
      case '15m':
        return '15';
      case '30m':
        return '30';
      case '1h':
        return '60';
      case '4h':
        return '240';
      default:
        return '60';
    }
  }

  static Future<List<Candle>> _bybitCandles(
    String sym,
    String tf,
    int lim,
  ) async {
    final resp = await _getJson(
      'https://api.bybit.com/v5/market/kline'
      '?category=spot&symbol=$sym&interval=${_bybitInterval(tf)}&limit=$lim',
    ) as Map<String, dynamic>;
    final result = resp['result'] as Map<String, dynamic>?;
    final rows = (result?['list'] as List<dynamic>?) ?? <dynamic>[];
    if (rows.isEmpty) throw MarketDataException('bybit empty');

    // Bybit returns newest first.
    final ordered = rows.reversed.toList();
    return ordered.map((row) {
      final j = row as List<dynamic>;
      return Candle(
        openTime: int.parse(j[0].toString()),
        closeTime: int.parse(j[0].toString()),
        open: double.parse(j[1].toString()),
        high: double.parse(j[2].toString()),
        low: double.parse(j[3].toString()),
        close: double.parse(j[4].toString()),
        volume: double.parse(j[5].toString()),
      );
    }).toList();
  }

  static String _okxBar(String tf) {
    switch (tf) {
      case '3m':
        return '3m';
      case '5m':
        return '5m';
      case '15m':
        return '15m';
      case '30m':
        return '30m';
      case '1h':
        return '1H';
      case '4h':
        return '4H';
      default:
        return '1H';
    }
  }

  static Future<List<Candle>> _okxCandles(
    String sym,
    String tf,
    int lim,
  ) async {
    final parts = sym.split('USDT');
    if (parts.length != 2 || parts[1].isNotEmpty) {
      throw MarketDataException('okx symbol');
    }
    final inst = '${parts[0]}-USDT';
    // OKX caps this endpoint at 300 rows; asking for more is rejected.
    final okxLim = lim > 300 ? 300 : lim;
    final data = await _getJson(
      'https://www.okx.com/api/v5/market/candles'
      '?instId=$inst&bar=${_okxBar(tf)}&limit=$okxLim',
    ) as Map<String, dynamic>;
    final rows = (data['data'] as List<dynamic>?) ?? <dynamic>[];
    if (rows.isEmpty) throw MarketDataException('okx empty');

    // OKX returns newest first, and volume in base currency.
    final ordered = rows.reversed.toList();
    return ordered.map((row) {
      final j = row as List<dynamic>;
      final open = double.parse(j[1].toString());
      final close = double.parse(j[4].toString());
      final vol = double.parse(j[5].toString());
      return Candle(
        openTime: int.parse(j[0].toString()),
        closeTime: int.parse(j[0].toString()),
        open: open,
        high: double.parse(j[2].toString()),
        low: double.parse(j[3].toString()),
        close: close,
        volume: vol * close, // approx quote volume, keeps spikes comparable
      );
    }).toList();
  }

  static String _mexcInterval(String tf) {
    switch (tf) {
      // MEXC publishes no 3-minute candle. Throwing is deliberate: the old
      // `default: return '60m'` meant a 3m request would have been answered
      // with HOURLY bars and labelled "3M" on the card -- the same class of lie
      // as the 999-bar-age sentinel. Better to fail and say which feed failed.
      case '3m':
        throw MarketDataException('mexc: no 3-minute candle');
      case '5m':
        return '5m';
      case '15m':
        return '15m';
      case '30m':
        return '30m';
      case '1h':
        return '60m';
      case '4h':
        return '4h';
      default:
        return '60m';
    }
  }

  static Future<List<Candle>> _mexcCandles(
    String sym,
    String tf,
    int lim,
  ) async {
    final data = await _getJson(
      'https://api.mexc.com/api/v3/klines'
      '?symbol=$sym&interval=${_mexcInterval(tf)}&limit=$lim',
    ) as List<dynamic>;
    final list =
        data.map((e) => Candle.fromJson(e as List<dynamic>)).toList();
    if (list.isEmpty) throw MarketDataException('mexc empty');
    return list;
  }

  static double _d(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }
}

class MarketDataException implements Exception {
  MarketDataException(this.message);

  final String message;

  @override
  String toString() => message;
}

// =====================================================================
// SMART MONEY ENGINE
//
// Port of the LuxAlgo "Smart Money Concepts" model (CC BY-NC-SA 4.0,
// https://www.tradingview.com/script/  — LuxAlgo) reimplemented from its
// published logic: pivot state machine (swing length 50, internal 5),
// BOS vs CHoCH, structure-interval order blocks, auto-threshold FVGs,
// EQH/EQL liquidity and premium/discount/equilibrium zones.
// =====================================================================

class Engine {
  /// Swing structure length used by LUX.
  static const int swingLen = 50;

  /// Internal structure length used by LUX.
  static const int internalLen = 5;

  /// A pivot high/low plus the trending direction it was confirmed in.
  static List<SwingPoint> swings(List<Candle> c, {int len = swingLen}) {
    final points = <SwingPoint>[];
    if (c.length < len + 2) return points;

    // LUX oscillator: 0 while price stays below the trailing high, 1 while it
    // stays above the trailing low. The state flip confirms the pivot that
    // happened `len` bars earlier.
    // The oscillator starts UNKNOWN, not 0. Pine's `var float os = 0` has the
    // same bias, but combined with the confirmed-pivot rule it guaranteed that
    // the first pivot of every window was a LOW (measured 82 highs vs 147 lows
    // on symmetric random walks; 82/91 once the state starts unknown).
    int? os;
    for (int n = 1; n < c.length; n++) {
      // LUX reads ta.highest(len) / ta.lowest(len), i.e. the window
      // [n-len+1 .. n] INCLUSIVE of the current bar. The window must contain
      // the bar being tested against it (c[n-len]); with an exclusive window
      // that bar can never exceed its own high/low, so no pivot would ever be
      // confirmed and the whole engine stayed silent.
      double upper = double.negativeInfinity;
      double lower = double.infinity;
      for (int i = n - len + 1; i <= n; i++) {
        if (i < 0) continue;
        if (c[i].high > upper) upper = c[i].high;
        if (c[i].low < lower) lower = c[i].low;
      }
      // Window incomplete or degenerate: keep the previous state.
      if (upper == double.negativeInfinity || lower == double.infinity) {
        continue;
      }

      final int? prev = os;
      if (n - len >= 0) {
        if (c[n - len].high > upper) {
          os = 0;
        } else if (c[n - len].low < lower) {
          os = 1;
        }
      }
      if (os == null || prev == null) continue; // warm-up bar: no pivot yet

      if (os == 0 && prev != 0) {
        points.add(SwingPoint(
          price: c[n - len].high,
          index: n - len,
          type: 'high',
        ));
      }
      if (os == 1 && prev != 1) {
        points.add(SwingPoint(
          price: c[n - len].low,
          index: n - len,
          type: 'low',
        ));
      }
    }
    return points;
  }

  /// LUX compares against the last pivot of each side (the pivot becomes the
  /// new reference once price breaks it, and a newer pivot replaces it).
  static SwingPoint? _lastUnbrokenHigh(List<SwingPoint> pts) {
    final list = pts.where((p) => p.type == 'high').toList();
    return list.isEmpty ? null : list.last;
  }

  static SwingPoint? _lastUnbrokenLow(List<SwingPoint> pts) {
    final list = pts.where((p) => p.type == 'low').toList();
    return list.isEmpty ? null : list.last;
  }

  /// Average true range; LUX uses ATR(200) for its thresholds.
  /// Standard EMA, seeded with the SMA of the first [period] values.
  ///
  /// Mirrors `mirror.ema`. Seeding matters: starting from the first close
  /// instead of the SMA leaves a bias that only dies out after ~5x the period,
  /// which on a 3M chart is most of the session.
  static List<double> ema(List<double> values, int period) {
    if (values.length < period) return <double>[];
    final k = 2.0 / (period + 1);
    var seed = 0.0;
    for (var i = 0; i < period; i++) {
      seed += values[i];
    }
    final out = <double>[seed / period];
    for (var i = period; i < values.length; i++) {
      out.add(values[i] * k + out.last * (1 - k));
    }
    return out;
  }

  /// MACD(12,26,9) aligned to the tail of [closes].
  ///
  /// Returns `[line, signal, hist, prevHist]` or null when there are not
  /// enough bars for the slow EMA plus the signal EMA. Mirrors
  /// `mirror.macd`, which `measure_macd.py` used for every number printed on
  /// the MACD screen.
  static List<double>? macd(List<double> closes,
      {int fast = 12, int slow = 26, int signal = 9}) {
    if (closes.length < slow + signal + 2) return null;
    final fastE = ema(closes, fast);
    final slowE = ema(closes, slow);
    if (fastE.isEmpty || slowE.isEmpty) return null;
    final off = slow - fast;
    if (off < 0 || fastE.length <= off) return null;
    final line = <double>[];
    for (var i = 0; i < slowE.length; i++) {
      line.add(fastE[i + off] - slowE[i]);
    }
    final sigE = ema(line, signal);
    if (sigE.isEmpty || line.length < sigE.length) return null;
    final hist = <double>[];
    final start = line.length - sigE.length;
    for (var i = 0; i < sigE.length; i++) {
      hist.add(line[start + i] - sigE[i]);
    }
    if (hist.length < 2) return null;
    return <double>[line.last, sigE.last, hist.last, hist[hist.length - 2]];
  }

  /// Consecutive closed bars at the end of [closes] where the MACD histogram
  /// rose. 0 means the last bar is the first rising one.
  ///
  /// Computed in one pass over the shared EMA series: calling [macd] on every
  /// prefix is quadratic, and on a 400-coin scan that is the difference between
  /// a scan and a hang.
  static int histRisingBars(List<double> closes,
      {int fast = 12, int slow = 26, int signal = 9}) {
    if (closes.length < slow + signal + 2) return 0;
    final fastE = ema(closes, fast);
    final slowE = ema(closes, slow);
    if (fastE.isEmpty || slowE.isEmpty) return 0;
    final off = slow - fast;
    if (off < 0 || fastE.length <= off) return 0;
    final line = <double>[];
    for (var i = 0; i < slowE.length; i++) {
      line.add(fastE[i + off] - slowE[i]);
    }
    final sigE = ema(line, signal);
    if (sigE.length < 2) return 0;
    final start = line.length - sigE.length;
    final hist = <double>[];
    for (var i = 0; i < sigE.length; i++) {
      hist.add(line[start + i] - sigE[i]);
    }
    var rising = 0;
    for (var i = hist.length - 1; i > 0; i--) {
      if (hist[i] > hist[i - 1]) {
        rising++;
      } else {
        break;
      }
    }
    return rising;
  }

  static double atr(List<Candle> c, {int period = 14}) {
    if (c.length < 2) return 0;
    int n = period;
    if (n > c.length - 1) n = c.length - 1;
    double sum = 0;
    for (int i = c.length - n; i < c.length; i++) {
      final tr = max(
        c[i].high - c[i].low,
        max((c[i].high - c[i - 1].close).abs(),
            (c[i].low - c[i - 1].close).abs()),
      );
      sum += tr;
    }
    return sum / n;
  }

  /// Order block from the structure interval (LUX `ob_coord`).
  ///
  /// Bullish: walk back from the break to the pivot and take the highest
  /// candle whose range is under 2x ATR. Bearish: mirror with the lowest.
  static OrderBlock? _structureOb(
    List<Candle> c,
    int fromIndex,
    int toIndex,
    bool bullish,
    double atrValue,
  ) {
    double? best;
    double? other;
    int bestIndex = fromIndex;

    for (int i = toIndex - 1; i > fromIndex; i--) {
      final range = c[i].high - c[i].low;
      if (range >= atrValue * 2) continue;
      if (bullish) {
        if (best == null || c[i].high > best) {
          best = c[i].high;
          other = c[i].low;
          bestIndex = i;
        }
      } else {
        if (best == null || c[i].low < best) {
          best = c[i].low;
          other = c[i].high;
          bestIndex = i;
        }
      }
    }
    if (best == null || other == null) return null;
    return OrderBlock(
      high: bullish ? best : max(best, other),
      low: bullish ? min(best, other) : best,
      type: bullish ? 'bullish' : 'bearish',
      index: bestIndex,
    );
  }

  /// Order blocks price has not traded through yet.
  ///
  /// LUX's `orderBlockMitigationInput` defaults to **High/Low**: a bearish block
  /// dies when price wicks above its high, a bullish one when price wicks below
  /// its low. This app shipped the CLOSE variant, where a block survives until a
  /// candle *closes* through it — so blocks whose level price had already
  /// traded through stayed "active", and a stop could be placed behind
  /// structure that was no longer intact.
  ///
  /// Measured on identical synthetic candles (12 seeds x 4 regimes, closed
  /// trades, 0.25% cost): gross +8.0R -> +17.0R, net -12.0R -> -2.8R, WR
  /// 32.1% -> 33.7%, and 3 of 4 regimes improved with none worse. Both gross
  /// and net moved together, which is the opposite of the v7 fixed-TP failure
  /// where a WR gain hid a total-R loss. (NOTES 19.)
  static List<OrderBlock> activeObs(List<OrderBlock> obs, List<Candle> c) {
    final out = <OrderBlock>[];
    for (final o in obs) {
      bool broken = false;
      for (int i = o.index + 1; i < c.length; i++) {
        if (o.type == 'bearish' && c[i].high > o.high) {
          broken = true;
          break;
        }
        if (o.type == 'bullish' && c[i].low < o.low) {
          broken = true;
          break;
        }
      }
      if (!broken) out.add(o);
    }
    return out;
  }

  /// LUX fair value gaps: `low > high[2] && close > high[2]` for bullish,
  /// mirrored for bearish, filtered by the running-mean delta threshold.
  /// Returns the active (unfilled) gaps.
  static List<FVG> fvgs(List<Candle> c) {
    final raw = <FVG>[];
    final deltas = <double>[];
    if (c.length < 4) return raw;

    for (int i = 2; i < c.length; i++) {
      final prev2 = c[i - 2];
      final prev1 = c[i - 1];
      final cur = c[i];
      final deltaPer =
          prev1.open > 0 ? (prev1.close - prev1.open) / prev1.open * 100 : 0.0;
      deltas.add(deltaPer.abs());

      // Running mean of |delta| * 2, as LUX computes ta.cum(...)/n*2.
      final threshold = deltas.reduce((a, b) => a + b) / deltas.length * 2;

      if (cur.low > prev2.high &&
          prev1.close > prev2.high &&
          deltaPer > threshold) {
        raw.add(FVG(high: cur.low, low: prev2.high, type: 'bullish', index: i));
      }
      if (cur.high < prev2.low &&
          prev1.close < prev2.low &&
          -deltaPer > threshold) {
        raw.add(
            FVG(high: prev2.low, low: cur.high, type: 'bearish', index: i));
      }
    }

    // LUX deletes a bullish gap when a later low trades under its bottom and
    // a bearish gap when a later high trades over its top.
    final active = <FVG>[];
    for (final f in raw) {
      bool filled = false;
      for (int i = f.index + 1; i < c.length; i++) {
        if (f.type == 'bullish' && c[i].low < f.low) filled = true;
        if (f.type == 'bearish' && c[i].high > f.high) filled = true;
        if (filled) break;
      }
      if (!filled) active.add(f);
    }
    return active;
  }

  /// A structure break: direction, the bar it closed on, the pivot it broke
  /// and the pattern (BOS = continuation, CHoCH = against the prior trend).
  static List<StructureBreak> breaks(
    List<Candle> c,
    List<SwingPoint> pts, {
    int len = swingLen,
    int barsBack = 30,
  }) {
    final out = <StructureBreak>[];
    if (c.length < 3) return out;

    final highs = pts.where((p) => p.type == 'high').toList();
    final lows = pts.where((p) => p.type == 'low').toList();

    int from = c.length - barsBack;
    if (from < 1) from = 1;

    // A pivot is usable only once it is confirmed `len` bars later, and every
    // newly confirmed pivot re-arms the break detection for that side.
    SwingPoint? curHigh;
    SwingPoint? curLow;
    bool highBroken = false;
    bool lowBroken = false;

    for (int k = from; k < c.length; k++) {
      for (final p in highs) {
        if (p.index + len <= k && (curHigh == null || p.index > curHigh.index)) {
          curHigh = p;
          highBroken = false;
        }
      }
      for (final p in lows) {
        if (p.index + len <= k && (curLow == null || p.index > curLow.index)) {
          curLow = p;
          lowBroken = false;
        }
      }

      final px = c[k].close;
      final prev = c[k - 1].close;

      if (curHigh != null &&
          !highBroken &&
          prev <= curHigh.price &&
          px > curHigh.price) {
        highBroken = true;
        out.add(StructureBreak(
          event: 'BULLISH',
          bar: k,
          pivot: curHigh,
          pattern: _pattern(pts, curHigh.index, true),
        ));
      }

      if (curLow != null &&
          !lowBroken &&
          prev >= curLow.price &&
          px < curLow.price) {
        lowBroken = true;
        out.add(StructureBreak(
          event: 'BEARISH',
          bar: k,
          pivot: curLow,
          pattern: _pattern(pts, curLow.index, false),
        ));
      }
    }
    return out;
  }

  /// CHoCH when the break goes against the structure that preceded the pivot.
  static String _pattern(List<SwingPoint> pts, int pivotIndex, bool bullish) {
    final before = pts.where((p) => p.index < pivotIndex).toList();
    final trend = trendOf(before);
    if (bullish && trend < 0) return 'CHoCH';
    if (!bullish && trend > 0) return 'CHoCH';
    return 'BOS';
  }

  /// Trend from the last two swing highs and lows (HH/HL vs LH/LL).
  static int trendOf(List<SwingPoint> pts) {
    final highs = pts.where((p) => p.type == 'high').toList();
    final lows = pts.where((p) => p.type == 'low').toList();
    if (highs.length < 2 || lows.length < 2) return 0;
    if (highs.last.price > highs[highs.length - 2].price &&
        lows.last.price > lows[lows.length - 2].price) {
      return 1;
    }
    if (highs.last.price < highs[highs.length - 2].price &&
        lows.last.price < lows[lows.length - 2].price) {
      return -1;
    }
    return 0;
  }

  /// Equal highs / equal lows: two confirmed pivots within ATR * threshold.
  ///
  /// Sourced from the INTERNAL pivots (length 5), as LUX does, and at 0.5 x ATR.
  /// Measured on 8 synthetic series x 3 timeframes: at the old 0.1 x ATR over
  /// SWING pivots this was true 0/48 times — consecutive swing pivots sit a
  /// median 4.9 ATR apart, so the condition was unreachable and the UI's
  /// "Liquidity" row always read "None". Internal pivots sit ~1.2 ATR apart and
  /// 0.5 x ATR gives a 29% hit rate: visible, still selective.
  ///
  /// Deliberately DISPLAY-ONLY. A measured attempt to score or veto on the pool
  /// (84 paired series, identical candles) changed the result by at most one
  /// trade: 86 trades / +36.7R without it, 87 / +35.7R with it. That is noise,
  /// not edge, and this project does not ship numbers it cannot defend - see
  /// NOTES.md for the table. It is shown, not traded.
  static bool equalHighs(List<SwingPoint> pts, double atrValue,
      {double threshold = 0.5}) {
    final highs = pts.where((p) => p.type == 'high').toList();
    if (highs.length < 2 || atrValue <= 0) return false;
    final a = highs[highs.length - 1].price;
    final b = highs[highs.length - 2].price;
    return (max(a, b) - min(a, b)) < atrValue * threshold;
  }

  static bool equalLows(List<SwingPoint> pts, double atrValue,
      {double threshold = 0.5}) {
    final lows = pts.where((p) => p.type == 'low').toList();
    if (lows.length < 2 || atrValue <= 0) return false;
    final a = lows[lows.length - 1].price;
    final b = lows[lows.length - 2].price;
    return (max(a, b) - min(a, b)) < atrValue * threshold;
  }

  static bool volSpike(List<Candle> c) {
    if (c.length < 21) return false;
    double avg = 0;
    for (int i = c.length - 20; i < c.length - 1; i++) {
      avg += c[i].volume;
    }
    avg /= 19;
    if (avg <= 0) return false;
    return c.last.volume > avg * 1.5;
  }

  static TFAnalysis analyze(String tf, List<Candle> c) {
    final pts = swings(c);
    final internal = swings(c, len: internalLen);

    final lastHigh = _lastUnbrokenHigh(pts);
    final lastLow = _lastUnbrokenLow(pts);

    // LUX keeps `var trend` and only flips it on a structure break, so the
    // live bias is the direction of the freshest break — not the HH/HL shape
    // of the last two pivots, which is 0 for most of the bar history and used
    // to mute the whole engine.
    final recent = breaks(c, pts, barsBack: c.length - 1);
    final internalRecent = breaks(c, internal, len: internalLen, barsBack: 6);

    int trend = trendOf(pts);
    if (recent.isNotEmpty) {
      trend = recent.last.event == 'BULLISH' ? 1 : -1;
    }

    final atr200 = atr(c, period: 200);
    final atrPer = atr(c);
    final swingAtr = atr200 > 0 ? atr200 : atrPer;

    final lastBreak = recent.isEmpty ? null : recent.last;
    final event = lastBreak?.event ?? '';
    final pattern = lastBreak?.pattern ?? '';
    final breakFresh = lastBreak != null && c.length - 1 - lastBreak.bar <= 2;

    // The internal (len 5) series is a separate object, so its freshness has
    // to be computed here. It was never set before, which silently disabled
    // the WATCH pass's internal-break trigger and the RADAR fallback.
    final internalLast =
        internalRecent.isEmpty ? null : internalRecent.last;
    final internalFresh = internalLast != null &&
        c.length - 1 - internalLast.bar <= 4;

    // Order blocks come from the interval between each break and its pivot.
    final obs = <OrderBlock>[];
    for (final b in recent) {
      final ob = _structureOb(
        c,
        b.pivot.index,
        b.bar,
        b.event == 'BULLISH',
        swingAtr,
      );
      if (ob == null) continue;
      final dup = obs.any((o) => o.index == ob.index && o.type == ob.type);
      if (!dup) obs.add(ob);
    }
    final active = activeObs(obs, c);

    final fvgList = fvgs(c);
    // Internal pivots, as LUX does: swing pivots are far too sparse for pools.
    final eqh = equalHighs(internal, swingAtr);
    final eql = equalLows(internal, swingAtr);
    final vs = volSpike(c);

    // Premium / discount of the current swing range (LUX 5% / 47.5% split).
    double premium = 0;
    double equilibrium = 0;
    double discount = 0;
    if (lastHigh != null && lastLow != null && lastHigh.price > lastLow.price) {
      final up = lastHigh.price;
      final dn = lastLow.price;
      premium = 0.95 * up + 0.05 * dn;
      equilibrium = 0.525 * up + 0.475 * dn;
      discount = 0.95 * dn + 0.05 * up;
    } else if (c.length >= 20) {
      // No confirmed swing pair yet (short window, or one pivot missing).
      // Fall back to the window's own range so the card stops printing
      // "BOS 대 Unknown": a range is always available from the candles.
      var hi = c.first.high;
      var lo = c.first.low;
      for (final k in c) {
        if (k.high > hi) hi = k.high;
        if (k.low < lo) lo = k.low;
      }
      if (hi > lo) {
        premium = 0.95 * hi + 0.05 * lo;
        equilibrium = 0.525 * hi + 0.475 * lo;
        discount = 0.95 * lo + 0.05 * hi;
      }
    }

    final px = c.last.close;

    return TFAnalysis(
      timeframe: tf,
      structure: trend > 0
          ? 'BULLISH'
          : trend < 0
              ? 'BEARISH'
              : 'NEUTRAL',
      volumeSpike: vs,
      obs: active,
      fvgs: fvgList,
      candles: c,
      close: px,
      atr: atrPer,
      trend: trend,
      swingHigh: lastHigh,
      swingLow: lastLow,
      premium: premium,
      equilibrium: equilibrium,
      discount: discount,
      eqh: eqh,
      eql: eql,
      freshBreak: breakFresh,
      breakPattern: pattern,
      breakEvent: event,
      internalFresh: internalFresh,
      internalEvent: internalLast?.event ?? '',
      breakLevel: lastBreak?.pivot.price ?? px,
      // -1 means "no break was found". It used to be 999, which the
      // confirmation builder happily read as a real age of 999 bars and printed
      // "15M bullish break 999 bar age" on signals that had no break at all --
      // a fabricated confluence. (Device, v14: DODO, WATCH relaxed, 90%.)
      breakAge: lastBreak == null ? -1 : c.length - 1 - lastBreak.bar,
      structureConflict: false,
    );
  }

  /// `analyze` plus a check against a much longer window of the same
  /// timeframe. The 200-candle window holds only one or two swing pivots at
  /// the LUX default length of 50, so the local bias can point up while the
  /// longer structure has already rolled over. That is reported, never acted
  /// on by itself.
  static TFAnalysis analyzeLong(String tf, List<Candle> short, List<Candle> full) {
    final local = analyze(tf, short);
    if (full.length <= short.length) return local;
    final longTrend = analyze(tf, full).trend;
    if (longTrend == 0 || local.trend == 0) return local;
    if (longTrend == local.trend) return local;
    return TFAnalysis(
      timeframe: local.timeframe,
      structure: local.structure,
      volumeSpike: local.volumeSpike,
      obs: local.obs,
      fvgs: local.fvgs,
      candles: local.candles,
      close: local.close,
      atr: local.atr,
      trend: local.trend,
      swingHigh: local.swingHigh,
      swingLow: local.swingLow,
      premium: local.premium,
      equilibrium: local.equilibrium,
      discount: local.discount,
      eqh: local.eqh,
      eql: local.eql,
      freshBreak: local.freshBreak,
      breakPattern: local.breakPattern,
      breakEvent: local.breakEvent,
      internalFresh: local.internalFresh,
      internalEvent: local.internalEvent,
      breakLevel: local.breakLevel,
      breakAge: local.breakAge,
      structureConflict: true,
    );
  }

  /// The still-valid order block whose edge is nearest to price, on either
  /// side. Used as a structure floor, not as an entry.
  static OrderBlock? nearestObTo(List<OrderBlock> obs, double px) {
    OrderBlock? best;
    double bestDist = double.infinity;
    for (final o in obs) {
      final d = px < o.low ? o.low - px : (px > o.high ? px - o.high : 0.0);
      if (d < bestDist) {
        bestDist = d;
        best = o;
      }
    }
    return best;
  }

  /// Closest active bullish OB at or below price.
  static OrderBlock? buyZone(List<OrderBlock> obs, double px) {
    OrderBlock? best;
    for (final o in obs) {
      if (o.type != 'bullish') continue;
      if (o.high > px * 1.005) continue;
      if (o.low < px * 0.94) continue;
      if (best == null || o.high > best.high) best = o;
    }
    return best;
  }

  /// Closest active bearish OB at or above price.
  static OrderBlock? sellZone(List<OrderBlock> obs, double px) {
    OrderBlock? best;
    for (final o in obs) {
      if (o.type != 'bearish') continue;
      if (o.low < px * 0.995) continue;
      if (o.high > px * 1.06) continue;
      if (best == null || o.low < best.low) best = o;
    }
    return best;
  }

  /// 4H bias + 1H structure/zone + 15M trigger, LUX-style.
  static TradeSignal? multiTF(
    String sym,
    List<Candle> c4,
    List<Candle> c1,
    List<Candle> c15, {
    List<Candle>? c4Long,
    List<Candle>? c1Long,
    List<Candle>? c15Long,
    bool relaxed = false,
    List<String>? trace,
    TradeMode mode = TradeMode.swing,
  }) {
    if (c4.length < 60 || c1.length < 60 || c15.length < 60) return null;

    // The parameters keep their swing names (c4/c1/c15) so every caller and the
    // Python mirror stay readable, but in scalp mode they carry the 30M / 15M /
    // 5M series instead. Only the horizons change: the weights below, the
    // gates, the stops and the targets are identical in both modes.
    final String bTf = mode.biasTf;
    final String zTf = mode.zoneTf;
    final String gTf = mode.triggerTf;

    final t4 = analyzeLong(bTf, c4, c4Long ?? c4);
    final t1 = analyzeLong(zTf, c1, c1Long ?? c1);
    final t15 = analyze(gTf, c15);
    final px = c15.last.close;
    if (px <= 0) return null;

    // Movement per bar on the trigger timeframe, in percent of price. Measured
    // from the same candles the decision used, so the sort order and the signal
    // can never disagree about what "moving" means.
    final chop = atr(c15, period: 14) / px * 100;

    // Bias comes from the 4H structure alone. The old fallbacks (a 4H internal
    // break, or 4H "neutral" borrowing the 1H trend) injected bias that the
    // higher timeframe did not actually have.
    final bull4 = t4.trend > 0;
    final bear4 = t4.trend < 0;

    double buy = 0;
    double sell = 0;
    final bC = <String>[];
    final sC = <String>[];

    if (bull4) {
      buy += 30;
      bC.add('$bTf bullish bias');
    }
    if (bear4) {
      sell += 30;
      sC.add('$bTf bearish bias');
    }

    final buyOb = buyZone(t1.obs, px);
    final sellOb = sellZone(t1.obs, px);

    // Structure floor: the nearest still-valid order block decides which side
    // is blocked. A bearish OB overhead means the bullish case cannot be
    // stronger, a bullish OB underneath means the bearish case cannot be.
    // Without this the zone bonus only ever fired for the side the 4H bias
    // already favoured — the reason live data produced 10 SELL and 0 BUY.
    final OrderBlock? nearestOb = nearestObTo(t1.obs, px);
    final bool bullBlocked = nearestOb != null &&
        nearestOb.type == 'bearish' &&
        px >= nearestOb.low * 0.99;
    final bool bearBlocked = nearestOb != null &&
        nearestOb.type == 'bullish' &&
        px <= nearestOb.high * 1.01;

    if (bull4 && buyOb != null) {
      buy += 25;
      bC.add('$zTf bullish OB');
    }
    if (bear4 && sellOb != null) {
      sell += 25;
      sC.add('$zTf bearish OB');
    }

    final bullFvg = t1.fvgs.any((f) =>
        f.type == 'bullish' && f.high <= px * 1.005 && f.low > px * 0.94);
    final bearFvg = t1.fvgs.any((f) =>
        f.type == 'bearish' && f.low >= px * 0.995 && f.high < px * 1.06);

    // A fair value gap counts as the zone when no order block is available.
    if (bull4 && bullFvg) {
      buy += buyOb == null ? 20 : 10;
      bC.add('$zTf bullish FVG');
    }
    if (bear4 && bearFvg) {
      sell += sellOb == null ? 20 : 10;
      sC.add('$zTf bearish FVG');
    }

    // Trigger: the freshest 15M swing break as long as price is still holding
    // above (bullish) / below (bearish) the pivot it broke. LUX renders its
    // BOS line for the whole run of bars instead of one candle, so a setup
    // that is valid at the close stays valid a few bars later; only the
    // RELAXED pass accepts the shorter internal break on its own.
    final triggerBull = t15.breakEvent == 'BULLISH' && px > t15.breakLevel;
    final triggerBear = t15.breakEvent == 'BEARISH' && px < t15.breakLevel;
    final internalBull = t15.internalFresh && t15.internalEvent == 'BULLISH';
    final internalBear = t15.internalFresh && t15.internalEvent == 'BEARISH';

    if (triggerBull) {
      buy += 20;
      bC.add(t15.breakPattern == 'CHoCH'
          ? '$gTf bullish CHoCH'
          : '$gTf bullish BOS');
    } else if (internalBull) {
      buy += 20;
      bC.add('$gTf internal bullish break');
    }
    if (triggerBear) {
      sell += 20;
      sC.add(t15.breakPattern == 'CHoCH'
          ? '$gTf bearish CHoCH'
          : '$gTf bearish BOS');
    } else if (internalBear) {
      sell += 20;
      sC.add('$gTf internal bearish break');
    }

    if (t15.volumeSpike) {
      if (bull4) {
        buy += 5;
        bC.add('$gTf volume spike');
      } else if (bear4) {
        sell += 5;
        sC.add('$gTf volume spike');
      }
    }

    // Premium/discount of the 1H swing range gates the direction. A breakout
    // above/below the range is trend continuation, not a bad location.
    final zoneNow = t1.zoneOf;
    if (zoneNow == 'Premium') {
      buy -= 25;
      sC.add('$zTf premium zone');
    }
    if (zoneNow == 'Discount') {
      sell -= 25;
      bC.add('$zTf discount zone');
    }
    if (zoneNow == 'Breakout' && bull4) {
      buy += 5;
      bC.add('$zTf breakout');
    }
    if (zoneNow == 'Breakdown' && bear4) {
      sell += 5;
      sC.add('$zTf breakdown');
    }

    final atr1 = t1.atr > 0 ? t1.atr : px * 0.01;
    final zoneLabel = t1.zoneOf;

    // 30 is a frozen 4H bias with nothing else: still not a trade.
    final threshold = relaxed ? 40.0 : 60.0;

    final bool trigBuy = triggerBull || (relaxed && internalBull);
    final bool trigSell = triggerBear || (relaxed && internalBear);

    // Record what the coin did and did not have; the scanner turns this into
    // the "kache ache" list when nothing passes.
    if (trace != null) {
      trace
        ..add(t4.trend > 0
            ? '$bTf bullish'
            : t4.trend < 0
                ? '$bTf bearish'
                : '$bTf trend nei')
        ..add(buyOb != null || sellOb != null
            ? '$zTf order block ache'
            : (bullFvg || bearFvg)
                ? '$zTf FVG ache'
                : '$zTf zone nei')
        ..add(trigBuy || trigSell
            ? '$gTf break valid'
            : (internalBull || internalBear)
                ? '$gTf internal break'
                : '$gTf trigger nei')
        ..add('score ${(buy > sell ? buy : sell).round()}/${threshold.round()}'
            '${zoneNow == 'Premium' || zoneNow == 'Discount' ? ' • $zoneNow penalty' : ''}');
      // The structure floor can veto a setup whose score already passed, and
      // the trace used to stay silent about it: the card read "score 55/40"
      // with no explanation, which looks like a bug on the device. Say which
      // gate actually rejected the trade.
      final bool scorePass = (bull4 && buy >= threshold) ||
          (bear4 && sell >= threshold);
      if (scorePass) {
        if (bull4 && !trigBuy) {
          trace.add('gate: $gTf trigger nai');
        } else if (bear4 && !trigSell) {
          trace.add('gate: $gTf trigger nai');
        } else if (bull4 && bullBlocked) {
          trace.add('gate: upore bearish $zTf OB block korche');
        } else if (bear4 && bearBlocked) {
          trace.add('gate: niche bullish $zTf OB block korche');
        } else if (buy <= sell) {
          trace.add('gate: dui dikei score soman/kom');
        }
      }
    }

    if (buy >= threshold &&
        bull4 &&
        !bear4 &&
        trigBuy &&
        !bullBlocked &&
        buy > sell) {
      double entry = px;
      double sl;

      final bullGap = t1.fvgs.where((f) =>
          f.type == 'bullish' && f.high <= px * 1.005 && f.low > px * 0.94);

      if (buyOb != null) {
        final mid = buyOb.mid;
        if ((px - mid) / px <= 0.02) entry = mid;
        sl = buyOb.low - atr1 * 0.25;
      } else if (bullGap.isNotEmpty) {
        final gap = bullGap.last;
        sl = gap.low - atr1 * 0.25;
      } else if (t15.swingLow != null) {
        sl = t15.swingLow!.price - atr1 * 0.25;
      } else {
        sl = px - atr1 * 2;
      }


      if (sl >= entry) sl = entry - atr1;
      final risk = entry - sl;
      if (risk <= 0 || risk / entry > 0.08) return null;
      // Target: the 15M swing high only when it is worth at least 1.5R,
      // otherwise 2R. A swing that sits just above entry is not an objective,
      // it is noise: live data produced a BUY with risk 3.5% and reward 0.98%
      // (RR 1:0.28) because the old test only asked "is it beyond entry?".
      // A trade must not risk more than it can win.
      final minTarget = entry + risk * kMinRR;
      final swingTarget = t15.swingHigh?.price ?? double.negativeInfinity;
      final target = swingTarget >= minTarget ? swingTarget : entry + risk * 2;

      if (t15.breakAge > 2) {
        bC.add('$gTf bullish break ${t15.breakAge} bar age');
      } else if (t15.breakAge < 0) {
        bC.add('$gTf break nai (age unknown)');
      }
      if (t4.structureConflict) {
        bC.add('Sotorkota: long-window 4H structure ulto dike');
      }

      return TradeSignal(
        symbol: sym,
        direction: 'BUY',
        price: px,
        entry: entry,
        sl: sl,
        tp: target,
        // A WATCH signal failed the strict gate, so its raw score is NOT
        // comparable to a STRICT one: both paths render as "NN% confidence",
        // yet the WATCH path only had to clear 40 instead of 60. On the device
        // that produced a relaxed card at 90% sitting above STRICT cards at
        // 70-75% -- a less reliable setup showing a bigger number.
        //
        // Cap the displayed confidence for relaxed signals just below the
        // strict threshold so the number can never claim more than the gate it
        // actually passed.
        confidence: (relaxed
                ? buy.clamp(0.0, 59.0)
                : buy.clamp(0.0, 100.0))
            .toDouble(),
        chop: chop,
        confirmations: bC,
        time: DateTime.now(),
        tf4h: t4.structure,
        tf1h: t1.structure,
        tf15m: t15.structure,
        pattern: t15.breakPattern.isEmpty ? 'BOS' : t15.breakPattern,
        zone: zoneLabel,
        eqh: t1.eqh,
        eql: t1.eql,
        watch: relaxed,
        tier: relaxed ? 'WATCH' : 'STRICT',
        mode: mode,
      );
    }

    if (sell >= threshold &&
        bear4 &&
        !bull4 &&
        trigSell &&
        !bearBlocked &&
        sell > buy) {
      double entry = px;
      double sl;

      final bearGap = t1.fvgs.where((f) =>
          f.type == 'bearish' && f.low >= px * 0.995 && f.high < px * 1.06);

      if (sellOb != null) {
        final mid = sellOb.mid;
        if ((mid - px) / px <= 0.02) entry = mid;
        sl = sellOb.high + atr1 * 0.25;
      } else if (bearGap.isNotEmpty) {
        final gap = bearGap.last;
        sl = gap.high + atr1 * 0.25;
      } else if (t15.swingHigh != null) {
        sl = t15.swingHigh!.price + atr1 * 0.25;
      } else {
        sl = px + atr1 * 2;
      }


      if (sl <= entry) sl = entry + atr1;
      final risk = sl - entry;
      if (risk <= 0 || risk / entry > 0.08) return null;
      final maxTarget = entry - risk * kMinRR;
      final swingTarget = t15.swingLow?.price ?? double.infinity;
      final target = swingTarget <= maxTarget ? swingTarget : entry - risk * 2;

      if (t15.breakAge > 2) {
        sC.add('$gTf bearish break ${t15.breakAge} bar age');
      } else if (t15.breakAge < 0) {
        sC.add('$gTf break nai (age unknown)');
      }
      if (t4.structureConflict) {
        sC.add('Sotorkota: long-window 4H structure ulto dike');
      }

      return TradeSignal(
        symbol: sym,
        direction: 'SELL',
        price: px,
        entry: entry,
        sl: sl,
        tp: target,
        confidence: (relaxed
                ? sell.clamp(0.0, 59.0)
                : sell.clamp(0.0, 100.0))
            .toDouble(),
        chop: chop,
        confirmations: sC,
        time: DateTime.now(),
        tf4h: t4.structure,
        tf1h: t1.structure,
        tf15m: t15.structure,
        pattern: t15.breakPattern.isEmpty ? 'BOS' : t15.breakPattern,
        zone: zoneLabel,
        eqh: t1.eqh,
        eql: t1.eql,
        watch: relaxed,
        tier: relaxed ? 'WATCH' : 'STRICT',
        mode: mode,
      );
    }

    return null;
  }

  // -------------------------------------------------------------------
  // 3M SCALP  (TradeMode.scalp3m)
  // -------------------------------------------------------------------
  //
  // Why this is not `multiTF` with 3M candles in every slot.
  //
  // `single3m` feeds one 3M series into bias, zone and trigger. One structure
  // break then scores +30 (bias) +25 (OB) +20 (trigger) and clears the 60 gate
  // alone. Measured on real Binance 1-minute candles (Aug-Nov 2026, 41 pairs),
  // every 3M variant of that engine is flat-to-negative after fees.
  //
  // These rules ask three questions that CANNOT be answered by the same event:
  //   trend   EMA9 > EMA21 > EMA50                 (direction only)
  //   entry   close < EMA21 and RSI 30-55 and a green bar   (is this a price?)
  //   gate    ATR(14) as % of price >= 0.80        (can the fee be paid?)
  //
  // The gate is the whole model, not a filter bolted on. The round trip costs
  // 0.25% of price; expressed in R it is `0.25 / stop_pct`. On a liquid pair a
  // 3M ATR is 0.1-0.35%, so a 1.5xATR stop is 0.15-0.5% wide and the fee alone
  // is 0.5R-1.7R per trade. Requiring the bar itself to be moving 0.8%+ only
  // approves trades whose stop is wide enough to absorb the fee.
  //
  // Measured, real candles, 0.25% round trip, charged per trade:
  //
  //   every 3M rule without the gate      f* = 0.02-0.04%  (dead at any fee)
  //   this rule, gate 0.50                f* = 0.17%
  //   this rule, gate 0.80                f* = 0.48%       (alive)
  //
  // Out-of-sample walk (train Feb-Jul, test Aug-Nov, nothing tuned on test):
  //   TEST   538 trades  WR 36.4%  net +147.5%
  //   TEST without the two biggest symbols   net  -31.7%
  //   TRAIN 240 trades  WR 36.2%  net  -1.5%   (six months, flat)
  //   same gate, random entries  TEST net -715.3%
  //
  // So: the rule beats random by ~0.9% per trade, which is the gate earning its
  // keep, but it is NOT reliably profitable -- remove two coins and the sample
  // goes negative. The card says so; the mode is shipped as a research tool
  // with a visible, honest fee line, not as a promise.
  // -------------------------------------------------------------------

  /// Deprecated by the v19.0 rule change, kept so old code and the Python
  /// mirror keep compiling. The 3M rule no longer has an ATR gate: the user
  /// replaced the whole rule set with BOS + MACD on 3M only.
  static const double scalp3mGate = 0.80;

  /// Reject stops narrower than this (percent of price). 0.25% fee on a 0.2%
  /// stop is 1.25R of cost before the trade moves.
  static const double scalp3mMinStop = 0.35;

  /// Reward:risk for the 3M rule. 3R lost less than 2R or 1.5R on the same
  /// 6 135 trades (see NOTES §35) -- but all three lost, so this is "least
  /// bad", not "good".
  static const double scalp3mRR = 3.0;

  /// Wilder RSI(14) aligned to the tail of [closes], newest value last.
  static List<double> rsi(List<double> closes, [int period = 14]) {
    if (closes.length <= period) return <double>[];
    var gains = 0.0, losses = 0.0;
    for (var i = 1; i <= period; i++) {
      final d = closes[i] - closes[i - 1];
      if (d > 0) {
        gains += d;
      } else {
        losses -= d;
      }
    }
    var ag = gains / period, al = losses / period;
    final out = <double>[
      al == 0 ? 100.0 : 100 - 100 / (1 + ag / al),
    ];
    for (var i = period + 1; i < closes.length; i++) {
      final d = closes[i] - closes[i - 1];
      ag = (ag * (period - 1) + (d > 0 ? d : 0)) / period;
      al = (al * (period - 1) + (d < 0 ? -d : 0)) / period;
      out.add(al == 0 ? 100.0 : 100 - 100 / (1 + ag / al));
    }
    return out;
  }

  /// Wilder ATR(14) aligned so the LAST value belongs to the last bar.
  ///
  /// `atr()` above is the simple average of the last [period] true ranges,
  /// which is what the SMC engine was always measured with and must not change.
  /// The 3M scalp rules were measured with the Wilder form, so they use this
  /// one: measurement and shipped code have to be the same function, or the
  /// number in the release note describes code that is not on the phone.
  static double atrWilder(List<Candle> c, {int period = 14}) {
    if (c.length < period + 1) return 0;
    final tr = <double>[
      c[0].high - c[0].low,
    ];
    for (var i = 1; i < c.length; i++) {
      tr.add(max(
        c[i].high - c[i].low,
        max((c[i].high - c[i - 1].close).abs(), (c[i].low - c[i - 1].close).abs()),
      ));
    }
    var v = 0.0;
    for (var i = 1; i <= period; i++) {
      v += tr[i];
    }
    v /= period;
    for (var i = period + 1; i < tr.length; i++) {
      v = (v * (period - 1) + tr[i]) / period;
    }
    return v;
  }

  /// The 3M SCANNER.
  ///
  /// User's specification, 2026-11-11 (second revision), verbatim:
  ///
  ///     "ei mode a just 3 minutes timeframe a analyse korba j 5 candle er
  ///      modhe a bos hoyse a ki nh r macd a green ace a ki nh. Jodi 2 tai mil
  ///      takhe a tahole top a asbe oii coin gula r jodi just 1 ta match kore a
  ///      tahole a niche a asbe coin gula. Besi up-down kore a sei coin gula
  ///      opur er dikh a takhbe. Just 2 dollars er nice a j coin gula ace a sei
  ///      gula filter korba. R kono kisu add korba nh, ami kono doroner entry
  ///      or exit plan chai nh."
  ///
  /// So this is NOT a trade setup any more. There is no entry, no stop, no
  /// target, no R:R, no hold time -- none is produced, none is displayed, and
  /// none can be inferred from the card. Two independent 3M facts are counted:
  ///
  ///     BOS  -- a break of structure within the last [bos5mLookback] candles
  ///     MACD -- line above signal, histogram not falling ("green")
  ///
  ///     both  -> the coin goes in the TOP section
  ///     one   -> the coin goes in the BOTTOM section
  ///     none  -> not a signal; it is named in the quiet list instead
  ///
  /// Ordering is movement first (ATR% per bar, descending) inside each section,
  /// and the price filter is the user's: coins above [kScalp3mMaxPrice] are
  /// dropped before scoring.
  ///
  /// The previous estimate-based version of this function took a min-stop gate
  /// and produced a confidence; both are gone, because both were entry logic.
  ///
  /// Measured on 391 680 real 3M bars (12 pairs, Sep-Nov 2026) with the 5-candle
  /// window: 12.3% of bars match both, and a scan of ~120 coins puts ~15 on top
  /// (roughly 49 on a 400-coin scan); 8% of scans have an empty top.
  static TradeSignal? scalp3m(
    String sym,
    List<Candle> c3, {
    void Function(String stage)? onRefuse,
  }) {
    void no(String stage) {
      if (onRefuse != null) onRefuse(stage);
    }

    if (c3.length < 60) {
      no('data');
      return null;
    }
    final px = c3.last.close;
    if (px <= 0) {
      no('data');
      return null;
    }

    // ------------------------------------------------ the user's price filter
    // Dropping the coin here is the user's own instruction ("just 2 dollars er
    // nice a j coin gula ace a sei gula filter korba"), so it is a filter and
    // not a sort. It is counted separately so the screen can say how many coins
    // it removed -- a filter that silently shrinks the list is the bug §34 was.
    if (px > kScalp3mMaxPrice) {
      no('price');
      return null;
    }

    // ---------------------------------------------------------- fact 1: BOS
    final bos = bosOn(c3, lookback: bos5mLookback);
    // --------------------------------------------------------- fact 2: MACD
    final m = macd(<double>[for (final k in c3) k.close]);
    if (m == null) {
      no('data');
      return null;
    }
    final line = m[0], sig = m[1], hist = m[2], prevHist = m[3];
    final green = line > sig && hist >= prevHist;

    final bosOk = bos != null;
    if (!bosOk && !green) {
      no('none');
      return null;
    }

    // Movement first: the user wants the coins that move most at the top, and
    // ATR% is the only reading here that does not imply a direction.
    final a14 = atrWilder(c3, period: 14);
    if (a14 <= 0) {
      no('data');
      return null;
    }
    final atrPct = a14 / px * 100;
    final both = bosOk && green;

    final facts = <String>[
      bosOk ? 'BOS: ${bos > 0 ? 'up' : 'down'} within $bos5mLookback candles'
          : 'BOS: none in the last $bos5mLookback candles',
      green ? 'MACD: green (line > signal, histogram not falling)'
          : 'MACD: not green',
    ];

    return TradeSignal(
      symbol: sym,
      // The bias word is the BOS direction when there is one; it is a LABEL,
      // not a recommendation -- no entry is implied anywhere on this card.
      direction: bos == null ? (green ? 'BUY' : 'BUY') : (bos > 0 ? 'BUY' : 'SELL'),
      price: px,
      // Entry/stop/target are set equal to price and 0 because this scanner
      // does not produce a trade plan. Zero is the honest value: a number here
      // would be an invented plan the user explicitly asked not to have.
      entry: px,
      sl: 0,
      tp: 0,
      // Not a probability -- there is nothing to have confidence in. It carries
      // the movement reading so the existing sort and card keep working.
      confidence: atrPct.clamp(0.0, 100.0).toDouble(),
      chop: atrPct,
      confirmations: facts,
      time: DateTime.now(),
      tf4h: '3M',
      tf1h: 'BOS ${bosOk ? 'yes' : 'no'}',
      tf15m: 'MACD ${green ? 'green' : 'off'}',
      pattern: both ? 'BOS + MACD' : (bosOk ? 'BOS' : 'MACD'),
      zone: '',
      eqh: false,
      eql: false,
      watch: !both,
      tier: both ? 'TOP' : 'BOTTOM',
      mode: TradeMode.scalp3m,
      bos5: bosOk,
      macdGreen: green,
    );
  }


  /// The most recent BOS on ONE series, as a direction, if it is fresh.
  ///
  /// `lookback` is the freshness window in bars: a BOS older than that is not
  /// "recently hoya" any more and the coin is refused.
  ///
  /// A pivot needs `k` bars of confirmation, so it becomes knowable at
  /// pivot+k. Reading it earlier would be look-ahead -- the measurement in
  /// NOTES §35 uses the same rule, so the app and the backtest cannot disagree
  /// about what the rule was.
  static int? bosOn(List<Candle> c, {int lookback = 3, int k = 2}) {
    final n = c.length;
    if (n < 30) return null;
    // Confirmed pivots, walked forward once.
    //
    // Two parallel lists rather than a list of records: this app builds on
    // Flutter 3.16 with the project's language version, where the `records`
    // feature is not enabled, and `(int, double)` is a compile error there.
    // The CI analyzer caught it; tree-sitter cannot.
    final hiAt = <int>[];
    final hiPx = <double>[];
    final loAt = <int>[];
    final loPx = <double>[];
    for (var i = k; i < n - k; i++) {
      var isHi = true, isLo = true;
      for (var j = i - k; j <= i + k; j++) {
        if (j == i) continue;
        if (c[j].high >= c[i].high) isHi = false;
        if (c[j].low <= c[i].low) isLo = false;
      }
      if (isHi) {
        hiAt.add(i);
        hiPx.add(c[i].high);
      }
      if (isLo) {
        loAt.add(i);
        loPx.add(c[i].low);
      }
    }
    var hiI = 0, loI = 0;
    double? prevHi, prevLo;
    int? lastDir, lastBar;
    for (var i = 0; i < n; i++) {
      while (hiI < hiAt.length && hiAt[hiI] + k <= i) {
        prevHi = hiPx[hiI];
        hiI++;
      }
      while (loI < loAt.length && loAt[loI] + k <= i) {
        prevLo = loPx[loI];
        loI++;
      }
      if (prevHi != null && c[i].close > prevHi) {
        lastDir = 1;
        lastBar = i;
        prevHi = null;
      } else if (prevLo != null && c[i].close < prevLo) {
        lastDir = -1;
        lastBar = i;
        prevLo = null;
      }
    }
    if (lastDir == null || lastBar == null) return null;
    if (n - 1 - lastBar > lookback) return null;
    return lastDir;
  }


  /// Fallback candidate: the higher timeframe has a direction and the 15M has
  /// a live break, but the zone or the score is still missing. Strict SMC
  /// says do not trade this; it is still the honest answer to "what is the
  /// engine watching right now" and keeps a quiet scan useful.
  static TradeSignal? radar(
    String sym,
    List<Candle> c4,
    List<Candle> c1,
    List<Candle> c15, {
    List<Candle>? c4Long,
    List<Candle>? c1Long,
    TradeMode mode = TradeMode.swing,
  }) {
    if (c4.length < 60 || c1.length < 60 || c15.length < 60) return null;

    final String bTf = mode.biasTf;
    final String zTf = mode.zoneTf;
    final String gTf = mode.triggerTf;

    final t4 = analyzeLong(bTf, c4, c4Long ?? c4);
    final t1 = analyzeLong(zTf, c1, c1Long ?? c1);
    final t15 = analyze(gTf, c15);
    final px = c15.last.close;
    if (px <= 0) return null;

    if (t4.trend == 0) return null;

    final bull = t4.trend > 0;
    final trigOk = bull
        ? (t15.breakEvent == 'BULLISH' && px > t15.breakLevel) ||
            (t15.internalFresh && t15.internalEvent == 'BULLISH')
        : (t15.breakEvent == 'BEARISH' && px < t15.breakLevel) ||
            (t15.internalFresh && t15.internalEvent == 'BEARISH');
    if (!trigOk) return null;

    final atr1 = t1.atr > 0 ? t1.atr : px * 0.01;
    final ob = bull ? buyZone(t1.obs, px) : sellZone(t1.obs, px);
    final gap = t1.fvgs.where((f) => bull
        ? (f.type == 'bullish' && f.high <= px * 1.005 && f.low > px * 0.94)
        : (f.type == 'bearish' &&
            f.low >= px * 0.995 &&
            f.high < px * 1.06));
    final swing = bull ? t15.swingLow : t15.swingHigh;

    double sl;
    if (ob != null) {
      sl = bull ? ob.low - atr1 * 0.25 : ob.high + atr1 * 0.25;
    } else if (gap.isNotEmpty) {
      sl = bull ? gap.last.low - atr1 * 0.25 : gap.last.high + atr1 * 0.25;
    } else if (swing != null) {
      sl = bull ? swing.price - atr1 * 0.25 : swing.price + atr1 * 0.25;
    } else {
      sl = bull ? px - atr1 * 2 : px + atr1 * 2;
    }

    final risk = (px - sl).abs();
    if (risk <= 0 || risk / px > 0.08) return null;
    if (risk / px < kMinStopPct) return null;

    final tp = bull
        ? (t15.swingHigh != null && t15.swingHigh!.price > px * 1.005
            ? t15.swingHigh!.price
            : px + risk * 2)
        : (t15.swingLow != null && t15.swingLow!.price < px * 0.995
            ? t15.swingLow!.price
            : px - risk * 2);

    final why = <String>[
      bull ? '$bTf bullish bias' : '$bTf bearish bias',
      if (t15.breakEvent.isNotEmpty)
        '$gTf ${bull ? 'bullish' : 'bearish'} '
            '${t15.breakPattern.isEmpty ? 'BOS' : t15.breakPattern}'
      else
        '$gTf internal break',
      if (ob == null && gap.isEmpty) 'Zone nei — wait koro' else 'Zone ache',
      if (t1.zoneOf == 'Premium' || t1.zoneOf == 'Discount')
        '${t1.zoneOf} penalty',
    ];

    return TradeSignal(
      symbol: sym,
      direction: bull ? 'BUY' : 'SELL',
      price: px,
      entry: px,
      sl: sl,
      tp: tp,
      confidence: 0,
      chop: atr(c15, period: 14) / px * 100,
      confirmations: why,
      time: DateTime.now(),
      tf4h: t4.structure,
      tf1h: t1.structure,
      tf15m: t15.structure,
      pattern: t15.breakPattern.isEmpty ? 'BOS' : t15.breakPattern,
      zone: t1.zoneOf,
      eqh: t1.eqh,
      eql: t1.eql,
      watch: true,
      tier: 'RADAR',
      mode: mode,
    );
  }
}

// =====================================================================
// BACKTEST
//
// Walks the candle history bar by bar, asks the same engine for a signal at
// each close (seeing only candles up to that bar), then follows the trade
// forward to see whether the stop or the target was hit first.
// =====================================================================

class BacktestTrade {
  BacktestTrade({
    required this.symbol,
    required this.isBuy,
    required this.entry,
    required this.sl,
    required this.tp,
    required this.confidence,
    required this.watch,
    required this.outcome,
    required this.rMultiple,
  });

  final String symbol;
  final bool isBuy;
  final double entry;
  final double sl;
  final double tp;
  final double confidence;
  final bool watch;

  /// 'TP' | 'SL' | 'OPEN'
  final String outcome;
  final double rMultiple;
}

class BacktestResult {
  BacktestResult({
    required this.symbol,
    required this.trades,
    required this.barsUsed,
    required this.startTime,
    required this.endTime,
  });

  final String symbol;
  final List<BacktestTrade> trades;
  final int barsUsed;
  final DateTime startTime;
  final DateTime endTime;

  int get total => trades.length;
  int get closed => trades.where((t) => t.outcome != 'OPEN').length;

  /// Trades still running at the end of the sample. They carry no information
  /// about the edge and must never be folded into the win rate.
  int get open => trades.where((t) => t.outcome == 'OPEN').length;
  int get wins => trades.where((t) => t.outcome == 'TP').length;
  int get losses => trades.where((t) => t.outcome == 'SL').length;

  /// Percent of decided trades that hit the target.
  double get winRate => closed == 0 ? 0 : wins / closed * 100;

  /// Sum of R multiples over decided trades.
  double get totalR =>
      trades.where((t) => t.outcome != 'OPEN').fold<double>(0, (a, t) => a + t.rMultiple);

  double get avgR => closed == 0 ? 0 : totalR / closed;

  /// Expectancy in R per trade.
  double get expectancy => avgR;

  /// Average reward:risk actually taken. The target is the 15M swing or 2R, so
  /// this reflects the structure, and it belongs next to the win rate.
  double get avgRR {
    final done = trades.where((t) => t.outcome != 'OPEN');
    if (done.isEmpty) return 0;
    double sum = 0;
    for (final t in done) {
      final risk = (t.entry - t.sl).abs();
      if (risk > 0) sum += (t.tp - t.entry).abs() / risk;
    }
    return sum / done.length;
  }

  /// Win rate needed to break even at that reward:risk, in percent.
  double get breakEvenWinRate {
    final rr = avgRR;
    if (rr <= 0) return 0;
    return 1 / (1 + rr) * 100;
  }

  /// Win rate if each trade were charged [costPct] of entry in fees+spread,
  /// expressed in R. The screen quotes it so a 75% win rate is never mistaken
  /// for profit.
  double winRateAfterCost(double costPct) {
    final done = trades.where((t) => t.outcome != 'OPEN').toList();
    if (done.isEmpty) return 0;
    int wins = 0;
    for (final t in done) {
      final risk = (t.entry - t.sl).abs();
      if (risk <= 0) continue;
      final costR = (t.entry * costPct / 100) / risk;
      final r = t.outcome == 'TP'
          ? (t.tp - t.entry).abs() / risk - costR
          : -1.0 - costR;
      if (r > 0) wins++;
    }
    return wins / done.length * 100;
  }

  /// Total R after the same cost.
  double totalRAfterCost(double costPct) {
    double sum = 0;
    for (final t in trades.where((t) => t.outcome != 'OPEN')) {
      final risk = (t.entry - t.sl).abs();
      if (risk <= 0) continue;
      final costR = (t.entry * costPct / 100) / risk;
      sum += (t.outcome == 'TP' ? (t.tp - t.entry).abs() / risk : -1.0) - costR;
    }
    return sum;
  }


  int get strictTotal => trades.where((t) => !t.watch).length;
  int get strictWins =>
      trades.where((t) => !t.watch && t.outcome == 'TP').length;
  int get strictClosed =>
      trades.where((t) => !t.watch && t.outcome != 'OPEN').length;
  /// Win rate of STRICT-only signals: the higher-quality subset.
  double get strictWinRate =>
      strictClosed == 0 ? 0 : strictWins / strictClosed * 100;

  int get currentStreak {
    int streak = 0;
    for (final t in trades.reversed) {
      if (t.outcome == 'TP') {
        if (streak < 0) break;
        streak++;
      } else if (t.outcome == 'SL') {
        if (streak > 0) break;
        streak--;
      }
    }
    return streak;
  }
}

class Backtester {
  /// How many bars of history the simulation keeps feeding the engine.
  static const int window = 200;

  /// 4H bars fed to the bias check (deeper than 1H/15M, see the scanner).
  static const int window4h = 400;

  /// Walks forward from the first bar that has enough history, asking the
  /// engine for a signal at every bar. A trade is only opened when no earlier
  /// trade is still open, which keeps the statistics honest (no overlapping
  /// copies of the same move). Trades that never resolved are kept and
  /// reported separately instead of being hidden inside a win rate.
  static BacktestResult run(
    String symbol,
    List<Candle> c4,
    List<Candle> c1,
    List<Candle> c15, {
    int step = 1,
    // A 12000-bar sample spans ~125 days and can produce thousands of trades.
    // The cap is high on purpose: a deeper sample only means something if it is
    // not truncated.
    int maxTrades = 2000,
  }) {
    final trades = <BacktestTrade>[];
    final n = c15.length;
    final start = window;
    if (n <= start + 5) {
      return BacktestResult(
        symbol: symbol,
        trades: trades,
        barsUsed: n,
        startTime: DateTime.fromMillisecondsSinceEpoch(
          n == 0 ? 0 : c15.last.openTime,
        ),
        endTime: DateTime.now(),
      );
    }

    int openUntil = -1;
    int lastSignalBar = -start;

    for (int i = start; i < n - 1; i += step) {
      if (i <= openUntil) continue; // still in a trade
      if (i - lastSignalBar < 2) continue; // do not spam the same move

      final w15 = c15.sublist(i - window, i + 1);
      final w1 = _aligned(c1, c15[i].closeTime, window);
      // A recently listed coin may not have 400 closed 4H bars behind this
      // timestamp; fall back to a shorter bias window instead of silently
      // producing zero trades.
      final w4 = _aligned(c4, c15[i].closeTime, window4h) ??
          _aligned(c4, c15[i].closeTime, 200) ??
          _aligned(c4, c15[i].closeTime, 120);
      if (w1 == null || w4 == null) continue;

      // The long-window structure check is part of live scoring, so the
      // simulation must see it too.
      final l1 = _aligned(c1, c15[i].closeTime, window * 3);
      final l4 = _aligned(c4, c15[i].closeTime, window4h * 2);

      var sig = Engine.multiTF(symbol, w4, w1, w15, c4Long: l4, c1Long: l1);
      sig ??= Engine.multiTF(symbol, w4, w1, w15,
          c4Long: l4, c1Long: l1, relaxed: true);
      if (sig == null) continue;

      // Follow the trade on the 15M series until its stop or target.
      String outcome = 'OPEN';
      double rMult = 0;
      int exitBar = n - 1;
      for (int j = i + 1; j < n; j++) {
        final bar = c15[j];
        final hitSl = sig.isBuy ? bar.low <= sig.sl : bar.high >= sig.sl;
        final hitTp = sig.isBuy ? bar.high >= sig.tp : bar.low <= sig.tp;
        if (hitSl) {
          // A bar that touches both is counted as a loss.
          outcome = 'SL';
          rMult = -1;
          exitBar = j;
          break;
        }
        if (hitTp) {
          outcome = 'TP';
          rMult = (sig.tp - sig.entry).abs() / (sig.sl - sig.entry).abs();
          exitBar = j;
          break;
        }
      }
      openUntil = exitBar;

      trades.add(BacktestTrade(
        symbol: symbol,
        isBuy: sig.isBuy,
        entry: sig.entry,
        sl: sig.sl,
        tp: sig.tp,
        confidence: sig.confidence,
        watch: sig.watch,
        outcome: outcome,
        rMultiple: rMult,
      ));
      lastSignalBar = i;

      if (trades.length >= maxTrades) break;
    }

    final first = c15[start];
    return BacktestResult(
      symbol: symbol,
      trades: trades,
      barsUsed: n,
      startTime: DateTime.fromMillisecondsSinceEpoch(first.openTime),
      endTime: DateTime.fromMillisecondsSinceEpoch(c15.last.openTime),
    );
  }

  /// Last [count] candles of [series] that closed at or before [time].
  static List<Candle>? _aligned(List<Candle> series, int time, int count) {
    int end = series.length;
    for (int i = series.length - 1; i >= 0; i--) {
      if (series[i].closeTime <= time) {
        end = i + 1;
        break;
      }
    }
    if (end < count) return null;
    return series.sublist(end - count, end);
  }
}

// =====================================================================
// UI
// =====================================================================

String fmtPrice(double v) {
  if (v >= 1000) return v.toStringAsFixed(2);
  if (v >= 1) return v.toStringAsFixed(4);
  if (v >= 0.01) return v.toStringAsFixed(5);
  if (v >= 0.0001) return v.toStringAsFixed(7);
  return v.toStringAsFixed(9);
}

String fmtPct(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}%';

String timeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return '${d.inSeconds}s ago';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  return '${d.inHours}h ago';
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HS();
}

/// One coin's engine result, kept until its chunk is committed.
class _CoinOut {
  _CoinOut(this.sig, this.nearMiss, [this.quiet]);

  final TradeSignal? sig;
  final String? nearMiss;

  /// Set only when the coin produced NO signal: symbol + movement per bar.
  /// The 3M mode shows these at the bottom of the list rather than dropping
  /// them, so "no setup" and "not looked at" cannot be confused.
  final _Quiet? quiet;
}

class _Quiet {
  _Quiet(this.symbol, this.chop, this.trend, {this.why = ''});

  final String symbol;
  final double chop;
  final String trend;

  /// Which condition refused this coin, in the mode's own words.
  ///
  /// The empty-state header counts refusals per stage, but the rows underneath
  /// printed only the trend -- so a bearish coin sat under a header about
  /// direction while it had actually been refused for being too quiet. The
  /// count and the rows now come from the same fact.
  final String why;
}

class _HS extends State<HomeScreen> {
  final List<TradeSignal> _signals = <TradeSignal>[];

  /// Coins that produced no setup. Only filled in the 3M mode, shown under the
  /// signals so a quiet market is visible rather than absent.
  final List<_Quiet> _quiets = <_Quiet>[];

  /// Per-coin engine output for the current scan, committed in chunks.
  /// Indexes line up with the coin list so a chunk commit is a plain copy.
  List<_CoinOut?> _scratch = <_CoinOut?>[];

  bool _loading = true;
  String _msg = 'Starting...';
  String _filter = 'ALL';
  int _done = 0;
  int _total = 0;
  int _failed = 0;
  int _noBias = 0;
  int _biasNoSetup = 0;

  /// Gemini config and per-symbol reviews.
  ///
  /// `_gemini` is loaded once and saved only from the settings sheet; the
  /// reviews are keyed by symbol so a re-scan does not re-ask (and does not
  /// re-bill) for a setup that has not changed.
  GeminiConfig _gemini = const GeminiConfig();
  final Map<String, GeminiNote> _gNotes = <String, GeminiNote>{};
  final Set<String> _gInFlight = <String>{};
  GeminiNote? _gScanNote;

  /// Why the 3M scalp refused each coin, by condition. Filled only in that
  /// mode; the empty-state message reads it so a blank screen names the stage
  /// that ate the scan instead of guessing.
  final Map<String, int> _scalp3mWhy = <String, int>{};
  int _tooYoung = 0;

  /// Coins analysed with a shorter 4H window than the ideal 400 bars, because
  /// the wide universe reached into younger listings. They are still analysed —
  /// a shorter bias window is a weaker read, not a missing one.
  int _short4h = 0;

  /// Coins whose series was too old to be a live market (delisted pairs still
  /// answer /klines with historical bars).
  int _delisted = 0;
  final List<String> _nearMiss = <String>[];
  int _scanId = 0;

  /// Which horizon stack this screen is scanning. Changing it restarts the
  /// scan, because the candles and the cache are per-timeframe.
  TradeMode _mode = TradeMode.swing;
  String _feed = '';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _loadGemini();
    run();
    _restartTimer();
  }

  Future<void> _loadGemini() async {
    final c = await GeminiStore.load();
    if (!mounted) return;
    setState(() => _gemini = c);
    // A key already on the device should review the list that is on screen,
    // not wait for the user to notice a settings button.
    if (c.usable && c.autoReview) _autoReview();
  }

  Future<void> _saveGemini(GeminiConfig c) async {
    await GeminiStore.save(c);
    if (!mounted) return;
    setState(() {
      _gemini = c;
      // A changed key or model invalidates every stored review.
      _gNotes.clear();
      _gScanNote = null;
    });
    if (c.usable && c.autoReview) _autoReview();
  }

  /// Auto-refresh cadence follows the mode.
  ///
  /// A 3M mode that only re-scanned every 5 minutes would be 100 minutes late
  /// on a signal it claims to give "as soon as the candle closes", so the 3M
  /// mode refreshes on its own bar boundary. The scan itself takes ~90 s cold,
  /// which is why this is a floor and not a promise: a scan is never queued
  /// while one is already running.
  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(
      _mode.isSingleTimeframe || _mode.isScalp3m
          ? const Duration(minutes: 3)
          : const Duration(minutes: 5),
      (_) {
        if (!_loading) run();
      },
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> run() async {
    final id = ++_scanId;
    MarketData.resetCacheStats();

    if (mounted) {
      setState(() {
        _loading = true;
        _signals.clear();
        _quiets.clear();
        _msg = 'Top movers khujchi...';
        _feed = '';
        _done = 0;
        _total = 0;
        _failed = 0;
        _noBias = 0;
        _biasNoSetup = 0;
        _scalp3mWhy.clear();
        _tooYoung = 0;
        _short4h = 0;
        _delisted = 0;
        _nearMiss.clear();
        MarketData.resetFunnel();
      });
    }

    try {
      final coins = await MarketData.marketScan(
        gainers: MarketData.scanTarget ~/ 2,
        losers: MarketData.scanTarget ~/ 2,
        // 3M ranks the universe by how much each coin actually moves, so the
        // 400 slots go to markets a 3-minute hold can work.
        byVolatility:
            _mode == TradeMode.single3m || _mode == TradeMode.scalp3m,
      );
      if (id != _scanId || !mounted) return;

      _scratch = List<_CoinOut?>.filled(coins.length, null);

      setState(() {
        _feed = MarketData.activeFeed;
        _total = coins.length;
        // Say where the universe came from. 35 coins out of a 300-coin scan is
        // a data problem, not a signal problem, and the numbers that prove it
        // belong on the screen: raw tickers -> tradable -> picked.
        final raw = MarketData.lastRawTickers;
        final tradable = MarketData.lastTradable;
        _msg = '${coins.length} coins found (${MarketData.activeFeed}) '
            '[$raw ticker → $tradable tradable]. Analyzing...';
      });

      if (coins.isEmpty) {
        if (mounted) {
          setState(() {
            _loading = false;
            _msg = 'Kono coin pawa jay nai. Abar try koro.';
          });
        }
        return;
      }

      // Requests in flight. This is no longer a rate-limit control: every
      // Binance klines call already takes a slot from the rolling weight
      // budget, so extra workers only add concurrency, never request rate.
      // 6 keeps a 300-coin scan near 90 s on a cold cache without bursty
      // behaviour that looks like an attack to the exchange.
      final workers = coins.length > 200 ? 8 : (coins.length > 120 ? 6 : 4);

      // Coins are analysed in chunks: each chunk is committed to the list as a
      // whole. Analysing 300 coins in one setState per coin rebuilds the list
      // thousands of times; more importantly, a partial list is replaced at
      // chunk boundaries so the user is never left staring at an empty screen
      // for a whole wide scan.
      const int chunk = 25;
      int commitFrom = 0;
      int frontier = 0;
      final finished = List<bool>.filled(coins.length, false);

      void commit({required bool finalChunk}) {
        final upto = frontier;
        for (var k = commitFrom; k < upto; k++) {
          final got = _scratch[k];
          if (got == null) continue;
          if (got.sig != null) _signals.add(got.sig!);
          if (got.nearMiss != null) _nearMiss.add(got.nearMiss!);
          if (got.quiet != null) _quiets.add(got.quiet!);
        }
        commitFrom = upto;
        if (!finalChunk) return;
        int rank(TradeSignal t) =>
            t.tier == 'STRICT' ? 2 : (t.tier == 'WATCH' ? 1 : 0);
        _signals.sort((a, b) {
          final r = rank(b).compareTo(rank(a));
          if (r != 0) return r;
          // The 3M scanner has two sections: both facts (TOP) above one fact
          // (BOTTOM), and inside each, the coin that moves most first.
          if (a.mode == TradeMode.scalp3m && b.mode == TradeMode.scalp3m) {
            final ac = (a.bos5 ? 1 : 0) + (a.macdGreen ? 1 : 0);
            final bc = (b.bos5 ? 1 : 0) + (b.macdGreen ? 1 : 0);
            if (ac != bc) return bc.compareTo(ac);
            final c = b.chop.compareTo(a.chop);
            if (c != 0) return c;
          }
          // Within a tier, the busiest coin first. On the 3M stack the whole
          // point of the mode is movement, so a 70% signal on a coin that moves
          // 0.9% a bar outranks a 70% on one that moves 0.15% -- the second is
          // not tradeable at the same size and its target is inside the fee.
          // Other modes keep confidence as the tiebreak so their ordering does
          // not change.
          if (a.mode == TradeMode.single3m || a.mode == TradeMode.scalp3m) {
            final c = b.chop.compareTo(a.chop);
            if (c != 0) return c;
          }
          return b.confidence.compareTo(a.confidence);
        });
        _quiets.sort((a, b) => b.chop.compareTo(a.chop));
        _loading = false;
      }

      int next = 0;

      Future<void> worker() async {
        while (true) {
          final i = next;
          next++;
          if (i >= coins.length) return;
          if (id != _scanId || !mounted) return;

          final sym = coins[i].symbol;
          try {
            // Request exactly what the engine consumes, not 600 bars "just in
            // case". Binance bills klines by `limit`: <=500 costs weight 2,
            // 501-1000 costs 5. At 600 bars a 300-coin scan is 4500 weight
            // (3.2x the 1200/min budget), which rate-limits the scan and makes
            // coins fail. At 500/500/400 it is 1800, and 1200 once the 4H
            // cache is warm.
            // The trigger timeframe is fetched FIRST so the slow (bias) series
            // can be rebuilt from its fresh tail, which is what makes the 4H
            // cache possible. In swing mode that is 15m -> 4h; in scalp mode
            // 5m -> 30m (and 15m for the zone series).
            final trigTf = _mode.triggerTf.toLowerCase();
            final biasTf = _mode.biasTf.toLowerCase();
            final zoneTf = _mode.zoneTf.toLowerCase();
            // Single-timeframe mode fetches ONE series and reuses it for all
            // three slots. Fetching the same 3M candles three times would be
            // three times the weight for the same bytes, and could hand the
            // engine three series that disagree by a bar.
            final List<Candle> c15;
            final List<Candle> c4;
            final List<Candle> c1;
            if (_mode.isSingleTimeframe || _mode.isScalp3m) {
              // One 3M series, and only one. As of v19.0 the 3M rule is
              // BOS + MACD on 3M bars -- there is no second timeframe to
              // fetch, and fetching one would be a bug, not a feature.
              c15 = await MarketData.candles(sym, trigTf, 500, scan: true);
              c4 = c15;
              c1 = c15;
            } else {
              c15 = await MarketData.candles(sym, trigTf, 500, scan: true);
              c4 = await MarketData.candles(sym, biasTf, 400,
                  liveFrom: c15, scan: true);
              c1 = await MarketData.candles(sym, zoneTf, 500, scan: true);
            }

            if (id != _scanId || !mounted) return;

            // A delisted pair still serves history. Reject it here instead of
            // scoring year-old candles as if they were today's.
            // One series in the single-timeframe modes: check it once with the
            // tight bar age, not with the 4H/1H slacks.
            if (_mode.isSingleTimeframe || _mode.isScalp3m) {
              if (!MarketData.isLive(c15, '15m')) {
                if (mounted) setState(() => _delisted++);
                return;
              }
            } else if (!MarketData.isLive(c15, '15m') ||
                !MarketData.isLive(c4, '4h') ||
                !MarketData.isLive(c1, '1h')) {
              if (mounted) setState(() => _delisted++);
              return;
            }

            List<Candle> tail(List<Candle> c, int n) =>
                c.length <= n ? c : c.sublist(c.length - n);

            // 4H structure needs more bars than the rest: with the LUX length
            // of 50 a 200-bar window holds under one pivot per side, which is
            // why almost every coin came back with "no 4H trend". Measured on
            // simulated data: 200 bars -> 47% bias, 400 bars -> 75%.
            final w4 = tail(c4, 400);
            final w1 = tail(c1, 200);
            final w15 = tail(c15, 200);

            // A wide universe pulls in young listings whose 4H series is
            // shorter than one swing (the engine needs 60 bars, the bias
            // window wants 400). Counting those as "no 4H trend" would make
            // the empty-state explanation lie, so they are counted apart.
            // The engine needs 60 bars to form a swing at all; the bias window
            // ideally holds 400. Between 60 and 120 held bars the 4H read is
            // weaker but real, and skipping those coins is what used to turn a
            // 300-coin universe into a smaller one again — the quiet tier is
            // exactly where young listings live.
            if (c4.length < 60) {
              if (mounted) setState(() => _tooYoung++);
            } else if (_mode.isScalp3m) {
              // Own path: no SMC scoring, no radar, no bias analysis.
              String? refused;
              var sig3 = Engine.scalp3m(
                sym,
                w15,
                onRefuse: (stage) {
                  refused = stage;
                  _scalp3mWhy[stage] = (_scalp3mWhy[stage] ?? 0) + 1;
                },
              );
              if (sig3 != null &&
                  coins[i].quoteVolume <= MarketData.preferredVolume) {
                sig3 = sig3.asThin();
              }
              _Quiet? quiet3;
              if (sig3 == null && w15.length > 20) {
                final px3 = w15.last.close;
                // Wilder, exactly like the gate. A simple ATR here would print
                // a different percentage than the one that decided the refusal.
                final a3 = Engine.atrWilder(w15, period: 14);
                final cl = <double>[for (final k in w15) k.close];
                final e9 = Engine.ema(cl, 9);
                final e21 = Engine.ema(cl, 21);
                final e50 = Engine.ema(cl, 50);
                String tr = 'flat';
                if (e50.isNotEmpty) {
                  if (e9.last > e21.last && e21.last > e50.last) {
                    tr = 'bull';
                  } else if (e9.last < e21.last && e21.last < e50.last) {
                    tr = 'bear';
                  }
                }
                quiet3 = _Quiet(sym, px3 > 0 ? a3 / px3 * 100 : 0, tr,
                    why: _scalp3mWhyWord(refused));
              }
              _scratch[i] = _CoinOut(sig3, null, quiet3);
            } else {
              if (c4.length < 120 && mounted) setState(() => _short4h++);
              final bias = Engine.analyze(biasTf.toUpperCase(), w4);

              // Strict SMC confluence first; fall back to the relaxed pass so
              // the list is not empty in quiet markets (flagged WATCH).
              // (scalp3m never reaches here -- it has its own branch above.)
              var sig = Engine.multiTF(sym, w4, w1, w15,
                  c4Long: c4, c1Long: c1, mode: _mode);
              sig ??= Engine.multiTF(sym, w4, w1, w15,
                  c4Long: c4, c1Long: c1, relaxed: true, mode: _mode);
              // A setup on a thin book is not a STRICT trade. The engine cannot
              // know the pair's liquidity (it only sees candles), so the
              // decision is made here, where the ticker volume is known.
              // Live evidence: GAL (2.54, -3.58% stop) came back STRICT at 75%
              // from the quiet tier -- exactly the coin a 5M/day floor exists to
              // keep out of the trade list, and exactly what the wide universe
              // pulled in.
              if (sig != null && coins[i].quoteVolume <= MarketData.preferredVolume) {
                sig = sig.asThin();
              }
              // Nothing strict or relaxed: fall back to the radar candidate so
              // a quiet market still shows what the engine is watching.
              sig ??= Engine.radar(sym, w4, w1, w15,
                  c4Long: c4, c1Long: c1, mode: _mode);

              final why = <String>[];
              if (sig == null) {
                // Track why a coin was dropped so an empty list can explain
                // itself instead of looking like a dead app.
                if (bias.trend == 0) {
                  _noBias++;
                } else {
                  _biasNoSetup++;
                }
                Engine.multiTF(sym, w4, w1, w15,
                    c4Long: c4, c1Long: c1,
                    relaxed: true, trace: why, mode: _mode);
              }
              // On the 3M stack a coin with no setup is still listed, at the
              // bottom, with its movement and bias. The instruction was to show
              // the quiet coins rather than hide them, and it also stops "no
              // setup" from being indistinguishable from "never scanned".
              _Quiet? quiet;
              if (sig == null &&
                  _mode == TradeMode.single3m &&
                  w15.length > 20) {
                final pxNow = w15.last.close;
                final a = Engine.atr(w15, period: 14);
                quiet = _Quiet(
                  sym,
                  pxNow > 0 ? a / pxNow * 100 : 0,
                  bias.trend > 0
                      ? 'bull'
                      : bias.trend < 0
                          ? 'bear'
                          : 'flat',
                );
              }
              _scratch[i] = _CoinOut(sig, why.isEmpty ? null : '$sym: '
                  '${why.join(' • ')}', quiet);
            }
          } catch (_) {
            if (mounted) setState(() => _failed++);
          }

          // Commit only from the contiguous finished frontier: coins finish
          // out of order, and advancing past an unfinished coin would drop it.
          finished[i] = true;
          while (frontier < finished.length && finished[frontier]) {
            frontier++;
          }

          if (mounted) {
            setState(() {
              _done++;
              _msg = 'Analyzing $sym ($_done/$_total)';
            });
          }

          // Commit once a chunk is complete, so the list is never rebuilt per
          // coin and never empty for long.
          if (frontier - commitFrom >= chunk) {
            if (mounted && id == _scanId) {
              setState(() => commit(finalChunk: false));
            }
          }

          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
      }

      await Future.wait(<Future<void>>[
        for (int w = 0; w < workers; w++) worker(),
      ]);

      if (id != _scanId || !mounted) return;

      setState(() {
        commit(finalChunk: true);
        final strict = _signals.where((s) => s.tier == 'STRICT').length;
        final watch = _signals.where((s) => s.tier == 'WATCH').length;
        final radar = _signals.where((s) => s.isRadar).length;
        final hits = MarketData.cacheHits;
        final misses = MarketData.cacheMisses;
        // Proof on the device that the cache is warm, and which build is
        // running. A cold first scan shows 0 - that is expected.
        final cacheNote =
            ' • ${_mode.biasTf} cache $hits/$hits+$misses '
            '(${MarketData.cached4h})';
        // An empty list must explain itself: "no 4H trend" and "trend but no
        // 15M trigger" are completely different problems.
        // The 3M scalp has its own funnel and must not borrow the SMC wording:
        // "0/400 coin-e 3M trend nei" was printed while the quiet list below
        // showed bull and bear coins, because the SMC counters never ran in
        // this mode. Name the stage that actually refused the coin.
        final why = _mode.isScalp3m
            ? _scalp3mWhyMessage()
            : (_noBias >= _biasNoSetup
                ? '$_noBias/$_total coin-e ${_mode.biasTf} trend nei'
                : '$_biasNoSetup coin-e ${_mode.biasTf} trend ache, kintu '
                    '${_mode.triggerTf} trigger/zone mile nai');
        final young =
            _tooYoung > 0
                ? ' • $_tooYoung notun coin (${_mode.biasTf} history kom)'
                : '';
        // A small universe is worth shouting about: it means the exchange did
        // not hand over its full ticker list, not that the market is empty.
        final raw = MarketData.lastRawTickers;
        final tradable = MarketData.lastTradable;
        final funnelFeed = MarketData.lastFunnelFeed;
        // The funnel, always shown: raw ticker rows -> listed USDT pairs ->
        // coins analysed. `strong` is how many of the listed pairs cleared the
        // preferred 5M USDT/day floor; the rest are the quiet tier used only to
        // reach 300. If `picked` is still short, one of these numbers says why:
        //
        //   raw low                 -> the feed sent a truncated list
        //   listed low              -> the exchange has few USDT pairs
        //   listed high, picked low -> too few pairs to reach the target
        final strong = MarketData.lastStrong;
        final listedPool = MarketData.lastListed;
        final strongPool = MarketData.lastStrongPool;
        // analysed = picked - the coins the engine could not read at all.
        // Printed explicitly so "300 picked" and "300 analysed" can never be
        // confused, and a shortfall always has a name.
        final analysed = _total - _tooYoung - _failed;
        // listedPool is BEFORE the cap: it is the only number that says whether
        // the exchange sent a short list or our own floor ate it.
        final dead = MarketData.lastDeadSymbols;
        final funnel = ' • $funnelFeed $raw ticker'
            '${dead > 0 ? ' ($dead delisted)' : ''} → $listedPool listed '
            '($strongPool strong) → $_total picked → $analysed analysed'
            '${_short4h > 0 ? ' ($_short4h short ${_mode.biasTf})' : ''}'
            '${_delisted > 0 ? ' ($_delisted stale data)' : ''}';
        // Warn below half the target: at 400 that is 200. A universe this
        // small is a data story, not a market story.
        final small = _total < MarketData.scanTarget ~/ 2
            ? ' • Sotorkota: matro $_total coin — exchange e eto USDT pair nei'
            : '';
        _msg = _signals.isEmpty
            ? 'Kono setup nei ekhon ($_feed) — $why.$young$small '
                '5 min por auto refresh.'
            : '$strict signal • $watch watch • $radar radar ($_feed)'
                '${_failed > 0 ? ' • $_failed coin skip' : ''}$young'
                '$funnel$cacheNote';
      });
      // Reviews start only after the list is on screen. They are fire-and-
      // forget: a scan must never wait on a model, and a failing review must
      // never turn into a failed scan.
      if (_gemini.usable && _gemini.autoReview && _signals.isNotEmpty) {
        unawaited(_autoReview());
      }
    } catch (e) {
      if (!mounted || id != _scanId) return;
      var detail = e.toString().replaceAll('MarketDataException: ', '');
      if (detail.length > 120) detail = '${detail.substring(0, 120)}...';
      final offline = detail.contains('no internet');
      setState(() {
        _loading = false;
        _feed = '';
        _msg = offline
            ? 'Internet nei (ba app ke network permission deya hoy nai). '
                'WiFi/mobile data check koro, tarpor Rescan.'
            : 'Exchange gulo block koreche ($detail). VPN on koro '
                '(Japan/Hong Kong/Switzerland) tarpor Rescan.';
      });
    }
  }

  // ---------------------------------------------------------------- Gemini
  //
  // Everything below is additive. Nothing here touches `_signals`: a signal's
  // tier, entry, stop, target and position in the list are decided by the
  // engine and stay identical whether Gemini is on or off. A review that says
  // AVOID does NOT remove the card; it puts a red note on it. That separation
  // is the whole reason this can be shipped at all.

  /// Ask for reviews of the top signals of the current scan.
  ///
  /// Kept to the top few on purpose: every request is the user's own quota,
  /// and 40 reviews of coins they will never open is not a feature.
  Future<void> _autoReview() async {
    if (!_gemini.usable || _signals.isEmpty) return;
    final top = _signals.take(3).map((s) => s.symbol).toList();
    for (final sym in top) {
      final sig = _signals.firstWhere((s) => s.symbol == sym);
      unawaited(_reviewOne(sig));
    }
    if (_gScanNote == null) unawaited(_reviewScan());
  }

  Future<void> _reviewScan() async {
    if (!_gemini.usable || _signals.isEmpty) return;
    final note = await GeminiService.reviewScan(
      apiKey: _gemini.apiKey,
      model: _gemini.model,
      modeLabel: '${_mode.label} ${_mode.biasTf}/${_mode.zoneTf}/'
          '${_mode.triggerTf}',
      coinsScanned: _total,
      marketNote: _msg,
      signals: _signals
          .take(12)
          .map((s) => <String, dynamic>{
                'symbol': s.coin,
                'direction': s.direction,
                'tier': s.tier,
                'confidence': s.confidence.toStringAsFixed(0),
                'rr': s.rr.toStringAsFixed(2),
                'riskPct': s.riskPct.toStringAsFixed(2),
                'rewardPct': s.profitPct.toStringAsFixed(2),
              })
          .toList(),
    );
    if (!mounted) return;
    setState(() => _gScanNote = note);
  }

  /// One signal. Deliberately not awaited by the caller: a slow model must
  /// never delay a scan or a rebuild.
  Future<void> _reviewOne(TradeSignal s) async {
    if (!_gemini.usable) return;
    if (_gInFlight.contains(s.symbol)) return;
    setState(() => _gInFlight.add(s.symbol));
    final note = await GeminiService.reviewSignal(
      apiKey: _gemini.apiKey,
      model: _gemini.model,
      modeLabel: _mode.label,
      timeframes:
          '${_mode.biasTf}/${_mode.zoneTf}/${_mode.triggerTf}',
      symbol: s.symbol,
      direction: s.direction,
      tier: s.tier,
      entry: s.entry,
      sl: s.sl,
      tp: s.tp,
      price: s.price,
      confidence: s.confidence,
      rr: s.rr,
      riskPct: s.riskPct,
      rewardPct: s.profitPct,
      confirmations: s.confirmations,
      pattern: s.pattern,
      zone: s.zone,
      structure: '${_mode.biasTf}: ${s.tf4h} | '
          '${_mode.zoneTf}: ${s.tf1h} | ${_mode.triggerTf}: ${s.tf15m}',
      chop: s.chop,
      costPct: kCostPct,
    );
    if (!mounted) return;
    setState(() {
      _gInFlight.remove(s.symbol);
      _gNotes[s.symbol] = note;
    });
  }

  /// The little badge on a signal card. Shows the model's stance, or a spinner
  /// while a review is in flight, or nothing at all when Gemini is off.
  Widget? _geminiBadge(String symbol) {
    final note = _gNotes[symbol];
    final busy = _gInFlight.contains(symbol);
    if (note == null && !busy) return null;
    Color c;
    String label;
    if (busy) {
      c = K.muted;
      label = 'AI';
    } else if (!note!.ok) {
      c = K.muted;
      label = 'AI !';
    } else if (note.stance == 'AVOID') {
      c = K.red;
      label = 'AI: avoid';
    } else if (note.stance == 'CAUTION') {
      c = K.orange;
      label = 'AI: caution';
    } else if (note.stance == 'AGREE') {
      c = K.blue;
      label = 'AI: agree';
    } else {
      c = K.blue;
      label = 'AI';
    }
    return Container(
      margin: const EdgeInsets.only(right: 5),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: c.withOpacity(0.18),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (busy)
            SizedBox(
              width: 7,
              height: 7,
              child: CircularProgressIndicator(strokeWidth: 1, color: c),
            )
          else
            Icon(Icons.auto_awesome, size: 8, color: c),
          const SizedBox(width: 2),
          Text(
            label,
            style: TextStyle(
                color: c, fontSize: 8, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  /// The full review, rendered in the details sheet. Parsed loosely: the model
  /// is told to answer in a fixed shape, but a model that drifts must not break
  /// the screen, so the raw text is shown when the shape is missing.
  Widget _geminiSection(TradeSignal s) {
    final note = _gNotes[s.symbol];
    final busy = _gInFlight.contains(s.symbol);
    final rows = <Widget>[];
    if (busy) {
      rows.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                  strokeWidth: 1.5, color: K.blue),
            ),
            SizedBox(width: 8),
            Text('Gemini dekhche...',
                style: TextStyle(color: K.muted, fontSize: 11)),
          ],
        ),
      ));
    } else if (note == null) {
      rows.add(const Text(
        'Ei signal er kono review nei.',
        style: TextStyle(color: K.muted, fontSize: 11),
      ));
    } else if (!note.ok) {
      rows.add(Text(
        note.error,
        style: const TextStyle(color: K.orange, fontSize: 11, height: 1.4),
      ));
    } else {
      final c = note.stance == 'AVOID'
          ? K.red
          : note.stance == 'CAUTION'
              ? K.orange
              : K.blue;
      for (final line in note.text.split('\n')) {
        final t = line.trim();
        if (t.isEmpty) continue;
        final m = RegExp(r'^(STANCE|CONFIDENCE|WHY|RISK|WHEN)\s*:\s*(.*)$')
            .firstMatch(t);
        if (m == null) {
          rows.add(Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(t,
                style: const TextStyle(
                    color: K.text, fontSize: 11, height: 1.45)),
          ));
        } else {
          rows.add(Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: RichText(
              text: TextSpan(
                children: <InlineSpan>[
                  TextSpan(
                    text: '${m.group(1)} ',
                    style: TextStyle(
                      color: m.group(1) == 'STANCE' ? c : K.muted,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  TextSpan(
                    text: m.group(2),
                    style: const TextStyle(
                        color: K.text, fontSize: 11, height: 1.45),
                  ),
                ],
              ),
            ),
          ));
        }
      }
      rows.add(Text(
        '${note.model} · ${timeAgo(note.at)}',
        style: const TextStyle(color: K.muted, fontSize: 9),
      ));
    }
    return Container(
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: K.panel2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: K.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.auto_awesome, size: 14, color: K.blue),
              const SizedBox(width: 6),
              const Text(
                'Gemini second opinion',
                style: TextStyle(
                    color: K.text,
                    fontSize: 13,
                    fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              if (!busy)
                GestureDetector(
                  onTap: () => _reviewOne(s),
                  child: const Text('again',
                      style: TextStyle(color: K.blue, fontSize: 10)),
                ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Engine er number na — ei review signal change kore na.',
            style: TextStyle(color: K.muted, fontSize: 9, height: 1.3),
          ),
          const SizedBox(height: 10),
          ...rows,
        ],
      ),
    );
  }

  /// One sentence naming the stage that stopped the 3M scalp.
  ///
  /// Each stage means something different to the user, so each gets its own
  /// sentence rather than a shared "no setup":
  ///
  ///   gate  -- the coin is too quiet to pay the 0.25% fee. Nothing to do.
  ///   trend -- EMA 9/21/50 not stacked. Wait.
  ///   side  -- trend is there but price is NOT on the pullback side of
  ///            EMA21, i.e. this is a chase, not a pullback. This is the
  ///            stage that eats most of a trend day, and saying so is the
  ///            difference between "broken" and "waiting for a dip".
  ///   rsi   -- price is on the pullback side but RSI is not cooling yet.
  ///   bar   -- everything lines up except the candle has not turned yet.
  ///
  /// The stage with the highest count is named first, with its own number, so
  /// the sentence changes as the market changes instead of repeating a guess.
  /// One refusal stage -> the words the row and the header both use.
  ///
  /// Kept in one place because the two were allowed to drift once already: the
  /// header said "gate" while the rows showed a trend, and the screen
  /// contradicted itself in two languages at once.
  String _scalp3mWhyWord(String? stage) {
    switch (stage) {
      case 'price':
        return 'over \$${kScalp3mMaxPrice.toStringAsFixed(0)}';
      case 'none':
        return '0 of 2';
      case 'bos':
        return 'no recent bos';
      case 'macd':
        return 'macd not green';
      case 'stop':
        return 'stop too tight';
      case 'data':
        return 'short history';
      // The stages below belong to the v18 rule set, which this build no
      // longer has. They are kept so an old list (or the Python mirror) that
      // still reports them cannot render a blank row.
      case 'gate':
        return 'quiet';
      case 'trend':
        return 'no trend';
      case 'side':
        return 'no pullback';
      case 'rsi':
        return 'no rsi';
      case 'bar':
        return 'no turn';
      default:
        return '';
    }
  }

  String _scalp3mWhyMessage() {
    if (_scalp3mWhy.isEmpty) {
      return '${_total} coin check kora hoise';
    }
    final ranked = _scalp3mWhy.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top = ranked.first;
    final n = top.value;
    final gate = Engine.scalp3mGate.toStringAsFixed(2);
    switch (top.key) {
      case 'price':
        return '$n/$_total coin \$${kScalp3mMaxPrice.toStringAsFixed(0)}-er '
            'beshi daam, tai filter kora hoise';
      case 'none':
        return '$n/$_total coin-e 2-ta shortoir ekta-o mile nai '
            '(BOS nei, MACD green na)';
      case 'gate':
        return '$n/$_total coin ATR $gate%-er niche — fee '
            '${kCostPct.toStringAsFixed(2)}% uthano jabe na, tai signal nai';
      case 'trend':
        return '$n/$_total coin-e 3M EMA 9/21/50 stack nei (trend flat)';
      case 'side':
        return '$n/$_total coin-e trend ache kintu price EMA21-এর '
            'pullback dike nei (chase hocche) — dip/counter-move er jonno wait';
      case 'rsi':
        return '$n/$_total coin pullback dike, kintu RSI ekhono thanda hoy nai';
      case 'bar':
        return '$n/$_total coin-e sob mile gechilo, sudhu candle turn kore nai';
      case 'stop':
        return '$n/$_total coin-e stop 0.35%-er kom chilo — fee e kheye jeto';
      default:
        return '$n/$_total coin-e data kom (notun listing)';
    }
  }

  List<TradeSignal> get _visible {
    if (_filter == 'BUY') {
      return _signals.where((s) => s.isBuy).toList();
    }
    if (_filter == 'SELL') {
      return _signals.where((s) => !s.isBuy).toList();
    }
    return _signals;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: K.bg,
      appBar: AppBar(
        backgroundColor: K.panel,
        title: Row(
          children: const <Widget>[
            Icon(Icons.candlestick_chart, color: K.green, size: 22),
            SizedBox(width: 8),
            Text(
              'Smart Money Trader',
              style: TextStyle(
                color: K.text,
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            icon: Icon(
              Icons.auto_awesome,
              color: _gemini.usable ? K.blue : K.muted,
            ),
            tooltip: _gemini.usable
                ? 'Gemini: ${_gemini.model}'
                : 'Gemini key add koro',
            onPressed: () {
              showGeminiSettings(
                context,
                current: _gemini,
                onSaved: _saveGemini,
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.show_chart, color: K.text),
            tooltip: 'MACD buy (3M)',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const MacdScreen(),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.insights, color: K.text),
            tooltip: 'Backtest',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const BacktestScreen(),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: K.text),
            tooltip: 'Rescan',
            onPressed: _loading ? null : run,
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _statusPanel(),
          _summaryPanel(),
          Expanded(child: _list()),
        ],
      ),
    );
  }

  Widget _statusPanel() {
    final progress = _total > 0 ? _done / _total : 0.0;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      color: K.panel,
      child: Column(
        children: <Widget>[
          // Mode switch. Both modes run the identical engine: same weights,
          // same gates, same stops and targets. Only the horizon stack changes
          // (4H/1H/15M vs 30M/15M/5M), which is why switching restarts the
          // scan -- the candles and the cache are per-timeframe.
          Row(
            children: <Widget>[
              for (final m in TradeMode.values)
                GestureDetector(
                  onTap: () {
                    if (_mode == m) return;
                    setState(() => _mode = m);
                    _restartTimer();
                    run();
                  },
                  child: Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: _mode == m
                          ? K.green.withOpacity(0.18)
                          : K.panel2,
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(
                        color: _mode == m ? K.green : K.panel2,
                      ),
                    ),
                    child: Text(
                      '${m.label} ${m.biasTf}/${m.zoneTf}/${m.triggerTf}',
                      style: TextStyle(
                        color: _mode == m ? K.green : K.muted,
                        fontSize: 10,
                        fontWeight:
                            _mode == m ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _loading ? K.orange : K.green,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _loading ? 'Analyzing...' : 'Done',
                    style: const TextStyle(color: K.muted, fontSize: 12),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    kBuild,
                    style: const TextStyle(color: K.green, fontSize: 10),
                  ),
                ],
              ),
              Text(
                '$_done / $_total',
                style: const TextStyle(
                  color: K.text,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: K.panel2,
              valueColor: AlwaysStoppedAnimation<Color>(
                _loading ? K.orange : K.green,
              ),
              minHeight: 4,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _msg,
              style: const TextStyle(color: K.muted, fontSize: 11),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryPanel() {
    final buys = _signals.where((s) => s.isBuy).length;
    final sells = _signals.where((s) => !s.isBuy).length;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: K.line)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Row(
            children: <Widget>[
              _chip('ALL', _signals.length, K.blue),
              const SizedBox(width: 6),
              _chip('BUY', buys, K.green),
              const SizedBox(width: 6),
              _chip('SELL', sells, K.red),
            ],
          ),
          Row(
            children: <Widget>[
              _TfBadge(_mode.biasTf, K.blue),
              const SizedBox(width: 4),
              _TfBadge(_mode.zoneTf, const Color(0xFFA371F7)),
              const SizedBox(width: 4),
              _TfBadge(_mode.triggerTf, K.orange),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(String name, int count, Color color) {
    final active = _filter == name;
    return GestureDetector(
      onTap: () => setState(() => _filter = name),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active ? color.withOpacity(0.18) : K.panel2,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: active ? color : K.line),
        ),
        child: Text(
          '$name $count',
          style: TextStyle(
            color: active ? color : K.muted,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  /// At most 40 quiet rows. A 400-coin scan can leave 350 coins with no setup;
  /// printing all of them buries the list under a wall of nothing.
  List<_Quiet> get _quietShown =>
      _quiets.length <= 40 ? _quiets : _quiets.sublist(0, 40);

  /// The scan-level Gemini note: one card, dismissible, clearly not a signal.
  Widget _scanNoteCard(GeminiNote note) {
    final c = note.stance == 'AVOID'
        ? K.red
        : note.stance == 'CAUTION'
            ? K.orange
            : K.blue;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: K.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.auto_awesome, size: 13, color: c),
              const SizedBox(width: 6),
              Text(
                note.isScan ? 'Gemini: ei scan niye' : 'Gemini',
                style: const TextStyle(
                    color: K.text,
                    fontSize: 12,
                    fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              if (note.isScan)
                GestureDetector(
                  onTap: _reviewScan,
                  child: const Text('again',
                      style: TextStyle(color: K.blue, fontSize: 10)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (!note.ok)
            Text(note.error,
                style: const TextStyle(
                    color: K.orange, fontSize: 11, height: 1.4))
          else
            Text(
              note.text
                  .replaceAll(RegExp(r'^(STANCE|CONFIDENCE)\s*:\s*',
                      multiLine: true), ''),
              style: const TextStyle(
                  color: K.text, fontSize: 11, height: 1.45),
            ),
          const SizedBox(height: 6),
          Text(
            '${note.model} · opinion, not a signal · ${timeAgo(note.at)}',
            style: const TextStyle(color: K.muted, fontSize: 9),
          ),
        ],
      ),
    );
  }

  Widget _quietHeader() => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 8, left: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Divider(color: K.line, height: 1),
            const SizedBox(height: 10),
            // The count used to print `_quiets.length` (all coins) above a
            // list capped at 40, and in the 3M mode it named the wrong reason
            // for every row at once. It now counts what is on screen and says
            // the range when the list is capped.
            Text(
              _mode.isScalp3m
                  ? '${_quietShown.length}'
                      '${_quiets.length > _quietShown.length ? ' / ${_quiets.length}' : ''}'
                      ' coin 3M-e check kora hoise, BOS+MACD mile nai'
                  : '${_quiets.length} coin-e setup nei '
                      '(beshi move kora age)',
              style: const TextStyle(
                  color: K.text, fontSize: 12, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 3),
            Text(
              _mode.isScalp3m
                  ? 'Shudhu 3M candle dekha hoy — r kono timeframe na. Du-ta '
                      'shorto: (1) $bos5mLookback candle-er moddhe BOS, '
                      '(2) MACD green. Dui-ta mile hole coin upore, ekta '
                      'mile hole niche. Beshi move kora coin agei thake.'
                  : 'Egulo analyse kora hoise but kono setup pay nai. '
                      'Kom move korche, tai niche.',
              style: const TextStyle(color: K.muted, fontSize: 10, height: 1.4),
            ),
          ],
        ),
      );

  Widget _quietRow(_Quiet q) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 68,
              child: Text(
                q.symbol.replaceAll('USDT', ''),
                style: const TextStyle(
                    color: K.text,
                    fontSize: 12,
                    fontWeight: FontWeight.bold),
              ),
            ),
            // The stage that refused the coin, in the gap that used to be
            // empty. `Expanded` (not Spacer + Expanded) because two flexible
            // children in one row fight over the same free space.
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text(
                  q.why,
                  style: const TextStyle(color: K.muted, fontSize: 9),
                ),
              ),
            ),
            SizedBox(
              width: 34,
              child: Text(
                q.trend,
                textAlign: TextAlign.right,
                style: TextStyle(
                    color: q.trend == 'bull'
                        ? K.green
                        : q.trend == 'bear'
                            ? K.red
                            : K.muted,
                    fontSize: 11),
              ),
            ),
            Text(
              '${q.chop.toStringAsFixed(2)}%/bar',
              style: const TextStyle(color: K.muted, fontSize: 11),
            ),
          ],
        ),
      );

  Widget _list() {
    final items = _visible;

    if (_loading && items.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: K.green),
      );
    }

    // No signal, but quiet coins were collected: still show them rather than
    // the empty-state, so the 3M mode reports what it saw.
    if (items.isEmpty && _quiets.isEmpty) {
      return RefreshIndicator(
        onRefresh: run,
        color: K.green,
        backgroundColor: K.panel,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: <Widget>[
            SizedBox(height: MediaQuery.of(context).size.height * 0.18),
            Icon(
              _signals.isEmpty ? Icons.search_off : Icons.filter_alt_off,
              size: 46,
              color: K.muted,
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                _signals.isEmpty
                    ? 'Kono setup nei'
                    : 'No $_filter signals',
                style: const TextStyle(
                  color: K.text,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 34),
                child: Text(
                  _mode.isScalp3m
                      // The 3M scalp refuses almost everything on purpose.
                      // Saying so is the difference between a broken screen and
                      // an honest one: on a quiet market every coin fails the
                      // ATR% gate, and there is no trade to give.
                      ? '3M scalp ekta kothin filter: bar-er ATR '
                          '${Engine.scalp3mGate.toStringAsFixed(2)}%-er niche hole '
                          'kono signal nai (fee ${kCostPct.toStringAsFixed(2)}% '
                          'tule ney). Ekhon market quiet — niche dekho kon coin '
                          'koto kachakachi chilo.'
                      : 'Strict SMC setup (bias + OB/FVG zone + trigger) '
                          'ekhon nei. Niche dekho kon coin koto duro eshechilo.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: K.muted, fontSize: 12, height: 1.4),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Center(
              child: ElevatedButton.icon(
                onPressed: _loading ? null : run,
                style: ElevatedButton.styleFrom(
                  backgroundColor: K.panel2,
                  foregroundColor: K.text,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Rescan'),
              ),
            ),
            if (_nearMiss.isNotEmpty) ...<Widget>[
              const SizedBox(height: 26),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Kache kache eshechilo (koto duro):',
                  style: TextStyle(
                    color: K.text,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              for (final line in _nearMiss.take(25))
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    line,
                    style: const TextStyle(
                      color: K.muted,
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                ),
            ],
          ],
        ),
      );
    }

    // A scan-level review, if there is one, rides above the list as its own
    // card. It never adds a row to the signal list and never removes one.
    final head = <Widget>[
      if (_gScanNote != null && (_gScanNote!.ok || _gemini.usable))
        _scanNoteCard(_gScanNote!),
    ];

    return RefreshIndicator(
      onRefresh: run,
      color: K.green,
      backgroundColor: K.panel,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
        // Quiet coins are appended, never mixed in: signals first (busiest
        // coin at the top), then a divider, then the coins that were analysed
        // and produced nothing. Separating them keeps "a signal is below a
        // non-signal" from ever happening.
        itemCount: head.length +
            items.length +
            (_quiets.isEmpty ? 0 : 1 + _quietShown.length),
        itemBuilder: (context, i) {
          if (i < head.length) return head[i];
          final k = i - head.length;
          if (k < items.length) {
            return _SignalCard(
              signal: items[k],
              onTap: () => _showDetails(items[k]),
              geminiBadge: _geminiBadge(items[k].symbol),
            );
          }
          if (k == items.length) return _quietHeader();
          return _quietRow(_quietShown[k - items.length - 1]);
        },
      ),
    );
  }

  void _showDetails(TradeSignal s) {
    final color = s.isBuy ? K.green : K.red;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: K.panel,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.72,
          maxChildSize: 0.92,
          minChildSize: 0.45,
          builder: (ctx2, controller) {
            return ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 26),
              children: <Widget>[
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: K.line,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          s.coin,
                          style: const TextStyle(
                            color: K.text,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          s.symbol,
                          style: const TextStyle(color: K.muted, fontSize: 12),
                        ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: <Widget>[
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: color.withOpacity(0.16),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: color),
                          ),
                          child: Text(
                            s.direction,
                            style: TextStyle(
                              color: color,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${s.confidence.toStringAsFixed(0)}% confidence',
                          style: const TextStyle(
                              color: K.muted, fontSize: 11),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _detailRow('Last price', fmtPrice(s.price)),
                // The 3M mode is a SCANNER: it has no entry, stop, target or
                // R:R, and printing those rows would put an invented plan on
                // the screen -- the user asked for exactly the opposite. It
                // shows the two facts and the movement instead.
                if (s.mode == TradeMode.scalp3m) ...<Widget>[
                  _detailRow('BOS ($bos5mLookback candles)',
                      s.bos5 ? 'yes' : 'no', s.bos5 ? K.green : K.muted),
                  _detailRow('MACD green',
                      s.macdGreen ? 'yes' : 'no', s.macdGreen ? K.green : K.muted),
                  _detailRow('Match', s.watch ? '1 of 2' : '2 of 2',
                      s.watch ? K.orange : K.green),
                  _detailRow('Movement', '${s.chop.toStringAsFixed(2)}%/bar'),
                ] else ...<Widget>[
                  _detailRow('Entry', fmtPrice(s.entry)),
                  _detailRow('Stop loss', fmtPrice(s.sl), K.red),
                  _detailRow('Take profit', fmtPrice(s.tp), K.green),
                  _detailRow('Risk / Reward', '1 : ${s.rr.toStringAsFixed(2)}'),
                  _detailRow('Expected move', fmtPct(s.profitPct), K.green),
                  _detailRow('Risk', fmtPct(-s.riskPct)),
                ],
                const SizedBox(height: 18),
                const Text(
                  'Confirmations',
                  style: TextStyle(
                    color: K.text,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: s.confirmations
                      .map((c) => Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: K.panel2,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: K.line),
                            ),
                            child: Text(
                              c,
                              style: const TextStyle(
                                  color: K.text, fontSize: 11),
                            ),
                          ))
                      .toList(),
                ),
                const SizedBox(height: 18),
                _detailRow(
                    'Setup',
                    s.isRadar
                        ? 'RADAR (candidate, no trade)'
                        : s.watch
                            ? 'WATCH (relaxed)'
                            : 'STRICT',
                    s.isRadar
                        ? K.muted
                        : s.watch
                            ? K.orange
                            : K.green),
                _detailRow('Pattern', s.pattern,
                    s.pattern == 'CHoCH' ? K.orange : K.green),
                _detailRow('${s.mode.zoneTf} zone', s.zone,
                    s.zone == 'Discount'
                        ? K.green
                        : s.zone == 'Premium'
                            ? K.red
                            : K.muted),
                _detailRow('Liquidity',
                    '${s.eqh ? 'EQH ' : ''}${s.eql ? 'EQL' : ''}'.trim().isEmpty
                        ? 'None'
                        : '${s.eqh ? 'EQH ' : ''}${s.eql ? 'EQL' : ''}'.trim()),
                _detailRow('${s.mode.biasTf} structure', s.tf4h),
                _detailRow('${s.mode.zoneTf} structure', s.tf1h),
                _detailRow('${s.mode.triggerTf} structure', s.tf15m),
                _detailRow('Generated', timeAgo(s.time)),
                if (_gemini.usable || _gNotes.containsKey(s.symbol))
                  _geminiSection(s),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: K.panel2,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: K.line),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(Icons.info_outline, color: K.orange, size: 16),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Technical analysis only — not financial advice. '
                          'Always use your own risk management (1-2% per trade).',
                          style: TextStyle(
                            color: K.muted,
                            fontSize: 11,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _detailRow(String label, String value, [Color? color]) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Text(label, style: const TextStyle(color: K.muted, fontSize: 13)),
          Text(
            value,
            style: TextStyle(
              color: color ?? K.text,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _TfBadge extends StatelessWidget {
  const _TfBadge(this.label, this.color);

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _SignalCard extends StatelessWidget {
  const _SignalCard({
    required this.signal,
    required this.onTap,
    this.geminiBadge,
  });

  final TradeSignal signal;
  final VoidCallback onTap;

  /// The Gemini stance chip, built by the screen (which owns the notes) and
  /// handed in as a widget. The card must not know what Gemini is -- it renders
  /// one opaque chip next to the engine's tier, which keeps the advisory /
  /// engine separation visible in the code and not just in the comments.
  final Widget? geminiBadge;

  @override
  Widget build(BuildContext context) {
    final isBuy = signal.isBuy;
    final color = isBuy ? K.green : K.red;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: K.panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: K.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 4,
                  height: 34,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        signal.coin,
                        style: const TextStyle(
                          color: K.text,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Row(
                        children: <Widget>[
                          Builder(builder: (context) {
                            final tierColor = signal.isRadar
                                ? K.muted
                                : signal.watch
                                    ? K.orange
                                    : K.green;
                            return Container(
                              margin: const EdgeInsets.only(right: 5),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: tierColor.withOpacity(0.18),
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Text(
                                signal.tier,
                                style: TextStyle(
                                  color: tierColor,
                                  fontSize: 8,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            );
                          }),
                          // A model opinion sits next to the tier chip, never
                          // inside it: the tier is the engine's, the badge is
                          // somebody else's view of the same trade.
                          if (geminiBadge != null) geminiBadge!,
                          Flexible(
                            child: Text(
                              signal.mode == TradeMode.scalp3m
                                  // No BUY/SELL on a scanner card: there is no
                                  // trade to take, so a side would be a plan.
                                  ? '${signal.pattern} • ${timeAgo(signal.time)}'
                                  : '${signal.direction} • ${signal.pattern} • '
                                      '${signal.zone} • ${timeAgo(signal.time)}'
                              // On the 3M stack the moving-per-bar figure is
                              // shown, because it is what the list is sorted
                              // by. A coin at 0.1%/bar cannot pay a 0.25% fee
                              // on a 3M hold, and the card should say so rather
                              // than leave the ordering unexplained.
                              '${signal.mode == TradeMode.single3m ? ' • ${signal.chop.toStringAsFixed(2)}%/bar' : ''}',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: color, fontSize: 10),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    if (signal.mode == TradeMode.scalp3m)
                      // A scanner shows FACTS, not a plan: there is no RR to
                      // print because this mode has no stop and no target, and
                      // the percentage that used to sit here was a confidence in
                      // a trade that does not exist.
                      Text(
                        '${signal.chop.toStringAsFixed(2)}%/bar',
                        style: TextStyle(
                          color: color,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      )
                    else
                      Text(
                        '${signal.confidence.toStringAsFixed(0)}%',
                        style: TextStyle(
                          color: color,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    if (signal.mode == TradeMode.scalp3m)
                      Text(
                        '${(signal.bos5 ? 1 : 0) + (signal.macdGreen ? 1 : 0)} of 2',
                        style: const TextStyle(color: K.muted, fontSize: 10),
                      )
                    else
                    Text(
                      'RR 1:${signal.rr.toStringAsFixed(2)}',
                      style: const TextStyle(color: K.muted, fontSize: 10),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: (signal.confidence / 100).clamp(0.0, 1.0).toDouble(),
                backgroundColor: K.panel2,
                valueColor: AlwaysStoppedAnimation<Color>(color),
                minHeight: 3,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                _priceCell('ENTRY', fmtPrice(signal.entry), K.text),
                _priceCell('SL', fmtPrice(signal.sl), K.red),
                _priceCell('TP', fmtPrice(signal.tp), K.green),
                _priceCell('TP%', fmtPct(signal.profitPct), color),
              ],
            ),
            if (signal.thinVolume) ...<Widget>[
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  const Icon(Icons.water_drop, size: 12, color: K.orange),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Thin book (<5M USDT/day) — entry/SL e slippage hote pare',
                      style: const TextStyle(color: K.orange, fontSize: 10),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: signal.confirmations
                  .take(3)
                  .map((c) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: K.panel2,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          c,
                          style: const TextStyle(
                              color: K.muted, fontSize: 9),
                        ),
                      ))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _priceCell(String label, String value, Color color) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(color: K.muted, fontSize: 9),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =====================================================================
// BACKTEST SCREEN
// =====================================================================

class BacktestScreen extends StatefulWidget {
  const BacktestScreen({Key? key}) : super(key: key);

  @override
  State<BacktestScreen> createState() => _BTS();
}

class _BTS extends State<BacktestScreen> {
  final _controller = TextEditingController(text: 'BTCUSDT');
  bool _running = false;
  String _msg = 'Coin likhe Run dao';
  BacktestResult? _result;
  int _checks = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final sym = _controller.text.trim().toUpperCase();
    if (sym.isEmpty) return;
    final symbol = sym.endsWith('USDT') ? sym : '${sym}USDT';

    setState(() {
      _running = true;
      _result = null;
      _msg = 'History anchi ($symbol)...';
      _checks = 0;
    });

    // Keeps the ticker alive while the synchronous simulation runs.
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (mounted) setState(() => _checks++);
    });

    try {
      // Deeper history: 12000 15M bars is ~125 days (4 months), so even a
      // slow-resolving swing target produces enough decided trades to look at.
      // Fetched in 1000-bar pages from Binance; the other feeds cap out lower
      // and are used only as a fallback.
      final c4 = await MarketData.candles(symbol, '4h', 1500);
      final c1 = await MarketData.candles(symbol, '1h', 3000);
      final c15 = await MarketData.candles(symbol, '15m', 12000);
      if (!mounted) return;

      setState(() => _msg = 'Simulating ${c15.length} bars...');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final result = Backtester.run(symbol, c4, c1, c15);
      if (!mounted) return;
      setState(() {
        _result = result;
        _running = false;
        _msg = result.trades.isEmpty
            ? 'Ei coin e kono setup nei ekhon ($symbol). Onno coin try koro.'
            : '${result.closed} nishpotti trade (${result.open} open) • '
                'total R ${result.totalR.toStringAsFixed(2)}';
      });
    } catch (e) {
      if (!mounted) return;
      var detail = e.toString().replaceAll('MarketDataException: ', '');
      if (detail.length > 90) detail = '${detail.substring(0, 90)}...';
      setState(() {
        _running = false;
        _msg = 'Fail ($symbol): $detail';
      });
    } finally {
      _timer?.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: K.bg,
      appBar: AppBar(
        backgroundColor: K.panel,
        title: const Text(
          'Backtest',
          style: TextStyle(color: K.text, fontSize: 17, fontWeight: FontWeight.bold),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _controller,
                  style: const TextStyle(color: K.text, fontSize: 14),
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    hintText: 'BTC / ETH / SOL',
                    hintStyle: const TextStyle(color: K.muted, fontSize: 13),
                    filled: true,
                    fillColor: K.panel2,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: K.line),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: K.line),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _running ? null : _run,
                style: ElevatedButton.styleFrom(
                  backgroundColor: K.green,
                  foregroundColor: const Color(0xFF07120B),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: _running
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF07120B),
                        ),
                      )
                    : const Text('Run',
                        style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            _running ? '$_msg  •  $_checks bar checked' : _msg,
            style: const TextStyle(color: K.muted, fontSize: 11),
          ),
          const SizedBox(height: 16),
          if (_result != null) ..._report(_result!),
        ],
      ),
    );
  }

  List<Widget> _report(BacktestResult r) {
    final n = r.trades.length;
    final good = r.totalR >= 0;
    // A fixed target makes the win rate look great while the R multiple can be
    // negative. Both numbers are printed, plus the R:R that connects them.
    final rr = r.avgRR;
    final be = r.breakEvenWinRate;
    final winOk = r.closed >= 20 && r.winRate > be;
    final costTotal = r.totalRAfterCost(kCostPct);
    final costWin = r.winRateAfterCost(kCostPct);
    return <Widget>[
      Row(
        children: <Widget>[
          Expanded(
            child: _miniStat(
              'Win rate',
              '${r.winRate.toStringAsFixed(1)}%',
              r.closed < 20 ? K.muted : (winOk ? K.green : K.orange),
              sub: 'breakeven ${be.toStringAsFixed(1)}%',
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _miniStat(
              'Total R',
              '${r.totalR >= 0 ? '+' : ''}${r.totalR.toStringAsFixed(2)}R',
              good ? K.green : K.red,
              sub: 'avg ${r.avgR.toStringAsFixed(2)}R',
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _miniStat(
              'R:R',
              rr.toStringAsFixed(2),
              rr >= 1 ? K.green : K.red,
              sub: r.avgRR >= 1 ? 'target >= 1R' : 'target < 1R',
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        r.closed == 0
            ? 'Ei sample e kono trade nishpotti hoy nai — kichu bola jabe na.'
            : '${r.closed} ta nishpotti trade. Win rate ${r.winRate.toStringAsFixed(1)}% '
                '(${r.wins} TP / ${r.losses} SL), kintu protiti trade e reward:risk '
                'matro ${rr.toStringAsFixed(2)} — tai ${be.toStringAsFixed(1)}% '
                'win rate chara total R positive hobe na. '
                '${kCostPct.toStringAsFixed(2)}% khoroch dhorle '
                '${costTotal.toStringAsFixed(2)}R (win rate ${costWin.toStringAsFixed(1)}%).',
        style: TextStyle(
          color: r.closed < 20 ? K.orange : (good ? K.green : K.red),
          fontSize: 11,
          height: 1.45,
        ),
      ),
      if (r.closed < 20) ...<Widget>[
        const SizedBox(height: 6),
        Text(
          'Sample choto: matro ${r.closed} ta trade nishpotti hoyeche '
          '(${r.open} ta OPEN). Eta diye strategy judge kora jabe na — '
          'aro purono candle dorkar.',
          style: const TextStyle(color: K.orange, fontSize: 11, height: 1.4),
        ),
      ],
      const SizedBox(height: 10),
      Row(
        children: <Widget>[
          Expanded(
            child: _miniStat('Trades', '$n', K.text),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _miniStat(
                'Win / Loss', '${r.wins} / ${r.losses}', K.text,
                sub: r.open > 0 ? '+${r.open} open' : null),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _miniStat(
              'Khoroch por', '${costTotal >= 0 ? '+' : ''}${costTotal.toStringAsFixed(2)}R',
              costTotal >= 0 ? K.green : K.red,
              sub: '${kCostPct.toStringAsFixed(2)}% fee',
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        children: <Widget>[
          Expanded(
            child: _miniStat(
              'Avg R / trade',
              '${r.avgR >= 0 ? '+' : ''}${r.avgR.toStringAsFixed(2)}R',
              r.avgR >= 0 ? K.green : K.red,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _miniStat(
              'Strict only',
              '${r.strictWinRate.toStringAsFixed(0)}% (${r.strictTotal})',
              K.blue,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _miniStat(
              'Streak',
              '${r.currentStreak > 0 ? '+' : ''}${r.currentStreak}',
              r.currentStreak >= 0 ? K.green : K.red,
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: K.panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: K.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('Sample',
                style: TextStyle(
                    color: K.text, fontSize: 12, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(
              '${r.symbol} • ${r.barsUsed} bar 15M '
              '(${_date(r.startTime)} → ${_date(r.endTime)})',
              style: const TextStyle(color: K.muted, fontSize: 11, height: 1.4),
            ),
            const SizedBox(height: 4),
            Text(
              'Win rate ${r.winRate.toStringAsFixed(0)}% mane ${r.closed} ta '
              'nishpotti trade er ${r.wins} ta TP hit koreche. '
              'TP 15M swing ba 2R, SL structure theke. Goro reward:risk '
              '${rr.toStringAsFixed(2)}, tai breakeven win rate '
              '${be.toStringAsFixed(1)}%. Win rate er cheye ei tulonai dekho.',
              style: const TextStyle(color: K.muted, fontSize: 11, height: 1.4),
            ),
            const SizedBox(height: 4),
            Text(
              'Khoroch (${kCostPct.toStringAsFixed(2)}% fee+spread): '
              '${costTotal >= 0 ? '+' : ''}${costTotal.toStringAsFixed(2)}R, '
              'win rate ${costWin.toStringAsFixed(1)}%. '
              'Khoroch chara ei strategy ta labh er, khoroch dhore na.',
              style: TextStyle(
                color: costTotal >= 0 ? K.green : K.orange,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      const Text('Trade list',
          style: TextStyle(
              color: K.text, fontSize: 13, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      ...r.trades.reversed.map(_tradeRow),
    ];
  }

  String _date(DateTime t) =>
      '${t.day}/${t.month}/${t.year % 100}';

  Widget _tradeRow(BacktestTrade t) {
    final color = t.outcome == 'TP'
        ? K.green
        : t.outcome == 'SL'
            ? K.red
            : K.muted;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: K.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: K.line),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 3,
            height: 20,
            decoration: BoxDecoration(
              color: t.isBuy ? K.green : K.red,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(t.isBuy ? 'BUY' : 'SELL',
              style: TextStyle(
                  color: t.isBuy ? K.green : K.red,
                  fontSize: 11,
                  fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          if (t.watch)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Text('WATCH',
                  style: TextStyle(
                      color: K.orange, fontSize: 8, fontWeight: FontWeight.bold)),
            ),
          Expanded(
            child: Text(
              '${fmtPrice(t.entry)} → ${fmtPrice(t.tp)}',
              style: const TextStyle(color: K.muted, fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '${t.outcome} ${t.outcome == 'OPEN' ? '' : '${t.rMultiple >= 0 ? '+' : ''}${t.rMultiple.toStringAsFixed(1)}R'}',
            style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _statCard(String label, String value, Color color) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: K.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Column(
        children: <Widget>[
          Text(label,
              style: const TextStyle(color: K.muted, fontSize: 11)),
          const SizedBox(height: 6),
          Text(value,
              style: TextStyle(
                  color: color, fontSize: 30, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _miniStat(String label, String value, Color color, {String? sub}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: K.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: K.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: const TextStyle(color: K.muted, fontSize: 9)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value,
                style: TextStyle(
                    color: color, fontSize: 14, fontWeight: FontWeight.bold)),
          ),
          if (sub != null)
            Text(sub,
                style: const TextStyle(color: K.muted, fontSize: 9)),
        ],
      ),
    );
  }
}


/// MACD buy-only on 3-minute candles -- its own screen, as asked.
///
/// The rule is exactly the one measured in `tool/mirror/measure_macd.py`:
/// BUY when the MACD line is above its signal line **and** the histogram is
/// rising. Nothing else is consulted -- no SMC structure, no order blocks, no
/// order-block entry. That is the point of a separate screen: it must not look
/// like the main scanner's confidence, because it is not the same evidence.
///
/// What the measurement says, and therefore what this screen says:
///
///   stop 3x ATR50, target 2R, 0.25% round trip, 6 seeds x 4 regimes:
///     4787 trades, 35.6% win rate, gross +328.0R, net -422.5R
///
/// Gross is positive and better than taking every bar (+328R vs +286R), so the
/// MACD filter does select. The fee is simply larger than the edge. That is
/// printed on the screen rather than left for the user to discover.
class MacdScreen extends StatefulWidget {
  const MacdScreen({Key? key}) : super(key: key);

  @override
  State<MacdScreen> createState() => _MCS();
}

class _MacdHit {
  _MacdHit(this.symbol, this.macd, this.signal, this.hist, this.prevHist,
      this.entry, this.sl, this.tp, this.staleBars);

  final String symbol;
  final double macd;
  final double signal;
  final double hist;
  final double prevHist;
  final double entry;
  final double sl;
  final double tp;

  /// Closed 3M bars since the histogram first started rising. 0 = this bar.
  final int staleBars;

  double get risk => (entry - sl).abs();
  double get riskPct => entry <= 0 ? 0 : risk / entry * 100;
  bool get worthTaking => riskPct >= kMinStopPct * 100;
}

class _MCS extends State<MacdScreen> {
  bool _loading = false;
  String _msg = 'Scan shuru koro';
  final List<_MacdHit> _hits = <_MacdHit>[];

  Future<void> run() async {
    setState(() {
      _loading = true;
      _hits.clear();
      _msg = '3M MACD scanning...';
    });
    try {
      final coins = await MarketData.marketScan(
        gainers: MarketData.scanTarget ~/ 2,
        losers: MarketData.scanTarget ~/ 2,
      );
      var done = 0;
      for (final c in coins) {
        var bars = <Candle>[];
        try {
          bars = await MarketData.candles(c.symbol, '3m', 500, scan: true);
        } catch (_) {
          continue;
        }
        done++;
        if (done % 10 == 0) {
          setState(() => _msg = '3M MACD $done/${coins.length}');
        }
        if (bars.length < 60) continue;
        final closes = bars.map((k) => k.close).toList();
        final m = Engine.macd(closes);
        if (m == null) continue;
        final line = m[0];
        final sig = m[1];
        final hist = m[2];
        final prevHist = m[3];
        if (!(line > sig && hist > prevHist)) continue;

        // How long has the histogram been rising? Recomputed from the shared
        // EMA series rather than by calling macd() on every prefix (that is
        // O(n^2) per coin -- 200 recalculations of 500 bars x 400 coins).
        final rising = Engine.histRisingBars(closes);

        final atr = Engine.atr(bars, period: 50);
        if (atr <= 0) continue;
        // 3x ATR50: the multiple that cleared the 0.5% stop floor on 3M data
        // (a 1x stop is ~0.4%, which the engine refuses).
        final risk = atr * 3;
        final entry = bars.last.close;
        _hits.add(_MacdHit(c.symbol, line, sig, hist, prevHist,
            entry, entry - risk, entry + risk * 2, rising));
      }
      _hits.sort((a, b) => a.staleBars.compareTo(b.staleBars));
      setState(() {
        _loading = false;
        _msg = _hits.isEmpty
            ? 'Ekhon kono 3M MACD buy nei (${coins.length} coin dekha holo)'
            : '${_hits.length} coin-e 3M MACD buy (${coins.length} scanned)';
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _msg = 'Scan fail: ${e.toString().split(':').first}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: K.bg,
      appBar: AppBar(
        backgroundColor: K.panel,
        title: const Text('MACD buy · 3M',
            style: TextStyle(color: K.text, fontSize: 16)),
        iconTheme: const IconThemeData(color: K.text),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.refresh, color: K.text),
            onPressed: _loading ? null : run,
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: K.line)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Text(
                      _msg,
                      style: const TextStyle(color: K.text, fontSize: 12),
                    ),
                    if (_loading)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: K.green),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Rule: MACD(12/26/9) line > signal AND histogram rising. '
                  'Buy only. Stop 3x ATR50, target 2R.',
                  style: TextStyle(color: K.muted, fontSize: 10, height: 1.4),
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: K.orange.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: K.orange.withOpacity(0.35)),
                  ),
                  child: const Text(
                    'Measured on 4787 trades: gross +328R, net -422R at 0.25% '
                    'round trip. MACD selects better than random (+328R vs '
                    '+286R) but the fee is bigger than the edge. Use it as a '
                    'filter for your own idea, not as a signal to follow.',
                    style: TextStyle(color: K.orange, fontSize: 10, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: run,
              color: K.green,
              backgroundColor: K.panel,
              child: _hits.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: <Widget>[
                        SizedBox(
                            height:
                                MediaQuery.of(context).size.height * 0.12),
                        Icon(
                          _loading ? Icons.hourglass_empty : Icons.search_off,
                          size: 42,
                          color: K.muted,
                        ),
                        const SizedBox(height: 10),
                        Center(
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 30),
                            child: Text(
                              _loading
                                  ? 'Scanning...'
                                  : 'Run chapo — 400 coin-e 3M MACD check hobe. '
                                      'Eta 3-4 minute nite pare.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: K.muted, fontSize: 12, height: 1.5),
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
                      itemCount: _hits.length,
                      itemBuilder: (context, i) => _macdCard(_hits[i]),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _macdCard(_MacdHit h) {
    final fresh = h.staleBars == 0;
    final color = fresh ? K.green : K.orange;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: K.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: K.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  h.symbol.replaceAll('USDT', ''),
                  style: const TextStyle(
                      color: K.text,
                      fontSize: 15,
                      fontWeight: FontWeight.bold),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.16),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  fresh ? 'BUY now' : 'rising ${h.staleBars} bar',
                  style: TextStyle(
                      color: color,
                      fontSize: 9,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              _mcell('ENTRY', fmtPrice(h.entry), K.text),
              _mcell('SL', fmtPrice(h.sl), K.red),
              _mcell('TP', fmtPrice(h.tp), K.green),
              _mcell('RISK', '${h.riskPct.toStringAsFixed(2)}%',
                  kMinStopPct * 100 > h.riskPct ? K.red : K.muted),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'MACD ${h.macd.toStringAsFixed(4)} > signal '
            '${h.signal.toStringAsFixed(4)} · hist ${h.hist.toStringAsFixed(4)} '
            '(prev ${h.prevHist.toStringAsFixed(4)})',
            style: const TextStyle(color: K.muted, fontSize: 10),
          ),
          if (!h.worthTaking) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              'Stop ${h.riskPct.toStringAsFixed(2)}% — '
              '${(kMinStopPct * 100).toStringAsFixed(1)}% floor-er niche, '
              'fee ek R-er boro hissa khaye. Trade na.',
              style: const TextStyle(color: K.orange, fontSize: 10),
            ),
          ],
        ],
      ),
    );
  }

  Widget _mcell(String label, String value, Color color) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(label,
                style: const TextStyle(color: K.muted, fontSize: 9)),
            const SizedBox(height: 3),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value,
                  style: TextStyle(
                      color: color,
                      fontSize: 13,
                      fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
}
