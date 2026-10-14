import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/library_store.dart';
import '../../i18n/dsh_i18n.dart';
import '../../local/dsh_runtime.dart';
import '../../local/media_service.dart';
import '../theme/dsh_tokens.dart';

/// 「剪辑」：**手上已经有视频之后**的那几刀。
///
/// ## 为什么它和「短剧 / 口播」不是一回事
///
/// 那两条线是**生成**（把图片和配音合成一条片子）；这一页管的是**编辑已有素材**：
/// 剪掉一段、把几段拼起来、把声音抽出来、截一张封面、压小一点好发出去。
/// 手机上这两件事经常同时需要，但以前只有前者。
///
/// ## 为什么不做一个"多轨时间线剪辑器"
///
/// 桌面上的开源剪辑器（如 OpenCut）是"任意多轨 + 实时预览"的形态，它需要一个
/// 真正的媒体内核 —— 连 OpenCut 自己的重写版第一步也是**发一个 ffmpeg 二进制**
/// （见其 `crates/media/setup/ffmpeg.json`）。手机上做那个形态，要么做不成、
/// 要么做成一个很差的仿制品。所以这里只做**能真跑、能验证**的那几刀：
/// 除「压小」和「精确剪」外全部走 `-c copy`（不重编码），
/// 一段 10 分钟的视频剪一刀通常**几秒**就完事，也不掉画质。
///
/// ## 两条如实写在界面上的边界
///
/// * `-c copy` **不对齐到你要的那一帧**，而是对齐到最近的关键帧（可能差零点几秒
///   到一两秒）；要精确就勾「精确剪（重编码）」，手机上会慢很多。
/// * 拼接要求几段的画面/声音格式一致；不一致时**不会硬拼**（硬拼的成品画面会中途
///   变形，看着像成功），而是明确告诉你要勾「参数不一致时重新编码」。
class ClipPage extends StatefulWidget {
  const ClipPage({super.key, required this.runtime});

  final DshRuntime runtime;

  /// 五刀。
  ///
  /// ⚠️ 这里的字面量是**数据表里的中文**，i18n 扫描器看不见 ——
  /// 靠文件底部 `clipI18nAnchors()` 逐字复写一遍才收得到（同 `ai_role_page.dart`）。
  static const List<({String id, String label, String hint})> ops =
      <({String id, String label, String hint})>[
    (id: 'trim', label: '剪一段', hint: '掐头去尾，只留中间那一段（默认不重编码，几秒就完）'),
    (id: 'concat', label: '拼接', hint: '把几段按你排的顺序接成一条（要求参数一致，否则要勾重编码）'),
    (id: 'audio', label: '抽音频', hint: '只把声音拿出来存成 .m4a（声音原样搬，不掉音质）'),
    (id: 'frame', label: '抽一帧', hint: '在某一秒截一张图当封面（.jpg）'),
    (id: 'compress', label: '压小', hint: '重新编码压小体积，方便发出去（这一项慢，按片长等）'),
  ];

  @override
  State<ClipPage> createState() => _ClipPageState();
}

class _ClipPageState extends State<ClipPage> {
  late final MediaService _service = MediaService(widget.runtime);

  String _op = 'trim';
  final List<String> _inputs = <String>[];

  final TextEditingController _start = TextEditingController();
  final TextEditingController _end = TextEditingController();
  final TextEditingController _at = TextEditingController();
  final TextEditingController _crf = TextEditingController(text: '28');
  final TextEditingController _maxWidth = TextEditingController(text: '1280');

  bool _exact = false;
  bool _reencode = false;
  bool _running = false;
  String _lastLine = '';
  MediaResult? _result;
  Process? _proc;

  @override
  void dispose() {
    _proc?.kill();
    _start.dispose();
    _end.dispose();
    _at.dispose();
    _crf.dispose();
    _maxWidth.dispose();
    super.dispose();
  }

  bool get _needsMany => _op == 'concat';
  int get _minInputs => _needsMany ? 2 : 1;
  bool get _ready => _inputs.length >= _minInputs && !_running;

  void _pick() {
    // 只让选**视频**：这一页的五刀里只有「抽一帧」的输入是视频（产出才是图），
    // 所以输入侧不需要列图片，列了反而让人以为能拿图片做剪辑。
    _showPicker(context);
  }

