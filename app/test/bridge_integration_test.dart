/// 端到端集成测试：App 的协议层（BridgeClient + models）真连一个运行中的桥。
///
/// 前置：桥已在 127.0.0.1:8788 运行（`node bridge/src/bridge.mjs serve`）。
/// 运行：flutter test test/bridge_integration_test.dart
///
/// 这是"App 能不能用"的最强证据——它复用与 UI 完全相同的协议代码，
/// 覆盖配对 → 握手 → 建会话 → 订阅 → 发消息 → 收 update → 状态 → 关闭。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/protocol/bridge_client.dart';
import 'package:dsh_mobile/protocol/models.dart';
import 'package:flutter_test/flutter_test.dart';

const String kHost = '127.0.0.1';
const int kPort = 8788;

Future<Map<String, dynamic>> _adminGet(String path) async {
  final http = HttpClient();
  try {
    final request = await http.getUrl(Uri.parse('http://$kHost:$kPort$path'));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw StateError('管理端点 $path 返回 ${response.statusCode}');
    }
    return jsonDecode(body) as Map<String, dynamic>;
  } finally {
    http.close(force: true);
  }
}

void main() {
  test(
    '端到端：配对 → 握手 → 建会话 → 发消息 → 收 update → 关闭',
    () async {
      // ---- 0. 桥可达性 ----
      // 桥没在跑时**显式 skip**（原来是直接 fail）：迁移到 Linux 后本机没有常驻桥，
      // 每次 `flutter test` 都会稳定报一条假失败，把真正的回归淹掉。
      // 要真跑这条用例：另开终端执行 `node bridge/src/bridge.mjs serve`。
      final Map<String, dynamic> health;
      try {
        health = await _adminGet('/health');
      } on SocketException catch (e) {
        markTestSkipped(
          '桥未运行在 $kHost:$kPort（${e.message}）—— 先启动：node bridge/src/bridge.mjs serve',
        );
        return;
      }
      expect(health['ok'], isTrue);
      expect(health['dsh'], 'running', reason: 'DSH 子进程必须处于 running 状态');

      // ---- 1. 取一次性配对码 ----
      final pairInfo = await _adminGet('/pair');
      final code = pairInfo['code'] as String;
      expect(code, hasLength(6));

      // ---- 2. 连接并配对 ----
      final logs = <String>[];
      final bridge = BridgeClient(host: kHost, port: kPort, onLog: logs.add);
      await bridge.connect();
      expect(bridge.isConnected, isTrue);

      final paired = await bridge.pair(code, 'flutter-integration-test');
      expect(paired['type'], 'pair_ok', reason: '配对应成功：$paired');
      final token = paired['deviceToken'] as String;
      expect(token, isNotEmpty);

      // ---- 3. 握手 ----
      final hello = await bridge.hello(token, '0.1.0-test');
      expect(hello['type'], 'hello_ok', reason: '握手应成功：$hello');
      final hostInfo = HostInfo.fromJson(hello['host'] as Map<String, dynamic>);
      expect(hostInfo.permissionMode, isNotEmpty);
      expect(hostInfo.cwd, isNotEmpty);

      // ---- 4. 新建会话 ----
      final created =
          await bridge.request('new_session', {'cwd': hostInfo.cwd});
      expect(created['type'], 'session', reason: '新建会话应成功：$created');
      final session =
          SessionInfo.fromJson(created['session'] as Map<String, dynamic>);
      expect(session.id, startsWith('s_'));

      // ---- 5. 订阅（先挂监听再订阅，避免漏掉事件）----
      final updates = <SequencedUpdate>[];
      final permissionRequests = <PermissionRequest>[];
      final idle = Completer<void>();
      final running = Completer<void>();

      final sub = bridge.frames.listen((msg) {
        switch (msg['type']) {
          case 'update':
            final update =
                BridgeUpdate.fromJson(msg['update'] as Map<String, dynamic>);
            updates.add(SequencedUpdate(
              sessionId: msg['sessionId'] as String,
              seq: msg['seq'] as int,
              update: update,
            ));
            break;
          case 'permission_request':
            permissionRequests.add(PermissionRequest.fromJson(msg));
            break;
          case 'session_status':
            final state = msg['state'] as String?;
            if (state == 'running' && !running.isCompleted) running.complete();
            if (state == 'idle' && !idle.isCompleted) idle.complete();
            break;
        }
      });

      final subscribed = await bridge
          .request('subscribe', {'sessionId': session.id, 'fromSeq': 0});
      expect(subscribed['type'], 'subscribed');
      expect(subscribed['needSnapshot'], isFalse);

      // ---- 6. 发一条消息 ----
      final accepted = await bridge.request('prompt', {
        'sessionId': session.id,
        'text': '只回答两个字：收到',
        'clientMsgId': 'integration-1',
      });
      expect(accepted['type'], 'accepted', reason: '入队应被接受：$accepted');
      expect(accepted['queued'], isTrue);

      // ---- 7. 等轮次真正结束 ----
      await running.future.timeout(const Duration(minutes: 2));
      await idle.future.timeout(const Duration(minutes: 3));

      // ---- 8. 断言收到的更新 ----
      final messages =
          updates.where((u) => u.update.kind == 'message').toList();
      expect(messages, isNotEmpty,
          reason:
              '必须收到 kind=message 的 update，实际收到：${updates.map((u) => u.update.kind).toList()}');
      expect(messages.single.update.text, contains('收到'));

      // seq 必须严格递增且无重复
      final seqs = updates.map((u) => u.seq).toList();
      for (var i = 1; i < seqs.length; i++) {
        expect(seqs[i], greaterThan(seqs[i - 1]), reason: 'seq 必须严格递增：$seqs');
      }

      // ---- 9. 关闭会话（销毁；与 unsubscribe 语义不同）----
      final closed =
          await bridge.request('close_session', {'sessionId': session.id});
      expect(closed['type'], 'closed');
      expect(closed['sessionId'], session.id);

      await sub.cancel();
      await bridge.disconnect();

      // 日志里不应出现协议层异常
      expect(logs.where((l) => l.contains('无法解析')).isEmpty, isTrue,
          reason: '不应出现无法解析的帧：$logs');
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
