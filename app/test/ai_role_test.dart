/// 「AI 角色（实验）」的测试（`lib/ui/pages/ai_role_page.dart`）。
///
/// ## 为什么值得测
///
/// 这一页自己**不实现**任何游戏逻辑 —— 它只做一件事：把「谁演谁 / 在哪 /
/// 你要办成什么 / 什么时候算完」写进**会话首句**，剩下的交给会话里的模型。
/// 所以"首句拼对没有"就是这一页的全部正确性：
///
/// * 少一段（比如漏掉结束条件）→ 模型会一直演下去、不给你结尾，用户看到的是
///   "AI 不肯停"，而这是**我们**的文案问题，不是模型的问题；
/// * 顺序错了（规则排在角色前面）→ 模型常会先"确认一下任务"从而出戏；
/// * 把中文骨架写死在 `buildRoleStartPrompt` 里 → 英文界面下模型收到的是
///   "英文卡片夹在中文壳里"（这条专门钉住，见下面的 `不再是写死的中文骨架`）。
///
/// 另外两个"看不见"的坑也在这里拦：
///
/// * **i18n 锚点漂移**：三张开局牌与共用规则的中文写在 `const` 数据表里，
///   `install/i18n/rewrite-tables.mjs` 看不见它们 —— 靠 `aiRoleI18nAnchors()`
///   里逐字复写一遍才收得到。改了卡片忘了改锚点，界面会在切语言时露出中文，
///   而 `check-tables.mjs` 依然是 0 漂移（它只比表，不比数据表）。
/// * **模板占位符**：首句骨架是**一条**可翻译模板，带 `{0}..{4}`。占位符少了
///   一个，某个部分就会被静默丢掉（译文照样"非空、无占位符错"）。
library;

import 'dart:io';

import 'package:dsh_mobile/ui/pages/ai_role_page.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假的"翻译 + 填占位符"：只做 `{n}` 替换，不查表 —— 这样断言的是**拼装**，
/// 与当前语言无关（真机上它接的是 `context.tr`）。
String _render(String template, List<Object?> args) {
  var out = template;
  for (var i = 0; i < args.length; i += 1) {
    out = out.replaceAll('{$i}', '${args[i]}');
  }
  return out;
}

/// 源码里的锚点片段（`aiRoleI18nAnchors() { ... }`）。
String _anchorRegion(String src) {
  final at = src.indexOf('void aiRoleI18nAnchors()');
  expect(at, greaterThan(0), reason: '找不到 aiRoleI18nAnchors()：锚点被改名或删掉了？');
  final open = src.indexOf('{', at);
  final close = src.indexOf('\n}', open);
  expect(close, greaterThan(open), reason: '锚点函数的括号没配对');
  return src.substring(open, close);
}

