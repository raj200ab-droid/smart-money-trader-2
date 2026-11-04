// ============================================================
//  SMART MONEY TRADING SIGNAL APP
//  Binance Spot Trade - Multi-Timeframe Analysis
//  ALL CODE IN ONE FILE
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

// ==============================
//        MAIN ENTRY
// ==============================
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Color(0xFF0D1117),
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const MyApp());
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
        primaryColor: Colors.green,
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF161B22),
          elevation: 0,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// ==============================
//        DATA MODELS
// ==============================
class Candle {
  final int openTime;
  final double open, high, low, close, volume;
  final int closeTime;

  Candle({
    required this.openTime,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
    required this.closeTime,
  });

  factory Candle.fromJson(List<dynamic> json) {
    return Candle(
      openTime: json[0] as int,
      open: double.parse(json[1].toString()),
      high: double.parse(json[2].toString()),
      low: double.parse(json[3].toString()),
      close: double.parse(json[4].toString()),
      volume: double.parse(json[5].toString()),
      closeTime: json[6] as int,
    );
  }

  bool get isBullish => close > open;
  bool get isBearish => close < open;
  double get bodySize => (close - open).abs();
  double get upperWick => high - (close > open ? close : open);
  double get lowerWick => (close > open ? open : close) - low;
}

class CoinData {
  final String symbol;
  final double lastPrice, priceChangePercent;
  final double highPrice, lowPrice, quoteVolume;

  CoinData({
    required this.symbol,
    required this.lastPrice,
    required this.priceChangePercent,
    required this.highPrice,
    required this.lowPrice,
    required this.quoteVolume,
  });

  factory CoinData.fromJson(Map<String, dynamic> json) {
    return CoinData(
      symbol: json['symbol'] as String,
      lastPrice: double.parse(json['lastPrice'].toString()),
      priceChangePercent:
          double.parse(json['priceChangePercent'].toString()),
      highPrice: double.parse(json['highPrice'].toString()),
      lowPrice: double.parse(json['lowPrice'].toString()),
      quoteVolume: double.parse(json['quoteVolume'].toString()),
    );
  }
}

class OrderBlock {
  final double high, low;
  final String type;
  final int index;
  OrderBlock({
    required this.high,
    required this.low,
    required this.type,
    required this.index,
  });
  double get mid => (high + low) / 2;
}

class FVG {
  final double high, low;
  final String type;
  final int index;
  FVG({
    required this.high,
    required this.low,
    required this.type,
    required this.index,
  });
}

class SwingPoint {
  final double price;
  final int index;
  final String type;
  SwingPoint({
    required this.price,
    required this.index,
    required this.type,
  });
}

class TimeframeAnalysis {
  final String timeframe;
  final String structure;
  final String? bos, sweep;
  final double buyScore, sellScore;
  final bool volumeSpike;
  final List<String> buyConfirmations, sellConfirmations;
  final OrderBlock? bullishOB, bearishOB;
  final List<FVG> fvgs;

  TimeframeAnalysis({
    required this.timeframe,
    required this.structure,
    this.bos,
    this.sweep,
    required this.buyScore,
    required this.sellScore,
    required this.volumeSpike,
    required this.buyConfirmations,
    required this.sellConfirmations,
    this.bullishOB,
    this.bearishOB,
    required this.fvgs,
  });
}

class TradeSignal {
  final String symbol, direction;
  final double entryPrice, stopLoss, takeProfit, confidence;
  final List<String> confirmations;
  final DateTime generatedAt;
  final String tf4hTrend, tf1hTrend, tf15mTrigger;
  final List<String> timeframeBreakdown;

  TradeSignal({
    required this.symbol,
    required this.direction,
    required this.entryPrice,
    required this.stopLoss,
    required this.takeProfit,
    required this.confidence,
    required this.confirmations,
    required this.generatedAt,
    required this.tf4hTrend,
    required this.tf1hTrend,
    required this.tf15mTrigger,
    required this.timeframeBreakdown,
  });

  double get profitPercent => direction == 'BUY'
      ? ((takeProfit - entryPrice) / entryPrice) * 100
      : ((entryPrice - takeProfit) / entryPrice) * 100;

