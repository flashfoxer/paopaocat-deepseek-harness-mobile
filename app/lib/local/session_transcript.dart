import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'dsh_runtime.dart';
import 'session_failure_store.dart';

/// 读取一条已持久化会话的**历史对话**，用于在界面上回放。
///
/// ## 为什么必须自己读文件
///
/// 实测（读 DSH 源码 `@deepseek-ai/dsh-acp/lib/index.js`）：
/// **ACP 的 `session/resume` 只返回 `{ configOptions }`，不返回任何历史消息**
/// （第 1208-1251 行）。所以"恢复会话时把历史显示出来"这件事，
/// 协议层给不了，只能自己读会话记录文件。
///
/// ## 为什么用 node 而不是 Dart
///
/// 会话记录是**多帧 zstd**（`session.v4.jsonl.zstd`，实测一个文件 820 帧）。
/// Dart 侧没有 zstd 解码器，而运行时里**自带 node**（`DshRuntime.runOnce` 已经能用），
/// 所以把解码交给 node，Dart 只解析它打印的 JSON。
///
/// ## 记录的真实结构（不要凭猜测改）
///
/// 逐个 JSON 行，每行 `{"type": "...", ...}`：
///   * `session`          → `createdAt`（**epoch 毫秒**）、`cwd`
///   * `session/title`    → `data.title`（**DSH 生成的真实标题**）
///   * `user/message`     → `data.content[]`：`{type:'text',text}` / `{type:'file',attachment:{name}}`
///   * `assistant/message`→ `data.message.content[]`：`{type:'text'|'reasoning',text}`
///     （`reasoning` 是思维链，**不回放**，只取 `text`）
///
/// 已用真实会话文件（2.1MB / 1511 条记录）验证过这套取值。
class SessionTranscript {
  const SessionTranscript({
    this.title,
    this.createdAt,
    this.messages = const <SessionTranscriptMessage>[],
    this.total = 0,
    this.capped = 0,
  });

  /// DSH 生成的会话标题（`session/title`），取不到为 null
  final String? title;

  /// 会话创建时间（来自 `session` 记录的 `createdAt`）
  final DateTime? createdAt;

  /// 回放用的消息（已按上限截取尾部）
  final List<SessionTranscriptMessage> messages;

  /// 文件里实际有多少条可回放消息
  final int total;

  /// 因为上限被丢掉多少条（界面如实说明"还有 N 条更早的没显示"）
  final int capped;

  bool get isEmpty => messages.isEmpty;
}

/// 一条可回放的消息。
class SessionTranscriptMessage {
  const SessionTranscriptMessage({
    required this.role,
    required this.text,
    this.detail,
  });

  /// `user` / `assistant` / `notice`
  ///
  /// `notice` 不是转录里的事件，是 App 侧补的一条"这次没回上来 + 原因"
  /// （见 `local/session_failure_store.dart`）。界面要把它画成**失败提示**，
  /// 不能画成助手回答 —— 那会变成"模型说了这句话"的假象。
  final String role;
  final String text;

  /// 技术细节（原始报错）。只有 `notice` 会带。
  final String? detail;

  bool get isUser => role == 'user';

  /// 是不是"没有回答"那条提示
  bool get isNotice => role == 'notice';
}

