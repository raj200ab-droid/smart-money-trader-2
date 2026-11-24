import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// ---------------------------------------------------------------------------
/// Gemini as a second opinion, never as the decision.
/// ---------------------------------------------------------------------------
///
/// The app has one hard rule it will not break: the engine decides, and a
/// signal's tier, entry, stop and target come from candles only. Gemini is
/// added on top of that as an ADVISOR. Three consequences, all deliberate:
///
///   1. Turning Gemini on never adds, removes or re-orders a signal. A scan
///      with the key set and a scan without it produce the same list.
///   2. Every review is labelled with its source on the card, so a model
///      opinion can never be mistaken for the engine's measurement.
///   3. The review is asked to ATTACK the setup, not to agree with it. A model
///      given a trade and asked "is this good?" says yes. Given the same trade
///      and asked "what would make this fail?", it is useful.
///
/// The key is stored on the device only (SharedPreferences, private to the app
/// sandbox). It is never bundled into the APK, never sent anywhere except
/// generativelanguage.googleapis.com, and this file's only network call is the
/// one the user's key authorises.

class GeminiConfig {
  const GeminiConfig({
    this.apiKey = '',
    this.model = kGeminiDefaultModel,
    this.enabled = true,
    this.autoReview = true,
  });

  final String apiKey;
  final String model;
  final bool enabled;

  /// Queue the top signals for review automatically after each scan.
  final bool autoReview;

  bool get hasKey => apiKey.trim().length > 10;
  bool get usable => hasKey && enabled;

  GeminiConfig copyWith({
    String? apiKey,
    String? model,
    bool? enabled,
    bool? autoReview,
  }) =>
      GeminiConfig(
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
        enabled: enabled ?? this.enabled,
        autoReview: autoReview ?? this.autoReview,
      );
}

/// Model used when the user has not picked one.
///
/// Google moves these; the settings sheet offers a "Find a working model"
/// button that asks the API which models this key can actually use, so a dead
/// name is a two-second fix rather than a mystery.
const String kGeminiDefaultModel = 'gemini-flash-latest';

const List<String> kGeminiModels = <String>[
  'gemini-flash-latest',
  'gemini-2.5-flash',
  'gemini-2.5-flash-lite',
  'gemini-3-flash-preview',
  'gemini-3.5-flash',
  'gemini-3.8-flash',
];

/// A review of one signal, or of the whole scan (symbol == '').
class GeminiNote {
  GeminiNote({
    required this.symbol,
    required this.text,
    required this.model,
    required this.at,
    this.error = '',
    this.stance = '',
    this.confidence = -1,
  });

  final String symbol;
  final String text;
  final String model;
  final DateTime at;
  final String error;

  /// 'AGREE' | 'CAUTION' | 'AVOID' when the model followed the format, else ''.
  final String stance;

  /// The model's own 0-100 conviction, or -1 when it did not give one.
  final int confidence;

  bool get ok => error.isEmpty && text.trim().isNotEmpty;
  bool get isScan => symbol.isEmpty;
}

/// Thrown for anything the user can act on (bad key, no quota, bad model name).
class GeminiException implements Exception {
  GeminiException(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => message;
}

class GeminiService {
  static const String _host = 'https://generativelanguage.googleapis.com/v1beta';

  /// Reviews are deliberately short: the user needs a second opinion on one
  /// setup, not an essay. It also keeps a free-tier key usable for far longer.
  static const int _maxTokens = 700;

  static const Duration _timeout = Duration(seconds: 45);

