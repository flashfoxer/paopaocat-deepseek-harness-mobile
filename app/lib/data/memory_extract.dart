/// 「从最近会话里提炼长期记忆」—— 调**模型**把一段真实对话读成 0~5 条候选记忆。
///
/// ## 三件必须先讲清楚的事（都不是实现细节，是设计约束）
///
/// ### 1. 为什么走 `headless`（而不是当前会话的那条 ACP 连接）
///
/// `DshRuntime.headless(prompt)` 内部就是 `dsh --profile headless --patch <overlay> <任务>`
/// —— 与「定时任务」用的是**同一条**已经跑通的通道（见 `local/schedule_runner.dart`），
/// 没有另造一套执行路径。选它而不是复用正在跑的会话连接，理由是：
///   * **不污染会话历史**：headless 是一次性进程，它的提示词与输出**不写进**
///     用户当前那条会话的转录（会话转录是用户会回看的东西，绝不能塞进
///     一段"请你提炼记忆"的机器提示和模型的 JSON 回包）；
///   * **不干扰正在跑的那一轮**：复用 ACP 连接就得排队、甚至可能插进用户
///     正在进行的对话中间；一次性进程完全独立；
///   * **用完即走**：进程结束 = 资源释放，不留常驻连接。
///
/// 代价：每次提炼要冷启动一个 node 进程（秒级）+ 一次真实的模型调用（**会花额度**）。
/// 所以界面上必须"用户点了才跑"，不能悄悄跑。
///
/// ### 2. 超时 / 失败各代表什么（界面要如实说，不能吞）
///
/// * **超时**（默认 150 秒）：进程被 kill，模型这一轮到点没返回。它**不代表**
///   "没有记忆可提炼" —— 代表"这次没问出结果"。用户可以重试。
/// * **exit != 0**：headless 通道本身没跑起来（运行时没就绪 / Key 无效 / 网络不通）。
///   原始 stderr 前几行会带进失败原因里，方便排查。
/// * **解析失败**：模型答了，但答的不是约定的 JSON（可能是解释性文字、被截断的 JSON、
///   空输出）。这时**必须报失败**，不能返回"0 条候选" —— 那会让用户以为
///   "这段对话没啥可记的"，而真相是"这次没解析出来"。
///
/// 所以本文件把"成功但 0 条"（[MemoryExtraction.items] 为空且 [MemoryExtraction.ok]）
/// 与"失败"（[MemoryExtraction.failure] 非空）**分成两种状态**，界面分别显示。
///
/// ### 3. 为什么结果必须由用户确认才写盘
///
/// 提炼结果是**模型写的**，可能记偏、可能把一次性的抱怨记成长期禁忌。
/// 记忆一旦进了 `AGENTS.md` 就是**每个新会话都注入的全局指令** ——
/// 写错一条会长期污染模型行为，而用户根本不知道它是怎么进去的。
/// 所以：
///   * 本文件**只读**：不碰 `memory.json`，不碰 `AGENTS.md`，不写任何文件；
///   * 提炼结果只作为"候选"返回，由界面画成一个个勾选框，
///     用户勾完（还能改分类/重要度）再调 `MemoryStore.addFromCandidate(...)`。
///
/// ## 也不碰正在跑的会话 / ACP 进程
///
/// 这里只 `spawn` 一个**新的** headless 进程，并且在超时或用户取消时 kill 它自己；
/// 不会去动 ACP 会话进程，也不会写会话转录。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, immutable;

import '../i18n/dsh_i18n.dart' show tr;
import '../local/dsh_runtime.dart';
import '../local/session_transcript.dart';
import 'memory_store.dart';



/// 送给模型的对话**最多**取多少条（从最后往前取）。
const int kMemoryExtractMaxMessages = 30;

/// 单条消息最多带多少字符（超长**截断**，不丢最后那条的完整语义）。
const int kMemoryExtractPerMessageChars = 600;

/// 提示词里对话部分的总字符上限（防止一段超长对话把上下文顶爆）。
const int kMemoryExtractTotalChars = 12000;

/// 一次提炼的结果。
@immutable
class MemoryExtraction {
  const MemoryExtraction({
    this.items = const <MemoryCandidate>[],
    this.failure,
    this.raw,
    this.dropped = 0,
  });

