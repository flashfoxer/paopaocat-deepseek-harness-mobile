import 'package:dsh_mobile/local/rotate_log.dart';
import 'package:flutter_test/flutter_test.dart';

/// 这份解析很容易写错，而写错的表现是**会话里显示一个错的成员名** —— 比不显示更糟。
void main() {
  test('换了成员：取最后一条"第 N 个成员顶上"', () {
    final r = RotateLog.parseLastUsed('''
2026-10-07T00:01:00Z → cat: model="x" stream=true 起始成员=gpt-5
2026-10-07T00:01:02Z cat: gpt-5 失败(上游 429)，改用 claude-sonnet
2026-10-07T00:01:03Z cat: claude-sonnet 成功（第 2 个成员顶上）
''');
    expect(r, isNotNull);
    expect(r!.pool, 'cat');
    expect(r.member, 'claude-sonnet');
  });

  test('没换过成员：退回"起始成员="', () {
    final r = RotateLog.parseLastUsed('''
→ cat: model="x" stream=false 起始成员=qwen3-32b
''');
    expect(r!.member, 'qwen3-32b');
  });

  test('verbose 模式下的普通成功行也能认', () {
    final r = RotateLog.parseLastUsed('''
→ fast: model="y" stream=true 起始成员=a-fast
fast: a-fast 成功
''');
    expect(r!.pool, 'fast');
    expect(r.member, 'a-fast');
  });

  test('"顶上"优先于起始成员（两种都在时不能取错）', () {
    final r = RotateLog.parseLastUsed('''
→ cat: 起始成员=first
cat: second 成功（第 2 个成员顶上）
''');
    expect(r!.member, 'second');
  });

  test('空日志 / 认不出来 → null（界面就不显示，不猜）', () {
    expect(RotateLog.parseLastUsed(''), isNull);
    expect(RotateLog.parseLastUsed('一些无关的日志\n随便写写'), isNull);
  });

  test('文件不存在 → null，不抛', () async {
    final r = await const RotateLog(path: '/tmp/definitely-not-here-9f3a.log')
        .lastUsed();
    expect(r, isNull);
  });
}
