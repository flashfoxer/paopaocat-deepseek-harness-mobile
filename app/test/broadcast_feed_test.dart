// 用户 2026-10-15 第 3 条：首页要有「信息滚动栏 / 广告位」，位置在版本号下面。
//
// 数据来自仓库根目录的 `notice.json`（见 local/broadcast_feed.dart）。
// 这个测试钉住**解析**与**缓存**这两段纯逻辑（网络那一段靠"拉不到就静默"的
// 约定，不在单测里打真网）。
//
// 三条口径：
//   ① 清单里既能写对象、也能写一行字符串（手改清单时最省事）；
//   ② 空文本 / 空 items 一律丢掉 —— 界面宁可没有，也不显示一行空白；
//   ③ 缓存能原样读回来（离线时靠它）。

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/local/broadcast_feed.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('dsh-notice-'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('清单解析', () {
    test('对象写法：text 必填，url / tag 可选，空文本丢掉', () {
      final feed = BroadcastFeed.fromJson(<String, Object?>{
        'updatedAt': '2026-10-15T10:00:00+08:00',
        'items': <Object?>[
          <String, Object?>{'tag': '公告', 'text': '0.76 在做：会话列表显示时间与用量'},
          <String, Object?>{'text': '', 'tag': '公告'},
          <String, Object?>{'text': '公众号更新了', 'url': 'https://example.com/a'},
          '一行字符串也能用',
        ],
      });
      expect(feed, isNotNull);
      expect(feed!.items.length, 3);
      expect(feed.items[0].tag, '公告');
      expect(feed.items[0].url, isNull);
      expect(feed.items[1].url, 'https://example.com/a');
      expect(feed.items[2].text, '一行字符串也能用');
      expect(feed.updatedAt, isNotNull);
    });

    test('没有 items 数组 → null（不是"空清单"，界面据此不动）', () {
      expect(BroadcastFeed.fromJson(<String, Object?>{'foo': 1}), isNull);
      expect(BroadcastFeed.fromJson('字符串'), isNull);
      expect(BroadcastFeed.fromJson(null), isNull);
    });

    test('items 里全是垃圾 → 空清单（界面不画那一条）', () {
      final feed = BroadcastFeed.fromJson(<String, Object?>{
        'items': <Object?>[null, 42, <String, Object?>{'nope': 'x'}],
      });
      expect(feed, isNotNull);
      expect(feed!.isEmpty, isTrue);
    });
  });

  group('本地缓存（离线时的兜底）', () {
    test('存了就能读回来，内容一致', () {
      final feed = BroadcastFeed(
        items: const <BroadcastItem>[
          BroadcastItem(text: '第一条', tag: '公告'),
          BroadcastItem(text: '第二条', url: 'https://example.com'),
        ],
        updatedAt: DateTime(2026, 10, 15, 10),
        fetchedAt: DateTime(2026, 10, 15, 11),
      );
      saveCachedBroadcast(tmp.path, feed);
      final back = loadCachedBroadcast(tmp.path);
      expect(back, isNotNull);
      expect(back!.items.map((e) => e.text), <String>['第一条', '第二条']);
      expect(back.items[1].url, 'https://example.com');
      expect(back.fetchedAt, isNotNull);
      // 落盘的是**明文 JSON**（排查时能直接看，不用猜）
      final raw = jsonDecode(
          File(broadcastCachePath(tmp.path)).readAsStringSync()) as Map;
      expect((raw['items'] as List).length, 2);
    });

    test('没有缓存文件 → null（不编一份出来）', () {
      expect(loadCachedBroadcast(tmp.path), isNull);
    });

    test('缓存文件坏了 → null（当成没有，不崩）', () {
      File(broadcastCachePath(tmp.path)).writeAsStringSync('{不是 JSON');
      expect(loadCachedBroadcast(tmp.path), isNull);
    });
  });
}
