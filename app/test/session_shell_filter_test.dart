// 会话丢失修复单 · 缺陷 A（0 消息空壳）
//
// 用户的现象是「点开历史会话，里面是空的，以为对话被删了」。实测（设备 v0.74，
// 见 `docs/CHANGES-2026-10-14.md`）：48 条会话里 17 条从头到尾只有头部记录、
// 磁盘上一条都没被删。根因两条：
//
//   * **A1** 打开聊天页就先 `session/new`（已在 chat_page 里改成"第一条消息才建"）；
//   * **A2** 那些已经落盘的空壳还留在列表里 —— 这一条要**列出来之前**判掉。
//
// 这个测试钉住 A2 的判据本身，因为它的两个数据源都很容易想当然：
//   * 投影缓存（明文 JSON，Dart 能读）说"没聊过"；
//   * 转录文件大小（多帧 zstd，Dart 解不了，但 stat 得到）。
//
// 判错的代价不对称，所以测试里两条都覆盖：
//   * **把有内容的会话藏起来** = 用户真的丢东西（绝不允许）；
//   * 多列一条空壳 = 只是列表难看（可接受）。
// 因此凡"读不到 / 不确定"一律 **unknown → 照常显示**。

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/data/workspace_store.dart';
import 'package:dsh_mobile/local/session_projcache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late String home;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dsh-shell-');
    home = '${tmp.path}/dshhome';
    Directory('$home/storages/session_projcache/sessions')
        .createSync(recursive: true);
    Directory('$home/sessions/--data-workspace--').createSync(recursive: true);
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 写一份投影缓存。字段形状照设备实测：`record.rows.<row>.val.count|lastTurn`。
  void writeProjcache(String id, {int? titleCount, int? lastTurn, String? raw}) {
    final f = File('$home/storages/session_projcache/sessions/$id.json');
    if (raw != null) {
      f.writeAsStringSync(raw);
      return;
    }
    f.writeAsStringSync(jsonEncode({
      'record': {
        'rows': {
          if (titleCount != null) 'titleInput': {'val': {'count': titleCount}},
          if (lastTurn != null) 'turnBoundary': {'val': {'lastTurn': lastTurn}},
        }
      }
    }));
  }

  /// 写一个转录文件（内容无所谓，只看大小 —— Dart 解不了多帧 zstd）。
  void writeTranscript(String id, int bytes) {
    File('$home/sessions/--data-workspace--/$id/session.v4.jsonl.zstd')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List<int>.filled(bytes, 0));
  }

  group('空壳判据（缺陷 A2）', () {
    test('缓存说没聊过 + 转录只有几百字节 → 判空（这就是设备上那 17 条）', () {
      writeProjcache('shell-1', titleCount: 0, lastTurn: 0);
      writeTranscript('shell-1', 329);
      expect(
        sessionContentState(
          dshHome: home,
          sessionId: 'shell-1',
          transcriptBytes: scanTranscriptSizes(home),
        ),
        SessionContentState.empty,
      );
    });

    test('缓存说没聊过，但转录明显不小 → 判有内容（缓存滞后时不许藏真对话）', () {
      writeProjcache('real-1', titleCount: 0, lastTurn: 0);
      writeTranscript('real-1', kShellTranscriptMaxBytes + 1);
      expect(
        sessionContentState(
          dshHome: home,
          sessionId: 'real-1',
          transcriptBytes: scanTranscriptSizes(home),
        ),
        SessionContentState.hasMessages,
      );
    });

    test('缓存说聊过 → 直接判有内容', () {
      writeProjcache('real-2', titleCount: 1, lastTurn: 3);
      writeTranscript('real-2', 200);
      expect(
        sessionContentState(
          dshHome: home,
          sessionId: 'real-2',
          transcriptBytes: scanTranscriptSizes(home),
        ),
        SessionContentState.hasMessages,
      );
    });

    test('没有投影缓存 → unknown（读不到就不许当成空）', () {
      writeTranscript('nope-1', 100);
      expect(
        sessionContentState(
          dshHome: home,
          sessionId: 'nope-1',
          transcriptBytes: scanTranscriptSizes(home),
        ),
        SessionContentState.unknown,
      );
    });

    test('缓存说空、但转录文件找不到 → unknown（不敢下结论）', () {
      writeProjcache('nope-2', titleCount: 0, lastTurn: 0);
      expect(
        sessionContentState(
          dshHome: home,
          sessionId: 'nope-2',
          transcriptBytes: scanTranscriptSizes(home),
        ),
        SessionContentState.unknown,
      );
    });

    test('缓存是坏 JSON → unknown', () {
      writeProjcache('bad-1', raw: '{不是 JSON');
      writeTranscript('bad-1', 10);
      expect(
        sessionContentState(
          dshHome: home,
          sessionId: 'bad-1',
          transcriptBytes: scanTranscriptSizes(home),
        ),
        SessionContentState.unknown,
      );
    });

    test('没给转录大小时，缓存说空也只能算 unknown（少一路佐证就不动手）', () {
      writeProjcache('shell-2', titleCount: 0, lastTurn: 0);
      expect(
        sessionContentState(dshHome: home, sessionId: 'shell-2'),
        SessionContentState.unknown,
      );
    });

    test('扫描能跨多个 cwd 目录找到每条的转录大小', () {
      writeTranscript('a', 111);
      Directory('$home/sessions/--another--/b').createSync(recursive: true);
      File('$home/sessions/--another--/b/session.v4.jsonl.zstd')
          .writeAsBytesSync(List<int>.filled(222, 0));
      final sizes = scanTranscriptSizes(home);
      expect(sizes['a'], 111);
      expect(sizes['b'], 222);
    });
  });

  group('列表不再出现空壳（缺陷 A2 的界面侧）', () {
    test('sessionsOf 跳过空壳，但磁盘总数与"隐藏了几条"都要如实报出', () async {
      final store = WorkspaceStore(tmp.path);
      await store.refreshIndex(() async => <DshSession>[
            DshSession(
                id: 'aaaaaaaa-1',
                cwd: '${tmp.path}/workspace',
                createdAt: DateTime(2026, 10, 1)),
            DshSession(
                id: 'bbbbbbbb-2',
                cwd: '${tmp.path}/workspace',
                createdAt: DateTime(2026, 10, 2),
                emptyShell: true),
            DshSession(
                id: 'cccccccc-3',
                cwd: '${tmp.path}/workspace',
                createdAt: DateTime(2026, 10, 3),
                emptyShell: true),
          ]);

      final list = store.sessionsOf('${tmp.path}/workspace');
      expect(list.map((s) => s.id), ['aaaaaaaa-1'],
          reason: '空壳不该出现在列表里（点开全空 = 用户以为丢了）');
      expect(store.totalDiskSessions, 3, reason: '磁盘上确实有 3 条，别谎报');
      expect(store.hiddenEmptySessions, 2,
          reason: '界面要说出"其中 2 条是空会话" —— 否则用户数一遍还是以为在丢');
    });

    test('本次运行的会话（live）不会被空壳判据挡住', () async {
      final store = WorkspaceStore(tmp.path);
      // 真实 ACP sessionId 是 UUID（36 字符）；这里用够长的假 id
      // （`noteSession` 会取前 8 位做日志前缀，太短的 id 它自己会炸）。
      const liveId = 'dddddddd-1111-2222-3333-444444444444';
      store.noteSession(
          id: liveId, cwd: '${tmp.path}/workspace', title: '你好');
      final list = store.sessionsOf('${tmp.path}/workspace');
      expect(list.map((s) => s.id), [liveId],
          reason: 'live 会话有真实标题，不该被空壳判据挡住');
      expect(list.single.emptyShell, isFalse);
    });
  });
}