  Future<void> _showPicker(BuildContext context) async {
    // ⚠️ **不能用「只扫默认工作区」那一版**（2026-10-12 真机反馈第 5 条：
    //    资料库里明明有东西，点「从资料库选」却说"工作区里没找到视频"）。
    //    原因：用户看到的"资料库/作品"里那批视频，多数是**生成出来的产物**，
    //    它们落在 `media/video/`（还有一部分在用户自建的工作区 `workspaces/` 下），
    //    而旧实现只 `scan(默认工作区)` → 一个都找不到。
    //    现在改成问**同一个作品库**（`MediaService.listItems()`：media/{image,video}
    //    + workspace + workspaces 四处都扫），"能看到的"与"能选的"就一致了。
    final items = _service.listItems();
    final videos = items.where((m) => m.kind == MediaKind.video).toList();
    videos.sort((a, b) => b.modified.compareTo(a.modified));
    if (!mounted) return;

    if (!context.mounted) return;
    final picked = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => _PickerDialog(
        videos: videos,
        multi: _needsMany,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (_needsMany) {
        // 拼接：**追加**（这样可以在不同目录里分几次挑，顺序就是挑的顺序）
        for (final p in picked) {
          if (!_inputs.contains(p)) _inputs.add(p);
        }
      } else {
        _inputs
          ..clear()
          ..addAll(picked.take(1));
      }
      _result = null;
    });
  }

  /// 产物路径。
  ///
  /// ⚠️ 与其它几条线**同一条规矩**：产物落进 `media/{image,video}`，
  /// 所以「作品」页与「资料库」都自动看得到（不用我们再去登记一遍）。
  /// 抽帧的产物是**图**，就进图片目录 —— 放进视频目录会让人在"作品"里看到
  /// 一张混在视频里的图。
  String _dest(String prefix, String ext, {bool image = false}) {
    final dir = image ? _service.imageDir : _service.videoDir;
    return '${dir.path}/${MediaService.defaultName(prefix, ext)}';
  }

  /// 按当前操作拼 `clip-video.mjs` 的参数（**唯一一份口径**：不在 Dart 里二次转译）。
  List<String> _args() {
    switch (_op) {
      case 'trim':
        return <String>[
          'trim', _inputs.first, _dest('clip-trim', 'mp4'),
          '--start', _start.text.trim().isEmpty ? '0' : _start.text.trim(),
          if (_end.text.trim().isNotEmpty) ...<String>['--end', _end.text.trim()],
          if (_exact) '--exact',
        ];
      case 'concat':
        return <String>[
          'concat', _dest('clip-cat', 'mp4'), ..._inputs,
          if (_reencode) '--reencode',
        ];
      case 'audio':
        return <String>['audio', _inputs.first, _dest('clip-audio', 'm4a')];
      case 'frame':
        return <String>[
          'frame', _inputs.first, _dest('clip-frame', 'jpg', image: true),
          if (_at.text.trim().isNotEmpty) ...<String>['--at', _at.text.trim()],
        ];
      case 'compress':
        return <String>[
          'compress', _inputs.first, _dest('clip-small', 'mp4'),
          '--max-width', _maxWidth.text.trim().isEmpty ? '1280' : _maxWidth.text.trim(),
          '--crf', _crf.text.trim().isEmpty ? '28' : _crf.text.trim(),
        ];
      default:
        return <String>[];
    }
  }

  Future<void> _run() async {
    // ⚠️ 必须先建目录：脚本对"输出目录不存在"是**明确报错**的（不猜、不自己造目录），
    //    而 media/video 只在第一次生成时才存在。
    await _service.ensureDirs();
    if (!mounted) return;
    final args = _args();
    if (args.isEmpty) return;
    setState(() {
      _running = true;
      _result = null;
      _lastLine = '';
    });
    final r = await _service.clip(
      args,
      onLog: (line) {
        final t = line.trim();
        if (t.isNotEmpty && mounted) setState(() => _lastLine = t);
      },
      onProcess: (p) => _proc = p,
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      _proc = null;
      _result = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    final opMeta = ClipPage.ops.firstWhere((o) => o.id == _op);
    return Scaffold(
      backgroundColor: DshColors.bg,
      appBar: AppBar(title: Text(context.tr('剪辑'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
        children: <Widget>[
          _card(
            context,
            title: context.tr('这是什么'),
            child: Text(
              context.tr('手上已经有视频之后的几刀：剪一段、把几段拼起来、把声音抽出来、'
                  '截一张封面、压小一点好发出去。**全部在本机跑**（用随包的 ffmpeg），'
                  '不联网、不花任何额度。除了「压小」和「精确剪」要重新编码，'
                  '其余几刀都是几秒就完事、也不掉画质。'),
              style: TextStyle(color: DshColors.textDim, fontSize: 12, height: 1.6),
            ),
          ),
          _card(
            context,
            title: context.tr('选一刀'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final o in ClipPage.ops)
                      ChoiceChip(
                        selected: _op == o.id,
                        label: Text(context.tr(o.label)),
                        onSelected: _running
                            ? null
                            : (_) => setState(() {
                                  _op = o.id;
                                  _inputs.clear();
                                  _result = null;
                                }),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(context.tr(opMeta.hint),
                    style: TextStyle(color: DshColors.textFaint, fontSize: 11.5, height: 1.5)),
              ],
            ),
          ),
          _inputCard(context),
          _paramsCard(context),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  onPressed: _ready ? _run : null,
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: Text(_running
                      ? context.tr('正在处理…')
                      : context.tr('开始（本机执行，不联网）')),
                ),
              ),
              if (_running) ...<Widget>[
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => _proc?.kill(),
                  child: Text(context.tr('停止')),
                ),
              ],
            ],
          ),
          if (_running && _lastLine.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(_lastLine,
                style: TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.4)),
          ],
          if (_result != null) ...<Widget>[
            const SizedBox(height: 10),
            _resultCard(context, _result!),
          ],
          const SizedBox(height: 6),
          _card(
            context,
            title: context.tr('边界（如实说）'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final t in <String>[
                  // ⚠️ 每一条都写成 `context.tr('字面量')`（而不是先塞进一个字符串数组、
                  //    再 `Text(t)`）—— i18n 扫描器只认"字面量紧跟 tr(" 这种写法，
                  //    先塞进数组它就**看不见**：切到英/日/韩会静默留中文，
                  //    而 `check-tables.mjs` 照样报 0 漂移（同类先例见本页底部锚点注释）。
                  context.tr('不勾「精确剪」时走 `-c copy`（不重编码）：剪出来的位置会**对齐到最近的关键帧**，'
                      '可能和你填的差零点几秒到一两秒 —— 换来的是几秒出结果、画质一点不掉。'),
                  context.tr('拼接**要求几段的画面/声音格式一致**（同一次拍摄的通常就行）。不一致时不会硬拼'
                      '（硬拼的成品画面会中途变形），而是让你勾「参数不一致时重新编码」——那就慢了。'),
                  context.tr('压小要重新编码，按片长等：手机上处理 1 分钟 1080p 大约要几十秒到几分钟。'),
                  context.tr('产物会出现在「资料库」里（视频/音频进作品的视频目录，截图进图片目录），'
                      '原始素材**不会被改动**。'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('· $t',
                        style: TextStyle(
                            color: DshColors.textFaint, fontSize: 11.5, height: 1.5)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _inputCard(BuildContext context) {
    return _card(
      context,
      title: _needsMany ? context.tr('选要拼的视频（按顺序）') : context.tr('选一个视频'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (var i = 0; i < _inputs.length; i += 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: <Widget>[
                  if (_needsMany)
                    Text('${i + 1}. ',
                        style: TextStyle(color: DshColors.textFaint, fontSize: 11.5)),
                  Expanded(
                    child: Text(
                      _inputs[i].split('/').last,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: DshColors.text, fontSize: 12),
                    ),
                  ),
                  IconButton(
                    tooltip: context.tr('移除'),
                    icon: const Icon(Icons.close, size: 14),
                    onPressed: _running
                        ? null
                        : () => setState(() => _inputs.removeAt(i)),
                  ),
                ],
              ),
            ),
          if (_inputs.isEmpty)
            Text(context.tr('还没选文件。点下面「从资料库选」—— 只列工作区里的视频。'),
                style: TextStyle(color: DshColors.textFaint, fontSize: 11.5, height: 1.5)),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: _running ? null : _pick,
                icon: const Icon(Icons.video_library_outlined, size: 15),
                label: Text(context.tr('从资料库选')),
              ),
              if (_needsMany && _inputs.length >= 2) ...<Widget>[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _running
                      ? null
                      : () => setState(() {
                            final first = _inputs.removeAt(0);
                            _inputs.add(first);
                          }),
                  child: Text(context.tr('换个顺序')),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _paramsCard(BuildContext context) {
    return _card(
      context,
      title: context.tr('参数'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (_op == 'trim') ...<Widget>[
            Row(
              children: <Widget>[
                Expanded(child: _field(context, _start, context.tr('从第几秒开始（如 0:05）'))),
                const SizedBox(width: 8),
                Expanded(child: _field(context, _end, context.tr('到第几秒结束（留空=到结尾）'))),
              ],
            ),
            _check(
              context,
              value: _exact,
              onChanged: (v) => setState(() => _exact = v),
              title: context.tr('精确剪（重新编码，慢）'),
              subtitle: context.tr('不勾就是对齐关键帧、几乎瞬间完成'),
            ),
          ],
          if (_op == 'concat')
            _check(
              context,
              value: _reencode,
              onChanged: (v) => setState(() => _reencode = v),
              title: context.tr('参数不一致时重新编码（慢）'),
              subtitle: context.tr('几段不是同一种格式时勾上：先把每段统一成第一段的规格再拼'),
            ),
          if (_op == 'frame')
            _field(context, _at, context.tr('截第几秒（如 0:03，留空=开头）')),
          if (_op == 'compress') ...<Widget>[
            Row(
              children: <Widget>[
                Expanded(child: _field(context, _maxWidth, context.tr('最大宽度（像素）'))),
                const SizedBox(width: 8),
                Expanded(child: _field(context, _crf, context.tr('清晰度 CRF（越大越糊越小）'))),
              ],
            ),
            const SizedBox(height: 4),
            Text(context.tr('CRF 20 左右画质很好、26~30 是"发出去够用"那一档。原来的宽度没超上限就不放大，只降码率。'),
                style: TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.5)),
          ],
          if (_op == 'audio')
            Text(context.tr('声音是**原样搬过去**的（不重新编码），存成 .m4a —— 安卓/苹果/电脑都能放。'),
                style: TextStyle(color: DshColors.textFaint, fontSize: 11.5, height: 1.5)),
        ],
      ),
    );
  }

  Widget _resultCard(BuildContext context, MediaResult r) {
    final path = r.file ?? '';
    final name = path.isEmpty ? '' : path.split('/').last;
    return _card(
      context,
      title: r.ok ? context.tr('做好了') : context.tr('没做成'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (r.ok) ...<Widget>[
            Text(name, style: TextStyle(color: DshColors.text, fontSize: 12.5)),
            const SizedBox(height: 3),
            Text(
              r.bytes == null ? path : '${humanSize(r.bytes!)} · $path',
              style: TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.5),
            ),
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: path));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(context.tr('已复制路径'))));
                  },
                  icon: const Icon(Icons.copy, size: 15),
                  label: Text(context.tr('复制路径')),
                ),
              ],
            ),
          ] else ...<Widget>[
            Text(
              // 脚本里的错误都写成「错误：…」，[MediaResult.error] 已经把最后一条挑出来了。
              r.error ?? context.tr('没有拿到失败原因，下面是脚本的原话：'),
              style: TextStyle(color: DshColors.err, fontSize: 12, height: 1.6),
            ),
          ],
          if (r.log.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: Text(context.tr('脚本原话（出问题时能看出来卡在哪）'),
                    style: TextStyle(color: DshColors.textFaint, fontSize: 11.5)),
                children: <Widget>[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: DshColors.bgSoft,
                      borderRadius: BorderRadius.circular(
                          DshMetrics.radius(DshMetrics.controlRadius)),
                    ),
                    child: SelectableText(
                      r.log.trim(),
                      style: TextStyle(
                          color: DshColors.textDim,
                          fontSize: 10.5,
                          height: 1.45,
                          fontFamily: 'monospace'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 一个勾选项。
  ///
  /// ⚠️ 这里**不用 `CheckboxListTile`**：它本质是 ListTile，而 ListTile 会把背景与点击
  /// 水波画在最近的 Material 上；我们这个卡片是带底色的 `Container`（DecoratedBox），
  /// 于是 Flutter 会**断言**「ListTile background color or ink splashes may be invisible」
  /// —— 也就是说点击反馈会被卡片底色盖住（widget 测试直接抓到了这条）。
  /// 自己拼一个 Checkbox + 文字，就没有这个问题，也更好控制行距。
  Widget _check(
    BuildContext context, {
    required bool value,
    required void Function(bool) onChanged,
    required String title,
    required String subtitle,
  }) {
    return InkWell(
      onTap: _running ? null : () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Checkbox(
              value: value,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: _running ? null : (v) => onChanged(v ?? false),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: TextStyle(color: DshColors.text, fontSize: 12.5)),
                  const SizedBox(height: 1),
                  Text(subtitle,
                      style: TextStyle(
                          color: DshColors.textFaint, fontSize: 11, height: 1.4)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(BuildContext context, TextEditingController c, String label) {
    return TextField(
      controller: c,
      enabled: !_running,
      style: TextStyle(color: DshColors.text, fontSize: 12.5),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: DshColors.textFaint, fontSize: 11.5),
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _card(BuildContext context, {required String title, required Widget child}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DshColors.surfaceStrong,
        borderRadius:
            BorderRadius.circular(DshMetrics.radius(DshMetrics.cardRadius)),
        border: Border.all(color: DshColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title,
              style: TextStyle(
                  color: DshColors.text, fontSize: 13.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// 从资料库里挑视频。`multi` 为真时**多选**（拼接要按顺序挑好几段）。
class _PickerDialog extends StatefulWidget {
  const _PickerDialog({
    required this.videos,
    required this.multi,
  });

  /// 视频候选 —— 来自**作品库**（`MediaService.listItems()`），不是"只扫工作区"。
  /// 2026-10-12 真机反馈第 5 条：生成出来的视频落在 `media/video/`，
  /// 只扫工作区会一个都看不到，用户看到的是"资料库明明有东西却说没找到视频"。
  final List<MediaItem> videos;
  final bool multi;

  @override
  State<_PickerDialog> createState() => _PickerDialogState();
}

class _PickerDialogState extends State<_PickerDialog> {
  final List<String> _selected = <String>[];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.tr('从资料库选视频')),
      content: SizedBox(
        width: double.maxFinite,
        child: widget.videos.isEmpty
            ? Text(
                context.tr('没有找到可以剪的视频。\n这里列的是「作品」里生成过的视频 + 工作区里的视频；'
                    '两个地方都空的话，先去「创作台 → 生视频」生成一段，或把视频放进工作区。'),
                style: TextStyle(color: DshColors.textDim, fontSize: 12, height: 1.5),
              )
            : ListView.builder(
                shrinkWrap: true,
                itemCount: widget.videos.length,
                itemBuilder: (ctx, i) {
                  final e = widget.videos[i];
                  final selected = _selected.contains(e.path);
                  // ⚠️ 两个 `tr(...)` **必须写在插值外面**：写成
                  //    `Text('${... ? context.tr('作品库') : ...}')` 的话，
                  //    扫描器看不见那两个字面量（它们在 `${}` 里）→ 表里没有 →
                  //    切外语时这两处会静默露中文（这一条 2026-10-12 真踩到）。
                  //
                  // ⚠️ 判据用**真实路径**（`isGeneratedMediaPath`），**不是** `MediaSource`：
                  //    后者说的是"来自影视/来自会话"，而工作区里的文件也是 session ——
                  //    拿它当目录判据会把"会话里生成的视频"标成"工作区"（2026-10-13 自查发现）。
                  final sourceLabel = isGeneratedMediaPath(e.path)
                      ? context.tr('作品库')
                      : context.tr('工作区');
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      selected
                          ? Icons.check_circle
                          : (widget.multi ? Icons.circle_outlined : Icons.play_circle_outline),
                      size: 18,
                      color: selected ? DshColors.accent : DshColors.textFaint,
                    ),
                    title: Text(e.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: DshColors.text, fontSize: 12.5)),
                    subtitle: Text('${e.sizeLabel} · $sourceLabel',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: DshColors.textFaint, fontSize: 11)),
                    onTap: () {
                      setState(() {
                        if (!widget.multi) {
                          _selected
                            ..clear()
                            ..add(e.path);
                          return;
                        }
                        if (selected) {
                          _selected.remove(e.path);
                        } else {
                          _selected.add(e.path);
                        }
                      });
                    },
                  );
                },
              ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.tr('取消')),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(List<String>.of(_selected)),
          child: Text(widget.multi
              ? context.tr('就用这 {0} 段', <Object?>[_selected.length])
              : context.tr('就用它')),
        ),
      ],
    );
  }
}

/// ⚠️ **i18n 扫描器的锚点**（不要删）。
///
/// 上面 [ClipPage.ops] 里的中文是**数据表里的字面量**，界面用 `context.tr(...)` 显示；
/// 而扫描器只认源码里 `tr('字面量')` 这种写法 —— 写在 `const` 记录里的字符串它**看不见**
/// （同 `ai_role_page.dart` 的 `aiRoleI18nAnchors`）。
/// **改了那五个操作的文案，这里要逐字同步**（`test/clip_page_test.dart` 会核对）。
// ignore: unused_element
void clipI18nAnchors() {
  tr('剪一段');
  tr('掐头去尾，只留中间那一段（默认不重编码，几秒就完）');
  tr('拼接');
  tr('把几段按你排的顺序接成一条（要求参数一致，否则要勾重编码）');
  tr('抽音频');
  tr('只把声音拿出来存成 .m4a（声音原样搬，不掉音质）');
  tr('抽一帧');
  tr('在某一秒截一张图当封面（.jpg）');
  tr('压小');
  tr('重新编码压小体积，方便发出去（这一项慢，按片长等）');
}
