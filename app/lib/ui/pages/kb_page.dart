/// 「知识库」——给本地模型查的**离线资料**（下载 / 从手机导入 / 删除）。
///
/// ## 这一页现在做到哪一步（如实说）
///
/// ✅ 已经能用：看到清单、**下载**（多源 + 断点续传 + 进度 + 取消）、
/// **从手机导入**、**建索引**、删除。
///
/// ⚠️ **没有随包样例**（用户 2026-10-09 决定：样本库不要内置）：原先随包的
/// 400 条样例已删除，装完 App 必须先下载或从手机导入才有东西可用。
/// 代码里 `bundled` 那条路保留着 —— 老版本装过样例的用户，其登记表里
/// `source` 仍是 `bundled`，界面要认得出；将来若放回**人工筛过**的样例也能直接用。
/// （删掉的原因见 `docs/KB-COMPLIANCE-2026-10-09.md`：逐条通读那 400 条
/// 找出 5 条不宜预置的内容，而关键词扫描对它们全部漏判。）
///
/// ✅ **检索已接通**（0.56 起）：建过索引的包，在「本地对话」提问时会自动检索，
/// 命中的段落折进那一轮请求（每包最多 2 段、全局最多 3 段），
/// 端到端证据见 `test/kb_local_chat_e2e_test.dart`。
/// 口径：App 负责"把资料送到引擎手里"，**不保证模型照资料回答**。
///
/// ⏳ 还没接：**切块 + 建检索索引**、以及在「本地对话」里提问时自动去查。
/// 这两步做完，知识库才真正开始影响模型的回答。界面上会明写这一点，
/// 不让用户以为"装了知识库模型就变聪明了"。
///
/// ## 为什么知识库和模型分开放
///
/// 模型是"算力"，资料是"知识"：一个 524 MB 的百科和 2.4 GB 的模型是两类东西，
/// 它们的下载口径、校验方式、清理策略都不同（见 `kb_store.dart`）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../i18n/dsh_i18n.dart';
import '../../local/dsh_runtime.dart';
import '../../local/kb_index.dart';
import '../../local/kb_manifest.dart';
import '../../local/kb_store.dart';
import '../theme/dsh_tokens.dart';
import '../widgets/common.dart';
import '../widgets/dsh_panel.dart';

class KbPage extends StatefulWidget {
  const KbPage({super.key, required this.dshHome});

  /// DSH_HOME（`.../files/dshhome`）—— 知识库落在 `<DSH_HOME>/kb/`。
  final String dshHome;

  /// 「可下载」区要不要显示那条**第三方语料提示**。
  ///
  /// 只在**还有需要联网下载的包**时才提示：随包样例（bundled）是我们自己随 APK
  /// 发出去的，对它喊"第三方语料、未经我们审查"是假警报，会让用户不敢用。
  /// （现在清单里已经**没有**随包样例了，所以正常状态下这条提示都会显示；
  /// 判断逻辑仍按包逐个判，将来若放回样例也自动正确。）
  ///
  /// 抽成静态函数是为了能在单测里直接钉住这个条件 —— 走界面测的话，
  /// `KbStore.list()` 里有真实文件 I/O，而 `testWidgets` 的 fake-async 区里
  /// 真实 I/O 不会完成，`pumpAndSettle` 会一直等到 10 分钟超时。
  @visibleForTesting
  static bool needsDownloadNotice(List<KbPack> notInstalled) =>
      notInstalled.any((KbPack p) => !p.bundled);

  @override
  State<KbPage> createState() => _KbPageState();
}

class _KbPageState extends State<KbPage> {
  KbManifest _manifest = KbManifest.empty;
  List<KbInstalled> _installed = const <KbInstalled>[];
  bool _loading = true;
  String? _error;

  /// 正在下载的那一包（同一时刻只允许一个：手机带宽有限，并发只会都变慢）。
  String? _downloadingId;
  KbDownloadProgress? _progress;
  KbCancelToken? _cancel;

  /// 正在建索引的那一包 + 进度（0~1）。
  String? _indexingId;
  double _indexProgress = 0;
  bool _indexCancel = false;

