import 'dart:io';

import 'package:flutter/material.dart';

import '../ui/theme/dsh_tokens.dart';
import '../ui/widgets/common.dart';
import 'artifact_opener.dart';

import '../i18n/dsh_i18n.dart';

/// 产物（设计稿 `page-04` 的产物列表）。
///
/// ## 口径（用户 2026-10-04 定：**「产物这里就应该是产生的文件」**）
///
/// [Artifact] **只在核实过"工作区里真有这个文件、而且是这次会话写出来的"之后**
/// 才成立（见 [verifyProducedArtifacts]）。
///
/// 光有名字**不算产物**。用户实测踩过坑：让模型画一张图，产物列表里立刻冒出
/// 三个"文件"，直到图片生成完都点不开，他最后只能在「资料库」里找到那张图。
/// 那三个名字其实是 `make-image` 技能文档正文里的**示例占位名**
/// （`输出.png` / `参考图.png` / 一段被当成文件名的自检命令）——
/// 文档作为工具结果进了会话，被下面的正则捞了出来。
///
/// 所以现在的链路是两段，缺一不可：
///   1. [extractArtifactCandidates]：从工具内容里捞**候选名**（可能会误捞）；
///   2. [verifyProducedArtifacts]：拿候选名去工作区**核实**（存在 + 是本次会话
///      写出来的），核实通过才变成 [Artifact] 进列表，并带上真实路径。
class Artifact {
  const Artifact({
    required this.name,
    required this.extension,
    this.sizeLabel,
    this.path,
    this.sessionId,
    this.sessionCwd,
  });

  /// 不含扩展名的文件名（设计稿里名字和 `MD 文件·4.6KB` 是分两行显示的）
  final String name;

  /// 扩展名（小写，不含点）
  final String extension;

  /// 体积文案，如 `4.6KB`；未知时为 null
  final String? sizeLabel;

  /// **核实过的真实绝对路径**；null 表示这还只是个候选（不该进产物列表）。
  final String? path;

  /// 产出它的会话 id（用户意见⑤：要能知道"哪个会话产生的文件"）。
  ///
  /// null = 来源未知（老索引 / 手工构造）。界面此时**如实不显示来源**，不编。
  final String? sessionId;

  /// 产出时的会话工作目录（资料库里显示相对路径用）。
  final String? sessionCwd;

  /// 去重键：核实过的按**真实路径**去重（同一个文件只有一条），
  /// 还没核实的退化成"名字+体积"。
  String get key => path ?? '$name.$extension|${sizeLabel ?? ''}';

  /// 完整文件名
  String get fullName => '$name.$extension';

  /// 设计稿的副标题形态：`MD 文件·4.6KB`
  String get subtitle => tr('{0} 文件{1}',
      [extension.toUpperCase(), sizeLabel != null ? '·$sizeLabel' : '']);

  /// 落盘用（见 `data/artifact_store.dart`）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'extension': extension,
        if (sizeLabel != null) 'sizeLabel': sizeLabel,
        if (path != null) 'path': path,
        if (sessionId != null) 'sessionId': sessionId,
        if (sessionCwd != null) 'sessionCwd': sessionCwd,
      };

  /// 从落盘索引读回。字段不全（老版本写的）时返回 null，由调用方跳过。
  static Artifact? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    final extension = raw['extension'];
    if (name is! String || name.isEmpty || extension is! String) return null;
    return Artifact(
      name: name,
      extension: extension,
      sizeLabel: raw['sizeLabel'] is String ? raw['sizeLabel'] as String : null,
      path: raw['path'] is String ? raw['path'] as String : null,
      sessionId: raw['sessionId'] is String ? raw['sessionId'] as String : null,
      sessionCwd:
          raw['sessionCwd'] is String ? raw['sessionCwd'] as String : null,
    );
  }
}

