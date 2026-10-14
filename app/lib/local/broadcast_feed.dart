/// 「群发消息 / 首页公告」：拉一份 `notice.json`，给首页那条滚动信息栏用。
///
/// ## 它是什么、不是什么
///
///   * **是**：我在仓库里改一个字就能让所有装了 App 的人看到的**单向广播**
///     （发版说明、活动、公众号推广、临时通知）。清单放**仓库根目录**，
///     与 `update.json` 并排 —— 复用同一套"raw 主源 + jsDelivr 兜底"的理由
///     （见 `update_source.dart` 的实测表）。
///   * **不是**：不是推送、不是聊天、更不是用户数据回传 ——
///     这个 App **只读不写**，一个字节的客户端信息都不会发出去。
///
/// ## 三条纪律（与 `update_checker.dart` 完全一致，别改）
///
///   ① 失败**静默**：网络不通是常态，拉不到公告不该弹窗、更不该卡启动；
///   ② **有缓存就有内容**：每次成功拉到都落一份到私有目录，
///      离线/断网时用上次那份（界面如实写"上次同步于 …"）；
///   ③ **拉不到就不显示**：绝不用假数据撑场面 —— 首页那条栏空着比写着编的
///      "欢迎使用"诚实。
///
/// ## 为什么自己写 HttpClient
///
/// 同 `update_checker.dart`：只为一次 GET 给 APK 加第三方依赖不值；并且这里
/// 同样**限制响应体积**（[kMaxBroadcastBytes]）—— 清单是几 KB 的东西，
/// 真有人塞个 100 MB 的响应回来不该把 App 撑死。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'update_source.dart';

/// 公告清单响应上限（正常几 KB；256 KB 是留给"公告写长一点"的余量）。
const int kMaxBroadcastBytes = 256 * 1024;

/// 单个源的超时。**刻意短** —— 这是启动后台行为，宁可这次没有。
const Duration kBroadcastTimeout = Duration(seconds: 8);

/// 一条公告 / 一条广告位内容。
class BroadcastItem {
  const BroadcastItem({required this.text, this.url, this.tag});

  /// 正文（必填；空的条目直接丢掉，不给界面留一个空行）
  final String text;

  /// 可选跳转（点"查看详情"时用系统浏览器打开）
  final String? url;

  /// 可选标签：`公告` / `推广` / `活动`…（界面用它着色；不填就是不显示标签）
  final String? tag;

  Map<String, Object?> toJson() => <String, Object?>{
        'text': text,
        if (url != null && url!.isNotEmpty) 'url': url,
        if (tag != null && tag!.isNotEmpty) 'tag': tag,
      };

  static BroadcastItem? fromJson(Object? raw) {
    if (raw is String) {
      // 也接受"清单里就写一行字符串"的极简写法（手改清单时最省事）
      final s = raw.trim();
      return s.isEmpty ? null : BroadcastItem(text: s);
    }
    if (raw is! Map) return null;
    final text = raw['text']?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    final url = raw['url']?.toString().trim() ?? '';
    final tag = raw['tag']?.toString().trim() ?? '';
    return BroadcastItem(
      text: text,
      url: url.isEmpty ? null : url,
      tag: tag.isEmpty ? null : tag,
    );
  }
}

/// 一份公告清单。
class BroadcastFeed {
  const BroadcastFeed({required this.items, this.updatedAt, this.fetchedAt});

  final List<BroadcastItem> items;

  /// 清单里写的更新时间（`updatedAt`，可缺）
  final DateTime? updatedAt;

  /// 本地成功拉到的时刻（缓存读回来的那份就是它当时的时间）
  final DateTime? fetchedAt;

  bool get isEmpty => items.isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
        if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
        if (fetchedAt != null) 'fetchedAt': fetchedAt!.toIso8601String(),
        'items': items.map((e) => e.toJson()).toList(),
      };

  static BroadcastFeed? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final list = raw['items'];
    if (list is! List) return null;
    final items = <BroadcastItem>[];
    for (final e in list) {
      final item = BroadcastItem.fromJson(e);
      if (item != null) items.add(item);
    }
    return BroadcastFeed(
      items: items,
      updatedAt: _parseTime(raw['updatedAt']),
      fetchedAt: _parseTime(raw['fetchedAt']),
    );
  }
}

