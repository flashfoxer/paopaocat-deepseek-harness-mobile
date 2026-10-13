import 'package:flutter/foundation.dart';

import '../data/workspace_store.dart';
import 'acp_client.dart';
import 'dsh_runtime.dart';

/// 读磁盘上的会话索引（= ACP `session/list`）。
///
/// 为什么必须为它单开一个 ACP 连接：
///   * `session/list` 是 **ACP 连接级**的能力 —— 只有活着的
///     `dsh --profile acp` 子进程才能回答；
///   * DSH 把会话存成 `<DSH_HOME>/sessions/<cwd 编码>/<id>/session.v4.jsonl.zstd`，
///     而那是 **zstd 多帧**压缩文件，Dart 侧没有 zstd 解码器（`dart:io` 不提供），
///     界面层读不了它。
///
/// 这个连接**只用来列会话**：列完立刻关掉，不在界面期间常驻第二个 node 进程。
/// 代价是一次 node 启动（秒级），所以上层（[WorkspaceStore.refreshIndex]）会
/// 把结果缓存住，并且只在用户主动刷新/首次打开工作区页时才跑。
///
/// 失败**不吞**：异常向上抛，界面如实显示"会话索引读取失败：<原因>"。
Future<List<DshSession>> listPersistedSessions(
    {required DshRuntime runtime}) async {
  debugPrint('[ws-index] 开一次性 ACP 连接读 session/list…');
  final acp = await AcpClient.start(
    runtime: runtime,
    // cwd 用 filesDir：这次连接自己不开会话，只要一个合法目录即可。
    workspace: runtime.filesDir,
    overlayPath: runtime.hasModelConfig ? runtime.overlayPath : null,
    onLog: (m) => debugPrint('[ws-index]$m'),
  );

  try {
    final rows = await acp.listSessions();
    debugPrint('[ws-index] session/list 返回 ${rows.length} 条');
    return [
      for (final r in rows)
        DshSession(id: r.sessionId, cwd: r.cwd, createdAt: r.createdAt),
    ];
  } finally {
    // 无论成功失败都要把进程收掉：真机上多一个常驻 node 就是多一份内存。
    await acp.close();
  }
}
