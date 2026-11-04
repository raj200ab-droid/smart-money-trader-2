import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Color(0xFF0D1117),
    statusBarIconBrightness: Brightness.light,
  ));
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

// =================== MODELS ===================
class Candle {
  final int openTime, closeTime;
  final double open, high, low, close, volume;
  Candle({
    required this.openTime,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
    required this.closeTime,
  });
  factory Candle.fromJson(List<dynamic> j) => Candle(
    openTime: j[0] as int,
    open: double.parse(j[1].toString()),
    high: double.parse(j[2].toString()),
    low: double.parse(j[3].toString()),
    close: double.parse(j[4].toString()),
    volume: double.parse(j[5].toString()),
    closeTime: j[6] as int,
  );
  bool get isBullish => close > open;
  bool get isBearish => close < open;
  double get bodySize => (close - open).abs();
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
  factory CoinData.fromJson(Map<String, dynamic> j) => CoinData(
    symbol: j['symbol'],
    lastPrice: double.parse(j['lastPrice'].toString()),
    priceChangePercent: double.parse(j['priceChangePercent'].toString()),
    highPrice: double.parse(j['highPrice'].toString()),
    lowPrice: double.parse(j['lowPrice'].toString()),
    quoteVolume: double.parse(j['quoteVolume'].toString()),
  );
}

class OrderBlock {
  final double high, low;
  final String type;
  final int index;
  OrderBlock({required this.high, required this.low, required this.type, required this.index});
  double get mid => (high + low) / 2;
}

class FVG {
  final double high, low;
  final String type;
  final int index;
  FVG({required this.high, required this.low, required this.type, required this.index});
}

class SwingPoint {
  final double price;
  final int index;
  final String type;
  SwingPoint({required this.price, required this.index, required this.type});
}

class TFAnalysis {
  final String timeframe, structure;
  final String? bos, sweep;
  final double buyScore, sellScore;
  final bool volumeSpike;
  final List<String> buyConf, sellConf;
  final OrderBlock? bullOB, bearOB;
  final List<FVG> fvgs;
  TFAnalysis({
    required this.timeframe,
    required this.structure,
    this.bos,
    this.sweep,
    required this.buyScore,
    required this.sellScore,
    required this.volumeSpike,
    required this.buyConf,
    required this.sellConf,
    this.bullOB,
    this.bearOB,
    required this.fvgs,
  });
}