DateTime? _parseTime(Object? raw) {
  if (raw is num) {
    final ms = raw < 100000000000 ? raw.toInt() * 1000 : raw.toInt();
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }
  if (raw is String && raw.trim().isNotEmpty) {
    return DateTime.tryParse(raw.trim());
  }
  return null;
}

/// 拉一次公告清单：多个源依次试，**不抛异常**（失败返回 null）。
///
/// [customSource] 非空时**只用它**（用户在设置里自填镜像的场景）。
Future<BroadcastFeed?> fetchBroadcastFeed({
  String? customSource,
  List<String>? sources,
  bool bypassCache = false,
  Duration timeout = kBroadcastTimeout,
  HttpClient Function()? clientFactory,
}) async {
  final list = <String>[];
  final custom = customSource?.trim() ?? '';
  if (custom.isNotEmpty) {
    list.add(custom);
  } else {
    list.addAll(sources ?? defaultBroadcastSources());
  }

  var attempt = 0;
  for (var url in list) {
    attempt++;
    if (bypassCache) {
      url = '$url${url.contains('?') ? '&' : '?'}t=${DateTime.now().millisecondsSinceEpoch}';
    }
    final client = (clientFactory ?? HttpClient.new)();
    client.connectionTimeout = timeout;
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(timeout);
      final res = await req.close().timeout(timeout);
      if (res.statusCode != 200) {
        debugPrint('[dsh-notice] 源 $attempt 返回 ${res.statusCode}：$url');
        continue;
      }
      final buf = <int>[];
      await for (final chunk in res.timeout(timeout)) {
        buf.addAll(chunk);
        if (buf.length > kMaxBroadcastBytes) {
          debugPrint('[dsh-notice] 源 $attempt 响应超过 $kMaxBroadcastBytes 字节，放弃');
          buf.clear();
          break;
        }
      }
      if (buf.isEmpty) continue;
      final decoded = jsonDecode(utf8.decode(buf));
      final feed = BroadcastFeed.fromJson(decoded);
      if (feed == null) {
        debugPrint('[dsh-notice] 源 $attempt 的 JSON 里没有 items 数组：$url');
        continue;
      }
      debugPrint('[dsh-notice] 源 $attempt 拉到 ${feed.items.length} 条公告');
      return BroadcastFeed(
        items: feed.items,
        updatedAt: feed.updatedAt,
        fetchedAt: DateTime.now(),
      );
    } catch (e) {
      debugPrint('[dsh-notice] 源 $attempt 失败（换下一个）：$e');
    } finally {
      client.close(force: true);
    }
  }
  debugPrint('[dsh-notice] ${list.length} 个源都没拿到公告（静默，不打扰用户）');
  return null;
}

// ─────────────────────────────────────────── 本地缓存（离线也能看到上次那份）

String broadcastCachePath(String filesDir) => '$filesDir/notice_cache.json';

/// 读上次成功拉到的那份公告（没有就返回 null）。
BroadcastFeed? loadCachedBroadcast(String filesDir) {
  try {
    final f = File(broadcastCachePath(filesDir));
    if (!f.existsSync()) return null;
    return BroadcastFeed.fromJson(jsonDecode(f.readAsStringSync()));
  } catch (e) {
    debugPrint('[dsh-notice] 读本地缓存失败（当成没有）：$e');
    return null;
  }
}

/// 把刚拉到的那份落盘（先写 .tmp 再改名，中途被杀不会留半截 JSON）。
void saveCachedBroadcast(String filesDir, BroadcastFeed feed) {
  try {
    final f = File(broadcastCachePath(filesDir));
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(feed.toJson()));
    tmp.renameSync(f.path);
  } catch (e) {
    debugPrint('[dsh-notice] 写本地缓存失败（不影响本次显示）：$e');
  }
}