  /// 失败态：**空列表 + 中文原因**，与"成功但 0 条"是两回事。
  factory MemoryExtraction.failure(String reason, {String? raw}) =>
      MemoryExtraction(items: const <MemoryCandidate>[], failure: reason, raw: raw);

  /// 候选条目（0~5 条；可能为空 —— 那表示"这段对话确实没什么可长期记的"）
  final List<MemoryCandidate> items;

  /// 失败原因（中文给用户看）；null = 成功。**空列表与失败必须能区分**。
  final String? failure;

  /// 模型的原始输出（排障用；界面只在失败时可折叠展示）。
  final String? raw;

  /// 解析时丢掉的条数（没有 text / 不是对象）。不影响成功与否，但如实报出来。
  final int dropped;

  bool get ok => failure == null;
}

/// 一条候选记忆（用户确认前的形态）。
@immutable
class MemoryCandidate {
  const MemoryCandidate({
    required this.text,
    this.kind = MemoryKind.other,
    this.importance = 2,
  });

  final String text;
  final MemoryKind kind;
  final int importance;

  MemoryCandidate copyWith({String? text, MemoryKind? kind, int? importance}) =>
      MemoryCandidate(
        text: text ?? this.text,
        kind: kind ?? this.kind,
        importance: clampImportance(importance ?? this.importance),
      );
}

/// 拼给模型的中文提示词。
///
/// ⚠️ 这段**不是界面文案**，所以刻意**不**包 `tr(...)`：它是要发给模型的一次性指令，
/// 跟着界面语言变没有意义（而且四语翻译会把它拆得不像话）。
/// `install/i18n` 的扫描器只认 `tr('字面量')`，所以它不会进翻译表。
String buildMemoryExtractPrompt({
  required List<SessionTranscriptMessage> messages,
  List<String> existingTexts = const <String>[],
}) {
  // 只带走用户/助手两种角色（notice 是 App 侧的失败提示，不是对话内容）
  final usable = <SessionTranscriptMessage>[
    for (final m in messages)
      if (m.role == 'user' || m.role == 'assistant') m,
  ];
  final recent = usable.length > kMemoryExtractMaxMessages
      ? usable.sublist(usable.length - kMemoryExtractMaxMessages)
      : usable;

  // 从**最新**往前拼，拼满总预算就停（更早的对话对"提炼长期偏好"价值更低）
  final lines = <String>[];
  var used = 0;
  for (final m in recent.reversed) {
    final body = _clip(m.text.replaceAll(RegExp(r'\n{3,}'), '\n\n'),
        kMemoryExtractPerMessageChars);
    final line = '${m.isUser ? '用户' : '助手'}：$body';
    if (used + line.length > kMemoryExtractTotalChars && lines.isNotEmpty) break;
    lines.add(line);
    used += line.length;
  }
  final transcript = lines.reversed.join('\n\n');

  final sb = StringBuffer()
    ..writeln('你在帮一台手机上的 DSH 助手整理「长期记忆」。')
    ..writeln()
    ..writeln('下面是一段真实对话。请从中提炼**跨会话长期有效**的信息，'
        '**只输出 JSON**，不要任何解释文字。')
    ..writeln()
    ..writeln('只提炼这四类（对应 kind）：')
    ..writeln('- identity：用户是谁（语言、职业、长期身份）')
    ..writeln('- preference：用户希望怎么被回答（风格、格式、习惯）')
    ..writeln('- project：正在做的项目、技术选型、已经确认的约定')
    ..writeln('- avoid：用户明确说过「不要做」的事（红线、禁忌）')
    ..writeln()
    ..writeln('规则：')
    ..writeln('1. 数量 0~5 条，宁缺毋滥。只提炼长期有效、跨会话有用的信息；'
        '**不要记流水账**（「用户今天问了 X」不是记忆）。')
    ..writeln('2. **不要重复**下面「已有记忆」里的条目，也不要把已有记忆换个说法再写一遍。')
    ..writeln('3. 只依据对话里**用户明确表达过**的内容，不要推测、不要编造。')
    ..writeln('4. 每条一句话，不超过 100 字；用陈述句写清事实，不要写「用户好像喜欢…」这种含糊话。')
    ..writeln();
  if (existingTexts.isNotEmpty) {
    sb
      ..writeln('【已有记忆（不要重复）】')
      ..writeln();
    for (var i = 0; i < existingTexts.length; i++) {
      sb.writeln('${i + 1}. ${_clip(existingTexts[i], 200)}');
    }
    sb.writeln();
  }
  sb
    ..writeln('【对话】')
    ..writeln()
    ..writeln(transcript)
    ..writeln()
    ..writeln('【输出格式】只输出这样一个 JSON 对象，不要 Markdown 代码块、不要注释：')
    ..writeln('{"items":[{"text":"……","kind":"identity|preference|project|avoid",'
        '"importance":1}]}')
    ..writeln('importance 取 1/2/3（1 最重要）。没有值得长期记住的内容就输出 '
        '{"items":[]}。');
  return sb.toString();
}