/// 从工具调用的内容里捞**候选**文件名。
///
/// **为什么要靠猜**：ACP 协议只有 `session/update`（消息块 / 思考块 /
/// 工具调用 / 用量），**没有 artifact 通知**（设计稿里那套产物卡片是云端能力）。
/// 所以只能从工具标题、入参、输出里捞"看起来像文件"的字符串。
///
/// **捞到 != 产物**：这里只产出候选，调用方**必须**再过一遍
/// [verifyProducedArtifacts] 才算产物。跳过核实就会出现上面注释里说的
/// "文档示例名当成产物"。
///
/// 候选里带路径的（绝对路径 / 相对路径）会把路径整段留着，好在核实阶段
/// 直接去 stat 那个路径，而不是只拿一个名字去猜。
List<Artifact> extractArtifactCandidates({
  String? title,
  Object? rawInput,
  String? output,
}) {
  final found = <String, Artifact>{};

  void scan(String? text) {
    if (text == null || text.isEmpty) return;
    for (final spec in _filePatterns) {
      for (final m in spec.pattern.allMatches(text)) {
        final full = m.group(0);
        if (full == null) continue;
        final art = _toArtifact(full);
        if (art != null) found.putIfAbsent(art.key, () => art);
      }
    }
  }

  scan(title);
  // rawInput 是 Map，深挖一层字符串值就够用
  if (rawInput is Map) {
    for (final v in rawInput.values) {
      if (v is String) scan(v);
    }
  }
  scan(output);

  final list = found.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  return list;
}

/// 把候选名**核实成真产物**：文件真的在工作区里、而且**是 [since] 之后
/// 被写出来的**（= 这次会话产出的），两条都满足才算。
///
/// 为什么还要卡时间：光"存在"不够 —— 模型读一份旧文档、顺口提一句工作区里
/// 已有的文件名，那也不是"产物"。产物是**这次产生的文件**。
/// （[since] 会往前留一点余量，见 [_mtimeTolerance]。）
///
/// 核实在主 isolate 之外做（只是 stat 文件，很便宜），生成不出来就**丢掉**，
/// 宁可少显示，也不摆一堆点不开的卡片。
Future<List<Artifact>> verifyProducedArtifacts(
  Iterable<Artifact> candidates, {
  required String cwd,
  required DateTime since,
}) async {
  final out = <Artifact>[];
  final seen = <String>{};
  final floor = since.subtract(_mtimeTolerance);

  for (final c in candidates) {
    final abs = _absolutePathFor(c, cwd);
    if (abs == null) continue;

    final FileStat stat;
    try {
      stat = await File(abs).stat();
    } catch (_) {
      // 读不到就当没核实成功 —— 不编、不猜
      continue;
    }
    if (stat.type != FileSystemEntityType.file) continue;
    if (stat.modified.isBefore(floor)) continue;
    if (!seen.add(abs)) continue;

    final base = _baseName(abs);
    out.add(
      Artifact(
        name: _withoutExtension(base),
        extension: _extensionOf(base) ?? c.extension,
        sizeLabel: formatSizeLabel(stat.size),
        path: abs,
      ),
    );
  }
  return out;
}

/// 会话刚开始时，文件系统时间戳可能比 [DateTime.now()] 略早一点点
/// （同一台设备上偏差很小，留余量只是为了不误杀刚写出来的文件）。
const Duration _mtimeTolerance = Duration(seconds: 5);

/// 候选 → 绝对路径。
///
///   * 候选自带绝对路径 → 直接用（bash/脚本输出里通常就是绝对路径）；
///   * 候选自带相对路径 → 以会话 cwd 为基准（DSH 就是在 cwd 里跑的）；
///   * 只有裸名字 → 也按 cwd 拼（脚本把文件写在 cwd 根目录是常态）。
///
/// 解析不出来返回 null（比如 cwd 都拿不到）。
String? _absolutePathFor(Artifact c, String cwd) {
  final raw = c.path;
  if (raw != null && raw.isNotEmpty) {
    if (_isAbsolutePath(raw)) return _tidy(raw);
    if (cwd.isEmpty) return null;
    return _tidy('${_trimTrailingSlash(cwd)}/$raw');
  }
  if (c.fullName.isEmpty || cwd.isEmpty) return null;
  return '${_trimTrailingSlash(cwd)}/${c.fullName}';
}

/// 是不是绝对路径。
///
/// Android 上永远是 `/…`；盘符那一条是给**桌面跑单测**用的
/// （本仓库的测试在 Windows 上跑，临时目录是 `D:\…`）。
bool _isAbsolutePath(String s) {
  if (s.startsWith('/')) return true;
  return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(s);
}

