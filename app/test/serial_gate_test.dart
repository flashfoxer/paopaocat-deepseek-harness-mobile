import 'package:dsh_mobile/local/serial_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('并发调用被排成队列：同一时刻只跑一个', () async {
    final gate = SerialGate();
    var running = 0;
    var maxRunning = 0;
    final order = <int>[];

    Future<void> job(int i) => gate.run(() async {
          running++;
          maxRunning = maxRunning < running ? running : maxRunning;
          order.add(i);
          // 任务里必须有 await，否则测不出"并发"这件事。
          await Future<void>.delayed(const Duration(milliseconds: 10));
          running--;
        });

    await Future.wait(<Future<void>>[for (var i = 0; i < 5; i++) job(i)]);

    expect(maxRunning, 1, reason: '任何时刻都只能有一个任务在跑');
    expect(order.length, 5, reason: '5 个任务一个都不能丢');
    expect(order, <int>[0, 1, 2, 3, 4], reason: '按调用顺序执行（FIFO）');
  });

  test('前面的任务抛错，不影响后面的排队', () async {
    final gate = SerialGate();
    final done = <String>[];

    final bad = gate.run<void>(() async => throw StateError('炸了'));
    final good = gate.run<void>(() async => done.add('ok'));

    await expectLater(bad, throwsA(isA<StateError>()));
    await good;
    expect(done, <String>['ok'], reason: '队列不能因为一个失败就卡死');
  });

  test('返回值能正常透传', () async {
    final gate = SerialGate();
    expect(await gate.run<int>(() async => 42), 42);
  });
}