  /// 每包已有的索引元信息（没建就没有这条）。
  final Map<String, KbIndexMeta> _indexMeta = <String, KbIndexMeta>{};

  bool _importing = false;
  int _importDone = 0;
  int _importTotal = 0;

  KbStore get _store => KbStore(dshHome: widget.dshHome);

  @override
  void initState() {
    super.initState();
    DshHost.bindImportProgress((done, total, _) {
      if (!mounted) return;
      setState(() {
        _importDone = done;
        _importTotal = total;
      });
    });
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await rootBundle.loadString('assets/kb/kb_manifest.json');
      final installed = await _store.list();
      final metas = <String, KbIndexMeta>{};
      for (final kb in installed) {
        final m = await readIndexMeta(_store.dirOf(kb.id));
        if (m != null) metas[kb.id] = m;
      }
      if (!mounted) return;
      setState(() {
        _manifest = KbManifest.parse(raw);
        _installed = installed;
        _indexMeta
          ..clear()
          ..addAll(metas);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _installBundled(KbPack pack) async {
    try {
      final data = await rootBundle.load('assets/kb/${pack.fileName}');
      await _store.installBundled(pack,
          read: () async => data.buffer.asUint8List());
      await _reload();
    } catch (e) {
      _toast('导入失败：{0}', ['$e']);
    }
  }

  Future<void> _reload() async {
    final installed = await _store.list();
    final metas = <String, KbIndexMeta>{};
    for (final kb in installed) {
      final m = await readIndexMeta(_store.dirOf(kb.id));
      if (m != null) metas[kb.id] = m;
    }
    if (!mounted) return;
    setState(() {
      _installed = installed;
      _indexMeta
        ..clear()
        ..addAll(metas);
    });
  }

  /// 给一包建检索索引（流式，边读边写 —— 几百 MB 的包也不会把内存撑爆）。
  Future<void> _buildIndex(KbInstalled kb) async {
    if (_indexingId != null) return;
    setState(() {
      _indexingId = kb.id;
      _indexProgress = 0;
      _indexCancel = false;
    });
    try {
      final r = await KbIndexer.build(
        sourcePath: kb.path,
        outDir: _store.dirOf(kb.id),
        isCancelled: () => _indexCancel,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _indexProgress = p);
        },
      );
      await _reload();
      if (!mounted) return;
      _toast(r.cancelled
          ? '建索引已取消（可以重新建，会从头开始）'
          : '索引建好了：{0} 段', r.cancelled ? null : ['${r.chunks}']);
    } catch (e) {
      _toast('建索引失败：{0}', ['$e']);
    } finally {
      if (mounted) setState(() => _indexingId = null);
    }
  }

  Future<void> _download(KbPack pack) async {
    if (_downloadingId != null) return;
    final token = KbCancelToken();
    setState(() {
      _downloadingId = pack.id;
      _progress = null;
      _cancel = token;
    });
    try {
      final downloader = KbDownloader(store: _store);
      await downloader.download(
        pack,
        cancel: token,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _progress = p);
        },
      );
      await _reload();
      _toast('已下载：{0}', [pack.name]);
    } catch (e) {
      if (!mounted) return;
      // 取消不是错误，别用报错的口气说。
      if (token.cancelled) {
        _toast('已取消（已下的部分保留，下次接着下）');
      } else {
        _toast('下载失败：{0}', ['$e']);
      }
    } finally {
      if (mounted) {
        setState(() {
          _downloadingId = null;
          _progress = null;
          _cancel = null;
        });
      }
    }
  }

  Future<void> _delete(KbInstalled kb) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DshColors.surfaceStrong,
        content: Text(context.tr('确定删除「{0}」吗？', [kb.name]),
            style: TextStyle(color: DshColors.text, fontSize: 14)),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(context.tr('取消'))),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(context.tr('删除'))),
        ],
      ),
    );
    if (ok != true) return;
    await _store.delete(kb.id);
    await _reload();
  }

  /// 从手机导入：走系统文件选择器（原生复制进 kb/ 目录），再把每个文件登记成一包。
  Future<void> _import() async {
    if (_importing || _downloadingId != null) return;
    setState(() {
      _importing = true;
      _importDone = 0;
      _importTotal = 0;
    });
    try {
      final raw = await DshHost.importModelFiles(
          targetDir: _store.dir, expected: const <Map<String, dynamic>>[]);
      if (raw == null) {
        _toast('没有选择文件');
        return;
      }
      var n = 0;
      var dupSkipped = 0;
      for (final item in raw) {
        if (item['ok'] != true) continue;
        final path = (item['path'] as String?) ?? '';
        final name = (item['file'] as String?) ?? '';
        if (path.isEmpty || name.isEmpty) continue;
        final src = File(path);
        if (!src.existsSync()) continue;

        // **内容完全相同就不重复导入**（按原生算好的 sha256）。
        // 不做这一步的后果：同一个文件导两次 = 两包，检索多占名额，
        // 用户还会以为导进了两份不同的东西。
        final sha = ((item['sha256'] as String?) ?? '').trim();
        final dup = _store.findBySha(_installed, sha);
        if (dup != null) {
          dupSkipped++;
          try {
            await src.delete(); // 原生已把它复制进 kb/ 根目录，重复了就别留着
          } catch (_) {}
          continue;
        }
        // 一包一个目录：`kb/<id>/<原文件名>`。
        //
        // ⚠️ **同名再导入不能覆盖已有的那一包**（同名文件很常见：两个都叫
        //    `笔记.json`）。以前这里直接复用 id → 第二次导入会把第一次的**悄悄顶掉**。
        //    现在遇到目录已存在就加序号，两包并存（界面上名字一样，但各是各的）。
        var id = _idFromFileName(name);
        var suffix = 1;
        while (Directory(_store.dirOf(id)).existsSync()) {
          suffix++;
          id = '${_idFromFileName(name)}_$suffix';
        }
        final d = Directory(_store.dirOf(id));
        if (!d.existsSync()) await d.create(recursive: true);
        final dst = File('${d.path}/$name');
        if (src.path != dst.path) {
          if (dst.existsSync()) await dst.delete();
          await src.rename(dst.path);
        }
        await _store.register(
          id: id,
          name: name,
          fileName: name,
          bytes: (item['bytes'] as num?)?.toInt() ?? await dst.length(),
          sha256: sha,
          // 导入的文件还没统计条目数（等建索引时一起算），也**不知道许可**——
          // 界面会显示“未知”，由用户自己确认来源是否可用。
          entries: 0,
          license: '',
          source: 'import',
        );
        n++;
      }
      await _reload();
      if (n == 0 && dupSkipped > 0) {
        _toast('这些文件和已有的知识库内容完全相同，已跳过 {0} 个', ['$dupSkipped']);
      } else if (n == 0) {
        _toast('没有文件导入成功');
      } else if (dupSkipped > 0) {
        _toast('已导入 {0} 个文件（跳过重复 {1} 个）', ['$n', '$dupSkipped']);
      } else {
        _toast('已导入 {0} 个文件', ['$n']);
      }
    } catch (e) {
      _toast('导入失败：{0}', ['$e']);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  static String _idFromFileName(String fileName) {
    final base = fileName.replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), '');
    final safe = base.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
    return 'imported_${safe.isEmpty ? DateTime.now().millisecondsSinceEpoch : safe}';
  }

  /// 弹一条提示。
  ///
  /// 刻意**只收 i18n 的 key + 参数**，不收已经拼好的字符串：调用点大多在 `await`
  /// 之后，在那里用 `context.tr(...)` 会踩 `use_build_context_synchronously`；
  /// 把翻译推迟到这里（先查 `mounted`）既消掉了告警，也更安全。
  void _toast(String key, [List<String>? args]) {
    if (!mounted) return;
    final msg = args == null ? context.tr(key) : context.tr(key, args);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  static String _fmtBytes(int bytes) {
    if (bytes >= 1073741824) {
      return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DshColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            DshPageHeader(
              title: context.tr('知识库'),
              subtitle: context.tr('给本地模型查的离线资料'),
              trailing: IconButton(
                onPressed: _loading ? null : _load,
                tooltip: context.tr('重新载入'),
                icon: Icon(Icons.refresh,
                    size: 20,
                    color: _loading ? DshColors.textFaint : DshColors.textDim),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
                      children: <Widget>[
                        _intro(context),
                        if (_error != null) _errorBox(context, _error!),
                        _installedSection(context),
                        _availableSection(context),
                        _importSection(context),
                        _nextStepNote(context),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _intro(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          context.tr('知识库是给本地模型查的离线资料 —— 查到的片段会折进'
              '「本地对话」那一轮的问题里，所以它不联网、不花额度。'),
          style: TextStyle(
              color: DshColors.textFaint, fontSize: 10.5, height: 1.5),
        ),
      );

  Widget _errorBox(BuildContext context, String message) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: DshColors.surface,
          borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
          border: Border.all(color: DshColors.err),
        ),
        child: Text(message,
            style: TextStyle(color: DshColors.err, fontSize: 11.5, height: 1.5)),
      );

  Widget _installedSection(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(context.tr('已装知识库'),
              style: TextStyle(
                  color: DshColors.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (_installed.isEmpty)
            Text(
              context.tr('还没有装任何知识库：可以下载下面列出的，或从手机导入。'),
              style: TextStyle(
                  color: DshColors.textFaint, fontSize: 11.5, height: 1.5),
            )
          else
            for (final kb in _installed) _installedTile(context, kb),
          const SizedBox(height: 14),
        ],
      );

  Widget _installedTile(BuildContext context, KbInstalled kb) {
    final sourceLabel = switch (kb.source) {
      'bundled' => context.tr('随包样例'),
      'download' => context.tr('下载'),
      _ => context.tr('导入'),
    };
    final meta = <String>[
      _fmtBytes(kb.bytes),
      kb.entries > 0
          ? context.tr('{0} 条', ['${kb.entries}'])
          : context.tr('条目数未知'),
      sourceLabel,
      if (kb.license.trim().isNotEmpty)
        context.tr('许可：{0}', [kb.license])
      else
        context.tr('许可未知（请自行确认来源）'),
    ];
    return DshGlassCard(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(kb.name,
                    style: TextStyle(color: DshColors.text, fontSize: 13),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Text(meta.join(' · '),
                    style: TextStyle(
                        color: DshColors.textFaint, fontSize: 10.5, height: 1.4)),
                const SizedBox(height: 6),
                _enabledRow(context, kb),
                const SizedBox(height: 6),
                _indexRow(context, kb),
              ],
            ),
          ),
          IconButton(
            onPressed: () => _delete(kb),
            tooltip: context.tr('删除'),
            icon: Icon(Icons.delete_outline,
                size: 18, color: DshColors.textDim),
          ),
        ],
      ),
    );
  }

  /// 「参与检索」开关：装了两包以上时，用户可以只让其中一本参与问答。
  Widget _enabledRow(BuildContext context, KbInstalled kb) {
    return Row(
      children: <Widget>[
        SizedBox(
          height: 24,
          child: Switch(
            value: kb.enabled,
            onChanged: (v) async {
              await _store.setEnabled(kb, v);
              await _reload();
            },
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            kb.enabled
                ? context.tr('参与检索')
                : context.tr('已停用：这本不参与「本地对话」的问答'),
            style: TextStyle(
                color: kb.enabled ? DshColors.textDim : DshColors.textFaint,
                fontSize: 10.5,
                height: 1.4),
          ),
        ),
      ],
    );
  }

  /// 一包资料的**索引状态**：没建 → 给按钮；在建 → 进度条 + 取消；建好 → 显示段数。
  Widget _indexRow(BuildContext context, KbInstalled kb) {
    final meta = _indexMeta[kb.id];
    final busy = _indexingId == kb.id;
    if (busy) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          LinearProgressIndicator(
            value: _indexProgress <= 0 ? null : _indexProgress,
            backgroundColor: DshColors.line,
            color: DshColors.accent,
          ),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  context.tr('正在建索引 {0}%（建完才能被检索）',
                      ['${(_indexProgress * 100).round()}']),
                  style: TextStyle(
                      color: DshColors.textFaint, fontSize: 10.5),
                ),
              ),
              TextButton(
                onPressed: () => setState(() => _indexCancel = true),
                child: Text(context.tr('取消')),
              ),
            ],
          ),
        ],
      );
    }
    if (meta != null) {
      // ⚠️ 用户 2026-10-12：「本地大模型调用知识库是没什么效用的，感觉回答得乱七八糟」。
      //    根因之一是**切片把互不相关的文档合并进同一块**（12 篇并成 2 块，一块里 9 篇），
      //    检索因此基本失效（实测 top-1 命中 1/11；修完 15/16）。
      //
      //    但块的切法在建索引时就烧进 `chunks.bin` 了 —— **升级 App 不会让已有索引变好**。
      //    所以老索引必须在这里如实标出来，并告诉用户点「重建」就解决。
      final legacy = meta.isLegacyChunking;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                legacy ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                size: 13,
                color: legacy ? DshColors.accent3 : DshColors.ok,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  legacy
                      ? context.tr('已建索引：{0} 段 —— 但这是**旧切法**建的，检索会不准',
                          ['${meta.chunks}'])
                      : context.tr('已建索引：{0} 段（可被「本地对话」检索）',
                          ['${meta.chunks}']),
                  style: TextStyle(
                      color: legacy ? DshColors.accent3 : DshColors.ok,
                      fontSize: 10.5,
                      height: 1.4),
                ),
              ),
              TextButton(
                onPressed: _indexingId == null ? () => _buildIndex(kb) : null,
                child: Text(legacy ? context.tr('重建（推荐）') : context.tr('重建')),
              ),
            ],
          ),
          if (legacy)
            Padding(
              padding: const EdgeInsets.only(left: 17, bottom: 4),
              child: Text(
                context.tr('旧切法会把好几篇不相关的文章塞进同一块，模型拿到的就是一大坨'
                    '无关材料 —— 所以答得乱七八糟。点「重建」重新切一次就好（本机完成，不联网）。'),
                style: TextStyle(
                    color: DshColors.textFaint, fontSize: 10.5, height: 1.45),
              ),
            ),
        ],
      );
    }
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            context.tr('还没建索引 —— 不建就只能看，没法被检索。'),
            style: TextStyle(
                color: DshColors.accent3, fontSize: 10.5, height: 1.4),
          ),
        ),
        TextButton(
          onPressed: _indexingId == null ? () => _buildIndex(kb) : null,
          child: Text(context.tr('建立索引')),
        ),
      ],
    );
  }

  Widget _availableSection(BuildContext context) {
    final notInstalled = <KbPack>[
      for (final p in _manifest.packs)
        if (!_store.isInstalled(_installed, p.id)) p,
    ];
    if (notInstalled.isEmpty) return const SizedBox.shrink();
    // 只有真的存在「要联网下载」的包时才提示。随包样例（bundled）是我们自己随包
    // 发出去的东西，不是第三方语料，对它提示是假警报。（清单里现在没有随包样例了，
    // 所以这条提示正常都会显示。）
    final hasDownloadable = KbPage.needsDownloadNotice(notInstalled);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(context.tr('可下载'),
            style: TextStyle(
                color: DshColors.text,
                fontSize: 14,
                fontWeight: FontWeight.w600)),
        // ⚠️ 这条提示是**必须的**，不是装饰（用户 2026-10-09 明确要求）：
        //    下载下来的资料是第三方社区语料，我们只做过关键词统计、**没有逐条审查**。
        //    把它写在按钮上方（而不是藏进「关于」）——用户在点「下载」之前就该看见。
        //    用词刻意保持中性：只说明「过滤不完整、未经我们审查」，不列举任何敏感词。
        if (hasDownloadable) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            // ⚠️ 用户 2026-10-12：「把知识库的中文维基百科字样消除，就写知识库三个字就行」。
            //    这一句里的「（中文维基百科 2023-07 快照）」已去掉 —— 只说
            //    「第三方社区语料」，不再点名是哪一份。
            //    提示本身**必须留着**（2026-10-09 明确要求：下载前就要说清
            //    "过滤不完整、未经我们审查、不代表我们观点"）。
            context.tr('下载的资料是第三方社区语料：'
                '数据集作者做过过滤，但过滤不完整，我们也没有逐条审查过，'
                '内容不代表我们的观点，请自行判断是否适合你的用途。'),
            style: TextStyle(
                color: DshColors.textFaint, fontSize: 10.5, height: 1.5),
          ),
        ],
        const SizedBox(height: 8),
        for (final p in notInstalled) _availableTile(context, p),
        const SizedBox(height: 14),
      ],
    );
  }

  Widget _availableTile(BuildContext context, KbPack pack) {
    final busy = _downloadingId == pack.id;
    final p = _progress;
    return DshGlassCard(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(pack.name,
              style: TextStyle(color: DshColors.text, fontSize: 13)),
          const SizedBox(height: 4),
          Text(
            <String>[
              if (pack.bytes > 0) _fmtBytes(pack.bytes),
              if (pack.entries > 0) context.tr('{0} 条', ['${pack.entries}']),
              context.tr('许可：{0}', [pack.license]),
            ].join(' · '),
            style: TextStyle(
                color: DshColors.textFaint, fontSize: 10.5, height: 1.4),
          ),
          if (pack.note.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(pack.note,
                style: TextStyle(
                    color: DshColors.textFaint, fontSize: 10.5, height: 1.5)),
          ],
          const SizedBox(height: 10),
          if (busy) ...<Widget>[
            LinearProgressIndicator(
              value: p == null || p.total <= 0 ? null : p.ratio,
              backgroundColor: DshColors.line,
              color: DshColors.accent,
            ),
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    p == null
                        ? context.tr('正在连接…')
                        : context.tr('下载中 {0} / {1} · {2}/s', [
                            _fmtBytes(p.received),
                            p.total > 0 ? _fmtBytes(p.total) : '?',
                            _fmtBytes(p.bytesPerSecond.round()),
                          ]),
                    style: TextStyle(
                        color: DshColors.textDim, fontSize: 11, height: 1.4),
                  ),
                ),
                TextButton(
                  onPressed: () => _cancel?.cancel(),
                  child: Text(context.tr('取消')),
                ),
              ],
            ),
          ] else
            Row(
              children: <Widget>[
                if (pack.bundled)
                  OutlinedButton(
                    onPressed: () => _installBundled(pack),
                    child: Text(context.tr('装入样例')),
                  )
                else
                  OutlinedButton(
                    onPressed: _downloadingId == null
                        ? () => _download(pack)
                        : null,
                    child: Text(context.tr('下载')),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _importSection(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(context.tr('从手机导入'),
              style: TextStyle(
                  color: DshColors.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          DshRichText(
            context.tr('支持 JSON / JSONL / TXT（每行一条或整个 JSON 数组都可以）。'
                '导入的资料**许可未知**，请自己确认来源可用。'),
            style: TextStyle(
                color: DshColors.textFaint, fontSize: 10.5, height: 1.5),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _importing || _downloadingId != null ? null : _import,
            icon: const Icon(Icons.folder_open, size: 16),
            label: Text(_importing
                ? context.tr('导入中… {0}/{1}', ['$_importDone', '$_importTotal'])
                : context.tr('选择文件')),
          ),
          const SizedBox(height: 16),
        ],
      );

  Widget _nextStepNote(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: DshColors.surface,
          borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
          border: Border.all(color: DshColors.accent3),
        ),
        child: Text(
          context.tr('说明：装进来之后，在下面点「建索引」，这一包才会被检索。'
              '建好索引的包，在「本地对话」里提问时会**自动查** —— '
              '把最相关的几段资料（每包最多 2 段、总共最多 3 段）一起发给模型。'
              '⚠️ 查到不等于模型一定照它回答；资料没命中时，一句都不会发出去。'),
          style: TextStyle(
              color: DshColors.accent3, fontSize: 11, height: 1.5),
        ),
      );
}