String _trimTrailingSlash(String s) =>
    s.endsWith('/') ? s.substring(0, s.length - 1) : s;

/// 把 `//` 收成 `/`（工具输出里偶见双斜杠）。
String _tidy(String path) => path.replaceAll(RegExp(r'/{2,}'), '/');

String _baseName(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? path : path.substring(i + 1);
}

String _withoutExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}

String? _extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return null;
  return name.substring(dot + 1).toLowerCase();
}

/// 体积文案：`16.3KB` / `1.4MB` / `812B`。
String formatSizeLabel(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
}

/// 支持的产物扩展名（与设计稿出现的一致：md / pdf / docx / pptx / html …）
const List<String> _extensions = [
  'md',
  'markdown',
  'pdf',
  'docx',
  'doc',
  'pptx',
  'ppt',
  'xlsx',
  'csv',
  'html',
  'json',
  'txt',
  'png',
  'jpg',
  'jpeg',
  'webp',
  'svg',
  'zip',
];

class _FileSpec {
  const _FileSpec(this.pattern);
  final RegExp pattern;
}

/// 文件名模式。
///
/// 用「贪婪匹配到最后一个合法扩展名」+ 事后校验，而不是精确字符类：
/// 中文文件名里带括号、全角符号、空格的情况太多，精确字符类总会漏。
/// 宽松捞 + 严格校验（见 [_toArtifact]）误报更少。
///
/// ⚠️ 开头那个 `/?` 是必需的（2026-10-05 修）：正则的第一个字符类只认
/// `[\w\u4e00-\u9fa5]`，**不认 `/`** —— 于是**独立出现的绝对路径**
/// （例如 `write` 工具的 `rawInput.file_path = "/data/…/笔记.txt"`）
/// 会从第二个字符开始匹配，把开头的 `/` 吃掉，变成 `data/…/笔记.txt`。
/// 这样的候选拿去核实时会被当成**相对路径**、拼到 cwd 下面去找，永远找不到
/// → 产物被静默丢弃。用户看到的现象就是「明明生成了 txt，产物里却没有」。
final List<_FileSpec> _filePatterns = [
  _FileSpec(RegExp(
    r'/?[\w\u4e00-\u9fa5][^<>"\r\n]{0,160}?\.(' +
        _extensions.join('|') +
        r')(?![A-Za-z0-9])',
    caseSensitive: false,
  )),
];

/// 名字里出现这些 ASCII 符号，基本就是从代码 / 命令里捞出来的片段，不是文件名。
///
/// 实测来源：`make-image` 技能文档里那行自检命令
/// `node -e "const b=require('node:fs').readFileSync('输出.png')…"` 会被整段
/// 捞成一个"文件"（名字里带着 `'` `(` `)` `=` `;`）。中文全角的括号、冒号
/// **不在**这个名单里 —— 真实的中文文件名经常用它们。
final RegExp _codeLikeChars = RegExp(r"""['"`=()\[\]{};,:\\<>|?*#]""");

Artifact? _toArtifact(String raw) {
  var s = raw.trim();
  // 去掉常见的前后噪声字符
  s = s
      .replaceAll(RegExp(r'^[`*「『《]+'), '')
      .replaceAll(RegExp(r'[`*」』》]+$'), '')
      .trim();
  if (s.isEmpty || s.length > 200) return null;

  // 句子里夹着路径时（工具输出常见 `已生成 /data/…/橘猫.png`），把前面那段说明切掉。
  // 判据：DSH 的绝对路径一定是 ASCII，所以"最后一个空格之后、以 `/` 开头的段"
  // 就是路径。中文名里带空格（`我的 文件.md`）不会被误切 —— 那种尾巴不以 `/` 开头。
  if (s.contains(' ')) {
    final tail = s.substring(s.lastIndexOf(' ') + 1);
    if (tail.startsWith('/') && tail.contains('/')) s = tail;
  }

  final dot = s.lastIndexOf('.');
  if (dot <= 0 || dot == s.length - 1) return null;
  final extCandidate = s.substring(dot + 1).trim().toLowerCase();
  if (!_extensions.contains(extCandidate)) return null;

  final before = s.substring(0, dot);
  final slash = before.lastIndexOf('/');
  final name = (slash >= 0 ? before.substring(slash + 1) : before).trim();
  if (name.isEmpty || name.length > 70) return null;
  if (name.length < 2) return null;
  if (_codeLikeChars.hasMatch(name)) return null;

  // 带路径的整段留着（核实阶段直接 stat 它，不用猜目录）
  final path = slash >= 0 ? s : null;
  return Artifact(name: name, extension: extCandidate, path: path);
}

