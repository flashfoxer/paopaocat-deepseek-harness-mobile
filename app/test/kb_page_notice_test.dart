/// 「知识库 → 下载」前那条第三方语料提示的回归测试。
///
/// 用户 2026-10-09 明确要求：下载下来的资料是第三方社区语料，
/// 必须**在点「下载」之前**就把这件事说清楚。这条提示是合规口径的一部分，
/// 不是装饰文案，所以钉住它别在后续改版里被顺手删掉。
///
/// 两个方向分开钉，因为它们的验证方式不同：
///   ① **正向（走真界面）**：有可下载的包时，提示必须真的渲染出来。
///   ② **反向（纯逻辑）**：只剩随包样例时不提示 —— 那是我们自己随 APK 发出去的
///      东西，对它喊"第三方语料未经审查"是假警报。
///
/// ⚠️ 2026-10-12 追加（用户：「把知识库的中文维基百科字样消除，就写知识库三个字就行」）：
/// 提示与清单里的「中文维基百科」字样**全部去掉**，可下载包就叫「知识库」。
/// 提示本身留着 —— 去掉的是"点名是哪一份语料"，不是"这是第三方语料"这件事。
/// 文件末尾那组测试把这条要求钉死（清单正文 + 页面源码都不许再出现那六个字）。
///
/// ⚠️ 清单里现在**已经没有**随包样例了（用户 2026-10-09 决定不内置样本库，
/// 见 docs/KB-COMPLIANCE-2026-10-09.md）。② 仍保留：它钉的是
/// [KbPage.needsDownloadNotice] 这个**函数契约**，将来若放回人工筛过的样例，
/// 行为必须还是对的。
///
/// ⚠️ 反向为什么不做成 widget 测试：`KbStore.list()` 里有真实文件 I/O
/// （`await meta.readAsString()`），而 `testWidgets` 跑在 fake-async 区里，
/// 真实 I/O 的 future 不会完成 → `pumpAndSettle` 会一路等到 10 分钟超时。
/// 实测踩过这个坑，所以把条件抽成 [KbPage.needsDownloadNotice] 直接断言。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/local/kb_manifest.dart';
import 'package:dsh_mobile/ui/pages/kb_page.dart';
import 'package:dsh_mobile/ui/theme/dsh_tokens.dart';

/// 提示的开头（整条很长，断言用开头足够定位，也不必把整段中文抄两遍）。
const String kNoticeHead = '下载的资料是第三方社区语料';

/// 造一个包：只要 [bundled] 不同，其余字段对这条测试都无所谓。
KbPack pack({required bool bundled}) => KbPack(
      id: bundled ? 'sample' : 'zhwiki-cn-2307',
      name: bundled ? '样例知识库' : '第三方语料包',
      kind: 'encyclopedia',
      format: 'json-array',
      textField: 'completion',
      bundled: bundled,
      fileName: 'x.json',
      bytes: 1,
      entries: 1,
      license: 'CC BY-SA 4.0',
      note: '',
      sources: const <KbSource>[],
    );

