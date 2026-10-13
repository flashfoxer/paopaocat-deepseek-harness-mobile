/// 会话注册表的行为测试 —— 用户意见①「多会话并发 / 切页不打断回答」的底层保证。
///
/// 最要紧的一条断言是：**页面 detach 时进程必须还活着**。
/// 原先 `ChatPage.dispose()` 里直接 `_acp?.close()`，而点底部别的 Tab 就会
/// pop 掉会话页 —— 正在生成的回答被当场打断。修好之后，只有**显式关闭**
/// 才允许收尸。
///
/// 这里用真实进程（`sleep`）而不是 mock：`AcpClient` 需要 dart:io 的 `Process`，
/// 而 `sleep` 不读 stdin，所以"进程是否还在"能干净地当作"有没有被误杀"的判据。
library;

import 'dart:async';
import 'dart:io';

import 'package:dsh_mobile/data/artifacts.dart';
import 'package:dsh_mobile/local/acp_client.dart';
import 'package:dsh_mobile/state/session_registry.dart';
import 'package:dsh_mobile/ui/widgets/message_stream.dart'
    show ChatMsg, ChatRole;
import 'package:flutter_test/flutter_test.dart';

Future<AcpClient> _fakeAcp() async {
  final p = await Process.start('sleep', <String>['60']);
  return AcpClient(process: p);
}

/// 进程还活着吗？
///
/// 注意 `Process.exitCode` 是 `Future<int>`（不是同步字段）：它要么在进程结束时
/// 完成，要么永远不完成 —— 所以"在超时前拿到退出码"才是"已经死了"的判据。
Future<bool> _alive(AcpClient acp, {int ms = 200}) async {
  try {
    await acp.process.exitCode.timeout(Duration(milliseconds: ms));
    return false;
  } on TimeoutException {
    return true;
  }
}

void main() {
  test('detach 不杀进程 —— 切页不打断回答的根本保证', () async {
    final acp = await _fakeAcp();
    final live = LiveSession(key: 'k1', acp: acp, workspace: '/tmp');
    live.attach(onNotification: (_) {}, onPermission: (_) {});
    expect(live.attached, isTrue, reason: 'attach 之后页面算挂上了');

    live.detach();
    expect(live.attached, isFalse);
    expect(
      await _alive(acp),
      isTrue,
      reason: '人走了（切到别的页面）**不该**杀进程，否则正在跑的回答就断了',
    );

    await live.close();
    expect(
      await _alive(acp, ms: 900),
      isFalse,
      reason: '只有显式关闭才允许收尸',
    );
  });

  test('注册表：同工作区同会话可复用，别的不复用', () async {
    final reg = SessionRegistry();
    final acp = await _fakeAcp();
    final live = LiveSession(key: 'k', acp: acp, workspace: '/ws');
    live.sessionId = 'sess-1';
    reg.register(live);

    expect(reg.all.length, 1);
    expect(reg.byKey('k'), same(live));
    // 命中 → 页面重进时复用它，绝不新起进程
    expect(reg.findReusable(workspace: '/ws', resumeId: 'sess-1'), same(live));
    // 别的会话 id / 别的工作区 → 不复用（该新建就新建）
    expect(reg.findReusable(workspace: '/ws', resumeId: 'sess-2'), isNull);
    expect(reg.findReusable(workspace: '/other', resumeId: 'sess-1'), isNull);

    await reg.closeAll();
    expect(reg.all, isEmpty);
    expect(await _alive(acp, ms: 900), isFalse);
  });

  test('runningOnes 只报正在跑的那些（首页据此显示"正在回答"）', () async {
    final reg = SessionRegistry();
    final a = await _fakeAcp();
    final b = await _fakeAcp();
    final la = LiveSession(key: 'a', acp: a, workspace: '/ws')..running = true;
    final lb = LiveSession(key: 'b', acp: b, workspace: '/ws');
    reg.register(la);
    reg.register(lb);

    expect(reg.runningOnes.map((s) => s.key).toList(), <String>['a']);

    await reg.closeAll();
  });

  test('消息与产物挂在句柄上 —— 页面重建也拿得到同一份', () async {
    final acp = await _fakeAcp();
    final live = LiveSession(key: 'k', acp: acp, workspace: '/ws');

    // 模拟"页面在时产生的内容"
    live.messages.add(ChatMsg(text: '你好', role: ChatRole.user));
    live.artifacts.add(const Artifact(name: 'x', extension: 'md'));
    live.artifactKeys.add('k');

    // 页面重建：新页面拿到的是**同一个**列表对象，内容还在
    expect(live.messages.length, 1);
    expect(live.messages.first.text, '你好');
    expect(live.artifacts.length, 1);
    expect(live.artifactKeys, contains('k'));

    await live.close();
  });
}
