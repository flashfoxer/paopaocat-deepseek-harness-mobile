import 'dart:io';

import 'package:dsh_mobile/state/usage_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late String path;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dsh-usage-');
    path = '${tmp.path}/usage.json';
  });
  tearDown(() => tmp.existsSync() ? tmp.deleteSync(recursive: true) : null);

  test('记一轮 → 落盘 → 换实例读回来（跨重启不丢）', () async {
    final a = UsageStore(path: path);
    await a.add(route: 'local/qwen2.5-1.5b', charsIn: 12, charsOut: 340);
    await a.add(route: 'local/qwen2.5-1.5b', charsIn: 8, charsOut: 100);

    final b = UsageStore(path: path);
    await b.load();
    final rec = b.of('local/qwen2.5-1.5b')!;
    expect(rec.requests, 2);
    expect(rec.charsIn, 20);
    expect(rec.charsOut, 440);
    expect(rec.totalChars, 460);
    expect(rec.lastAt, isNotNull);
  });

  test('不同模型分开记（按 route）', () async {
    final s = UsageStore(path: path);
    await s.add(route: 'agnes/a', charsIn: 1, charsOut: 2);
    await s.add(route: 'local/b', charsIn: 10, charsOut: 20);
    expect(s.of('agnes/a')!.requests, 1);
    expect(s.of('local/b')!.requests, 1);
    expect(s.of('local/b')!.totalChars, 30);
  });

  test('route 为空 → 整轮丢弃（不往假 key 上记）', () async {
    final s = UsageStore(path: path);
    await s.add(route: null, charsIn: 5, charsOut: 5);
    await s.add(route: '', charsIn: 5, charsOut: 5);
    expect(s.all, isEmpty);
    expect(File(path).existsSync(), isFalse, reason: '没记东西就不该写文件');
  });

  test('文件坏了当空表，不抛', () async {
    File(path).writeAsStringSync('{ 不是 JSON');
    final s = UsageStore(path: path);
    await s.load();
    expect(s.all, isEmpty);
    // 坏了之后照样能记新的。
    await s.add(route: 'x/y', charsIn: 1, charsOut: 1);
    expect(s.of('x/y')!.requests, 1);
  });

  test('字符数折短串', () {
    expect(UsageStore.shortChars(999), '999');
    expect(UsageStore.shortChars(12345), '1.2 万');
  });
}
