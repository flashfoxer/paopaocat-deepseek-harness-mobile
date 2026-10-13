import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../data/agnes_builtin.dart';
import '../data/media_models.dart';
import '../data/relative_time.dart';
import '../state/provider_keys.dart';
import 'dsh_runtime.dart';

/// 一次生成的结局。
class MediaResult {
  const MediaResult({
    required this.ok,
    required this.exitCode,
    required this.log,
    this.file,
    this.bytes,
    this.cancelled = false,
  });

  final bool ok;
  final int exitCode;

  /// 脚本的全部输出（stdout + stderr）—— 出问题时界面要能看到原话。
  final String log;

  /// 成功时的产物**绝对路径**。
  final String? file;
  final int? bytes;

  /// 用户主动取消（不是失败）。
  final bool cancelled;

  /// 给用户看的失败原因：脚本里的错误都写成 `错误：…` 走 stderr，
  /// 这里挑**最后一条**（脚本可能先报几次可恢复的提示，最后才定音）。
  String? get error {
    final lines = log
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    for (final line in lines.reversed) {
      if (line.startsWith('错误：')) return line.substring(3).trim();
    }
    for (final line in lines.reversed) {
      if (line.startsWith('ERR ')) return line.substring(4).trim();
    }
    return lines.isEmpty ? null : lines.last;
  }
}

/// 「影视」的执行层：**直接用随包的 node 跑工具箱脚本**（生图 / 生视频）。
///
/// ## 为什么要 Dart 直接跑，而不是让模型去跑
///
/// 会话里生成图片/视频是"模型调 bash → 跑脚本"，那条路依赖模型理解你的话
/// （要起会话、要等模型决定、还可能理解偏）。「影视」页是**表单式**的：
/// 你填提示词、点按钮，就该直接出结果 —— 所以这里由 Dart 直接拉起同一个脚本。
///
/// 生成能力**完全一致**（同一个 `make-image.mjs` / `make-video.mjs`），
/// 因此也自动继承刚做好的 **429 退避重试 + 多账号 Key 轮换**。
///
/// ## 成功标记是脚本约定的（不要改那两行）
///
/// `[agnes-image] ok file=… bytes=… model=…` / `[agnes-video] ok file=… bytes=… seconds=…`
/// 脚本里那两行写着「⚠ 这一行是 Dart 侧识别的成功标记，格式不要改」——
/// 就是给这里用的。（注意用**非贪婪**匹配：路径里可能有空格，
/// 所以取 `file=` 到 ` bytes=` 之间的全部内容。）
class MediaService {
  MediaService(this.runtime);

  final DshRuntime runtime;

  /// 产物根目录：`<filesDir>/media/{image,video}`。
  ///
  /// ⚠️ 放在这里（而不是 `dshhome/`）有两个原因：① `dshhome` 是 DSH 运行时的
  /// HOME，混进用户媒体会让运行时的目录越来越难认；② 这个目录**已加进
  /// FileProvider 白名单**（`android/app/src/main/res/xml/file_paths.xml`），
  /// 分享/用外部应用打开才走得通。
  Directory get rootDir => Directory('${runtime.filesDir}/media');
  Directory get imageDir => Directory('${rootDir.path}/image');
  Directory get videoDir => Directory('${rootDir.path}/video');

  Future<void> ensureDirs() async {
    if (!imageDir.existsSync()) await imageDir.create(recursive: true);
    if (!videoDir.existsSync()) await videoDir.create(recursive: true);
  }

  /// 默认文件名：时间戳，不用中文（避免个别分享目标对文件名编码处理不好）。
  static String defaultName(String prefix, String ext) {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '$prefix-${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}.$ext';
  }