class TradeSignal {
  final String symbol, direction, tf4h, tf1h, tf15m;
  final double entry, sl, tp, confidence;
  final List<String> confirmations;
  final DateTime time;
  TradeSignal({
    required this.symbol,
    required this.direction,
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
  double get profitPct =>
      direction == 'BUY' ? ((tp - entry) / entry) * 100 : ((entry - tp) / entry) * 100;
  double get riskPct =>
      direction == 'BUY' ? ((entry - sl) / entry) * 100 : ((sl - entry) / entry) * 100;
  double get rr => riskPct == 0 ? 0 : profitPct / riskPct;
  String get coin => symbol.replaceAll('USDT', '');
}

// =================== BINANCE API ===================
class BinanceApi {
  static const _urls = [
    'https://api.binance.com/api/v3',
    'https://api1.binance.com/api/v3',
    'https://api2.binance.com/api/v3',
    'https://api3.binance.com/api/v3',
  ];
  static int _i = 0;
  static String get _base => _urls[_i];
  static void _rot() => _i = (_i + 1) % _urls.length;

  static Future<List<CoinData>> topGainers({int limit = 100}) async {
    for (int a = 0; a < _urls.length; a++) {
      try {
        final r = await http
            .get(Uri.parse('$_base/ticker/24hr'))
            .timeout(const Duration(seconds: 20));
        if (r.statusCode == 200) {
          var data = json.decode(r.body) as List;
          var coins = data
              .map((e) => CoinData.fromJson(e))
              .where((c) => c.symbol.endsWith('USDT'))
              .where((c) => c.symbol != 'USDTUSDT')
              .where((c) => c.quoteVolume > 5000000)
              .where((c) => c.priceChangePercent > 0)
              .toList();
          coins.sort(
              (a, b) => b.priceChangePercent.compareTo(a.priceChangePercent));
          return coins.take(limit).toList();
        }
        _rot();
      } catch (_) {
        _rot();
      }
    }
    throw Exception('VPN ON koro');
  }

  static Future<List<Candle>> candles(String sym, String tf, int lim) async {
    for (int a = 0; a < _urls.length; a++) {
      try {
        final r = await http
            .get(Uri.parse(
                '$_base/klines?symbol=$sym&interval=$tf&limit=$lim'))
            .timeout(const Duration(seconds: 15));
        if (r.statusCode == 200) {
          return (json.decode(r.body) as List)
              .map((e) => Candle.fromJson(e))
              .toList();
        }
        _rot();
      } catch (_) {
        _rot();
      }
    }
    throw Exception('Fail: $sym');
  }
}

// =================== SMART MONEY ENGINE ===================
class Engine {
  static List<SwingPoint> swings(List<Candle> c, {int lb = 5}) {
    var pts = <SwingPoint>[];
    for (int i = lb; i < c.length - lb; i++) {
      bool sh = true, sl = true;
      for (int j = i - lb; j <= i + lb; j++) {
        if (j == i) continue;
        if (c[j].high >= c[i].high) sh = false;
        if (c[j].low <= c[i].low) sl = false;
      }
      if (sh) pts.add(SwingPoint(price: c[i].high, index: i, type: 'high'));
      if (sl) pts.add(SwingPoint(price: c[i].low, index: i, type: 'low'));
    }
    return pts;
  }

  static String structure(List<SwingPoint> p) {
    var h = p.where((x) => x.type == 'high').toList();
    var l = p.where((x) => x.type == 'low').toList();
    if (h.length < 2 || l.length < 2) return 'NEUTRAL';
    if (h.last.price > h[h.length - 2].price &&
        l.last.price > l[l.length - 2].price) return 'BULLISH';
    if (h.last.price < h[h.length - 2].price &&
        l.last.price < l[l.length - 2].price) return 'BEARISH';
    return 'NEUTRAL';
  }

  static String? bos(List<Candle> c, List<SwingPoint> p) {
    if (p.isEmpty) return null;
    double px = c.last.close;
    var h = p.where((x) => x.type == 'high').toList();
    var l = p.where((x) => x.type == 'low').toList();
    if (h.isNotEmpty && px > h.last.price) return 'BULLISH_BOS';
    if (l.isNotEmpty && px < l.last.price) return 'BEARISH_BOS';
    return null;
  }

  static List<OrderBlock> obs(List<Candle> c) {
    var res = <OrderBlock>[];
    double avg = 0;
    int n = 0;
    for (int i = max(0, c.length - 30); i < c.length; i++) {
      avg += c[i].bodySize;
      n++;
    }
    if (n > 0) avg /= n;
    if (avg == 0) return res;
    for (int i = 1; i < c.length - 1; i++) {
      if (c[i].isBearish && c[i + 1].isBullish && c[i + 1].bodySize > avg * 1.3) {
        res.add(OrderBlock(
            high: c[i].high, low: c[i].low, type: 'bullish', index: i));
      }
      if (c[i].isBullish && c[i + 1].isBearish && c[i + 1].bodySize > avg * 1.3) {
        res.add(OrderBlock(
            high: c[i].high, low: c[i].low, type: 'bearish', index: i));
      }
    }
    return res.where((o) => o.index > c.length - 60).toList();
  }

  static List<FVG> fvgs(List<Candle> c) {
    var res = <FVG>[];
    for (int i = 1; i < c.length - 1; i++) {
      if (c[i - 1].high < c[i + 1].low) {
        res.add(FVG(
            high: c[i + 1].low,
            low: c[i - 1].high,
            type: 'bullish',
            index: i));
      }
      if (c[i - 1].low > c[i + 1].high) {
        res.add(FVG(
            high: c[i - 1].low,
            low: c[i + 1].high,
            type: 'bearish',
            index: i));
      }
    }
    return res.where((f) => f.index > c.length - 60).toList();
  }

  static String? sweep(List<Candle> c, List<SwingPoint> p) {
    if (c.length < 3) return null;
    var last = c.last;
    var h = p.where((x) => x.type == 'high').toList();
    var l = p.where((x) => x.type == 'low').toList();
    if (l.isNotEmpty && last.low < l.last.price && last.close > l.last.price) {
      return 'BULLISH_SWEEP';
    }
    if (h.isNotEmpty && last.high > h.last.price && last.close < h.last.price) {
      return 'BEARISH_SWEEP';
    }
    return null;
  }

  static bool volSpike(List<Candle> c) {
    if (c.length < 20) return false;
    double avg = 0;
    for (int i = c.length - 20; i < c.length - 1; i++) avg += c[i].volume;
    avg /= 19;
    return c.last.volume > avg * 1.5;
  }

  static TFAnalysis analyze(String tf, List<Candle> c) {
    var pts = swings(c);
    String str = structure(pts);
    String? b = bos(c, pts);
    var obList = obs(c);
    var fvgList = fvgs(c);
    String? sw = sweep(c, pts);
    bool vs = volSpike(c);
    double px = c.last.close;

    double bs = 0, ss = 0;
    var bc = <String>[], sc = <String>[];
    OrderBlock? bo, so;

    if (str == 'BULLISH' || b == 'BULLISH_BOS') {
      bs += 25;
      bc.add('Bullish Structure');
    }
    if (str == 'BEARISH' || b == 'BEARISH_BOS') {
      ss += 25;
      sc.add('Bearish Structure');
    }
    for (var o in obList.where((x) => x.type == 'bullish')) {
      if (px >= o.low * 0.998 && px <= o.high * 1.002) {
        bo = o;
        bs += 25;
        bc.add('Bullish OB');
        break;
      }
    }
    for (var o in obList.where((x) => x.type == 'bearish')) {
      if (px >= o.low * 0.998 && px <= o.high * 1.002) {
        so = o;
        ss += 25;
        sc.add('Bearish OB');
        break;
      }
    }
    for (var f in fvgList.where((x) => x.type == 'bullish')) {
      if (px >= f.low * 0.998 && px <= f.high * 1.002) {
        bs += 15;
        bc.add('Bullish FVG');
        break;
      }
    }
    for (var f in fvgList.where((x) => x.type == 'bearish')) {
      if (px >= f.low * 0.998 && px <= f.high * 1.002) {
        ss += 15;
        sc.add('Bearish FVG');
        break;
      }
    }
    if (sw == 'BULLISH_SWEEP') {
      bs += 15;
      bc.add('Bullish Sweep');
    }
    if (sw == 'BEARISH_SWEEP') {
      ss += 15;
      sc.add('Bearish Sweep');
    }
    if (vs) {
      bs += 10;
      ss += 10;
      bc.add('Volume Spike');
      sc.add('Volume Spike');
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
      bullOB: bo,
      bearOB: so,
      fvgs: fvgList,
    );
  }

  static TradeSignal? multiTF(
      String sym, List<Candle> c4, List<Candle> c1, List<Candle> c15) {
    var t4 = analyze('4H', c4);
    var t1 = analyze('1H', c1);
    var t15 = analyze('15M', c15);

    double buy = 0, sell = 0;
    var bC = <String>[], sC = <String>[];

    bool t4Bull =
        t4.structure == 'BULLISH' || t4.bos == 'BULLISH_BOS';
    bool t4Bear =
        t4.structure == 'BEARISH' || t4.bos == 'BEARISH_BOS';
    if (t4Bull) {
      buy += 40;
      bC.add('4H: Bullish Trend');
    }
    if (t4Bear) {
      sell += 40;
      sC.add('4H: Bearish Trend');
    }

    if (t1.bullOB != null) {
      buy += 20;
      bC.add('1H: Bullish OB');
    }
    if (t1.bearOB != null) {
      sell += 20;
      sC.add('1H: Bearish OB');
    }
    if (t1.buyConf.any((c) => c.contains('FVG'))) {
      buy += 15;
      bC.add('1H: Bullish FVG');
    }
    if (t1.sellConf.any((c) => c.contains('FVG'))) {
      sell += 15;
      sC.add('1H: Bearish FVG');
    }

    if (t15.bos == 'BULLISH_BOS' || t15.sweep == 'BULLISH_SWEEP') {
      buy += 15;
      bC.add('15M: Trigger');
    }
    if (t15.bos == 'BEARISH_BOS' || t15.sweep == 'BEARISH_SWEEP') {
      sell += 15;
      sC.add('15M: Trigger');
    }
    if (t15.volumeSpike) {
      buy += 10;
      sell += 10;
      bC.add('15M: Volume');
      sC.add('15M: Volume');
    }

    double px = c15.last.close;

    if (buy >= 55 && t4Bull && buy > sell) {
      double e = px, s;
      if (t1.bullOB != null) {
        e = t1.bullOB!.mid;
        s = t1.bullOB!.low * 0.997;
      } else if (t4.bullOB != null) {
        e = t4.bullOB!.mid;
        s = t4.bullOB!.low * 0.997;
      } else {
        var lows = swings(c1).where((p) => p.type == 'low').toList();
        s = lows.isNotEmpty ? lows.last.price * 0.997 : px * 0.985;
      }
      if (s >= e) s = e * 0.985;
      return TradeSignal(
        symbol: sym,
        direction: 'BUY',
        entry: e,
        sl: s,
        tp: e * 1.01,
        confidence: buy.clamp(0, 100),
        confirmations: bC,
        time: DateTime.now(),
        tf4h: t4.structure,
        tf1h: t1.structure,
        tf15m: t15.structure,
      );
    }

    if (sell >= 55 && t4Bear && sell > buy) {
      double e = px, s;
      if (t1.bearOB != null) {
        e = t1.bearOB!.mid;
        s = t1.bearOB!.high * 1.003;
      } else if (t4.bearOB != null) {
        e = t4.bearOB!.mid;
        s = t4.bearOB!.high * 1.003;
      } else {
        var highs = swings(c1).where((p) => p.type == 'high').toList();
        s = highs.isNotEmpty ? highs.last.price * 1.003 : px * 1.015;
      }
      if (s <= e) s = e * 1.015;
      return TradeSignal(
        symbol: sym,
        direction: 'SELL',
        entry: e,
        sl: s,
        tp: e * 0.99,
        confidence: sell.clamp(0, 100),
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

// =================== UI ===================
class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);
  @override
  State<HomeScreen> createState() => _HS();
}

class _HS extends State<HomeScreen> {
  List<TradeSignal> signals = [];
  bool loading = true;
  String msg = 'Starting...';
  int done = 0, total = 0;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    run();
    timer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (!loading) run();
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> run() async {
    if (mounted) {
      setState(() {
        loading = true;
        signals.clear();
        msg = 'Top gainers khujchi...';
        done = 0;
        total = 0;
      });
    }
    try {
      var coins = await BinanceApi.topGainers(limit: 100);
      if (mounted) {
        setState(() {
          total = coins.length;
          msg = '${coins.length} coins found. Analyzing...';
        });
      }
      for (int i = 0; i < coins.length; i++) {
        if (!mounted) return;
        setState(() {
          msg = 'Analyzing ${coins[i].symbol} (${i + 1}/${coins.length})';
          done = i + 1;
        });
        try {
          var c4 = await BinanceApi.candles(coins[i].symbol, '4h', 200);
          await Future.delayed(const Duration(milliseconds: 100));
          var c1 = await BinanceApi.candles(coins[i].symbol, '1h', 200);
          await Future.delayed(const Duration(milliseconds: 100));
          var c15 = await BinanceApi.candles(coins[i].symbol, '15m', 200);
          var sig = Engine.multiTF(coins[i].symbol, c4, c1, c15);
          if (sig != null && mounted) setState(() => signals.add(sig));
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 300));
      }
      signals.sort((a, b) => b.confidence.compareTo(a.confidence));
    } catch (_) {
      if (mounted) setState(() => msg = 'Error: VPN ON koro');
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        title: Row(children: const [
          Icon(Icons.candlestick_chart, color: Colors.green, size: 22),
          SizedBox(width: 8),
          Text('Smart Money Trader',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold)),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: loading ? null : run,
          ),
        ],
      ),
      body: Column(children: [
        _status(),
        _filter(),
        Expanded(child: _list()),
      ]),
    );
  }

  Widget _status() {
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
                    color: loading ? Colors.orange : Colors.green,
                    shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Text(loading ? 'Analyzing...' : 'Done',
                style:
                    const TextStyle(color: Colors.white70, fontSize: 12)),
          ]),
          Text('$done / $total',
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: total > 0 ? done / total : 0,
            backgroundColor: const Color(0xFF21262D),
            valueColor:
                AlwaysStoppedAnimation(loading ? Colors.orange : Colors.green),
            minHeight: 4,
          ),
        ),
        const SizedBox(height: 6),
        Text(msg,
            style: const TextStyle(color: Colors.grey, fontSize: 11),
            maxLines: 2,
            overflow: TextOverflow.ellipsis),
      ]),
    );
  }

  Widget _filter() {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Signals: ${signals.length}',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
          Row(children: [
            _badge('4H', Colors.purple),
            const SizedBox(width: 4),
            _badge('1H', Colors.blue),
            const SizedBox(width: 4),
            _badge('15M', Colors.orange
