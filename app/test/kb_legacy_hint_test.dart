/// 「旧切法索引」必须在**本地对话页**也提示出来（用户 2026-10-12 排查时发现）。
///
/// ## 为什么非有不可
///
/// 旧切法的索引会把 0.66 新加的相关度门槛**废掉**：旧切法把好几篇互不相关的
/// 文章揉进同一块（实测 12 篇 → 2 块，一块里 9 篇），那个块跟**任何**问句都能
/// 对上 ≥2 个词，正好过门槛。这不能怪门槛（它没权力判断一块里混了几篇），
/// 是索引本身没重建。
///
/// 而提示**只做了一半**：知识库页会把旧索引标成「检索会不准」，但用户碰得
/// 最多的**对话页**一个字都不说 —— 于是"索引没重建的用户，0.66 的门槛对他
/// 几乎无效，而他根本不知道"。
library;

import 'dart:io';

import 'package:dsh_mobile/local/kb_index.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  KbIndexMeta? metaWith({int? chunkMode}) => KbIndexMeta.fromJson(<String, dynamic>{
        'chunks': 12,
        'sourceBytes': 4096,
        'signatureSize': 8,
        'builtAt': DateTime(2026, 10, 12).toIso8601String(),
        'sourceFile': 'wiki.json',
        if (chunkMode != null) 'chunkMode': chunkMode,
      });

  test('旧切法（老 meta 没有 chunkMode）的包会被挑出来', () {
    final legacy = legacyChunkPackNames(<String, KbIndexMeta?>{
      '知识库': metaWith(), // 老文件缺字段 → kChunkModeLegacy
      '我的笔记': metaWith(chunkMode: kChunkModeDocBoundary),
    });
    expect(legacy, <String>['知识库'],
        reason: '索引没重建却没提示 —— 用户会以为新门槛对他生效了');
  });

  test('新切法的包一个都不许被挑出来（别天天喊重建）', () {
    final legacy = legacyChunkPackNames(<String, KbIndexMeta?>{
      '知识库': metaWith(chunkMode: kChunkModeDocBoundary),
      '我的笔记': metaWith(chunkMode: kChunkModeDocBoundary),
    });
    expect(legacy, isEmpty);
  });

  test('没建索引的包（meta 为 null）不算旧切法 —— 它另有提示', () {
    final legacy = legacyChunkPackNames(<String, KbIndexMeta?>{'没建索引': null});
    expect(legacy, isEmpty);
  });

  test('对话页确实把这条提示接上了（防"算出来了但不显示"）', () {
    // 为什么读源码：这条要证明的是"页面用了这个判定并把它渲染出来"，
    // 而"算出来了却不显示"正是这次要修的那个洞。
    final src = File('lib/ui/pages/local_chat_page.dart').readAsStringSync();
    expect(src.contains('legacyChunkPackNames('), isTrue,
        reason: '对话页没用共用的判定');
    expect(src.contains('_kbLegacyNotice('), isTrue,
        reason: '判定出来了却不提示');
    expect(src.contains('去知识库页重建'), isTrue,
        reason: '只说了有问题，没给"怎么办"');
  });
}