/// 产物列表页（设计稿 `page-04`）。
class ArtifactListPage extends StatelessWidget {
  const ArtifactListPage({super.key, required this.artifacts, this.cwd});

  final List<Artifact> artifacts;

  /// 会话的工作目录（预览页要显示"相对工作区"的路径；拿不到就显示绝对路径）
  final String? cwd;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(tr('产物')),
        // ⚠️ 这里原来有一颗「批量操作」按钮，点了只弹一句
        // 「批量操作尚未实现（见 HANDOFF 待办）」（审计 P1-8）。
        // 一个只用来告诉你"没做"的按钮比没有按钮更糟：它看起来是功能，
        // 点下去是空转。功能做好之前不放入口 —— 待办在 HANDOFF 里，不会丢。
        actions: const <Widget>[],
      ),
      body: artifacts.isEmpty
          // 皮肤是运行时变量：这里不能 const（const 实例换肤时会被原样复用、颜色不刷新）
          // ignore: prefer_const_constructors
          ? DshEmptyState(
              icon: Icons.inventory_2_outlined,
              title: tr('还没有产物'),
              hint: tr('让 DSH 写一份文档或生成一张图，产物会出现在这里。'),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(DshMetrics.pagePad),
              itemCount: artifacts.length,
              itemBuilder: (context, i) => ArtifactCard(
                artifact: artifacts[i],
                cwd: cwd,
              ),
            ),
    );
  }
}

/// 产物卡片：设计稿里是「类型角标 + 文件名 + `MD 文件·4.6KB`」。
///
/// **可点击**：点它打开文件：路径已经在核实阶段 stat 过，直接用它；
/// 只有在没有路径（老数据）时才退回"按文件名扫工作区"（见 [ArtifactOpener]）。
///
/// **可分享**：卡片右侧的分享小按钮 + 长按整张卡片，都会先解析出真实路径，
/// 再拉起系统分享面板（见 [ArtifactOpener.share]）。
class ArtifactCard extends StatelessWidget {
  const ArtifactCard({super.key, required this.artifact, this.onTap, this.cwd});

  final Artifact artifact;

  /// 点击行为；不传则用默认的「打开产物」。
  final VoidCallback? onTap;

  /// 会话的工作目录（预览页显示相对路径用）
  final String? cwd;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${artifact.fullName} ${artifact.subtitle}',
      child: InkWell(
        onTap: onTap ?? () => ArtifactOpener.open(context, artifact, cwd: cwd),
        onLongPress: () => ArtifactOpener.share(context, artifact, cwd: cwd),
        borderRadius: BorderRadius.circular(DshMetrics.cardRadius),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(DshMetrics.cardPad),
          decoration: BoxDecoration(
            color: DshColors.surface,
            borderRadius: BorderRadius.circular(DshMetrics.cardRadius),
            border: Border.all(color: DshColors.divider, width: 0.8),
          ),
          child: Row(
            children: [
              DshFileTypeBadge(extension: artifact.extension),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      artifact.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: DshColors.text,
                        fontSize: 13.5,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      artifact.subtitle,
                      style:
                          TextStyle(color: DshColors.textFaint, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              // 分享小按钮（点它不会触发整卡的 onTap —— 按钮自己吃掉这次点击）。
              IconButton(
                onPressed: () =>
                    ArtifactOpener.share(context, artifact, cwd: cwd),
                tooltip: tr('分享'),
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                icon: Icon(Icons.ios_share, color: DshColors.textFaint),
              ),
              Icon(Icons.open_in_new, size: 15, color: DshColors.textFaint),
            ],
          ),
        ),
      ),
    );
  }
}
