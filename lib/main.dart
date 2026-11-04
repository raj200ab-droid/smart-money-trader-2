import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

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
    required this.bos,
    required this.sweep,
    required this.buyScore,
    required this.sellScore,
    required this.volumeSpike,
    required this.buyConf,
    required this.sellConf,
    required this.obs,
    required this.fvgs,
    required this.candles,
    required this.close,
    required this.atr,
    required this.trend,
    required this.choch,
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
  });

  final String timeframe;
  final String structure;
  final String? bos;
  final String? sweep;
  final double buyScore;
  final double sellScore;
  final bool volumeSpike;
  final List<String> buyConf;
  final List<String> sellConf;
  final List<OrderBlock> obs;
  final List<FVG> fvgs;
  final List<Candle> candles;
  final double close;
  final double atr;

  /// 1 = bullish, -1 = bearish, 0 = unknown. Swing (not internal) trend.
  final int trend;
  final bool choch;

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

  static const Duration _lag = Duration(
    milliseconds: 120,
  );

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

  static const List<String> _leveragedSuffixes = <String>[
    'UPUSDT',
    'DOWNUSDT',
    'BULLUSDT',
    'BEARUSDT',
    '3LUSDT',
    '3SUSDT',
  ];

  static String baseOf(String symbol) => symbol.replaceAll('USDT', '');

  static bool _isTradable(CoinData c) {
    if (!c.symbol.endsWith('USDT')) return false;
    if (c.symbol == 'USDTUSDT') return false;
    if (_skip.contains(c.symbol)) return false;
    for (final suffix in _leveragedSuffixes) {
      if (c.symbol.endsWith(suffix)) return false;
    }
    if (c.lastPrice <= 0) return false;
    return c.quoteVolume > 5000000; // 5M USDT daily volume
  }

  /// Top gainers + top losers so both BUY and SELL setups can appear.
  ///
  /// Binance is geo-blocked in many regions; if every mirror fails we walk
  /// the other feeds, because each one exposes the same USDT pairs.
  static Future<List<CoinData>> marketScan({
    int gainers = 60,
    int losers = 40,
  }) async {
    var errors = <String>[];

    final attempt = await _scanOnce(gainers, losers, errors);
    if (attempt.isNotEmpty) return attempt;

    // Every feed is still cooling down after a failed scan (the skip window).
    // skip window). Waiting is free here: the scan itself takes minutes.
    if (_feeds.every(_isDown)) {
      await Future<void>.delayed(const Duration(seconds: 20));
      errors = <String>[];
      final retry = await _scanOnce(gainers, losers, errors);
      if (retry.isNotEmpty) return retry;
    }

    activeFeed = '';
    throw MarketDataException(errors.isEmpty ? 'no feed' : errors.join(' | '));
  }

  static Future<List<CoinData>> _scanOnce(
    int gainers,
    int losers,
    List<String> errors,
  ) async {
    for (final feed in _feeds) {
      if (_isDown(feed)) {
        errors.add('${feed.name}: skipped (recently failed)');
        continue;
      }
      try {
        final all = await _tickers(feed);
        final picked = _pick(all, gainers, losers);
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
    return out;
  }

  static Future<List<Candle>> candles(
    String sym,
    String tf,
    int lim,
  ) async {
    final full = _feedOrder();
    var order = full.where((f) => !_isDown(f)).toList();
    if (order.isEmpty) order = full; // everything marked down: try again

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

  static Future<List<CoinData>> _binanceTickers() async {
    Object? last;
    for (final base in _binanceMirrors) {
      try {
        final data = await _getJson('$base/ticker/24hr') as List<dynamic>;
        final list = data
            .map((e) => CoinData.fromJson(e as Map<String, dynamic>))
            .where(_isTradable)
            .toList();
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
      if (_isTradable(coin)) out.add(coin);
    }
    return out;
  }

  /// OKX spot tickers, symbol format BTC-USDT.
  static Future<List<CoinData>> _okxTickers() async {
    final resp = await _getJson(
      'https://www.okx.com/api/v5/market/tickers?instType=SPOT',
    ) as Map<String, dynamic>;
    final rows = (resp['data'] as List<dynamic>?) ?? <dynamic>[];
    final out = <CoinData>[];
    for (final row in rows) {
      final m = row as Map<String, dynamic>;
      final inst = m['instId']?.toString() ?? '';
      if (!inst.endsWith('-USDT')) continue;
      final open = _d(m['open24h']);
      final px = _d(m['last']);
      final coin = CoinData(
        symbol: '${inst.split('-').first}USDT',
        lastPrice: px,
        priceChangePercent: open > 0 ? (px - open) / open * 100 : 0,
        highPrice: _d(m['high24h']),
        lowPrice: _d(m['low24h']),
        quoteVolume: _d(m['volCcy24h']),
      );
      if (_isTradable(coin)) out.add(coin);
    }
    return out;
  }

  /// MEXC spot tickers.
  static Future<List<CoinData>> _mexcTickers() async {
    final data = await _getJson(
      'https://api.mexc.com/api/v3/ticker/24hr',
    ) as List<dynamic>;
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
      if (_isTradable(coin)) out.add(coin);
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

  static String _bybitInterval(String tf) {
    switch (tf) {
      case '15m':
        return '15';
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
      case '15m':
        return '15m';
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
    final data = await _getJson(
      'https://www.okx.com/api/v5/market/candles'
      '?instId=$inst&bar=${_okxBar(tf)}&limit=$lim',
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
      case '15m':
        return '15m';
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
    var os = 0;
    for (int n = 1; n < c.length; n++) {
      double upper = double.negativeInfinity;
      double lower = double.infinity;
      for (int i = n - len; i < n; i++) {
        if (i < 0) continue;
        if (c[i].high > upper) upper = c[i].high;
        if (c[i].low < lower) lower = c[i].low;
      }
      // Window incomplete or degenerate: keep the previous state.
      if (upper == double.negativeInfinity || lower == double.infinity) {
        continue;
      }

      final int prev = os;
      if (n - len >= 0) {
        if (c[n - len].high > upper) {
          os = 0;
        } else if (c[n - len].low < lower) {
          os = 1;
        }
      }

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

  /// Order blocks that price has not closed through yet (LUX mitigation).
  static List<OrderBlock> activeObs(List<OrderBlock> obs, List<Candle> c) {
    final out = <OrderBlock>[];
    for (final o in obs) {
      bool broken = false;
      for (int i = o.index + 1; i < c.length; i++) {
        if (o.type == 'bearish' && c[i].close < o.low) {
          broken = true;
          break;
        }
        if (o.type == 'bullish' && c[i].close > o.high) {
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
  static bool equalHighs(List<SwingPoint> pts, double atrValue,
      {double threshold = 0.1}) {
    final highs = pts.where((p) => p.type == 'high').toList();
    if (highs.length < 2 || atrValue <= 0) return false;
    final a = highs[highs.length - 1].price;
    final b = highs[highs.length - 2].price;
    return (max(a, b) - min(a, b)) < atrValue * threshold;
  }

  static bool equalLows(List<SwingPoint> pts, double atrValue,
      {double threshold = 0.1}) {
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
    final trend = trendOf(pts);

    final recent = breaks(c, pts, barsBack: 30);
    final internalRecent = breaks(c, internal, len: internalLen, barsBack: 6);

    final atr200 = atr(c, period: 200);
    final atrPer = atr(c);
    final swingAtr = atr200 > 0 ? atr200 : atrPer;

    final lastBreak = recent.isEmpty ? null : recent.last;
    final event = lastBreak?.event ?? '';
    final pattern = lastBreak?.pattern ?? '';
    final breakFresh = lastBreak != null && c.length - 1 - lastBreak.bar <= 2;

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
    final eqh = equalHighs(pts, swingAtr);
    final eql = equalLows(pts, swingAtr);
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
    }

    final px = c.last.close;
    final insideRange = lastHigh != null &&
        lastLow != null &&
        px <= lastHigh.price &&
        px >= lastLow.price;
    final inPremium = insideRange && premium > 0 && px > premium;
    final inDiscount = insideRange && premium > 0 && px < discount;

    double bs = 0;
    double ss = 0;
    final bc = <String>[];
    final sc = <String>[];

    if (trend > 0) {
      bs += 25;
      bc.add('Bullish structure');
    }
    if (trend < 0) {
      ss += 25;
      sc.add('Bearish structure');
    }

    if (breakFresh && event == 'BULLISH') {
      bs += 25;
      bc.add(pattern == 'CHoCH' ? 'Bullish CHoCH' : 'Bullish BOS');
    }
    if (breakFresh && event == 'BEARISH') {
      ss += 25;
      sc.add(pattern == 'CHoCH' ? 'Bearish CHoCH' : 'Bearish BOS');
    }

    final internalLast = internalRecent.isEmpty ? null : internalRecent.last;
    final internalFresh = internalLast != null &&
        c.length - 1 - internalLast.bar <= 4;
    if (internalFresh && internalLast.event == 'BULLISH') {
      bs += 10;
      bc.add('Internal bullish break');
    }
    if (internalFresh && internalLast.event == 'BEARISH') {
      ss += 10;
      sc.add('Internal bearish break');
    }

    for (final o in active) {
      if (px >= o.low * 0.998 && px <= o.high * 1.002) {
        if (o.type == 'bullish') {
          bs += 20;
          bc.add('Inside bullish OB');
        } else {
          ss += 20;
          sc.add('Inside bearish OB');
        }
      }
    }
    for (final f in fvgList) {
      if (px >= f.low * 0.998 && px <= f.high * 1.002) {
        if (f.type == 'bullish') {
          bs += 10;
          bc.add('Inside bullish FVG');
        } else {
          ss += 10;
          sc.add('Inside bearish FVG');
        }
      }
    }

    if (eql) {
      bs += 10;
      bc.add('Equal lows (liquidity)');
    }
    if (eqh) {
      ss += 10;
      sc.add('Equal highs (liquidity)');
    }
    if (vs) {
      bs += 5;
      ss += 5;
      bc.add('Volume spike');
      sc.add('Volume spike');
    }

    // Premium/discount: never buy at a premium, never sell at a discount.
    if (inPremium) {
      bs -= 20;
      sc.add('Premium zone');
    }
    if (inDiscount) {
      ss -= 20;
      bc.add('Discount zone');
    }

    return TFAnalysis(
      timeframe: tf,
      structure: trend > 0
          ? 'BULLISH'
          : trend < 0
              ? 'BEARISH'
              : 'NEUTRAL',
      bos: event.isEmpty ? null : (breakFresh ? '${event}_BOS' : null),
      sweep: null,
      buyScore: bs,
      sellScore: ss,
      volumeSpike: vs,
      buyConf: bc,
      sellConf: sc,
      obs: active,
      fvgs: fvgList,
      candles: c,
      close: px,
      atr: atrPer,
      trend: trend,
      choch: pattern == 'CHoCH',
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
    );
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
    bool relaxed = false,
  }) {
    if (c4.length < 60 || c1.length < 60 || c15.length < 60) return null;

    final t4 = analyze('4H', c4);
    final t1 = analyze('1H', c1);
    final t15 = analyze('15M', c15);
    final px = c15.last.close;
    if (px <= 0) return null;

    // Bias: 4H structure, or a break that just happened. When 4H structure is
    // neutral we accept a fresh 4H internal break confirmed by the 1H trend.
    final bull4 = t4.trend > 0 ||
        (t4.freshBreak && t4.breakEvent == 'BULLISH') ||
        (t4.trend == 0 &&
            t4.internalFresh &&
            t4.internalEvent == 'BULLISH' &&
            t1.trend > 0);
    final bear4 = t4.trend < 0 ||
        (t4.freshBreak && t4.breakEvent == 'BEARISH') ||
        (t4.trend == 0 &&
            t4.internalFresh &&
            t4.internalEvent == 'BEARISH' &&
            t1.trend < 0);

    double buy = 0;
    double sell = 0;
    final bC = <String>[];
    final sC = <String>[];

    if (bull4) {
      buy += 30;
      bC.add('4H bullish bias');
    }
    if (bear4) {
      sell += 30;
      sC.add('4H bearish bias');
    }

    final buyOb = buyZone(t1.obs, px);
    final sellOb = sellZone(t1.obs, px);

    if (bull4 && buyOb != null) {
      buy += 25;
      bC.add('1H bullish OB');
    }
    if (bear4 && sellOb != null) {
      sell += 25;
      sC.add('1H bearish OB');
    }

    final bullFvg = t1.fvgs.any((f) =>
        f.type == 'bullish' && f.high <= px * 1.005 && f.low > px * 0.94);
    final bearFvg = t1.fvgs.any((f) =>
        f.type == 'bearish' && f.low >= px * 0.995 && f.high < px * 1.06);

    // A fair value gap counts as the zone when no order block is available.
    if (bull4 && bullFvg) {
      buy += buyOb == null ? 20 : 10;
      bC.add('1H bullish FVG');
    }
    if (bear4 && bearFvg) {
      sell += sellOb == null ? 20 : 10;
      sC.add('1H bearish FVG');
    }

    final triggerBull = t15.freshBreak && t15.breakEvent == 'BULLISH';
    final triggerBear = t15.freshBreak && t15.breakEvent == 'BEARISH';
    final internalBull = t15.internalFresh && t15.internalEvent == 'BULLISH';
    final internalBear = t15.internalFresh && t15.internalEvent == 'BEARISH';

    if (triggerBull) {
      buy += 20;
      bC.add(t15.breakPattern == 'CHoCH'
          ? '15M bullish CHoCH'
          : '15M bullish BOS');
    } else if (internalBull) {
      buy += 20;
      bC.add('15M internal bullish break');
    }
    if (triggerBear) {
      sell += 20;
      sC.add(t15.breakPattern == 'CHoCH'
          ? '15M bearish CHoCH'
          : '15M bearish BOS');
    } else if (internalBear) {
      sell += 20;
      sC.add('15M internal bearish break');
    }

    if (t15.volumeSpike) {
      if (bull4) {
        buy += 5;
        bC.add('15M volume spike');
      } else if (bear4) {
        sell += 5;
        sC.add('15M volume spike');
      }
    }

    // Premium/discount of the 1H swing range gates the direction. A breakout
    // above/below the range is trend continuation, not a bad location.
    final zoneNow = t1.zoneOf;
    if (zoneNow == 'Premium') {
      buy -= 25;
      sC.add('1H premium zone');
    }
    if (zoneNow == 'Discount') {
      sell -= 25;
      bC.add('1H discount zone');
    }
    if (zoneNow == 'Breakout' && bull4) {
      buy += 5;
      bC.add('1H breakout');
    }
    if (zoneNow == 'Breakdown' && bear4) {
      sell += 5;
      sC.add('1H breakdown');
    }

    final atr1 = t1.atr > 0 ? t1.atr : px * 0.01;
    final zoneLabel = t1.zoneOf;

    // 30 is a frozen 4H bias with nothing else: still not a trade.
    final threshold = relaxed ? 40.0 : 60.0;

    final bool trigBuy = triggerBull || internalBull;
    final bool trigSell = triggerBear || internalBear;

    if (buy >= threshold && bull4 && !bear4 && trigBuy && buy > sell) {
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
      final target =
          t15.swingHigh != null && t15.swingHigh!.price > entry * 1.005
          ? t15.swingHigh!.price
          : entry + risk * 2;

      return TradeSignal(
        symbol: sym,
        direction: 'BUY',
        price: px,
        entry: entry,
        sl: sl,
        tp: target,
        confidence: buy.clamp(0.0, 100.0).toDouble(),
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
      );
    }

    if (sell >= threshold && bear4 && !bull4 && trigSell && sell > buy) {
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
      final target = t15.swingLow != null && t15.swingLow!.price < entry * 0.995
          ? t15.swingLow!.price
          : entry - risk * 2;

      return TradeSignal(
        symbol: sym,
        direction: 'SELL',
        price: px,
        entry: entry,
        sl: sl,
        tp: target,
        confidence: sell.clamp(0.0, 100.0).toDouble(),
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
      );
    }

    return null;
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

  int get strictTotal => trades.where((t) => !t.watch).length;
  int get strictWins =>
      trades.where((t) => !t.watch && t.outcome == 'TP').length;
  int get strictClosed =>
      trades.where((t) => !t.watch && t.outcome != 'OPEN').length;
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

  /// Runs the engine over [bars], stepping forward one bar per signal check.
  /// A trade is only opened when no earlier trade is still open, which keeps
  /// the statistics honest (no overlapping copies of the same move).
  static BacktestResult run(
    String symbol,
    List<Candle> c4,
    List<Candle> c1,
    List<Candle> c15, {
    int step = 1,
    int maxTrades = 60,
  }) {
    final trades = <BacktestTrade>[];
    final n = c15.length;
    if (n < window + 20) {
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
    int lastSignalBar = -window;

    for (int i = window; i < n - 1; i += step) {
      if (i <= openUntil) continue; // still in a trade
      if (i - lastSignalBar < 2) continue; // do not spam the same move

      final w15 = c15.sublist(i - window, i + 1);
      final w1 = _aligned(c1, c15[i].closeTime, window);
      final w4 = _aligned(c4, c15[i].closeTime, window);
      if (w1 == null || w4 == null) continue;

      var sig = Engine.multiTF(symbol, w4, w1, w15);
      sig ??= Engine.multiTF(symbol, w4, w1, w15, relaxed: true);
      if (sig == null) continue;

      // Follow the trade on the 15M series.
      String outcome = 'OPEN';
      double rMult = 0;
      for (int j = i + 1; j < n; j++) {
        final bar = c15[j];
        final hitSl = sig.isBuy ? bar.low <= sig.sl : bar.high >= sig.sl;
        final hitTp = sig.isBuy ? bar.high >= sig.tp : bar.low <= sig.tp;
        if (hitSl && hitTp) {
          outcome = 'SL'; // ambiguous bar: assume the worst
          rMult = -1;
          openUntil = j;
          break;
        }
        if (hitSl) {
          outcome = 'SL';
          rMult = -1;
          openUntil = j;
          break;
        }
        if (hitTp) {
          outcome = 'TP';
          rMult = (sig.tp - sig.entry).abs() / (sig.sl - sig.entry).abs();
          openUntil = j;
          break;
        }
      }

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

    final first = c15.length > window ? c15[window] : c15.first;
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

class _HS extends State<HomeScreen> {
  final List<TradeSignal> _signals = <TradeSignal>[];

  bool _loading = true;
  String _msg = 'Starting...';
  String _filter = 'ALL';
  int _done = 0;
  int _total = 0;
  int _failed = 0;
  int _scanId = 0;
  String _feed = '';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    run();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (!_loading) run();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> run() async {
    final id = ++_scanId;

    if (mounted) {
      setState(() {
        _loading = true;
        _signals.clear();
        _msg = 'Top movers khujchi...';
        _feed = '';
        _done = 0;
        _total = 0;
        _failed = 0;
      });
    }

    try {
      final coins = await MarketData.marketScan(gainers: 60, losers: 40);
      if (id != _scanId || !mounted) return;

      setState(() {
        _feed = MarketData.activeFeed;
        _total = coins.length;
        _msg = '${coins.length} coins found '
            '(${MarketData.activeFeed}). Analyzing...';
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

      int next = 0;

      Future<void> worker() async {
        while (true) {
          final i = next;
          next++;
          if (i >= coins.length) return;
          if (id != _scanId || !mounted) return;

          final sym = coins[i].symbol;
          try {
            final c4 = await MarketData.candles(sym, '4h', 200);
            final c1 = await MarketData.candles(sym, '1h', 200);
            final c15 = await MarketData.candles(sym, '15m', 200);

            if (id != _scanId || !mounted) return;

            // Strict SMC confluence first; fall back to the relaxed pass so
            // the list is not empty in quiet markets (flagged WATCH).
            var sig = Engine.multiTF(sym, c4, c1, c15);
            sig ??= Engine.multiTF(sym, c4, c1, c15, relaxed: true);
            if (mounted) {
              setState(() {
                if (sig != null) _signals.add(sig);
              });
            }
          } catch (_) {
            if (mounted) setState(() => _failed++);
          }

          if (mounted) {
            setState(() {
              _done++;
              _msg = 'Analyzing $sym ($_done/$_total)';
            });
          }

          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
      }

      await Future.wait(<Future<void>>[
        for (int w = 0; w < 4; w++) worker(),
      ]);

      if (id != _scanId || !mounted) return;

      setState(() {
        _signals.sort((a, b) => b.confidence.compareTo(a.confidence));
        _loading = false;
        final strict = _signals.where((s) => !s.watch).length;
        final watch = _signals.length - strict;
        _msg = _signals.isEmpty
            ? 'Kono setup nei ekhon ($_feed). 5 min por auto refresh hobe.'
            : '$strict signal • $watch watch ($_feed)'
                '${_failed > 0 ? ' • $_failed coin skip' : ''}';
      });
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
            children: const <Widget>[
              _TfBadge('4H', K.blue),
              SizedBox(width: 4),
              _TfBadge('1H', Color(0xFFA371F7)),
              SizedBox(width: 4),
              _TfBadge('15M', K.orange),
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

  Widget _list() {
    final items = _visible;

    if (_loading && items.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: K.green),
      );
    }

    if (items.isEmpty) {
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
                    ? 'No setup right now'
                    : 'No $_filter signals',
                style: const TextStyle(
                  color: K.text,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 6),
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 34),
                child: Text(
                  'Engine 4H bias + 1H OB/FVG + 15M trigger khujche. '
                  'Auto refresh every 5 min.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: K.muted, fontSize: 12, height: 1.4),
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
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: run,
      color: K.green,
      backgroundColor: K.panel,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
        itemCount: items.length,
        itemBuilder: (context, i) => _SignalCard(
          signal: items[i],
          onTap: () => _showDetails(items[i]),
        ),
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
                _detailRow('Entry', fmtPrice(s.entry)),
                _detailRow('Stop loss', fmtPrice(s.sl), K.red),
                _detailRow('Take profit', fmtPrice(s.tp), K.green),
                _detailRow('Risk / Reward', '1 : ${s.rr.toStringAsFixed(2)}'),
                _detailRow('Expected move', fmtPct(s.profitPct), K.green),
                _detailRow('Risk', fmtPct(-s.riskPct)),
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
                _detailRow('Setup', s.watch ? 'WATCH (relaxed)' : 'STRICT',
                    s.watch ? K.orange : K.green),
                _detailRow('Pattern', s.pattern,
                    s.pattern == 'CHoCH' ? K.orange : K.green),
                _detailRow('1H zone', s.zone,
                    s.zone == 'Discount'
                        ? K.green
                        : s.zone == 'Premium'
                            ? K.red
                            : K.muted),
                _detailRow('Liquidity',
                    '${s.eqh ? 'EQH ' : ''}${s.eql ? 'EQL' : ''}'.trim().isEmpty
                        ? 'None'
                        : '${s.eqh ? 'EQH ' : ''}${s.eql ? 'EQL' : ''}'.trim()),
                _detailRow('4H structure', s.tf4h),
                _detailRow('1H structure', s.tf1h),
                _detailRow('15M structure', s.tf15m),
                _detailRow('Generated', timeAgo(s.time)),
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
  const _SignalCard({required this.signal, required this.onTap});

  final TradeSignal signal;
  final VoidCallback onTap;

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
                          if (signal.watch) ...<Widget>[
                            Container(
                              margin: const EdgeInsets.only(right: 5),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: K.orange.withOpacity(0.18),
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: const Text(
                                'WATCH',
                                style: TextStyle(
                                  color: K.orange,
                                  fontSize: 8,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                          Flexible(
                            child: Text(
                              '${signal.direction} • ${signal.pattern} • '
                              '${signal.zone} • ${timeAgo(signal.time)}',
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
                    Text(
                      '${signal.confidence.toStringAsFixed(0)}%',
                      style: TextStyle(
                        color: color,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
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
      final c4 = await MarketData.candles(symbol, '4h', 1000);
      final c1 = await MarketData.candles(symbol, '1h', 1000);
      final c15 = await MarketData.candles(symbol, '15m', 1000);
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
            : '${result.total} trade • win rate '
                '${result.winRate.toStringAsFixed(0)}%';
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
    return <Widget>[
      _statCard('Win rate', '${r.winRate.toStringAsFixed(1)}%',
          r.winRate >= 50 ? K.green : K.orange),
      const SizedBox(height: 10),
      Row(
        children: <Widget>[
          Expanded(
            child: _miniStat('Trades', '$n', K.text),
          ),
          const SizedBox(width: 8),
          Expanded(child: _miniStat('Win / Loss', '${r.wins} / ${r.losses}', K.text)),
          const SizedBox(width: 8),
          Expanded(
            child: _miniStat(
              'Total R',
              '${r.totalR >= 0 ? '+' : ''}${r.totalR.toStringAsFixed(2)}R',
              good ? K.green : K.red,
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
              'Win rate ${r.winRate.toStringAsFixed(0)}% mane protiti 3 trade e '
              '2 tar target hobe. R positive hole strategy labh e ache.',
              style: const TextStyle(color: K.muted, fontSize: 11, height: 1.4),
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

  Widget _miniStat(String label, String value, Color color) {
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
        ],
      ),
    );
  }
}