void main() {
  final fields = <String>[
    for (final c in AiRolePage.cards) ...<String>[c.name, c.teaser, c.role, c.scene, c.goal],
  ];

  group('开局牌本身', () {
    test('至少三张，名字不重复', () {
      expect(AiRolePage.cards.length, greaterThanOrEqualTo(3));
      final names = AiRolePage.cards.map((c) => c.name).toSet();
      expect(names.length, AiRolePage.cards.length, reason: '开局牌重名，用户分不清');
    });

    test('每一段的字都不为空（空白段会让首句出现空标题）', () {
      for (final c in AiRolePage.cards) {
        for (final s in <String>[c.name, c.teaser, c.role, c.scene, c.goal]) {
          expect(s.trim().isEmpty, isFalse, reason: '${c.name} 有一段是空的');
        }
      }
      expect(AiRolePage.rules.trim().isEmpty, isFalse);
    });

    test('每张牌都写清了"目标与结束条件"（不是只有角色和场景）', () {
      for (final c in AiRolePage.cards) {
        expect(c.goal.contains('对方的目标'), isTrue,
            reason: '${c.name} 没写目标：模型会一直演下去、不给结尾');
        expect(c.goal.contains('结束') || c.goal.contains('收尾'), isTrue,
            reason: '${c.name} 没写结束条件');
      }
    });

    test('规则里必须有一条"不要出戏"（这是"像角色"和"像助手"的分界）', () {
      expect(AiRolePage.rules.contains('不要出戏'), isTrue);
    });
  });

  group('首句拼装', () {
    test('五个部分都在，且顺序是「先立角色 → 再给约束 → 最后让模型开口」', () {
      final s = buildRoleStartPrompt(
        render: _render,
        name: 'NAME',
        role: 'ROLE',
        scene: 'SCENE',
        goal: 'GOAL',
        rules: 'RULES',
      );

      for (final part in <String>['NAME', 'ROLE', 'SCENE', 'GOAL', 'RULES']) {
        expect(s.contains(part), isTrue, reason: '首句里丢了 $part');
      }
      for (final m in <String>['【你演】', '【场景】', '【目标与结束条件】']) {
        expect(s.contains(m), isTrue, reason: '首句里丢了小标题 $m');
      }

      // 顺序：角色在场景之前，目标在规则之前，规则在"开口"那句之前。
      final order = <String>['NAME', 'ROLE', 'SCENE', 'GOAL', 'RULES'];
      var last = -1;
      for (final p in order) {
        final at = s.indexOf(p);
        expect(at, greaterThan(last), reason: '$p 的次序不对（首句顺序变了会让模型先"确认任务"）');
        last = at;
      }
      expect(s.trimRight().endsWith('现在开始：你先说第一句。'), isTrue,
          reason: '尾句必须是"你开口"的指令：不这样模型会先反问一句、直接出戏');
    });

    test('骨架恰好五个占位符，一个不多一个不少', () {
      final holders = RegExp(r'\{(\d+)\}')
          .allMatches(AiRolePage.promptTemplate)
          .map((m) => m.group(1))
          .toList();
      expect(holders, <String>['0', '1', '2', '3', '4'],
          reason: '占位符少了 → 某个部分会被静默丢掉；多了 → check-tables 会报占位符错');
    });

    test('骨架是"交给翻译"的那一条，而不是在函数里写死的中文', () {
      final src = File('lib/ui/pages/ai_role_page.dart').readAsStringSync();
      final body = src.substring(src.indexOf('String buildRoleStartPrompt('));
      expect(body.contains('我们来玩一局'), isFalse,
          reason: '骨架中文又写回函数里了：英文界面下会变成"英文卡片夹在中文壳里"');
      expect(body.contains('现在开始'), isFalse, reason: '同上');
      expect(body.contains('AiRolePage.promptTemplate'), isTrue,
          reason: '拼装必须走 promptTemplate 这条可翻译的模板');
    });

    test('render 拿到的是模板和五个参数（不是已经拼好的一整句）', () {
      String? gotTemplate;
      List<Object?>? gotArgs;
      buildRoleStartPrompt(
        render: (t, a) {
          gotTemplate = t;
          gotArgs = a;
          return '';
        },
        name: 'N',
        role: 'R',
        scene: 'S',
        goal: 'G',
        rules: 'X',
      );
      expect(gotTemplate, AiRolePage.promptTemplate);
      expect(gotArgs, <Object?>['N', 'R', 'S', 'G', 'X']);
    });
  });

  group('i18n 锚点与数据表同步', () {
    late String src;
    late String anchors;

    setUpAll(() {
      src = File('lib/ui/pages/ai_role_page.dart').readAsStringSync();
      anchors = _anchorRegion(src);
    });

    test('三张牌的每一段、共用规则、首句骨架，都在锚点里逐字出现', () {
      for (final f in fields) {
        expect(anchors.contains(f), isTrue,
            reason: '「$f」不在 aiRoleI18nAnchors() 里：切到英文会露出中文，'
                '而 check-tables 仍然报 0 漂移');
      }
      expect(anchors.contains(AiRolePage.rules), isTrue, reason: '共用规则没进锚点');
      // 骨架在源码里是**带 `\n` 转义的单行字面量**，运行时才是真换行 —— 两边对比
      // 前要先换成源码形态。
      final escaped = AiRolePage.promptTemplate.replaceAll('\n', r'\n');
      expect(anchors.contains(escaped), isTrue,
          reason: '首句骨架没进锚点（它是带 {0}..{4} 的模板，必须逐字一致）');
    });

    test('锚点里就这 17 条，没有多出来的（多写的会成为陈旧键）', () {
      final calls = RegExp(r'\btr\(').allMatches(anchors).length;
      expect(calls, fields.length + 2,
          reason: '锚点里应是 ${fields.length} 段牌面 + 规则 + 模板 = ${fields.length + 2} 条；'
              '多出来说明有牌被删了但锚点没跟着删');
    });
  });
}