  static const String systemPrompt = '''
You are a risk reviewer sitting next to a retail crypto trader. You are given
ONE trade setup produced by a rules engine, with the exact numbers the engine
used. Your job is to ATTACK it, not to approve it.

Rules you must follow:
- Judge only from the numbers given. You do not see a chart; do not pretend to.
- If the setup is inconsistent (target too close to be worth the fee, stop so
  tight the fee dominates, reward:risk under 1.5, direction fighting the stated
  structure), say so first.
- Be concrete. "Manage risk" is useless; "the 0.42% stop pays 1.4R of fee before
  the trade moves, so this needs a 60% win rate" is useful.
- Never invent a price, a level or an indicator value that was not supplied.
- Never claim certainty about the future, and never promise profit.

Answer in EXACTLY this shape, nothing else:

STANCE: AGREE | CAUTION | AVOID
CONFIDENCE: <0-100>
WHY: <one sentence, the single strongest point for or against>
RISK: <one sentence, the specific thing most likely to make this fail>
WHEN: <one sentence, what the trader should wait for or watch, or "take as is">
''';

  /// Ask the API which models this key can use, newest-relevant first.
  static Future<List<String>> listModels(String apiKey) async {
    if (apiKey.trim().length < 10) {
      throw GeminiException('API key nei. Prothome key add koro.');
    }
    final uri = Uri.parse('$_host/models?pageSize=100');
    final http.Response r;
    try {
      r = await http
          .get(uri, headers: <String, String>{'x-goog-api-key': apiKey.trim()})
          .timeout(_timeout);
    } on SocketException {
      throw GeminiException('Internet nei (ba network permission nei).');
    } on TimeoutException {
      throw GeminiException('Model list pete deri hocche. Abar try koro.');
    }
    _throwIfBad(r);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    final list = <String>[];
    for (final m in (body['models'] as List<dynamic>? ?? <dynamic>[])) {
      final map = m as Map<String, dynamic>;
      final methods = (map['supportedGenerationMethods'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList();
      if (!methods.contains('generateContent')) continue;
      final name = (map['name'] ?? '').toString().replaceFirst('models/', '');
      if (name.isEmpty) continue;
      list.add(name);
    }
    // Flash models first: they are the cheap ones and the ones a free key has.
    list.sort((a, b) {
      final af = a.contains('flash') ? 0 : 1;
      final bf = b.contains('flash') ? 0 : 1;
      if (af != bf) return af.compareTo(bf);
      return b.compareTo(a);
    });
    return list;
  }

  /// One generateContent call. Returns the text the model produced.
  static Future<String> _generate({
    required String apiKey,
    required String model,
    required String prompt,
    int maxTokens = _maxTokens,
    bool json = false,
  }) async {
    final uri = Uri.parse('$_host/models/$model:generateContent');
    final body = <String, dynamic>{
      'contents': <dynamic>[
        <String, dynamic>{
          'role': 'user',
          'parts': <dynamic>[
            <String, dynamic>{'text': prompt},
          ],
        },
      ],
      'systemInstruction': <String, dynamic>{
        'parts': <dynamic>[
          <String, dynamic>{'text': systemPrompt},
        ],
      },
      'generationConfig': <String, dynamic>{
        'temperature': 0.2,
        'maxOutputTokens': maxTokens,
        if (json) 'responseMimeType': 'application/json',
      },
    };
    final http.Response r;
    try {
      r = await http
          .post(
            uri,
            headers: <String, String>{
              'Content-Type': 'application/json',
              'x-goog-api-key': apiKey.trim(),
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } on SocketException {
      throw GeminiException('Internet nei (ba network permission nei).');
    } on TimeoutException {
      throw GeminiException('Gemini deri korche (>45s). Abar try koro.');
    }
    _throwIfBad(r);
    final decoded = jsonDecode(r.body) as Map<String, dynamic>;
    final cands = decoded['candidates'] as List<dynamic>? ?? <dynamic>[];
    if (cands.isEmpty) {
      final feedback = decoded['promptFeedback'];
      throw GeminiException('Model kono answer dey nai'
          '${feedback is Map ? ' (${feedback['blockReason'] ?? 'blocked'})' : ''}.');
    }
    final parts = ((cands.first as Map<String, dynamic>)['content']
            as Map<String, dynamic>?)?['parts'] as List<dynamic>? ??
        <dynamic>[];
    final buf = StringBuffer();
    for (final p in parts) {
      final t = (p as Map<String, dynamic>)['text'];
      if (t != null) buf.write(t);
    }
    return buf.toString().trim();
  }

  /// Turn an HTTP error into something a human can act on.
  static void _throwIfBad(http.Response r) {
    if (r.statusCode >= 200 && r.statusCode < 300) return;
    String detail = '';
    try {
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      detail = (j['error'] is Map)
          ? ((j['error']['message'] ?? '') as String)
          : r.body;
    } catch (_) {
      detail = r.body;
    }
    if (detail.length > 220) detail = '${detail.substring(0, 220)}...';
    switch (r.statusCode) {
      case 400:
        throw GeminiException(
            'Request bhul (400). Model name ba key check koro. $detail',
            status: 400);
      case 401:
      case 403:
        throw GeminiException(
            'Key kaj korche na (${r.statusCode}). Key thik ache kina dekho. '
            '$detail',
            status: r.statusCode);
      case 404:
        throw GeminiException(
            'Ei model ta nei (404). Settings e "Find a working model" chapo. '
            '$detail',
            status: 404);
      case 429:
        throw GeminiException(
            'Rate limit / quota shesh (429). Ektu por try koro. $detail',
            status: 429);
      default:
        throw GeminiException('HTTP ${r.statusCode}: $detail',
            status: r.statusCode);
    }
  }

  /// Cheap round trip used by the "Test key" button.
  static Future<String> ping({
    required String apiKey,
    required String model,
  }) async {
    final t = await _generate(
      apiKey: apiKey,
      model: model,
      prompt: 'Reply with the single word: OK',
      maxTokens: 20,
    );
    if (t.isEmpty) throw GeminiException('Key kaaj korche but answer khali.');
    return t;
  }

  /// Review one signal. The prompt carries the engine's own numbers, so the
  /// model cannot invent a setup it was not given.
  static Future<GeminiNote> reviewSignal({
    required String apiKey,
    required String model,
    required String modeLabel,
    required String timeframes,
    required String symbol,
    required String direction,
    required String tier,
    required double entry,
    required double sl,
    required double tp,
    required double price,
    required double confidence,
    required double rr,
    required double riskPct,
    required double rewardPct,
    required List<String> confirmations,
    required String pattern,
    required String zone,
    required String structure,
    double chop = 0,
    double costPct = 0.25,
  }) async {
    final stopPct = (entry - sl).abs() / (entry == 0 ? 1 : entry) * 100;
    final feeR = stopPct > 0 ? costPct / stopPct : 0;
    final barsToTarget = chop > 0 ? (rewardPct / chop) : 0;
    final prompt = StringBuffer()
      ..writeln('MODE: $modeLabel ($timeframes)')
      ..writeln('SYMBOL: $symbol')
      ..writeln('DIRECTION: $direction   TIER: $tier')
      ..writeln('PRICE: $price')
      ..writeln('ENTRY: $entry')
      ..writeln('STOP: $sl   (risk ${riskPct.toStringAsFixed(2)}% of price)')
      ..writeln('TARGET: $tp   (reward ${rewardPct.toStringAsFixed(2)}% of price)')
      ..writeln('REWARD:RISK: 1:${rr.toStringAsFixed(2)}')
      ..writeln('ENGINE CONFIDENCE: ${confidence.toStringAsFixed(0)}%')
      ..writeln('PATTERN: $pattern   ZONE: $zone')
      ..writeln('STRUCTURE: $structure')
      ..writeln('ROUND-TRIP COST: ${costPct.toStringAsFixed(2)}% of price, '
          'i.e. ${feeR.toStringAsFixed(2)}R on this stop');
    if (chop > 0) {
      prompt.writeln('MOVEMENT: ${chop.toStringAsFixed(2)}% per bar, so the '
          'target is roughly ${barsToTarget.toStringAsFixed(0)} bars away');
    }
    prompt.writeln('ENGINE CONFIRMATIONS:');
    for (final c in confirmations) {
      prompt.writeln('- $c');
    }
    prompt.writeln('');
    prompt.writeln('Review this setup. Follow the output format exactly.');

    final note = await _review(
      apiKey: apiKey,
      model: model,
      symbol: symbol,
      prompt: prompt.toString(),
    );
    return note;
  }

  /// Review the scan as a whole: is anything here worth taking, and what is the
  /// single best reason to sit out.
  static Future<GeminiNote> reviewScan({
    required String apiKey,
    required String model,
    required String modeLabel,
    required int coinsScanned,
    required String marketNote,
    required List<Map<String, dynamic>> signals,
  }) async {
    final prompt = StringBuffer()
      ..writeln('MODE: $modeLabel')
      ..writeln('COINS SCANNED: $coinsScanned')
      ..writeln('MARKET NOTE: $marketNote')
      ..writeln('SIGNALS (top ${signals.length}):');
    for (final s in signals) {
      prompt.writeln('- ${s['symbol']} ${s['direction']} ${s['tier']} '
          'conf ${s['confidence']}% RR 1:${s['rr']} '
          'risk ${s['riskPct']}% reward ${s['rewardPct']}%');
    }
    prompt.writeln('');
    prompt.writeln('Pick the ONE setup above you would take, if any, and say '
        'what would make you skip all of them. Follow the output format.');

    return _review(
      apiKey: apiKey,
      model: model,
      symbol: '',
      prompt: prompt.toString(),
    );
  }

  static Future<GeminiNote> _review({
    required String apiKey,
    required String model,
    required String symbol,
    required String prompt,
  }) async {
    try {
      final text = await _generate(
        apiKey: apiKey,
        model: model,
        prompt: prompt,
      );
      return GeminiNote(
        symbol: symbol,
        text: text,
        model: model,
        at: DateTime.now(),
        stance: _stance(text),
        confidence: _confidence(text),
      );
    } on GeminiException catch (e) {
      return GeminiNote(
        symbol: symbol,
        text: '',
        model: model,
        at: DateTime.now(),
        error: e.message,
      );
    } catch (e) {
      return GeminiNote(
        symbol: symbol,
        text: '',
        model: model,
        at: DateTime.now(),
        error: 'Gemini error: $e',
      );
    }
  }

  static String _stance(String text) {
    final m = RegExp(r'STANCE\s*:\s*(AGREE|CAUTION|AVOID)', caseSensitive: false)
        .firstMatch(text);
    return m == null ? '' : m.group(1)!.toUpperCase();
  }

  static int _confidence(String text) {
    final m = RegExp(r'CONFIDENCE\s*:\s*(\d{1,3})', caseSensitive: false)
        .firstMatch(text);
    if (m == null) return -1;
    final v = int.tryParse(m.group(1)!) ?? -1;
    if (v < 0) return -1;
    return v > 100 ? 100 : v;
  }
}

/// Key + model, stored on the device.
///
/// SharedPreferences is not in `pubspec.yaml` on purpose: adding a dependency
/// means a `flutter pub get` against pub.dev during the release build, and a
/// network hiccup there fails the whole APK. The key is small and does not need
/// a database, so it goes through platform channels directly --
/// `SharedPreferences` on the app's private sandbox, which is what the plugin
/// would have used anyway.
class GeminiStore {
  static const MethodChannel _ch =
      MethodChannel('com.smartmoney.smart_money_trader/prefs');

  static const String _kKey = 'gemini_api_key';
  static const String _kModel = 'gemini_model';
  static const String _kEnabled = 'gemini_enabled';
  static const String _kAuto = 'gemini_auto';

  /// True when the platform side answered. Before the Kotlin handler is
  /// installed, the settings sheet still works but says the key will not
  /// survive a restart.
  static bool persistent = false;

  static Future<String> _get(String k) async {
    try {
      final v = await _ch.invokeMethod<String>('getString', <String, dynamic>{
        'key': k,
      });
      persistent = true;
      return v ?? '';
    } on MissingPluginException {
      persistent = false;
      return '';
    } on PlatformException {
      persistent = false;
      return '';
    }
  }

  static Future<void> _set(String k, String v) async {
    try {
      await _ch.invokeMethod<void>('setString', <String, dynamic>{
        'key': k,
        'value': v,
      });
      persistent = true;
    } on MissingPluginException {
      persistent = false;
    } on PlatformException {
      persistent = false;
    }
  }

  static Future<GeminiConfig> load() async {
    final key = await _get(_kKey);
    final model = await _get(_kModel);
    final enabled = await _get(_kEnabled);
    final auto = await _get(_kAuto);
    return GeminiConfig(
      apiKey: key,
      model: model.isEmpty ? kGeminiDefaultModel : model,
      enabled: enabled.isEmpty ? true : enabled == '1',
      autoReview: auto.isEmpty ? true : auto == '1',
    );
  }

  static Future<void> save(GeminiConfig c) async {
    await _set(_kKey, c.apiKey.trim());
    await _set(_kModel, c.model);
    await _set(_kEnabled, c.enabled ? '1' : '0');
    await _set(_kAuto, c.autoReview ? '1' : '0');
  }
}

/// ---------------------------------------------------------------------------
/// The settings sheet: paste a key, pick a model, prove it works.
/// ---------------------------------------------------------------------------
///
/// Deliberately shown as a bottom sheet with the key masked, a "test" button
/// that performs a real request, and a "find a working model" button, because
/// the two ways a user gets stuck are a typo'd key and a retired model name.
/// Neither is solvable by a message that just says "error".
Future<void> showGeminiSettings(
  BuildContext context, {
  required GeminiConfig current,
  required Future<void> Function(GeminiConfig) onSaved,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF161B22),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _GeminiSettingsSheet(current: current, onSaved: onSaved),
  );
}

class _GeminiSettingsSheet extends StatefulWidget {
  const _GeminiSettingsSheet({required this.current, required this.onSaved});
  final GeminiConfig current;
  final Future<void> Function(GeminiConfig) onSaved;

  @override
  State<_GeminiSettingsSheet> createState() => _GeminiSettingsSheetState();
}

class _GeminiSettingsSheetState extends State<_GeminiSettingsSheet> {
  late TextEditingController _key;
  late String _model;
  late bool _enabled;
  late bool _auto;
  bool _obscure = true;
  bool _busy = false;
  String _status = '';
  bool _statusBad = false;

  static const Color _bg = Color(0xFF0D1117);
  static const Color _panel = Color(0xFF21262D);
  static const Color _line = Color(0xFF30363D);
  static const Color _green = Color(0xFF3FB950);
  static const Color _red = Color(0xFFF85149);
  static const Color _text = Color(0xFFE6EDF3);
  static const Color _muted = Color(0xFF8B949E);
  static const Color _blue = Color(0xFF58A6FF);

  @override
  void initState() {
    super.initState();
    _key = TextEditingController(text: widget.current.apiKey);
    _model = widget.current.model;
    _enabled = widget.current.enabled;
    _auto = widget.current.autoReview;
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  GeminiConfig get _cfg => GeminiConfig(
        apiKey: _key.text,
        model: _model,
        enabled: _enabled,
        autoReview: _auto,
      );

  void _say(String msg, {bool bad = false}) {
    setState(() {
      _status = msg;
      _statusBad = bad;
    });
  }

  Future<void> _test() async {
    setState(() => _busy = true);
    _say('Test hocche...');
    try {
      final reply = await GeminiService.ping(
        apiKey: _key.text,
        model: _model,
      );
      _say('Key kaj korche. Model: $_model — reply: "$reply"');
    } on GeminiException catch (e) {
      _say(e.message, bad: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _findModel() async {
    setState(() => _busy = true);
    _say('Kon model cholche dekchi...');
    try {
      final models = await GeminiService.listModels(_key.text);
      if (models.isEmpty) {
        _say('Ei key diye kono generateContent model pa jay nai.', bad: true);
      } else {
        setState(() => _model = models.first);
        _say('${models.length} model pa gechi. "${models.first}" set kora holo. '
            '${models.length > 1 ? 'Alternatives: ${models.take(4).skip(1).join(', ')}' : ''}');
      }
    } on GeminiException catch (e) {
      _say(e.message, bad: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    await widget.onSaved(_cfg);
    if (!mounted) return;
    setState(() => _busy = false);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 14, 18, 18 + insets),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: _line,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Gemini (second opinion)',
              style: TextStyle(
                  color: _text, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            const Text(
              'Engine-i signal dey. Gemini shudhu tar upor ekta opinion dey — '
              'signal add, remove ba reorder kore na.',
              style: TextStyle(color: _muted, fontSize: 11, height: 1.4),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _key,
              obscureText: _obscure,
              style: const TextStyle(color: _text, fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Gemini API key',
                labelStyle: const TextStyle(color: _muted, fontSize: 12),
                hintText: 'AIza...',
                hintStyle: const TextStyle(color: _muted, fontSize: 12),
                filled: true,
                fillColor: _panel,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure ? Icons.visibility : Icons.visibility_off,
                    color: _muted,
                    size: 18,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: _line),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: _line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: _blue),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _test,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _text,
                      side: const BorderSide(color: _line),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(Icons.wifi_tethering, size: 15),
                    label: const Text('Test key', style: TextStyle(fontSize: 12)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _findModel,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _text,
                      side: const BorderSide(color: _line),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(Icons.search, size: 15),
                    label: const Text('Find a model',
                        style: TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ),
            if (_status.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: (_statusBad ? _red : _green).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: (_statusBad ? _red : _green).withOpacity(0.5)),
                ),
                child: Text(
                  _status,
                  style: TextStyle(
                      color: _statusBad ? _red : _green,
                      fontSize: 11,
                      height: 1.4),
                ),
              ),
            ],
            const SizedBox(height: 16),
            const Text('Model',
                style: TextStyle(
                    color: _text,
                    fontSize: 13,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final m in <String>{
                  _model,
                  ...kGeminiModels,
                })
                  GestureDetector(
                    onTap: () => setState(() => _model = m),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 5),
                      decoration: BoxDecoration(
                        color: _model == m
                            ? _green.withOpacity(0.18)
                            : _panel,
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(
                            color: _model == m ? _green : _line),
                      ),
                      child: Text(
                        m,
                        style: TextStyle(
                          color: _model == m ? _green : _muted,
                          fontSize: 10,
                          fontWeight: _model == m
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _enabled,
              activeColor: _green,
              onChanged: (v) => setState(() => _enabled = v),
              title: const Text('Gemini on',
                  style: TextStyle(color: _text, fontSize: 13)),
              subtitle: const Text(
                'Off korle ekta request-o jay na.',
                style: TextStyle(color: _muted, fontSize: 11),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _auto,
              activeColor: _green,
              onChanged: (v) => setState(() => _auto = v),
              title: const Text('Auto review top signals',
                  style: TextStyle(color: _text, fontSize: 13)),
              subtitle: const Text(
                'Prottek scan e top 3 signal er review nije nije asbe.',
                style: TextStyle(color: _muted, fontSize: 11),
              ),
            ),
            if (!GeminiStore.persistent)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFD29922).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'Note: ei build e key app bondho korle save thakbe na '
                  '(device storage plugin nei). Key abar paste korte hobe.',
                  style: TextStyle(
                      color: Color(0xFFD29922), fontSize: 10, height: 1.4),
                ),
              ),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _muted,
                      side: const BorderSide(color: _line),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    child: const Text('Cancel', style: TextStyle(fontSize: 13)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    onPressed: _busy ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _green,
                      foregroundColor: _bg,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    child: Text(
                      _busy ? '...' : 'Save',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'Key shudhu tomar phone e thake. App theke shudhu '
              'generativelanguage.googleapis.com e jay. '
              'Key onujayi bill hobe tomar Google account e.',
              style: TextStyle(color: _muted, fontSize: 10, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
