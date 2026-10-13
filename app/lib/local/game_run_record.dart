/// 「游戏运行记录」的**内容拼装**（纯函数，便于单测）。
///
/// ## 这东西是干什么的（为什么不是"自动截图"）
///
/// 「小说改游戏」那条流水线的最后一环是 `game-qa`：它要在**真实运行环境**里证明
/// 画面渲染、输入、核心循环、至少一个结局、重开，以及明确写出限制。
///
/// 手机上**没有**浏览器自动化、也**没有**可靠的 WebView 截图能力：
/// Android 上 WebView 是**平台视图**，Flutter 的 `RepaintBoundary.toImage()`
/// 截到的往往是空白（平台视图不在 Flutter 的图层树里）。所以"我自动截几张图给你"
/// 这条路在本机是不成立的 —— 硬做出来只会给用户一堆空白图。
///
/// 所以走**人能验、且留下证据**的那条路：
///   让用户在 App 内把游戏跑起来（资料库已经能渲染 HTML），
///   由用户对着 `game-qa` 那几条**逐项勾选 + 写备注**，
///   我们把它落成一份 Markdown 放进工作区 —— 模型读这份文件就能继续做 QA。
///
/// 这份 Markdown 就是"证据"：谁、什么时候、在什么设备上、跑了哪个文件、
/// 哪几项通过了、哪几项没有、用户自己说了什么。**不假装是截图**。
library;

/// 一条待确认的检查项（问题 + 用户勾没勾）。
class GameRunCheck {
  const GameRunCheck({required this.question, required this.ok});

  /// 面向用户的问法（中文原文；渲染处包 `tr`）。
  final String question;
  final bool ok;
}

/// `game-qa` 那几条证据，翻译成**用户能回答的样子**。
///
/// ⚠️ 与 `assets/skills/game-qa/SKILL.md` 里那份清单对应 —— 那边是给模型的
/// 验收口径，这里是给玩家的一问一答。改一处记得看另一处。
List<String> get kGameRunQuestions => <String>[
      '画面真的出来了（不是黑屏/白屏）',
      '操作有反应（点按、键盘、拖拽里至少一种）',
      '核心循环走通了（能反复玩下去，不是玩一下就卡住）',
      '至少达成过一个结局（或明确的"失败"结算）',
      '重新开始正常（能开新的一局）',
    ];

/// 拼出运行记录（Markdown）。
String buildRunRecordMarkdown({
  required String fileName,
  required String filePath,
  required List<GameRunCheck> checks,
  required String notes,
  required DateTime at,
}) {
  final passed = checks.where((c) => c.ok).length;
  final buf = StringBuffer()
    ..writeln('# 游戏运行记录 · $fileName')
    ..writeln()
    ..writeln('> 这份记录由**用户在手机上实际游玩**后勾选生成（`dsh-mobile` 的'
        '「运行记录」页）。它不是自动截图 —— Android 上 WebView 是平台视图，'
        'Flutter 截屏拿到的常常是空白，所以这里**不假装**有截图。')
    ..writeln()
    ..writeln('- 时间：${_stamp(at)}')
    ..writeln('- 文件：`$filePath`')
    ..writeln('- 结果：**$passed / ${checks.length}** 项通过')
    ..writeln()
    ..writeln('## 逐项结果（对照 game-qa 的验收口径）')
    ..writeln()
    ..writeln('| 检查项 | 结果 |')
    ..writeln('|---|---|');
  for (final c in checks) {
    buf.writeln('| ${c.question} | ${c.ok ? '通过' : '**没通过**'} |');
  }
  buf
    ..writeln()
    ..writeln('## 玩家备注')
    ..writeln()
    ..writeln(notes.trim().isEmpty ? '（没有写备注）' : notes.trim())
    ..writeln()
    ..writeln('## 给模型的话')
    ..writeln()
    ..writeln('这是一次**真机实跑**的验收结果。请据此判断：'
        '没通过的那几项是"实现缺陷"还是"设计问题"；'
        '并按 `game-qa` 的要求把**未覆盖项与已知限制**写清楚，'
        '**不要**把这份记录当成"全部通过"的证据。');
  return buf.toString();
}

/// 记录文件名：`游戏运行记录-<文件名>-<时间>.md`（与游戏放在同一个目录）。
///
/// 用**同步可见的时间戳**命名（不用随机数）：同一个游戏多跑几次，
/// 文件名按时间排序天然分批，模型一眼能看出"最新那次"。
String runRecordFileName(String fileName, DateTime at) {
  final safe = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  return '游戏运行记录-$safe-${_stamp(at)}.md';
}

String _stamp(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)} '
      '${two(at.hour)}:${two(at.minute)}';
}
