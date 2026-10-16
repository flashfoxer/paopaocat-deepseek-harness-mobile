/// 「**带 free 的排前面**」这条排序规则的单元测试。
///
/// 用户 2026-10-16 原话：「所有模型全部可以获取，而且**带 free 字样的放到前边**」。
///
/// 为什么单独测：这条规则要在三处保持一致（获取模型的列表 / 会话的模型选择器 /
/// 保存进 models.json 的顺序），一旦哪处漏了就会出现"同一个列表两种顺序"，
/// 而那种不一致**不会报错**，只会让人觉得"刚才明明在前面"。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/data/model_order.dart';

void main() {
  test('免 Key 通道里的模型一律算免费（哪怕名字里没有 free）', () {
    // 真实例子：zen 的 big-pickle —— 它确实在"只列免费模型"的 /v1/models 里，
    // 但名字里一个 free 都没有。2026-10-16 实测时报的漏洞。
    expect(looksFreeModel('zen/big-pickle'), isTrue);
    expect(looksFreeModel('polli/openai-fast'), isTrue);
    // 用户自己配的厂家不享受这条（免得把收费模型当成免费）
    expect(looksFreeModel('deepseek/deepseek-chat'), isFalse);
    expect(looksFreeModel('agnes/agnes-2.0-flash'), isFalse);
  });

  test('free 判定：id 或 name 任一处带 free 都算（不分大小写）', () {
    expect(looksFreeModel('zen/mimo-v2.6-flash-free'), isTrue);
    expect(looksFreeModel('zen/x', 'MiMo Free'), isTrue);
    expect(looksFreeModel('zen/x', '免费（free）'), isTrue);
    expect(looksFreeModel('X-FREE'), isTrue);
    expect(looksFreeModel('x', 'FREE tier'), isTrue);
    // 不带 free 的不能被误判（⚠️ 注意别拿 zen/polli 举例：它们**免 Key 通道**，
    // 里面的模型一律算免费 —— 那一条由上面那个用例单独覆盖）
    expect(looksFreeModel('deepseek/deepseek-chat'), isFalse);
    expect(looksFreeModel('agnes/agnes-2.0-flash'), isFalse);
    expect(looksFreeModel('mimo/mimo-7b-rl'), isFalse);
  });

  test('排序：带 free 的全排前面，同类里按 id 字典序', () {
    final sorted = sortModelsFreeFirst(
      <String>[
        'deepseek/mimo-v2.5-free',
        'deepseek/deepseek-chat',
        'agnes/zzz',
        'agnes/aaa',
      ],
      idOf: (s) => s,
    );
    expect(sorted.first, 'deepseek/mimo-v2.5-free');
    expect(sorted.sublist(1),
        <String>['agnes/aaa', 'agnes/zzz', 'deepseek/deepseek-chat']);
  });

  test('排序：只有 name 里带 free 也生效（id 看不出来的那种）', () {
    final sorted = sortModelsFreeFirst(
      <String>['a-model', 'b-model'],
      idOf: (s) => s,
      nameOf: (s) => s == 'b-model' ? 'B（Free）' : 'A',
    );
    expect(sorted, <String>['b-model', 'a-model']);
  });

  test('不改原列表（返回新列表，调用方传进去的顺序不被就地改掉）', () {
    final src = <String>['b', 'a-free'];
    final out = sortModelsFreeFirst(src, idOf: (s) => s);
    expect(src, <String>['b', 'a-free'], reason: '原列表被就地改了');
    expect(out, <String>['a-free', 'b']);
  });
}