void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('dsh-kb-notice');
  });

  tearDown(() async {
    if (home.existsSync()) await home.delete(recursive: true);
  });

  testWidgets('有可下载的包时：下载按钮之前就有第三方语料提示',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildDshTheme(),
      home: Scaffold(body: KbPage(dshHome: home.path)),
    ));
    await tester.pumpAndSettle();

    // 前提：清单里那个 500 MB 的包确实渲染在「可下载」区（否则下面那条断言没意义）。
    // ⚠️ 锚点从"中文维基百科"换成了条数 —— 包名现在就叫「知识库」（用户 2026-10-12 要求），
    //    而"知识库"这三个字在页面上到处都是，当锚点等于没断言。
    expect(find.textContaining('254547'), findsWidgets,
        reason: '清单里的可下载包没渲染出来，测试前提不成立');

    expect(find.textContaining(kNoticeHead), findsOneWidget,
        reason: '下载前提示不见了 —— 用户明确要求这条必须在');
  });

  group('要不要显示提示（条件本身）', () {
    test('只剩随包样例 → 不提示（那是我们自己发出去的，别喊狼来了）', () {
      expect(KbPage.needsDownloadNotice(<KbPack>[pack(bundled: true)]), isFalse);
    });

    test('有需要联网下载的包 → 提示', () {
      expect(
          KbPage.needsDownloadNotice(<KbPack>[
            pack(bundled: true),
            pack(bundled: false),
          ]),
          isTrue);
    });

    test('一个包都没有 → 不提示（空列表不该冒出这段话）', () {
      expect(KbPage.needsDownloadNotice(const <KbPack>[]), isFalse);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 用户 2026-10-12：「把知识库的中文维基百科字样消除，就写知识库三个字就行」
  //
  // 这一组钉两件事，因为它们会以不同方式被改回去：
  //   ① **清单正文**里不许再出现那六个字（改的人可能只改页面、忘了清单）；
  //   ② **页面源码**里不许再出现（改的人可能只改清单、忘了提示）。
  // 另外把"包名就是知识库"也钉住 —— 用户要的是"三个字"，不是"知识库（清洗版・…）"。
  // ══════════════════════════════════════════════════════════════════════════
  group('知识库里不许再出现「中文维基百科」字样（2026-10-12 用户要求）', () {
    const forbidden = '中文维基百科';

    test('可下载清单正文里没有这六个字，且包名就是「知识库」', () {
      final f = File('assets/kb/kb_manifest.json');
      expect(f.existsSync(), isTrue, reason: '清单不在 → 这个测试失去意义');
      final src = f.readAsStringSync();
      expect(src.contains(forbidden), isFalse,
          reason: '清单里还有「$forbidden」—— 用户要求消除');

      final m = KbManifest.parse(src);
      final packs = m.packs.where((p) => !p.bundled).toList();
      expect(packs, isNotEmpty, reason: '清单里一个可下载包都没有了？');
      for (final p in packs) {
        expect(p.name, '知识库',
            reason: '包名应当是「知识库」三个字（用户原话），实际是「${p.name}」');
        expect(p.name.contains(forbidden), isFalse);
      }
    });

    test('知识库页的提示文案里也没有这六个字（提示本身必须在）', () {
      final src = File('lib/ui/pages/kb_page.dart').readAsStringSync();
      // 只检查**字符串字面量**那几行，注释里提到"用户要求去掉…"是允许的
      // （注释是给改代码的人看的，不会出现在界面上）。
      final offenders = src
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .where((l) => l.contains(forbidden))
          .toList();
      expect(offenders, isEmpty,
          reason: '页面代码里还有「$forbidden」：${offenders.join(' / ')}');
      expect(src.contains(kNoticeHead), isTrue,
          reason: '提示本身被误删了 —— 去掉的只是"点名是哪一份语料"');
    });

    // 用户 2026-10-12 选的是「**只去掉数据源名字和链接**，保留过滤不完整/未经审查的说明」。
    // 这一条钉的就是这个取舍：不能连披露一起删掉，也不能留着数据源名字。
    test('说明文字（note）不点名数据源，但合规披露必须还在', () {
      final packs = KbManifest.parse(
              File('assets/kb/kb_manifest.json').readAsStringSync())
          .packs
          .where((p) => !p.bundled)
          .toList();
      expect(packs, isNotEmpty);

      for (final p in packs) {
        final low = p.note.toLowerCase();
        for (final w in <String>['wikipedia', 'hf-mirror', 'huggingface']) {
          expect(low.contains(w), isFalse,
              reason: '「${p.name}」的说明文字里还有数据源字样「$w」');
        }
        // ↓ 这三样是"披露"的分量，删掉就等于撤回 2026-10-09 你自己要的那层说明。
        expect(p.note.contains('不完整'), isTrue,
            reason: '「${p.name}」的说明里"过滤不完整"没了');
        expect(p.note.contains('内容不代表'), isTrue,
            reason: '「${p.name}」的说明里"内容不代表我们观点"没了');
      }

      // ⚠️ 下载地址**不能**跟着一起删 —— 删了就下不下来了。
      //    （地址不在界面上渲染，只是 note 里不点名而已。）
      expect(packs.first.sources, isNotEmpty,
          reason: 'sources 是下载用的真地址，被误删了');
    });
  });
}