  /// 生图。成功时 [MediaResult.file] 是新图的绝对路径。
  ///
  /// [refs] 是参考图的**绝对路径**（`--ref`）。
  ///
  /// [size] / [ratio] **由调用方按厂家决定**（影视页从 `MediaVendors.imageOptions`
  /// 取），这里**不做任何换算** —— Agnes 的 `1K/2K` 是档位，别家要的是
  /// `1024x1024` 这类像素值，脚本按 `--provider` 自己翻译成这家的字段。
  /// 空值不发（"这家没有这一档"时不该塞一个空参数给上游）。
  Future<MediaResult> generateImage({
    required String prompt,
    String size = '1K',
    String? ratio,
    List<String> refs = const <String>[],
    String? outPath,
    MediaModelSpec? model,
    void Function(String line)? onLog,
    void Function(Process proc)? onProcess,
  }) async {
    await ensureDirs();
    final dest = outPath ?? '${imageDir.path}/${defaultName('img', 'png')}';
    final args = <String>[prompt, dest];
    if (size.trim().isNotEmpty) args.addAll(<String>['--size', size.trim()]);
    // 显式传模型名：即使 App 的环境变量注入失败，也不会悄悄用回别的模型。
    if (model != null && model.id.trim().isNotEmpty) {
      args.addAll(<String>['--model', model.id.trim()]);
      args.addAll(<String>['--provider', _providerArg(model)]);
    }
    if (ratio != null && ratio.trim().isNotEmpty) {
      args.addAll(<String>['--ratio', ratio.trim()]);
    }
    for (final r in refs) {
      args.addAll(<String>['--ref', r]);
    }
    return _run(
      'make-image.mjs',
      args,
      model: model,
      onLog: onLog,
      onProcess: onProcess,
    );
  }

  /// 生视频。视频默认**要等几分钟**，界面必须如实显示进度。
  ///
  /// [firstFrame] 给了就走 `--mode keyframe`（图生视频）。
  ///
  /// [resolution] / [seconds] / [ratio] 同样**由调用方按厂家决定**
  /// （影视页从 `MediaVendors.videoOptions` 取）：硅基流动没有时长参数、
  /// 豆包 Seedance 不发分辨率 —— 那些情况调用方传空串，这里就**不发那个参数**
  /// （而不是塞一个空值让脚本去猜）。默认 `720P / 5 / 16:9` 与改造前一致。
  Future<MediaResult> generateVideo({
    required String prompt,
    String seconds = '5',
    String ratio = '16:9',
    String resolution = '720P',
    String? firstFrame,
    String? outPath,
    MediaModelSpec? model,
    void Function(String line)? onLog,
    void Function(Process proc)? onProcess,
  }) async {
    await ensureDirs();
    final dest = outPath ?? '${videoDir.path}/${defaultName('vid', 'mp4')}';
    final args = <String>[prompt, dest];
    if (seconds.trim().isNotEmpty) {
      args.addAll(<String>['--seconds', seconds.trim()]);
    }
    if (ratio.trim().isNotEmpty) {
      args.addAll(<String>['--ratio', ratio.trim()]);
    }
    if (resolution.trim().isNotEmpty) {
      args.addAll(<String>['--resolution', resolution.trim()]);
    }
    if (model != null && model.id.trim().isNotEmpty) {
      args.addAll(<String>['--model', model.id.trim()]);
      args.addAll(<String>['--provider', _providerArg(model)]);
    }
    if (firstFrame != null && firstFrame.isNotEmpty) {
      args.addAll(<String>['--mode', 'keyframe', '--first-frame', firstFrame]);
    }
    return _run(
      'make-video.mjs',
      args,
      model: model,
      onLog: onLog,
      onProcess: onProcess,
    );
  }

  /// 传给脚本的 `--provider`：**厂家 id 本身**（脚本按它换请求形状，见
  /// `assets/toolbox/media-vendors.mjs` 的 `VENDORS`）。
  ///
  /// 取不到（用户没填 id）时按 `unknown` 走 —— 脚本那边对 unknown 的处理是
  /// "按 OpenAI 兼容形状试"，比瞎猜一家靠谱。
  static String _providerArg(MediaModelSpec model) {
    final p = model.provider.trim().toLowerCase();
    return p.isEmpty ? 'unknown' : p;
  }

