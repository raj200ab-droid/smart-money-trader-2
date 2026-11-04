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
// =====================================================================

class Engine {
  /// Pivot highs / lows with [lb] candles on each side.
  static List<SwingPoint> swings(List<Candle> c, {int lb = 5}) {
    final pts = <SwingPoint>[];
    if (c.length < lb * 2 + 1) return pts;
    for (int i = lb; i < c.length - lb; i++) {
      bool isHigh = true;
      bool isLow = true;
      for (int j = i - lb; j <= i + lb; j++) {
        if (j == i) continue;
        if (c[j].high >= c[i].high) isHigh = false;
        if (c[j].low <= c[i].low) isLow = false;
      }
      if (isHigh) pts.add(SwingPoint(price: c[i].high, index: i, type: 'high'));
      if (isLow) pts.add(SwingPoint(price: c[i].low, index: i, type: 'low'));
    }
    return pts;
  }

  /// HH+HL => BULLISH, LH+LL => BEARISH.
  static String structure(List<SwingPoint> p) {
    final h = p.where((x) => x.type == 'high').toList();
    final l = p.where((x) => x.type == 'low').toList();
    if (h.length < 2 || l.length < 2) return 'NEUTRAL';

    final higherHigh = h[h.length - 1].price > h[h.length - 2].price;
    final higherLow = l[l.length - 1].price > l[l.length - 2].price;
    final lowerHigh = h[h.length - 1].price < h[h.length - 2].price;
    final lowerLow = l[l.length - 1].price < l[l.length - 2].price;

    if (higherHigh && higherLow) return 'BULLISH';
    if (lowerHigh && lowerLow) return 'BEARISH';
    return 'NEUTRAL';
  }

  /// Break of structure measured against the last *confirmed* swing.
  static String? bos(List<Candle> c, List<SwingPoint> p, {int lb = 5}) {
    if (c.length < 3 || p.isEmpty) return null;
    final cutoff = c.length - lb - 1;
    final px = c.last.close;

    final highs =
        p.where((x) => x.type == 'high' && x.index <= cutoff).toList();
    final lows = p.where((x) => x.type == 'low' && x.index <= cutoff).toList();

    if (highs.isNotEmpty && px > highs.last.price) return 'BULLISH_BOS';
    if (lows.isNotEmpty && px < lows.last.price) return 'BEARISH_BOS';
    return null;
  }

  /// Displacement order blocks that have not been mitigated yet.
  static List<OrderBlock> obs(List<Candle> c) {
    final res = <OrderBlock>[];
    if (c.length < 20) return res;

    int start = c.length - 30;
    if (start < 0) start = 0;
    double sum = 0;
    int n = 0;
    for (int i = start; i < c.length; i++) {
      sum += c[i].bodySize;
      n++;
    }
    final avg = n > 0 ? sum / n : 0.0;
    if (avg <= 0) return res;

    int from = c.length - 80;
    if (from < 1) from = 1;

    for (int i = from; i < c.length - 1; i++) {
      final cur = c[i];
      final nxt = c[i + 1];

      if (cur.isBearish && nxt.isBullish && nxt.bodySize > avg * 1.4) {
        bool valid = true;
        for (int j = i + 2; j < c.length; j++) {
          if (c[j].close < cur.low) {
            valid = false;
            break;
          }
        }
        if (valid) {
          res.add(OrderBlock(
              high: cur.high, low: cur.low, type: 'bullish', index: i));
        }
      }

      if (cur.isBullish && nxt.isBearish && nxt.bodySize > avg * 1.4) {
        bool valid = true;
        for (int j = i + 2; j < c.length; j++) {
          if (c[j].close > cur.high) {
            valid = false;
            break;
          }
        }
        if (valid) {
          res.add(OrderBlock(
              high: cur.high, low: cur.low, type: 'bearish', index: i));
        }
      }
    }
    return res;
  }

