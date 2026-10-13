/// `DshRichText` 的测试（审计 P1-6：更新说明里的 `**` 在界面上是裸星号）。
///
/// 为什么值得一条测试：这类问题**渲染出来才看得见** —— 编译通过、测试也不疼，
/// 但用户在更新说明页看到的是满屏 `**为什么以前没暴露**`。
/// 50 条记录里 45 条中招，1082 处标记，靠肉眼是看不完的。
library;

import 'package:dsh_mobile/ui/theme/dsh_tokens.dart';
import 'package:dsh_mobile/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => DshColors.applySkin(DshPalettes.dark));

  Future<void> pump(WidgetTester tester, String text) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: DshRichText(text)),
    ));
  }

  /// 取出渲染后的 Text.rich 里的所有 span。
  List<TextSpan> spansOf(WidgetTester tester) {
    final t = tester.widget<Text>(find.byType(Text));
    final root = t.textSpan! as TextSpan;
    return <TextSpan>[
      for (final c in (root.children ?? const <InlineSpan>[]))
        if (c is TextSpan) c,
    ];
  }

  String plainOf(List<TextSpan> spans) => spans.map((s) => s.text ?? '').join();

  testWidgets('**粗体** 变成加粗，星号本身不再出现在文字里', (tester) async {
    await pump(tester, '**为什么以前没暴露**：旧路径走的是真服务器');
    final spans = spansOf(tester);
    expect(plainOf(spans), '为什么以前没暴露：旧路径走的是真服务器',
        reason: '星号必须被吃掉，否则用户看到的就是裸星号');
    final bold = spans.firstWhere((s) => s.text == '为什么以前没暴露');
    expect(bold.style?.fontWeight, FontWeight.w700);
  });

  testWidgets('`代码` 变成等宽样式，反引号不再出现', (tester) async {
    await pump(tester, '执行 `adb devices` 看设备');
    final spans = spansOf(tester);
    expect(plainOf(spans), '执行 adb devices 看设备');
    final code = spans.firstWhere((s) => s.text == 'adb devices');
    expect(code.style?.fontFamily, isNotNull, reason: '应该用等宽字体族');
  });

  testWidgets('没有标记时原样显示（不吞字符、不加样式）', (tester) async {
    await pump(tester, '普通一句话，没有任何标记。');
    final spans = spansOf(tester);
    expect(plainOf(spans), '普通一句话，没有任何标记。');
    expect(spans.length, 1);
    expect(spans.first.style?.fontWeight, isNull);
  });

  testWidgets('⚠️ 未配对的标记原样显示 —— 宁可看到星号也不要吃掉用户的字', (tester) async {
    await pump(tester, '这里有单个 ** 星号，还有单个 ` 反引号，都不成对');
    final spans = spansOf(tester);
    expect(plainOf(spans), '这里有单个 ** 星号，还有单个 ` 反引号，都不成对');
  });

  testWidgets('一行里多个标记都生效，且顺序不乱', (tester) async {
    await pump(tester, 'A**B**C`D`E**F**');
    final spans = spansOf(tester);
    expect(plainOf(spans), 'ABCDEF');
    expect(
      spans.map((s) => s.text).toList(),
      <String>['A', 'B', 'C', 'D', 'E', 'F'],
    );
  });

  testWidgets('真的拿一条更新说明的原文试（含真实的多处标记）', (tester) async {
    await pump(tester,
        '**清单收敛**：只保留 Gemma 4 的 `.litertlm`。**llama.cpp 的 GGUF 全部下线**'
        '（Qwen2.5-1.5B / Qwen3-1.7B）。');
    final spans = spansOf(tester);
    expect(plainOf(spans), contains('清单收敛'));
    expect(plainOf(spans), contains('llama.cpp 的 GGUF 全部下线'));
    expect(plainOf(spans), isNot(contains('**')));
    expect(plainOf(spans), isNot(contains('`')));
  });

  testWidgets('⚠️ `***已脱敏***` 这种"星号本身就是内容"的写法必须原样保留', (tester) async {
    // 真实文案（send_log_button）：脱敏占位符就是三个星号的字面量。
    // 第一版正则会把中间那段当粗体、留一个漏出来的星号 —— 那就是错字。
    await pump(tester, 'API Key 已自动脱敏（会变成 ***已脱敏***），**不会**包含你的 Key。');
    final spans = spansOf(tester);
    final plain = plainOf(spans);
    expect(plain, contains('***已脱敏***'), reason: '这六个星号是内容，不是标记');
    expect(plain, isNot(contains('**不会**')), reason: '同一条里的真标记仍要生效');
    final bold = spans.firstWhere((s) => s.text == '不会');
    expect(bold.style?.fontWeight, FontWeight.w700);
  });
}