String _clip(String s, int max) {
  final t = s.trim();
  if (t.length <= max) return t;
  return '${t.substring(0, max)}…（后文略）';
}

/// 把模型输出解析成候选。**纯函数**，不碰网络、不碰磁盘 —— 所以能直接测。
///
/// 宽容策略（模型不总是听话，但"能救回来的就别丢"）：
///   * 去掉 ```json / ``` 围栏；
///   * 从**第一个 `{`** 截到**最后一个 `}`**（模型爱在 JSON 前后加一句解释）；
///     没有 `{}` 时退一步试 `[]`（整个输出就是个数组的情况）；
///   * `items` 里每一项逐条校验：`text` 非空才收；`kind` 不在枚举里 → [MemoryKind.other]；
///     `importance` 越界/非数字 → 夹到 1..3（缺省 2）。
///
/// 硬失败（返回 [MemoryExtraction.failure]，**绝不静默返回空列表**）：
///   * 空输出 / 找不到任何 JSON 边界；
///   * JSON 语法错误；
///   * 顶层不是对象也不是数组；
///   * 是对象但没有 `items` 数组。
MemoryExtraction parseMemoryExtraction(String raw) {
  final text = raw.trim();
  if (text.isEmpty) {
    return MemoryExtraction.failure(tr('模型没有返回任何内容。'), raw: raw);
  }

  // 1) 去掉 Markdown 代码围栏（```json / ``` 都可能出现）
  var s = text.replaceAll(RegExp(r'```[A-Za-z]*'), '```').trim();
  if (s.startsWith('```')) s = s.substring(3).trim();
  if (s.endsWith('```')) s = s.substring(0, s.length - 3).trim();

  // 2) 截取 JSON 边界。
  //    优先按**对象**（`{...}`）截；如果 `[` 比第一个 `{` 更早出现（模型直接回了
  //    一个数组），就按数组截 —— 否则会把外层数组里的第一个对象当成整个答案，
  //    然后又因为它没有 items 而误报失败。
  var start = s.indexOf('{');
  var end = s.lastIndexOf('}');
  final arrayStart = s.indexOf('[');
  if (arrayStart >= 0 && (start < 0 || arrayStart < start)) {
    start = arrayStart;
    end = s.lastIndexOf(']');
  }
  if (start < 0 || end <= start) {
    return MemoryExtraction.failure(
      tr('模型的输出里找不到 JSON 结构（前 120 字：{0}）', <Object?>[_clip(text, 120)]),
      raw: raw,
    );
  }
  final candidate = s.substring(start, end + 1);

  Object? decoded;
  try {
    decoded = jsonDecode(candidate);
  } on FormatException catch (e) {
    return MemoryExtraction.failure(
      tr('模型的输出不是合法 JSON（{0}）', <Object?>[e.message]),
      raw: raw,
    );
  } catch (e) {
    return MemoryExtraction.failure(tr('模型的输出解析失败：{0}', <Object?>['$e']), raw: raw);
  }

  final Object? listRaw;
  if (decoded is List) {
    listRaw = decoded;
  } else if (decoded is Map) {
    listRaw = decoded['items'];
    if (listRaw is! List) {
      return MemoryExtraction.failure(
        tr('模型的 JSON 里没有 items 数组 —— 这次没提炼出结果。'),
        raw: raw,
      );
    }
  } else {
    return MemoryExtraction.failure(tr('模型的输出顶层既不是对象也不是数组。'), raw: raw);
  }

  final items = <MemoryCandidate>[];
  var dropped = 0;
  for (final item in (listRaw as List)) {
    if (item is! Map) {
      dropped++;
      continue;
    }
    final t = item['text'];
    if (t is! String || t.trim().isEmpty) {
      dropped++;
      continue;
    }
    items.add(MemoryCandidate(
      text: t.trim(),
      kind: memoryKindFromJson(item['kind']),
      importance: clampImportance(item['importance']),
    ));
  }
  debugPrint('[dsh-memory-extract] 解析出 ${items.length} 条候选'
      '（丢弃 $dropped 条结构不完整的）');
  return MemoryExtraction(items: items, raw: raw, dropped: dropped);
}