  double get riskPercent => direction == 'BUY'
      ? ((entryPrice - stopLoss) / entryPrice) * 100
      : ((stopLoss - entryPrice) / entryPrice) * 100;

  double get riskReward =>
      riskPercent == 0 ? 0 : profitPercent / riskPercent;

  String get coinName => symbol.replaceAll('USDT', '');
}

// ==============================
//     BINANCE API SERVICE
// ==============================
class BinanceApi {
  static const List<String> _endpoints = [
    'https://api.binance.com/api/v3',
    'https://api1.binance.com/api/v3',
    'https://api2.binance.com/api/v3',
    'https://api3.binance.com/api/v3',
  ];
  static int _idx = 0;
  static String get _url => _endpoints[_idx];
  static void _rotate() =>
      _idx = (_idx + 1) % _endpoints.length;

  static Future<List<CoinData>> getTopGainers(
      {int limit = 100}) async {
    for (int a = 0; a < _endpoints.length; a++) {
      try {
        final r = await http
            .get(Uri.parse('$_url/ticker/24hr'))
            .timeout(const Duration(seconds: 20));
        if (r.statusCode == 200) {
          List<dynamic> data = json.decode(r.body);
          List<CoinData> coins = data
              .map((e) =>
                  CoinData.fromJson(e as Map<String, dynamic>))
              .where((c) => c.symbol.endsWith('USDT'))
              .where((c) => c.symbol != 'USDTUSDT')
              .where((c) => c.quoteVolume > 5000000)
              .where((c) => c.priceChangePercent > 0)
              .toList();
          coins.sort((a, b) => b.priceChangePercent
              .compareTo(a.priceChangePercent));
          return coins.take(limit).toList();
        }
        _rotate();
      } catch (e) {
        _rotate();
      }
    }
    throw Exception('VPN চালু করুন');
  }

  static Future<List<Candle>> getCandles(
      String symbol, String interval, int limit) async {
    for (int a = 0; a < _endpoints.length; a++) {
      try {
        final r = await http
            .get(Uri.parse(
                '$_url/klines?symbol=$symbol&interval=$interval&limit=$limit'))
            .timeout(const Duration(seconds: 15));
        if (r.statusCode == 200) {
          List<dynamic> data = json.decode(r.body);
          return data
              .map((e) => Candle.fromJson(e as List<dynamic>))
              .toList();
        }
        _rotate();
      } catch (e) {
        _rotate();
      }
    }
    throw Exception('Failed: $symbol');
  }
}

// ==============================
//   SMART MONEY ANALYSIS ENGINE
// ==============================
class SmartMoneyAnalyzer {
  // --- Swing Points ---
  static List<SwingPoint> findSwingPoints(List<Candle> c,
      {int lookback = 5}) {
    List<SwingPoint> pts = [];
    for (int i = lookback; i < c.length - lookback; i++) {
      bool sh = true, sl = true;
      for (int j = i - lookback; j <= i + lookback; j++) {
        if (j == i) continue;
        if (c[j].high >= c[i].high) sh = false;
        if (c[j].low <= c[i].low) sl = false;
      }
      if (sh) {
        pts.add(
            SwingPoint(price: c[i].high, index: i, type: 'high'));
      }
      if (sl) {
        pts.add(
            SwingPoint(price: c[i].low, index: i, type: 'low'));
      }
    }
    return pts;
  }

  // --- Market Structure ---
  static String detectStructure(List<SwingPoint> pts) {
    var h = pts.where((p) => p.type == 'high').toList();
    var l = pts.where((p) => p.type == 'low').toList();
    if (h.length < 2 || l.length < 2) return 'NEUTRAL';
    bool hh = h[h.length - 1].price > h[h.length - 2].price;
    bool hl = l[l.length - 1].price > l[l.length - 2].price;
    if (hh && hl) return 'BULLISH';
    bool lh = h[h.length - 1].price < h[h.length - 2].price;
    bool ll = l[l.length - 1].price < l[l.length - 2].price;
    if (lh && ll) return 'BEARISH';
    return 'NEUTRAL';
  }