/// 内嵌的 node 解码脚本。
///
/// 刻意**内嵌成字符串**而不是走 Flutter asset：少一层 pubspec/asset 配置，
/// 而且每次调用都会重写一遍（4KB，可忽略），这样 App 升级后脚本一定是最新的，
/// 不会出现"设备上留着旧脚本"这种最难查的问题。
const String _kTranscriptScript = r'''
// DSH 会话记录 -> 可读的对话回放
// 用法: node read-transcript.mjs <dshHome> <sessionId>
// 输出: 一行 JSON {"title":..,"createdAt":..,"total":N,"messages":[{"role":"user|assistant","text":".."}]}
import { readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { zstdDecompressSync } from 'node:zlib';

const dshHome = process.argv[2];
const sessionId = process.argv[3];
const cap = Number(process.argv[4] || 40);
if (!dshHome || !sessionId) {
  console.error('usage: read-transcript.mjs <dshHome> <sessionId> [cap]');
  process.exit(2);
}

function findSessionFile(root) {
  const sessions = join(root, 'sessions');
  let cwds;
  try { cwds = readdirSync(sessions); } catch (e) { return null; }
  for (const c of cwds) {
    const dir = join(sessions, c);
    let subs;
    try { if (!statSync(dir).isDirectory()) continue; subs = readdirSync(dir); } catch (e) { continue; }
    for (const s of subs) {
      if (s.indexOf(sessionId) === -1) continue;
      const f = join(dir, s, 'session.v4.jsonl.zstd');
      try { if (statSync(f).isFile()) return f; } catch (e) { /* keep looking */ }
    }
  }
  return null;
}

function decodeAllFrames(buf) {
  const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);
  const offsets = [];
  let i = 0;
  while ((i = buf.indexOf(MAGIC, i)) !== -1) { offsets.push(i); i += 4; }
  const parts = [];
  for (let k = 0; k < offsets.length; k += 1) {
    const start = offsets[k];
    const end = k + 1 < offsets.length ? offsets[k + 1] : buf.length;
    const slice = buf.subarray(start, end);
    try {
      parts.push(zstdDecompressSync(slice).toString('utf8'));
    } catch (e) {
      // 帧尾若带上下一帧的字节，一次性解码会失败；逐步回退再试。
      for (let trim = 1; trim <= 64; trim += 1) {
        try {
          parts.push(zstdDecompressSync(slice.subarray(0, slice.length - trim)).toString('utf8'));
          break;
        } catch (e2) { /* trim more */ }
      }
    }
  }
  return parts.join('');
}

const file = findSessionFile(dshHome);
if (!file) {
  console.error('session file not found for ' + sessionId);
  process.exit(3);
}

const text = decodeAllFrames(readFileSync(file));
let title = null;
let createdAt = null;
const messages = [];

for (const line of text.split('\n')) {
  if (!line) continue;
  let o;
  try { o = JSON.parse(line); } catch (e) { continue; }
  const t = o.type;
  if (t === 'session') {
    if (typeof o.createdAt === 'number') createdAt = o.createdAt;
    continue;
  }
  if (t === 'session/title') {
    const v = o.data && o.data.title;
    if (typeof v === 'string' && v.trim()) title = v.trim();
    continue;
  }
  if (t === 'user/message') {
    const content = (o.data && o.data.content) || [];
    const parts = [];
    let onlyReminders = true;
    for (const c of content) {
      if (c && c.type === 'text' && typeof c.text === 'string') {
        // ⚠️ DSH 会把 <system-reminder>（工作区说明、当前策略这类**运行时注入**的内容）
        //    作为**一条独立的 user/message** 写进会话文件。它不是用户说的话，回放出来
        //    会让人以为"谁替我发了这段"；而且它会让同一句用户消息在 磁盘/内存 两份里
        //    文本对不上（chat_page 的 _mergedMessages 按「角色+正文」去重，对不上就会
        //    把同一句话显示两遍）。所以这类内容整条丢掉。
        if (c.text.trimStart().indexOf('<system-reminder>') === 0) continue;
        onlyReminders = false;
        parts.push(c.text);
      }
      else if (c && c.type === 'file') {
        onlyReminders = false;
        parts.push('[附件: ' + ((c.attachment && c.attachment.name) || '文件') + ']');
      }
    }
    if (onlyReminders) continue;
    const s = parts.join('\n').trim();
    if (s) messages.push({ role: 'user', text: s });
    continue;
  }
  if (t === 'assistant/message') {
    const content = (o.data && o.data.message && o.data.message.content) || [];
    const parts = [];
    for (const c of content) {
      // 只取可见正文；reasoning 是思维链，不回放。
      if (c && c.type === 'text' && typeof c.text === 'string') parts.push(c.text);
    }
    const s = parts.join('\n').trim();
    if (s) messages.push({ role: 'assistant', text: s });
    continue;
  }
}

const total = messages.length;
const kept = cap > 0 ? messages.slice(-cap) : messages;
process.stdout.write(JSON.stringify({
  title,
  createdAt,
  total,
  capped: total - kept.length,
  messages: kept,
}));
''';