  /// **剪辑**（本机 ffmpeg，不联网、不花额度）：剪一段 / 拼接 / 抽音频 / 抽一帧 / 压小。
  ///
  /// 与 [editImage] 同一类（都是"改手上的东西"，不是"生成新的"），
  /// 与 [narration] 分工明确：那个是**生成**成片，这个是**编辑已有素材**。
  ///
  /// `args` 直接交给 `clip-video.mjs`（`trim` / `concat` / `audio` / `frame` / `compress`
  /// 的动作与参数都由调用方拼好）—— 这样界面与脚本之间只有一份参数口径，
  /// 不在 Dart 里再转译一遍（转译一次就多一处会和脚本跑偏的地方）。
  ///
  /// ⚠️ **不传 `model`**：剪辑全程在本机跑，不需要任何 Key，也就不该去系统安全区
  /// 读凭据（读不到还会在日志里留下痕迹）。
  Future<MediaResult> clip(
    List<String> args, {
    void Function(String line)? onLog,
    void Function(Process proc)? onProcess,
  }) {
    return _run('clip-video.mjs', args, onLog: onLog, onProcess: onProcess);
  }

  /// **修图**（本机 ffmpeg 滤镜，不联网、不花额度）。
  ///
  /// [preset] 见 `assets/toolbox/edit-image.mjs`：none / fresh / cinema / skin / warm / cool；
  /// [strength] 1–100；[delogo] 是 `x:y:w:h`（像素，**由界面按预览框算好**再传，
  /// 保证"用户看到的框"就是"真正被盖住的框"）。
  ///
  /// 产物落 `media/image/`，所以**自动出现在「作品」页**（与生图同一个库）。
  Future<MediaResult> editImage({
    required String source,
    String preset = 'fresh',
    int strength = 60,
    String? delogo,
    String? outPath,
    void Function(String line)? onLog,
    void Function(Process proc)? onProcess,
  }) async {
    await ensureDirs();
    final dest = outPath ?? '${imageDir.path}/${defaultName('edit', 'png')}';
    final args = <String>[
      source,
      dest,
      '--preset',
      preset,
      '--strength',
      '$strength',
    ];
    if (delogo != null && delogo.isNotEmpty) {
      args.addAll(<String>['--delogo', delogo]);
    }
    return _run(
      'edit-image.mjs',
      args,
      onLog: onLog,
      onProcess: onProcess,
    );
  }

  Future<MediaResult> _run(
    String script,
    List<String> args, {
    MediaModelSpec? model,
    void Function(String line)? onLog,
    void Function(Process proc)? onProcess,
  }) async {
    final scriptPath = '${runtime.toolboxDir}/$script';
    if (!File(scriptPath).existsSync()) {
      return MediaResult(
        ok: false,
        exitCode: -1,
        log: '错误：工具箱脚本不在（$scriptPath）—— App 首次启动没能把脚本落盘。',
      );
    }
    final buffer = StringBuffer();
    Process proc;
    try {
      proc = await Process.start(
        runtime.nodeBinary,
        <String>[scriptPath, ...args],
        environment: await _env(model: model),
        // 脚本内部用 resolve() 处理相对路径；我们一律传绝对路径，这里只是给个稳的 cwd。
        workingDirectory: runtime.filesDir,
      );
    } catch (e) {
      return MediaResult(
          ok: false, exitCode: -1, log: '错误：启动 node 失败（$e）');
    }
    onProcess?.call(proc);

    void sink(String line) {
      buffer.writeln(line);
      onLog?.call(line);
    }

    final stdoutDone = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(sink)
        .asFuture<void>();
    final stderrDone = proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(sink)
        .asFuture<void>();

    final code = await proc.exitCode;
    // 等流读完，否则最后那行成功标记可能还没进 buffer。
    await Future.wait<void>(<Future<void>>[stdoutDone, stderrDone]);

    final text = buffer.toString();
    // ⚠️ 这里的标记集合必须与脚本**一一对应**：少一个就会把成功当失败
    //    （脚本那边写着「这一行是 Dart 侧识别的成功标记，格式不要改」）。
    //    `narration` 是口播/短剧的合成器 make-narration.mjs 打的；
    //    `edit-image` 是修图脚本 edit-image.mjs 打的；
    //    `clip` 是剪辑脚本 clip-video.mjs 打的（它的 `file=`/`bytes=` 同样紧跟 `ok `，
    //    只是在末尾多了个 `op=<操作>`）。
    final m = RegExp(r'\[(?:agnes-(?:image|video)|narration|edit-image|clip)\] ok file=(.+?) bytes=(\d+)')
        .firstMatch(text);
    if (code == 0 && m != null) {
      final path = m.group(1)!.trim();
      final bytes = int.tryParse(m.group(2)!);
      debugPrint('[dsh-media] 生成成功：$path（$bytes 字节）');
      return MediaResult(
        ok: true,
        exitCode: 0,
        log: text,
        file: path,
        bytes: bytes,
      );
    }
    // 退出码 0 但没有标记 = 脚本被改了却没同步这里，必须当作失败（绝不假装成功）。
    final why = code == 0
        ? '错误：脚本退出码是 0，但没有输出成功标记（脚本与 App 的约定被改坏了）。'
        : null;
    return MediaResult(
      ok: false,
      exitCode: code,
      log: why == null ? text : '$text\n$why',
    );
  }