  // --- BOS ---
  static String? detectBOS(List<Candle> c, List<SwingPoint> pts) {
    if (pts.isEmpty) return null;
    double price = c.last.close;
    var h = pts.where((p) => p.type == 'high').toList();
    var l = pts.where((p) => p.type == 'low').toList();
    if (h.isNotEmpty && price > h.last.price) return 'BULLISH_BOS';
    if (l.isNotEmpty && price < l.last.price) return 'BEARISH_BOS';
    return null;
  }

  // --- Order Blocks ---
  static List<OrderBlock> findOBs(List<Candle> c) {
    List<OrderBlock> obs = [];
    double avgBody = 0;
    int cnt = 0;
    for (int i = max(0, c.length - 30); i < c.length; i++) {
      avgBody += c[i].bodySize;
      cnt++;
    }
    if (cnt > 0) avgBody /= cnt;
    if (avgBody == 0) return obs;

    for (int i = 1; i < c.length - 1; i++) {
      var cur = c[i], nxt = c[i + 1];
      if (cur.isBearish && nxt.isBullish && nxt.bodySize > avgBody * 1.3) {
        obs.add(OrderBlock(
            high: cur.high, low: cur.low, type: 'bullish', index: i));
      }
      if (cur.isBullish && nxt.isBearish && nxt.bodySize > avgBody * 1.3) {
        obs.add(OrderBlock(
            high: cur.high, low: cur.low, type: 'bearish', index: i));
      }
    }
    return obs.where((o) => o.index > c.length - 60).toList();
  }

  // --- FVG ---
  static List<FVG> findFVGs(List<Candle> c) {
    List<FVG> fvgs = [];
    for (int i = 1; i < c.length - 1; i++) {
      var b = c[i - 1], a = c[i + 1];
      if (b.high < a.low) {
        fvgs.add(FVG(
            high: a.low, low: b.high, type: 'bullish', index: i));
      }
      if (b.low > a.high) {
        fvgs.add(FVG(
            high: b.low, low: a.high, type: 'bearish', index: i));
      }
    }
    return fvgs.where((f) => f.index > c.length - 60).toList();
  }

  // --- Liquidity Sweep ---
  static String? detectSweep(List<Candle> c, List<SwingPoint> pts) {
    if (c.length < 3) return null;
    var last = c[c.length - 1];
    var h = pts.where((p) => p.type == 'high').toList();
    var l = pts.where((p) => p.type == 'low').toList();
    if (l.isNotEmpty && last.low < l.last.price && last.close > l.last.price) {
      return 'BULLISH_SWEEP';
    }
    if (h.isNotEmpty && last.high > h.last.price && last.close < h.last.price) {
      return 'BEARISH_SWEEP';
    }
    return null;
  }

  // --- Volume Spike ---
  static bool volumeSpike(List<Candle> c, {double mult = 1.5}) {
    if (c.length < 20) return false;
    double avg = 0;
    for (int i = c.length - 20; i < c.length - 1; i++) {
      avg += c[i].volume;
    }
    avg /= 19;
    return c.last.volume > avg * mult;
  }