/// 提炼一次。**只读**：不写 `memory.json`、不写 `AGENTS.md`、不动会话转录。
///
/// 调的是 `runtime.headless(...)`（见文件头注释 §1），超时 [timeout] 秒，
/// [cancel] 完成时立刻 kill 掉这次 headless 进程（不碰 ACP 会话进程）。
Future<MemoryExtraction> extractMemoryCandidates({
  required DshRuntime runtime,
  required List<SessionTranscriptMessage> messages,
  List<String> existingTexts = const <String>[],
  Duration timeout = const Duration(seconds: 150),
  Future<void>? cancel,
}) async {
  final usable = <SessionTranscriptMessage>[
    for (final m in messages)
      if (m.role == 'user' || m.role == 'assistant') m,
  ];
  if (usable.isEmpty) {
    return MemoryExtraction.failure(tr('这条会话里没有可提炼的对话内容（没有用户或助手的消息）。'));
  }

  final prompt = buildMemoryExtractPrompt(
    messages: usable,
    existingTexts: existingTexts,
  );
  debugPrint('[dsh-memory-extract] 开始提炼：${usable.length} 条消息、'
      '提示词 ${prompt.length} 字符、超时 ${timeout.inSeconds}s');

  DshRunResult result;
  try {
    result = await runtime.headless(prompt, timeout: timeout, cancel: cancel);
  } catch (e) {
    debugPrint('[dsh-memory-extract] headless 抛异常：$e');
    return MemoryExtraction.failure(tr('提炼没能跑起来：{0}', <Object?>['$e']));
  }

  if (result.cancelled) {
    return MemoryExtraction.failure(tr('提炼已取消（那条一次性进程已经终止，没有留下任何东西）。'));
  }
  final timedOut = result.stderr.contains('超时');
  if (result.exitCode != 0) {
    final detail = _firstLines(result.stderr);
    debugPrint('[dsh-memory-extract] headless 退出码 ${result.exitCode}：$detail');
    if (timedOut) {
      return MemoryExtraction.failure(
        tr('提炼超时：{0} 秒内模型没有返回。可以重试，或直接手写一条。',
            <Object?>['${timeout.inSeconds}']),
        raw: result.stderr,
      );
    }
    return MemoryExtraction.failure(
      tr('提炼失败：模型这条通道退出码 {0}。{1}', <Object?>['${result.exitCode}', detail]),
      raw: result.stderr,
    );
  }

  // 正文在 stdout；stdout 里解析不出来时再试一次 stderr
  //（有些运行时版本会把最后一轮回答写到 stderr，宽容一点没坏处）。
  final out = result.stdout.trim();
  if (out.isEmpty) {
    return MemoryExtraction.failure(
      tr('提炼失败：模型没有任何输出（{0}）', <Object?>[_firstLines(result.stderr)]),
      raw: result.stderr,
    );
  }
  final parsed = parseMemoryExtraction(out);
  if (parsed.ok) return parsed;
  final fallback = parseMemoryExtraction(result.stderr);
  if (fallback.ok) {
    debugPrint('[dsh-memory-extract] stdout 解析失败，改用 stderr 里解析出来的结果');
    return fallback;
  }
  return parsed;
}

/// stderr 前几行（拼一行，最多 200 字）—— 失败原因要带原始信息，但不塞满界面。
String _firstLines(String raw, {int lines = 3, int max = 200}) {
  final t = raw
      .trim()
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .take(lines)
      .join(' | ');
  if (t.isEmpty) return '没有更多信息';
  return t.length > max ? '${t.substring(0, max)}…' : t;
}