  /// Unfilled fair value gaps.
  static List<FVG> fvgs(List<Candle> c) {
    final res = <FVG>[];
    if (c.length < 4) return res;

    int from = c.length - 80;
    if (from < 1) from = 1;

    for (int i = from; i < c.length - 1; i++) {
      final prev = c[i - 1];
      final next = c[i + 1];

      if (prev.high < next.low) {
        bool filled = false;
        for (int j = i + 2; j < c.length; j++) {
          if (c[j].low <= prev.high) {
            filled = true;
            break;
          }
        }
        if (!filled) {
          res.add(FVG(
              high: next.low, low: prev.high, type: 'bullish', index: i));
        }
      }

      if (prev.low > next.high) {
        bool filled = false;
        for (int j = i + 2; j < c.length; j++) {
          if (c[j].high >= prev.low) {
            filled = true;
            break;
          }
        }
        if (!filled) {
          res.add(FVG(
              high: prev.low, low: next.high, type: 'bearish', index: i));
        }
      }
    }
    return res;
  }

  /// Liquidity sweep inside the last 3 candles.
  static String? sweep(List<Candle> c, List<SwingPoint> p, {int lb = 5}) {
    if (c.length < lb * 2 + 2) return null;
    final cutoff = c.length - lb - 1;

    final highs =
        p.where((x) => x.type == 'high' && x.index <= cutoff).toList();
    final lows = p.where((x) => x.type == 'low' && x.index <= cutoff).toList();

    int from = c.length - 3;
    if (from < 0) from = 0;

    for (int i = from; i < c.length; i++) {
      if (lows.isNotEmpty &&
          c[i].low < lows.last.price &&
          c[i].close > lows.last.price) {
        return 'BULLISH_SWEEP';
      }
      if (highs.isNotEmpty &&
          c[i].high > highs.last.price &&
          c[i].close < highs.last.price) {
        return 'BEARISH_SWEEP';
      }
    }
    return null;
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

  /// Average true range, used for stop buffers.
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

  static TFAnalysis analyze(String tf, List<Candle> c) {
    final pts = swings(c);
    final str = structure(pts);
    final b = bos(c, pts);
    final sw = sweep(c, pts);
    final obList = obs(c);
    final fvgList = fvgs(c);
    final vs = volSpike(c);
    final px = c.last.close;

    double bs = 0;
    double ss = 0;
    final bc = <String>[];
    final sc = <String>[];

    if (str == 'BULLISH' || b == 'BULLISH_BOS') {
      bs += 25;
      bc.add('Bullish structure');
    }
    if (str == 'BEARISH' || b == 'BEARISH_BOS') {
      ss += 25;
      sc.add('Bearish structure');
    }

    for (final o in obList) {
      if (o.type == 'bullish' &&
          px >= o.low * 0.998 &&
          px <= o.high * 1.002) {
        bs += 25;
        bc.add('Inside bullish OB');
        break;
      }
    }
    for (final o in obList) {
      if (o.type == 'bearish' &&
          px >= o.low * 0.998 &&
          px <= o.high * 1.002) {
        ss += 25;
        sc.add('Inside bearish OB');
        break;
      }
    }

    for (final f in fvgList) {
      if (f.type == 'bullish' &&
          px >= f.low * 0.998 &&
          px <= f.high * 1.002) {
        bs += 15;
        bc.add('Inside bullish FVG');
        break;
      }
    }
    for (final f in fvgList) {
      if (f.type == 'bearish' &&
          px >= f.low * 0.998 &&
          px <= f.high * 1.002) {
        ss += 15;
        sc.add('Inside bearish FVG');
        break;
      }
    }

    if (sw == 'BULLISH_SWEEP') {
      bs += 15;
      bc.add('Bullish sweep');
    }
    if (sw == 'BEARISH_SWEEP') {
      ss += 15;
      sc.add('Bearish sweep');
    }

    if (vs) {
      bs += 10;
      ss += 10;
      bc.add('Volume spike');
      sc.add('Volume spike');
    }

    return TFAnalysis(
      timeframe: tf,
      structure: str,
      bos: b,
      sweep: sw,
      buyScore: bs,
      sellScore: ss,
      volumeSpike: vs,
      buyConf: bc,
      sellConf: sc,
      obs: obList,
      fvgs: fvgList,
      candles: c,
      close: px,
      atr: atr(c),
    );
  }

  /// Closest unmitigated bullish zone below price (for a BUY limit).
  static OrderBlock? _buyZone(List<OrderBlock> obs, double px) {
    OrderBlock? best;
    for (final o in obs) {
      if (o.type != 'bullish') continue;
      if (o.high > px * 1.005) continue; // must be at or below price
      if (o.low < px * 0.94) continue; // ignore far-away zones
      if (best == null || o.high > best.high) best = o;
    }
    return best;
  }

  /// Closest unmitigated bearish zone above price (for a SELL limit).
  static OrderBlock? _sellZone(List<OrderBlock> obs, double px) {
    OrderBlock? best;
    for (final o in obs) {
      if (o.type != 'bearish') continue;
      if (o.low < px * 0.995) continue; // must be at or above price
      if (o.high > px * 1.06) continue;
      if (best == null || o.low < best.low) best = o;
    }
    return best;
  }

  static bool _hasBullFvg(List<FVG> fvgs, double px) => fvgs.any((f) =>
      f.type == 'bullish' && f.high <= px * 1.005 && f.low > px * 0.94);

  static bool _hasBearFvg(List<FVG> fvgs, double px) => fvgs.any((f) =>
      f.type == 'bearish' && f.low >= px * 0.995 && f.high < px * 1.06);

  /// True when price crossed [level] within the last [lookback] closed candles
  /// of [candles] (used to require a fresh trigger, not a stale one).
  static bool _freshCross(
    List<Candle> candles,
    double level,
    bool bullish, {
    int lookback = 3,
  }) {
    if (candles.length < lookback + 1) return false;
    int from = candles.length - lookback;
    if (from < 1) from = 1;
    for (int i = from; i < candles.length; i++) {
      final prev = candles[i - 1].close;
      final cur = candles[i].close;
      if (bullish && prev <= level && cur > level) return true;
      if (!bullish && prev >= level && cur < level) return true;
    }
    return false;
  }

  /// Last swing level that price broke in the given direction.
  static double? _brokenLevel(List<SwingPoint> pts, double px, bool bullish) {
    final list = pts
        .where((x) => x.type == (bullish ? 'high' : 'low'))
        .where((x) => bullish ? x.price < px : x.price > px)
        .toList()
      ..sort((a, b) => bullish
          ? b.price.compareTo(a.price)
          : a.price.compareTo(b.price));
    return list.isEmpty ? null : list.first.price;
  }

  /// 4H bias + 1H zone + 15M trigger. Returns null when there is no setup.
  static TradeSignal? multiTF(
    String sym,
    List<Candle> c4,
    List<Candle> c1,
    List<Candle> c15,
  ) {
    if (c4.length < 40 || c1.length < 40 || c15.length < 40) return null;

    final t4 = analyze('4H', c4);
    final t1 = analyze('1H', c1);
    final t15 = analyze('15M', c15);
    final px = c15.last.close;
    if (px <= 0) return null;

    final bool bull4 = t4.structure == 'BULLISH' || t4.bos == 'BULLISH_BOS';
    final bool bear4 = t4.structure == 'BEARISH' || t4.bos == 'BEARISH_BOS';

    double buy = 0;
    double sell = 0;
    final bC = <String>[];
    final sC = <String>[];

    if (bull4) {
      buy += 35;
      bC.add('4H trend bullish');
    }
    if (bear4) {
      sell += 35;
      sC.add('4H trend bearish');
    }

    final buyZone = _buyZone(t1.obs, px);
    final sellZone = _sellZone(t1.obs, px);

    if (bull4 && buyZone != null) {
      buy += 25;
      bC.add('1H bullish OB');
    }
    if (bear4 && sellZone != null) {
      sell += 25;
      sC.add('1H bearish OB');
    }
    if (bull4 && _hasBullFvg(t1.fvgs, px)) {
      buy += 15;
      bC.add('1H bullish FVG');
    }
    if (bear4 && _hasBearFvg(t1.fvgs, px)) {
      sell += 15;
      sC.add('1H bearish FVG');
    }

    final bull15Level = _brokenLevel(swings(c15), px, true);
    final bear15Level = _brokenLevel(swings(c15), px, false);

    final bool freshBull = t15.sweep == 'BULLISH_SWEEP' ||
        (t15.bos == 'BULLISH_BOS' &&
            bull15Level != null &&
            _freshCross(c15, bull15Level, true));
    final bool freshBear = t15.sweep == 'BEARISH_SWEEP' ||
        (t15.bos == 'BEARISH_BOS' &&
            bear15Level != null &&
            _freshCross(c15, bear15Level, false));

    if (freshBull) {
      buy += 15;
      bC.add('15M bullish trigger');
    }
    if (freshBear) {
      sell += 15;
      sC.add('15M bearish trigger');
    }

    if (t15.volumeSpike) {
      if (bull4) {
        buy += 10;
        bC.add('15M volume spike');
      } else if (bear4) {
        sell += 10;
        sC.add('15M volume spike');
      }
    }

    final atr1 = t1.atr > 0 ? t1.atr : px * 0.01;

    if (buy >= 55 && bull4 && !bear4 && buy > sell) {
      double entry = px;
      double sl;

      if (buyZone != null) {
        // Limit into the middle of the zone when it is close enough.
        final mid = buyZone.mid;
        if ((px - mid) / px <= 0.02) entry = mid;
        sl = buyZone.low - atr1 * 0.25;
      } else {
        final lows = swings(c1).where((p) => p.type == 'low').toList();
        sl = lows.isNotEmpty ? lows.last.price - atr1 * 0.25 : px - atr1 * 2;
      }

      if (sl >= entry) sl = entry - atr1;
      final risk = entry - sl;
      if (risk <= 0 || risk / entry > 0.08) return null; // sanity: max 8% risk

      final tp = entry + risk * 2; // fixed 2R target

      return TradeSignal(
        symbol: sym,
        direction: 'BUY',
        price: px,
        entry: entry,
        sl: sl,
        tp: tp,
        confidence: buy.clamp(0.0, 100.0).toDouble(),
        confirmations: bC,
        time: DateTime.now(),
        tf4h: t4.structure,
        tf1h: t1.structure,
        tf15m: t15.structure,
      );
    }

    if (sell >= 55 && bear4 && !bull4 && sell > buy) {
      double entry = px;
      double sl;

      if (sellZone != null) {
        final mid = sellZone.mid;
        if ((mid - px) / px <= 0.02) entry = mid;
        sl = sellZone.high + atr1 * 0.25;
      } else {
        final highs = swings(c1).where((p) => p.type == 'high').toList();
        sl = highs.isNotEmpty ? highs.last.price + atr1 * 0.25 : px + atr1 * 2;
      }

      if (sl <= entry) sl = entry + atr1;
      final risk = sl - entry;
      if (risk <= 0 || risk / entry > 0.08) return null;

      final tp = entry - risk * 2;

      return TradeSignal(
        symbol: sym,
        direction: 'SELL',
        price: px,
        entry: entry,
        sl: sl,
        tp: tp,
        confidence: sell.clamp(0.0, 100.0).toDouble(),
        confirmations: sC,
        time: DateTime.now(),
        tf4h: t4.structure,
        tf1h: t1.structure,
        tf15m: t15.structure,
      );
    }

    return null;
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

            final sig = Engine.multiTF(sym, c4, c1, c15);
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
        _msg = _signals.isEmpty
            ? 'Kono valid setup nei ekhon ($_feed). 5 min por auto refresh hobe.'
            : '${_signals.length} signal ready ($_feed)'
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
    final sells = _signals.length - buys;

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
                      Text(
                        '${signal.direction} • ${timeAgo(signal.time)}',
                        style: TextStyle(color: color, fontSize: 10),
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