  // --- Single TF Analysis ---
  static TimeframeAnalysis analyzeTF(String tf, List<Candle> c) {
    var pts = findSwingPoints(c, lookback: 5);
    String structure = detectStructure(pts);
    String? bos = detectBOS(c, pts);
    List<OrderBlock> obs = findOBs(c);
    List<FVG> fvgs = findFVGs(c);
    String? sweep = detectSweep(c, pts);
    bool vol = volumeSpike(c);
    double price = c.last.close;

    double bScore = 0;
    List<String> bConf = [];
    double sScore = 0;
    List<String> sConf = [];

    if (structure == 'BULLISH' || bos == 'BULLISH_BOS') {
      bScore += 25;
      bConf.add('Bullish Structure/BOS');
    }
    if (structure == 'BEARISH' || bos == 'BEARISH_BOS') {
      sScore += 25;
      sConf.add('Bearish Structure/BOS');
    }

    OrderBlock? bOB, sOB;
    for (var ob in obs.where((o) => o.type == 'bullish')) {
      if (price >= ob.low * 0.998 && price <= ob.high * 1.002) {
        bOB = ob;
        bScore += 25;
        bConf.add('Price in Bullish OB');
        break;
      }
    }
    for (var ob in obs.where((o) => o.type == 'bearish')) {
      if (price >= ob.low * 0.998 && price <= ob.high * 1.002) {
        sOB = ob;
        sScore += 25;
        sConf.add('Price in Bearish OB');
        break;
      }
    }

    for (var f in fvgs.where((f) => f.type == 'bullish')) {
      if (price >= f.low * 0.998 && price <= f.high * 1.002) {
        bScore += 15;
        bConf.add('Price in Bullish FVG');
        break;
      }
    }
    for (var f in fvgs.where((f) => f.type == 'bearish')) {
      if (price >= f.low * 0.998 && price <= f.high * 1.002) {
        sScore += 15;
        sConf.add('Price in Bearish FVG');
        break;
      }
    }

    if (sweep == 'BULLISH_SWEEP') {
      bScore += 15;
      bConf.add('Bullish Sweep');
    }
    if (sweep == 'BEARISH_SWEEP') {
      sScore += 15;
      sConf.add('Bearish Sweep');
    }
    if (vol) {
      bScore += 10;
      sScore += 10;
      bConf.add('Volume Spike');
      sConf.add('Volume Spike');
    }

    return TimeframeAnalysis(
      timeframe: tf,
      structure: structure,
      bos: bos,
      sweep: sweep,
      buyScore: bScore,
      sellScore: sScore,
      volumeSpike: vol,
      buyConfirmations: bConf,
      sellConfirmations: sConf,
      bullishOB: bOB,
      bearishOB: sOB,
      fvgs: fvgs,
    );
  }

  // --- Multi-Timeframe Analysis ---
  static TradeSignal? analyzeMultiTF(
    String symbol,
    List<Candle> c4h,
    List<Candle> c1h,
    List<Candle> c15m,
  ) {
    var tf4h = analyzeTF('4H', c4h);
    var tf1h = analyzeTF('1H', c1h);
    var tf15m = analyzeTF('15M', c15m);

    double buyScore = 0, sellScore = 0;
    List<String> buyConf = [], sellConf = [];
    List<String> tfBreakdown = [];

    // 4H = Trend (40%)
    bool t4hBull = tf4h.structure == 'BULLISH' || tf4h.bos == 'BULLISH_BOS';
    bool t4hBear = tf4h.structure == 'BEARISH' || tf4h.bos == 'BEARISH_BOS';
    if (t4hBull) {
      buyScore += 40;
      buyConf.add('4H: Bullish Trend ✅');
    }
    if (t4hBear) {
      sellScore += 40;
      sellConf.add('4H: Bearish Trend ✅');
    }
    tfBreakdown.add('4H: ${tf4h.structure}');

    // 1H = Entry Zone (35%)
    if (tf1h.bullishOB != null) {
      buyScore += 20;
      buyConf.add('1H: Bullish Order Block ✅');
    }
    if (tf1h.bearishOB != null) {
      sellScore += 20;
      sellConf.add('1H: Bearish Order Block ✅');
    }
    if (tf1h.buyConfirmations.any((c) => c.contains('FVG'))) {
      buyScore += 15;
      buyConf.add('1H: Bullish FVG ✅');
    }
    if (tf1h.sellConfirmations.any((c) => c.contains('FVG'))) {
      sellScore += 15;
      sellConf.add('1H: Bearish FVG ✅');
    }
    tfBreakdown.add('1H: ${tf1h.structure}');

    // 15M = Trigger (25%)
    if (tf15m.bos == 'BULLISH_BOS' || tf15m.sweep == 'BULLISH_SWEEP') {
      buyScore += 15;
      buyConf.add('15M: Bullish Trigger ✅');
    }
    if (tf15m.bos == 'BEARISH_BOS' || tf15m.sweep == 'BEARISH_SWEEP') {
      sellScore += 15;
      sellConf.add('15M: Bearish Trigger ✅');
    }
    if (tf15m.volumeSpike) {
      buyScore += 10;
      sellScore += 10;
      buyConf.add('15M: Volume Spike ✅');
      sellConf.add('15M: Volume Spike ✅');
    }
    tfBreakdown.add('15M: ${tf15m.structure}');

    double price = c15m.last.close;

    // BUY Signal
    if (buyScore >= 55 && t4hBull && buyScore > sellScore) {
      double entry = price;
      double sl;
      if (tf1h.bullishOB != null) {
        entry = tf1h.bullishOB!.mid;
        sl = tf1h.bullishOB!.low * 0.997;
      } else if (tf4h.bullishOB != null) {
        entry = tf4h.bullishOB!.mid;
        sl = tf4h.bullishOB!.low * 0.997;
      } else {
        var lows = findSwingPoints(c1h)
            .where((p) => p.type == 'low')
            .toList();
        sl = lows.isNotEmpty
            ? lows.last.price * 0.997
            : price * 0.985;
      }
      if (sl >= entry) sl = entry * 0.985;

      return TradeSignal(
        symbol: symbol,
        direction: 'BUY',
        entryPrice: entry,
        stopLoss: sl,
        takeProfit: entry * 1.01,
        confidence: buyScore.clamp(0, 100),
        confirmations: buyConf,
        generatedAt: DateTime.now(),
        tf4hTrend: tf4h.structure,
        tf1hTrend: tf1h.structure,
        tf15mTrigger: tf15m.structure,
        timeframeBreakdown: tfBreakdown,
      );
    }

    // SELL Signal
    if (sellScore >= 55 && t4hBear && sellScore > buyScore) {
      double entry = price;
      double sl;
      if (tf1h.bearishOB != null) {
        entry = tf1h.bearishOB!.mid;
        sl = tf1h.bearishOB!.high * 1.003;
      } else if (tf4h.bearishOB != null) {
        entry = tf4h.bearishOB!.mid;
        sl = tf4h.bearishOB!.high * 1.003;
      } else {
        var highs = findSwingPoints(c1h)
            .where((p) => p.type == 'high')
            .toList();
        sl = highs.isNotEmpty
            ? highs.last.price * 1.003
            : price * 1.015;
      }
      if (sl <= entry) sl = entry * 1.015;

      return TradeSignal(
        symbol: symbol,
        direction: 'SELL',
        entryPrice: entry,
        stopLoss: sl,
        takeProfit: entry * 0.99,
        confidence: sellScore.clamp(0, 100),
        confirmations: sellConf,
        generatedAt: DateTime.now(),
        tf4hTrend: tf4h.structure,
        tf1hTrend: tf1h.structure,
        tf15mTrigger: tf15m.structure,
        timeframeBreakdown: tfBreakdown,
      );
    }

    return null;
  }
}