  /// 脚本需要的环境：运行时那一份 + **本次用的模型**的端点/模型名/Key。
  ///
  /// ⚠️ 三个要点：
  ///   1. **端点与模型名由「设置 → 图像 / 视频模型」里选中的那条决定**（[model]）；
  ///      不传就是内置的 Agnes 默认（与改造前行为完全一致）。
  ///   2. Key 按 `model.provider` 去系统安全区读（`agnes` 就是 Agnes 那几把，
  ///      支持多把轮换）；**脚本只认 `AGNES_API_KEY` 这个变量名**，所以对非 Agnes
  ///      厂商是"借名"传下去 —— 只是进程环境里的一个值，不落盘、不进日志。
  ///   3. 会话路径的注入规则（第一把给 `AGNES_API_KEY`、全部给 `AGNES_API_KEYS`）
  ///      在这里照样生效，所以"设置里加的备用 Key"这一页也吃得到。
  Future<Map<String, String>> _env({MediaModelSpec? model}) async {
    final providerId = model?.provider ?? AgnesBuiltin.providerId;
    final keys = await ProviderKeys.readAll(providerId);
    return <String, String>{
      ...runtime.environment,
      if (model != null && model.baseUrl.trim().isNotEmpty)
        'AGNES_BASE_URL': model.baseUrl.trim(),
      // make-image.mjs 读 AGNES_IMAGE_MODEL、make-video.mjs 读 AGNES_VIDEO_MODEL
      // （两个脚本都只在自己那条路上取自己的那个变量）。
      if (model != null && model.isImage) 'AGNES_IMAGE_MODEL': model.id,
      if (model != null && model.isVideo) 'AGNES_VIDEO_MODEL': model.id,
      if (keys.isNotEmpty) 'AGNES_API_KEY': keys.first,
      if (keys.isNotEmpty) 'AGNES_API_KEYS': keys.join(','),
    };
  }

  /// 口播 / 短剧：把「每镜一张（已带字幕的）图 + 一段配音」合成成片。
  ///
  /// [specJson] 的形状见 `assets/toolbox/make-narration.mjs` 顶部注释：
  /// `{size, fps, shots:[{image, audio?, seconds?}]}`。
  ///
  /// ⚠️ 字幕**不在这里烧**：随包的 ffmpeg 没有 subtitles/drawtext 滤镜
  /// （NDK 没有 libass/freetype）。调用方要给**已经画好字幕的图**
  /// （见 `data/subtitle_frame.dart`）。
  Future<MediaResult> composeNarration({
    required String specJson,
    String? outPath,
    void Function(String line)? onLog,
    void Function(Process proc)? onProcess,
  }) async {
    await ensureDirs();
    final dir = Directory('${rootDir.path}/narration');
    if (!dir.existsSync()) await dir.create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final specPath = '${dir.path}/spec-$stamp.json';
    await File(specPath).writeAsString(specJson);
    final dest = outPath ?? '${videoDir.path}/${defaultName('nar', 'mp4')}';
    final r = await _run(
      'make-narration.mjs',
      <String>[specPath, dest],
      onLog: onLog,
      onProcess: onProcess,
    );
    // spec 是中间产物，成功失败都没必要留着（失败时日志里已经有它的内容）
    try {
      File(specPath).deleteSync();
    } catch (_) {}
    return r;
  }

