import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../i18n/dsh_i18n.dart';
import '../../local/game_run_record.dart';
import '../theme/dsh_tokens.dart';

/// 「运行记录」页：把工作区里的一个 **HTML 游戏**跑起来，并让用户把验收结果记下来。
///
/// ## 为什么是这样一页（而不是"自动跑测试"）
///
/// 「小说改游戏」流水线的最后一环 `game-qa` 要在**真实运行环境**里拿证据。
/// 手机上做不到浏览器自动化，也拿不到可靠的 WebView 截图（Android 上 WebView 是
/// **平台视图**，Flutter 的 `RepaintBoundary.toImage()` 常常截到空白）——
/// 所以这一页把"验证"交给**人**：让用户真的玩一遍，然后按 `game-qa` 的口径逐项勾选，
/// 我们把它落成一份 Markdown 交给模型继续处理。**不假装有截图。**
///
/// 这一页只做三件事：渲染、收集、落盘。玩法与美术都不关它的事。
class GameRunPage extends StatefulWidget {
  const GameRunPage({super.key, required this.htmlPath, required this.fileName});

  /// 要运行的 HTML 文件（绝对路径）。
  final String htmlPath;

  /// 显示名（一般是文件名）。
  final String fileName;

  @override
  State<GameRunPage> createState() => _GameRunPageState();
}

class _GameRunPageState extends State<GameRunPage> {
  WebViewController? _web;
  String? _webError;

  /// 勾选状态（下标与 [kGameRunQuestions] 对应）。
  final List<bool> _checks = List<bool>.filled(kGameRunQuestions.length, false);

  final TextEditingController _notes = TextEditingController();
  bool _panelOpen = true;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final c = WebViewController();
      // 游戏一定要 JS（我们把整条"网页游戏"链路都建在这上面）。
      await c.setJavaScriptMode(JavaScriptMode.unrestricted);
      await c.setNavigationDelegate(
        NavigationDelegate(
          onWebResourceError: (WebResourceError e) {
            // 只报主文档的失败：同目录的图片/字体拉不到也会走这里，
            // 拿它当"游戏打不开"会误导用户。
            if (e.isForMainFrame != true) return;
            if (!mounted) return;
            setState(() => _webError =
                context.tr('游戏页面加载失败：{0}', [e.description]));
          },
        ),
      );
      await c.loadFile(widget.htmlPath);
      if (!mounted) return;
      setState(() => _web = c);
    } catch (e) {
      if (!mounted) return;
      setState(() => _webError = '$e');
    }
  }

  Future<void> _save() async {
    final at = DateTime.now();
    final md = buildRunRecordMarkdown(
      fileName: widget.fileName,
      filePath: widget.htmlPath,
      checks: <GameRunCheck>[
        for (var i = 0; i < kGameRunQuestions.length; i += 1)
          GameRunCheck(question: kGameRunQuestions[i], ok: _checks[i]),
      ],
      notes: _notes.text,
      at: at,
    );
    // 记录**与游戏放在同一个目录**（那是它的工作区），文件名带时间戳。
    final dir = File(widget.htmlPath).parent.path;
    final out = File('$dir/${runRecordFileName(widget.fileName, at)}');
    try {
      await out.parent.create(recursive: true);
      // 同步写：与仓库里其它"落盘"一致（异步写在这类路径上曾出现"静默不执行"）。
      out.writeAsStringSync(md, flush: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('保存失败：{0}', ['$e']))),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _saved = true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.tr('已保存到 {0}\n把这份记录发给模型，它就能接着做 QA。',
            [out.path])),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(DshMetrics.radius(DshMetrics.controlRadius));
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(context.tr('运行：{0}', [widget.fileName])),
        actions: <Widget>[
          IconButton(
            tooltip: context.tr('展开/收起运行记录'),
            icon: Icon(_panelOpen ? Icons.expand_more : Icons.expand_less),
            onPressed: () => setState(() => _panelOpen = !_panelOpen),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: _webError != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_webError!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70, fontSize: 12.5, height: 1.6)),
                    ),
                  )
                : (_web == null
                    ? const Center(child: CircularProgressIndicator())
                    : WebViewWidget(controller: _web!)),
          ),
          if (_panelOpen)
            Container(
              width: double.infinity,
              color: DshColors.bg,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(context.tr('运行记录（对照 game-qa 的验收口径逐项确认）'),
                      style: TextStyle(
                          color: DshColors.text,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    context.tr('本机**不能**自动截 WebView 的图（Android 上它是平台视图，'
                        '截出来常常是空白），所以这里由你玩过之后逐项勾选 —— 这份记录就是证据。'),
                    style: TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.45),
                  ),
                  const SizedBox(height: 6),
                  for (var i = 0; i < kGameRunQuestions.length; i += 1)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      value: _checks[i],
                      onChanged: (v) => setState(() => _checks[i] = v ?? false),
                      title: Text(context.tr(kGameRunQuestions[i]),
                          style: TextStyle(color: DshColors.textDim, fontSize: 12.5)),
                    ),
                  TextField(
                    controller: _notes,
                    maxLines: 3,
                    style: TextStyle(color: DshColors.text, fontSize: 12.5),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: context.tr('备注：卡在哪一步、哪里别扭、想改什么'),
                      hintStyle: TextStyle(color: DshColors.textFaint, fontSize: 12),
                      border: OutlineInputBorder(borderRadius: radius),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _save,
                      icon: Icon(_saved ? Icons.check : Icons.save_outlined, size: 16),
                      label: Text(context.tr('保存运行记录到工作区')),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