// ==============================
//         HOME SCREEN UI
// ==============================
class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<TradeSignal> signals = [];
  bool isLoading = true;
  String statusMessage = 'Starting analysis...';
  int analyzedCount = 0, totalCount = 0, errorsCount = 0;
  Timer? _autoRefresh;

  @override
  void initState() {
    super.initState();
    _startAnalysis();
    _autoRefresh = Timer.periodic(const Duration(minutes: 5), (t) {
      if (!isLoading) _startAnalysis();
    });
  }

  @override
  void dispose() {
    _autoRefresh?.cancel();
    super.dispose();
  }

  Future<void> _startAnalysis() async {
    if (mounted) {
      setState(() {
        isLoading = true;
        signals.clear();
        errorsCount = 0;
        statusMessage = 'Top 100 gainers খুঁজছি...';
        analyzedCount = 0;
        totalCount = 0;
      });
    }
    try {
      List<CoinData> gainers =
          await BinanceApi.getTopGainers(limit: 100);
      if (mounted) {
        setState(() {
          statusMessage =
              '${gainers.length} coins পাওয়া গেছে। 4H+1H+15M Analysis শুরু...';
          totalCount = gainers.length;
        });
      }
      for (int i = 0; i < gainers.length; i++) {
        if (!mounted) return;
        setState(() {
          statusMessage =
              'Analyzing ${gainers[i].symbol}... (${i + 1}/${gainers.length})';
          analyzedCount = i + 1;
        });
        try {
          var c4h = await BinanceApi.getCandles(
              gainers[i].symbol, '4h', 200);
          await Future.delayed(
              const Duration(milliseconds: 100));
          var c1h = await BinanceApi.getCandles(
              gainers[i].symbol, '1h', 200);
          await Future.delayed(
              const Duration(milliseconds: 100));
          var c15m = await BinanceApi.getCandles(
              gainers[i].symbol, '15m', 200);

          var signal = SmartMoneyAnalyzer.analyzeMultiTF(
              gainers[i].symbol, c4h, c1h, c15m);
          if (signal != null && mounted) {
            setState(() {
              signals.add(signal);
            });
          }
        } catch (e) {
          if (mounted) setState(() => errorsCount++);
        }
        await Future.delayed(
            const Duration(milliseconds: 300));
      }
      signals.sort((a, b) => b.confidence.compareTo(a.confidence));
    } catch (e) {
      if (mounted) {
        setState(() => statusMessage = 'Error: VPN চালু করুন');
      }
    }
    if (mounted) setState(() => isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        title: Row(children: const [
          Icon(Icons.candlestick_chart,
              color: Colors.green, size: 24),
          SizedBox(width: 8),
          Text('Smart Money Trader',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: isLoading ? null : _startAnalysis,
          ),
        ],
      ),
      body: Column(children: [
        _buildStatusBar(),
        _buildFilterBar(),
        Expanded(child: _buildSignalsList()),
      ]),
    );
  }

  Widget _buildStatusBar() {
    return Container(
      padding: const EdgeInsets.all(12),
      color: const Color(0xFF161B22),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Row(children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: isLoading ? Colors.orange : Colors.green,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(isLoading ? 'Analyzing...' : 'Done',
                style: const TextStyle(
                    color: Colors.white70, fontSize: 12)),
          ]),
          Text('$analyzedCount / $totalCount',
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: totalCount > 0 ? analyzedCount / totalCount : 0,
            backgroundColor: const Color(0xFF21262D),
            valueColor: AlwaysStoppedAnimation<Color>(
                isLoading ? Colors.orange : Colors.green),
            minHeight: 4,
          ),
        ),
        const SizedBox(height: 6),
        Text(statusMessage,
            style: const TextStyle(color: Colors.grey, fontSize: 11),
            maxLines: 2,
            overflow: TextOverflow.ellipsis),
      ]),
    );
  }

  Widget _buildFilterBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Signals: ${signals.length}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            Row(children: [
              _tfBadge('4H', Colors.purple),
              const SizedBox(width: 4),
              _tfBadge('1H', Colors.blue),
              const SizedBox(width: 4),
              _tfBadge('15M', Colors.orange),
            ]),
          ]),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: signals.isNotEmpty
                  ? Colors.green.withOpacity(0.2)
                  : Colors.grey.withOpacity(0.2),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(isLoading ? '🔄 Scanning' : '✅ Done',
                style: TextStyle(
                    color: signals.isNotEmpty
                        ? Colors.green
                        : Colors.grey,
                    fontSize: 12,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _tfBadge(String tf, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(tf,
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.bold)),
    );
  }

  Widget _buildSignalsList() {
    if (signals.isEmpty) {
      return Center(
        child: isLoading
            ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const CircularProgressIndicator(color: Colors.green),
                const SizedBox(height: 16),
                Text(statusMessage,
                    style: const TextStyle(color: Colors.grey),
                    textAlign: TextAlign.center),
              ])
            : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.search_off,
                    color: Colors.grey, size: 48),
                const SizedBox(height: 16),
                const Text('এখন কোনো সিগন্যাল নেই।',
                    style: TextStyle(color: Colors.grey, fontSize: 16)),
                const SizedBox(height: 8),
                const Text('Market condition এর উপর depend করে।\nRefresh করুন।',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                    textAlign: TextAlign.center),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _startAnalysis,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green),
                  child: const Text('Refresh'),
                ),
              ]),
      );
    }
    return RefreshIndicator(
      onRefresh: _startAnalysis,
      color: Colors.green,
      backgroundColor: const Color(0xFF21262D),
      child: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: signals.length,
        itemBuilder: (context, index) =>
            _buildSignalCard(signals[index]),
      ),
    );
  }

  Widget _buildSignalCard(TradeSignal s) {
    bool isBuy = s.direction == 'BUY';
    Color dc = isBuy ? Colors.green : Colors.red;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: dc.withOpacity(0.3), width: 1.5),
      ),
      child: Column(children: [
        // Header
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: dc.withOpacity(0.05),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(12)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: dc.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(isBuy ? '🟢 BUY' : '🔴 SELL',
                      style: TextStyle(
                          color: dc,
                          fontWeight: FontWeight.bold,
                          fontSize: 13)),
                ),
                const SizedBox(width: 10),
                Text(s.coinName,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 20)),
              ]),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('${s.confidence.toInt()}%',
                    style: TextStyle(
                        color: s.confidence >= 75
                            ? Colors.green
                            : s.confidence >= 55
                                ? Colors.orange
                                : Colors.red,
                        fontWeight: FontWeight.bold,
                        fontSize: 18)),
                const Text('Confidence',
                    style: TextStyle(color: Colors.grey, fontSize: 9)),
              ]),
            ],
          ),
        ),
        // Prices
        Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(children: [
            _priceBox('ENTRY', s.entryPrice, Colors.blue, Icons.login),
            const SizedBox(width: 6),
            _priceBox('STOP LOSS', s.stopLoss, Colors.red, Icons.block),
            const SizedBox(width: 6),
            _priceBox(
                'TAKE PROFIT', s.takeProfit, Colors.green, Icons.trending_up),
          ]),
        ),
        // Stats
        Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Row(children: [
            _statChip('💰 ${s.profitPercent.toStringAsFixed(2)}%', Colors.green),
            const SizedBox(width: 6),
            _statChip('⚠️ ${s.riskPercent.toStringAsFixed(2)}%', Colors.red),
            const SizedBox(width: 6),
            _statChip('📊 R:R 1:${s.riskReward.toStringAsFixed(1)}',
                Colors.orange),
          ]),
        ),
        // Multi-TF
        Container(
          margin: const EdgeInsets.fromLTRB(14, 8, 14, 4),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF21262D),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Multi-Timeframe:',
                    style: TextStyle(
                        color: Colors.grey,
                        fontSize: 11,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Row(children: [
                  _tfChip('4H', s.tf4hTrend, Colors.purple),
                  const SizedBox(width: 6),
                  _tfChip('1H', s.tf1hTrend, Colors.blue),
                  const SizedBox(width: 6),
                  _tfChip('15M', s.tf15mTrigger, Colors.orange),
                ]),
              ]),
        ),
        // Confirmations
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Smart Money Confirmations:',
                    style: TextStyle(
                        color: Colors.grey,
                        fontSize: 11,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: s.confirmations
                      .map((c) => Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF21262D),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                  color: Colors.green.withOpacity(0.2)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('✅ ',
                                    style: TextStyle(fontSize: 11)),
                                Text(c,
                                    style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 11)),
                              ],
                            ),
                          ))
                      .toList(),
                ),
              ]),
        ),
        // Footer
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('🕐 ${s.generatedAt.hour.toString().padLeft(2, '0')}:${s.generatedAt.minute.toString().padLeft(2, '0')}',
                  style: const TextStyle(color: Colors.grey, fontSize: 10)),
              const Text('Multi-TF Analysis',
                  style: TextStyle(color: Colors.grey, fontSize: 10)),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _tfChip(String tf, String trend, Color color) {
    Color tc;
    if (trend.contains('BULL')) {
      tc = Colors.green;
    } else if (trend.contains('BEAR')) {
      tc = Colors.red;
    } else {
      tc = Colors.grey;
    }
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Column(children: [
          Text(tf,
              style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(trend,
              style: TextStyle(
                  color: tc, fontSize: 10, fontWeight: FontWeight.bold)),
        ]),
      ),
    );
  }

  Widget _priceBox(
      String label, double price, Color color, IconData icon) {
    return Expanded(
      child: Container(
        padding:
            const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.25)),
        ),
        child: Column(children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(height: 4),
          Text(label,
              style: TextStyle(
                  color: color,
                  fontSize: 9,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(_fmt(price),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold)),
        ]),
      ),
    );
  }

  Widget _statChip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: 11)),
    );
  }

  String _fmt(double p) {
    if (p >= 1000) return '\$${p.toStringAsFixed(2)}';
    if (p >= 1) return '\$${p.toStringAsFixed(4)}';
    if (p >= 0.01) return '\$${p.toStringAsFixed(6)}';
    return '\$${p.toStringAsFixed(8)}';
  }
}