  /// 作品库：**所有生成过的图片/视频**，按时间从新到旧。
  ///
  /// ## 为什么要扫多个地方（用户 2026-10-11 反馈）
  ///
  /// 用户原话：「合成一个总库会方便，否则会让用户感觉到混乱」——
  /// 一开始作品库只扫 `media/`（影视页的产物），于是**会话里**让模型生成的图
  /// （模型把文件写进工作区了）不会出现在作品里，用户得知道"哪个功能生成的"
  /// 才知道去哪儿找。所以现在统一扫：
  ///
  ///   * `media/{image,video}` —— 「影视」页生成的 → 来源标 [MediaSource.studio]
  ///   * `workspace/`、`workspaces/**` —— **会话**里生成的（模型的工作目录就是这个）
  ///     → 来源标 [MediaSource.session]
  ///
  /// ## ⚠️ 递归扫描的三个必须
  ///
  /// 1. **跳过 `node_modules` / `build`**：一个工作区里只要装过依赖，
  ///    里面就有成百上千张 `.png` 图标 —— 不跳的话作品库会被**别人的图标**灌满，
  ///    这比"两个地方"更让人混乱。（隐藏目录以 `.` 开头，一并跳过。）
  /// 2. **只收媒体后缀**：工作区里还有代码、文档、临时文件，作品库只该有图/视频。
  /// 3. **有上限**：深度与条数都封顶，扫到大目录不会把界面卡住；
  ///    到顶时 [listItemsTruncated] 为 true，界面要**如实说"只显示了最新的 N 个"**。
  ///
  /// 为什么不扫 `dshhome/`：那是 DSH 运行时的 HOME（node_modules、skills 都在里面），
  /// 扫它等于把运行时自带的一堆图片当"用户作品"。用户可见的产物不落在那儿。
  List<MediaItem> listItems() {
    _truncated = false;
    final out = <MediaItem>[];
    final seen = <String>{};

    void scan(Directory dir, MediaSource source, int depth) {
      if (out.length >= maxItems) return;
      if (depth > maxScanDepth) return;
      List<FileSystemEntity> entries;
      try {
        if (!dir.existsSync()) return;
        entries = dir.listSync(followLinks: false);
      } catch (e) {
        debugPrint('[dsh-media] 扫 $dir 失败（跳过）：$e');
        return;
      }
      for (final e in entries) {
        if (out.length >= maxItems) {
          _truncated = true;
          return;
        }
        // ⚠️ **不要**用 `e.uri.pathSegments.last` 取名字：目录的 URI 带一个
        // **尾部空段**（`file:///…/陵川那些事/` → pathSegments 末尾是 ''），
        // 于是每个目录名都是空串、直接被下面的 `name.isEmpty` 跳掉 ——
        // **永远递归不进子目录**。而会话产物恰恰都在 `workspaces/<工作区名>/`
        // 这一层里，后果是"统一总库看不到所有会话生成的图"（真踩过，见测试
        // 「用户建的工作区（workspaces/<名字>/）也扫得到」）。
        final name = _baseName(e.path);
        if (name.isEmpty || name.startsWith('.')) continue; // 隐藏文件/临时文件
        if (e is Directory) {
          if (skipDirNames.contains(name)) continue; // node_modules / build …
          scan(e, source, depth + 1);
          continue;
        }
        if (e is! File) continue;
        final kind = _kindOfPath(name);
        if (kind == null) continue; // 不是图片/视频就别放进"作品"
        if (!seen.add(e.path)) continue;
        try {
          final st = e.statSync();
          out.add(MediaItem(
            path: e.path,
            kind: kind,
            bytes: st.size,
            modified: st.modified,
            source: source,
          ));
        } catch (err) {
          // ⚠️ 这里**不能**用 `catch (e)`：会把上面的循环变量 `e` 遮蔽掉。
          debugPrint('[dsh-media] 读属性失败（跳过）：${e.path} —— $err');
        }
      }
    }

    scan(imageDir, MediaSource.studio, 0);
    scan(videoDir, MediaSource.studio, 0);
    // 会话的工作目录（模型通过 bash 写产物就落在这里）
    scan(Directory('${runtime.filesDir}/workspace'), MediaSource.session, 0);
    scan(Directory('${runtime.filesDir}/workspaces'), MediaSource.session, 0);

    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  /// 上一次 [listItems] 是否**被上限截断**（界面据此如实提示，别假装只有这些）。
  bool _truncated = false;
  bool get listItemsTruncated => _truncated;

  /// 目录名黑名单：装过依赖的工作区里全是别人的图标，绝不能进作品库。
  static const Set<String> skipDirNames = <String>{
    'node_modules',
    'build',
    'vendor',
    '__pycache__',
  };

  /// 递归深度上限（工作区一般就几层；`build/` 那种深目录已经在黑名单里）。
  static const int maxScanDepth = 6;

  /// 条数上限：够用，且保证界面不被大目录拖住。
  static const int maxItems = 500;

  static const Set<String> imageExts = <String>{
    '.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp', '.heic',
  };
  static const Set<String> videoExts = <String>{
    '.mp4', '.mov', '.mkv', '.webm', '.avi', '.m4v',
  };

  /// 取路径末段（对文件与目录都成立；末尾有 `/` 也不会取到空串）。
  static String _baseName(String path) {
    var p = path;
    while (p.endsWith('/') || p.endsWith('\\')) {
      p = p.substring(0, p.length - 1);
    }
    final i = p.lastIndexOf('/');
    final j = p.lastIndexOf('\\');
    final cut = i > j ? i : j;
    return cut < 0 ? p : p.substring(cut + 1);
  }

  /// 后缀 → 类型；不是媒体返回 null。
  static MediaKind? _kindOfPath(String name) {
    final lower = name.toLowerCase();
    final dot = lower.lastIndexOf('.');
    if (dot < 0) return null;
    final ext = lower.substring(dot);
    if (imageExts.contains(ext)) return MediaKind.image;
    if (videoExts.contains(ext)) return MediaKind.video;
    return null;
  }
}

/// 这个路径是不是**本 App 生成出来的产物**（在 `<filesDir>/media/` 下）
/// 还是**工作区里的普通文件**（`<filesDir>/workspace(s)/…`）。
///
/// ## ⚠️ 为什么不能用 [MediaSource] 判断这件事（2026-10-13 自查发现）
///
/// `MediaSource` 的语义是「**来自影视 / 来自会话**」—— 它回答"谁生成的"；
/// 而**工作区里的文件也统统计成 `session`**。所以拿它当"作品库 / 工作区"的
/// 判据时，"会话里生成的一段视频"会被标成"工作区"（错的，而且用户看不出来）。
/// 要判断"这东西是生成物还是工作区文件"，只能看**真实路径**。
bool isGeneratedMediaPath(String path) {
  final norm = path.replaceAll('\\', '/');
  return norm.contains('/media/');
}

/// 作品从哪来（界面要标出来 —— 这正是"不混乱"的关键：
/// 用户看到「来自会话」就知道"哦，这是我在聊天里让它生成的"）。
enum MediaSource { studio, session }
enum MediaKind { image, video }

/// 作品库里的一项。
class MediaItem {
  const MediaItem({
    required this.path,
    required this.kind,
    required this.bytes,
    required this.modified,
    required this.source,
  });

  final String path;
  final MediaKind kind;
  final int bytes;
  final DateTime modified;

  /// 从哪来的 —— 界面必须显示（「来自影视」/「来自会话」）。
  /// 统一总库之后，用户看到一张陌生图片时的第一个疑问就是"这是哪来的"。
  final MediaSource source;

  String get fileName => path.split('/').last;

  /// 「1.2 MB」这类给人看的体积。
  String get sizeLabel {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  /// 「刚刚 / 12 分钟前 / 2026-09-28 14:02」—— 与其它页面**共用同一个实现**
  /// （`data/relative_time.dart`，本次会话刚抽出来的那份）。
  String get timeLabel => relativeTimeLabel(modified);
}
