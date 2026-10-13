import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import '../data/atomic_file.dart';

/// 一个模型的用量记录。
///
/// ## 为什么记的是"字符数"而不是 token
///
/// 用户要求（2026-10-07）：「所有大模型能不能加个字段，显示用量」。
///
/// token 数是**模型侧**才知道的东西：云端各家的 `usage` 字段要供应商返回，
/// 本机要引擎报。而 ACP 目前**不把用量推给客户端**（见 `context_budget.dart`
/// 里那句"这是估算，不是真实用量"）—— 所以我**不编造 token 数**，
/// 只记 App 自己**数得准**的两样：请求次数 + 输入/输出字符数。
/// 将来 DSH 真把 usage 推上来，再在这里加字段（不改界面）。
class UsageRecord {
  UsageRecord({
    this.requests = 0,
    this.charsIn = 0,
    this.charsOut = 0,
    this.lastAt,
  });

  /// 一共发过多少次请求（一轮算一次）。
  int requests;

  /// 用户输入的字符数合计。
  int charsIn;

  /// 模型输出的字符数合计。
  int charsOut;

  DateTime? lastAt;

  int get totalChars => charsIn + charsOut;

  factory UsageRecord.fromJson(Map<String, dynamic> j) => UsageRecord(
        requests: (j['requests'] as num?)?.toInt() ?? 0,
        charsIn: (j['charsIn'] as num?)?.toInt() ?? 0,
        charsOut: (j['charsOut'] as num?)?.toInt() ?? 0,
        lastAt: DateTime.tryParse((j['lastAt'] as String?) ?? ''),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'requests': requests,
        'charsIn': charsIn,
        'charsOut': charsOut,
        'lastAt': (lastAt ?? DateTime.now()).toIso8601String(),
      };
}

/// 按模型 route 记用量，落在 `<nodeHome>/usage.json`。
///
/// 为什么按 **route**（`provider/model`）记：用户看到的、能挑的、能比的都是 route；
/// 同一个厂家换模型要能分开看用量。
class UsageStore {
  UsageStore({required this.path});

  final String path;

  final Map<String, UsageRecord> _byRoute = <String, UsageRecord>{};

  bool _loaded = false;

  Map<String, UsageRecord> get all =>
      Map<String, UsageRecord>.unmodifiable(_byRoute);

  UsageRecord? of(String? route) {
    if (route == null || route.isEmpty) return null;
    return _byRoute[route];
  }

  Future<void> load() async {
    try {
      final f = File(path);
      if (f.existsSync()) {
        final raw = jsonDecode(f.readAsStringSync());
        if (raw is Map && raw['routes'] is Map) {
          (raw['routes'] as Map).forEach((k, v) {
            if (v is Map) {
              _byRoute['$k'] =
                  UsageRecord.fromJson(Map<String, dynamic>.from(v));
            }
          });
        }
      }
    } catch (e) {
      // 坏了当空表：用量是"看着舒服"的东西，绝不能因为它让会话起不来。
      debugPrint('[dsh-usage] 读用量失败（当作空）：$e');
      _byRoute.clear();
    }
    _loaded = true;
  }

  /// 记一轮：请求 +1，并累加输入/输出字符数。
  ///
  /// [route] 空则整轮丢弃（宁可不记，也不往一个假 key 上记）。
  Future<void> add({
    required String? route,
    int charsIn = 0,
    int charsOut = 0,
  }) async {
    if (route == null || route.isEmpty) return;
    if (!_loaded) await load();
    final rec = _byRoute.putIfAbsent(route, UsageRecord.new);
    rec.requests += 1;
    rec.charsIn += charsIn < 0 ? 0 : charsIn;
    rec.charsOut += charsOut < 0 ? 0 : charsOut;
    rec.lastAt = DateTime.now();
    await save();
  }

  Future<void> save() async {
    try {
      final dir = File(path).parent;
      if (!dir.existsSync()) await dir.create(recursive: true);
      await writeStringAtomic(File(path), jsonEncode(<String, dynamic>{
        'version': 1,
        'routes': _byRoute.map((k, v) => MapEntry(k, v.toJson())),
      }));
    } catch (e) {
      debugPrint('[dsh-usage] 写用量失败（不影响使用）：$e');
    }
  }

  /// 把字符数折成好读的短串（**不含任何语言**：数字 + 万/k 之类由界面决定措辞）。
  static String shortChars(int totalChars) => totalChars >= 10000
      ? '${(totalChars / 10000).toStringAsFixed(1)} 万'
      : '$totalChars';
}