/// 把 App 侧记下的"这次没回上来"合并成回放里的最后一条 `notice`（缺陷 C）。
///
/// 只在**最后一条是用户消息**时合并 —— 那说明这一轮确实没有助手回复；
/// 若最后一条是助手消息，说明后面成功过了，挂个过期的失败提示只会误导。
/// 另外失败必须发生在会话创建之后（防跨会话串 id 的极端情况）。
///
/// 抽成纯函数是为了能直接测（[loadSessionTranscript] 要真跑一个 node 进程）。
void mergeFailureNotice(
  List<SessionTranscriptMessage> messages,
  SessionFailureRecord? failure,
  DateTime? createdAt,
) {
  if (failure == null || messages.isEmpty || !messages.last.isUser) return;
  final createdMs = createdAt?.millisecondsSinceEpoch ?? 0;
  if (failure.at < createdMs) return;
  messages.add(SessionTranscriptMessage(
    role: 'notice',
    text: failure.friendly,
    detail: failure.detail,
  ));
  debugPrint('[dsh-transcript] 合并一条失败记录（${failure.friendly}）');
}

/// 从设备上的会话文件里读出历史对话。
///
/// 返回 null 表示**读不到**（会话文件找不到 / node 报错）—— 调用方要如实提示，
/// 不要把"读不到"显示成"这条会话没有历史"。
Future<SessionTranscript?> loadSessionTranscript({
  required DshRuntime runtime,
  required String sessionId,
  int maxMessages = 40,
  Duration timeout = const Duration(seconds: 60),
}) async {
  if (sessionId.trim().isEmpty) return null;

  String scriptPath;
  try {
    final toolsDir = Directory('${runtime.filesDir}/tools');
    if (!toolsDir.existsSync()) toolsDir.createSync(recursive: true);
    final f = File('${toolsDir.path}/read-transcript.mjs');
    // 每次都写：4KB 的成本换"升级后设备上不会留着旧脚本"。
    f.writeAsStringSync(_kTranscriptScript);
    scriptPath = f.path;
  } catch (e) {
    debugPrint('[dsh-transcript] 写脚本失败: $e');
    return null;
  }

  try {
    final result = await runtime.runOnce(
      <String>[
        scriptPath,
        runtime.nodeHome,
        sessionId,
        '$maxMessages',
      ],
      timeout: timeout,
    );
    if (result.exitCode != 0) {
      debugPrint(
        '[dsh-transcript] 脚本退出码 ${result.exitCode}：'
        '${result.stderr.trim().split('\n').take(3).join(' | ')}',
      );
      return null;
    }
    final out = result.stdout.trim();
    if (out.isEmpty) {
      debugPrint('[dsh-transcript] 脚本没有输出');
      return null;
    }
    final decoded = jsonDecode(out);
    if (decoded is! Map) return null;

    final rawMessages = decoded['messages'];
    final messages = <SessionTranscriptMessage>[];
    if (rawMessages is List) {
      for (final item in rawMessages) {
        if (item is! Map) continue;
        final role = item['role']?.toString() ?? '';
        final text = item['text']?.toString() ?? '';
        if (text.trim().isEmpty) continue;
        messages.add(SessionTranscriptMessage(role: role, text: text));
      }
    }

    final createdRaw = decoded['createdAt'];
    DateTime? created;
    if (createdRaw is num && createdRaw > 0) {
      final ms = createdRaw < 100000000000
          ? createdRaw.toInt() * 1000
          : createdRaw.toInt();
      created = DateTime.fromMillisecondsSinceEpoch(ms);
    }

    // 缺陷 C：把 App 记下的"这次没回上来"合并成一条 `notice` 挂在末尾。
    final failure = readSessionFailure(runtime: runtime, sessionId: sessionId);
    mergeFailureNotice(messages, failure, created);

    final transcript = SessionTranscript(
      title: decoded['title']?.toString(),
      createdAt: created,
      messages: messages,
      total: (decoded['total'] as num?)?.toInt() ?? messages.length,
      capped: (decoded['capped'] as num?)?.toInt() ?? 0,
    );
    debugPrint(
      '[dsh-transcript] 回放 ${messages.length}/${transcript.total} 条'
      '（标题=${transcript.title ?? '无'}）',
    );
    return transcript;
  } catch (e) {
    debugPrint('[dsh-transcript] 读取失败: $e');
    return null;
  }
}
