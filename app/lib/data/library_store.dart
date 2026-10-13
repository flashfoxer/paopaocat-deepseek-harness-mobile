import 'dart:convert';
import 'dart:io';

import '../i18n/dsh_i18n.dart';

/// ───────────────────────────────────────────────────────────────────────────
/// 资料库的数据层：把**当前工作区目录**里的真实文件扫出来、排好序、读预览。
///
/// 三条必须保持的约束（改这个文件前先读）：
///
/// 1. **只 import `dart:io` / `dart:convert`，刻意不 import Flutter。**
///    理由：扫描逻辑可以整份拷到纯 Dart 脚本里、在桌面上对**真实目录**跑一遍
///    做验证（本项目没有可用设备时，这是"真的能列出文件"的唯一硬证据）。
///    加一句 `debugPrint`、或者 import 一次 `package:flutter/foundation.dart`
///    就会破坏这个可验证性 —— 需要日志请由调用方（UI 层）打印。
///
/// 2. **不编造数据。** 列不出来就返回空列表 + 把 `errors` / `rootExists`
///    如实带回调用方；任何情况下都不返回设计稿里的示例文件名。
///
/// 3. **不写死任何绝对路径。** 工作区目录由 [resolveWorkspaceFromFilesDir]
///    从 `workspace_store.dart` 落盘的 `workspaces.json` 里读出来，
///    读不到才退到 `$filesDir/workspace`（= `WorkspaceStore._defaultPath`）。
/// ───────────────────────────────────────────────────────────────────────────

/// 扫描深度上限：相对工作区根目录的**目录层数** ≤ 4。
///
/// 口径：工作区根目录里直接躺着的文件算「第 1 层」；`a/b/c/d.md` 里的 `d.md`
/// 是第 4 层。也就是最多往下钻 3 层子目录。第 5 层起不再进入。
const int kLibraryMaxDepth = 4;

/// 文件数上限：最多 500 个。达到上限就停止扫描并在界面上如实说明
/// 「仅显示前 500 个」。
const int kLibraryMaxFiles = 500;

/// 文本预览上限：64 KB（用户要求「读前 ~64KB」）。
const int kLibraryPreviewMaxBytes = 64 * 1024;

/// 「最近」标签页最多列出多少行。
///
/// 为什么要有这个二级上限：扫描上限本身是 500，但"最近"按时间倒序排，
/// 500 行里绝大多数是陈年老文件，滚动毫无意义。列表只给最近 100 个，
/// 并在页脚说明口径（不隐藏事实：页脚会写清"共 N 个 / 只列最近 100"）。
const int kLibraryRecentLimit = 100;

/// 扫描时**跳过的目录名**（不含隐藏目录，隐藏目录由 `startsWith('.')` 覆盖）。
///
/// 用户明确点名的：`.git` / `node_modules` / `.dart_tool` / `build` / `.gradle`
/// ——后三个里的 `.git`、`.dart_tool`、`.gradle` 是隐藏目录，被下面的
/// 隐藏规则一并跳过；`node_modules` 与 `build` 在这里显式列出。
const Set<String> kLibrarySkipDirs = {
  'node_modules',
  'build',
  'bower_components',
  'Pods',
  '__pycache__',
};

/// 扫描时跳过的**文件名**（纯系统垃圾文件，不是用户产物）。
const Set<String> kLibrarySkipFiles = {
  '.DS_Store',
  'Thumbs.db',
  'desktop.ini',
};

/// 文本类扩展名：可以读前 64 KB 做预览。
const Set<String> kLibraryTextExtensions = {
  'md',
  'markdown',
  'txt',
  'text',
  'json',
  'jsonl',
  'ndjson',
  'csv',
  'tsv',
  'yaml',
  'yml',
  'toml',
  'ini',
  'conf',
  'cfg',
  'log',
  'xml',
  'html',
  'htm',
  'css',
  'scss',
  'js',
  'mjs',
  'cjs',
  'ts',
  'tsx',
  'jsx',
  'dart',
  'py',
  'sh',
  'ps1',
  'bat',
  'cmd',
  'java',
  'kt',
  'kts',
  'gradle',
  'c',
  'h',
  'cpp',
  'hpp',
  'go',
  'rs',
  'rb',
  'php',
  'sql',
  'env',
  'gitignore',
  'properties',
  'lock',
  'srt',
  'vtt',
  'diff',
  'patch',
};

/// 图片类扩展名：可以显示缩略图 / 全屏预览。
///
/// 只用 Flutter 内置的 `Image.file` 能解的那几种 —— 不解码不了的类型
/// （heic / tiff / svg 等）宁可不列进图片，也不要在界面上放一个破图。
const Set<String> kLibraryImageExtensions = {
  'png',
  'jpg',
  'jpeg',
  'webp',
  'gif',
  'bmp',
  'wbmp',
};

/// 文件类型（决定点开后给什么预览）。
enum LibraryFileKind {
  /// 文本：读前 64 KB 展示
  text,

  /// 图片：显示缩略图
  image,

  /// 视频：App 内播放（本机 HTTP 服务 + WebView 播放器，见
  /// `local/media_preview_server.dart`）
  video,

  /// 音频：与视频同一套（页面里换成 `<audio>`）
  audio,

  /// 其它二进制：**如实**提示「该类型暂不支持预览」
  other,
}

/// 视频扩展名（App 内**试着**放的那些）。
///
/// ⚠️ 列进来 ≠ 一定能放：能不能解码取决于 WebView / 系统（`.mkv` 在很多机器上
/// 就放不出来）。所以这里只决定"给它一个播放器试试"；放不出来时由播放页
/// **如实说明**并保留「用其它应用打开」（见 `media_preview_server.dart` 的 JS 回执）。
const Set<String> kLibraryVideoExtensions = {
  'mp4',
  'm4v',
  'mov',
  'webm',
  'mkv',
  'ogv',
  '3gp',
};

/// 音频扩展名（同上；配音产物就是 `.wav` / `.mp3`）。
const Set<String> kLibraryAudioExtensions = {
  'mp3',
  'wav',
  'm4a',
  'aac',
  'ogg',
  'opus',
  'flac',
  'amr',
};

/// 按扩展名判断类型（大小写不敏感）。
LibraryFileKind kindForExtension(String extension) {
  final ext = extension.toLowerCase();
  if (kLibraryTextExtensions.contains(ext)) return LibraryFileKind.text;
  if (kLibraryImageExtensions.contains(ext)) return LibraryFileKind.image;
  if (kLibraryVideoExtensions.contains(ext)) return LibraryFileKind.video;
  if (kLibraryAudioExtensions.contains(ext)) return LibraryFileKind.audio;
  return LibraryFileKind.other;
}

/// 工作区里的一个真实文件。
class LibraryEntry {
  LibraryEntry({
    required this.name,
    required this.relativePath,
    required this.absolutePath,
    required this.size,
    required this.modified,
  });

  /// 文件名（含扩展名）
  final String name;

  /// 相对工作区根目录的路径（用 `/` 分隔，跨平台一致）
  final String relativePath;

  /// 绝对路径（真实可读的那个）
  final String absolutePath;

  /// 字节数（来自真实的 `File.stat()`）
  final int size;

  /// 修改时间（来自真实的 `File.stat()`）
  final DateTime modified;

  /// 小写扩展名，没有扩展名时是空串。
  ///
  /// `.gitignore` 这种"点在前"的文件名不算有扩展名。
  String get extension {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  LibraryFileKind get kind => kindForExtension(extension);

  /// 人类可读体积，如 `4.6 KB` / `186.2 MB` / `812 B`。
  String get sizeLabel => humanSize(size);

  /// 所在目录（相对路径，根目录下的文件是空串）。
  String get directoryRelative {
    final i = relativePath.lastIndexOf('/');
    return i <= 0 ? '' : relativePath.substring(0, i);
  }

  /// 按**已知绝对路径**造一条（只 stat 这一个文件，不扫目录）。
  ///
  /// 用途：会话产物（`Artifact.path`）在核实阶段已经确认过存在，
  /// 打开预览时没必要再扫一遍整个工作区 —— 用户的资料库可能有几百 MB 文件。
  ///
  /// 不是文件（目录 / 不存在 / 读不了）时返回 null，调用方如实说"找不到"。
  /// [root] 是工作区根目录，用来算 [relativePath]；给不上就退回绝对路径
  /// （界面会显示全路径，但绝不编一个假的相对路径）。
  static LibraryEntry? probe(String absolutePath, {String root = ''}) {
    try {
      final stat = File(absolutePath).statSync();
      if (stat.type != FileSystemEntityType.file) return null;
      final i = absolutePath.lastIndexOf('/');
      final name = i < 0 ? absolutePath : absolutePath.substring(i + 1);
      var rel = absolutePath;
      if (root.isNotEmpty) {
        final prefix = root.endsWith('/') ? root : '$root/';
        if (absolutePath.startsWith(prefix)) {
          rel = absolutePath.substring(prefix.length);
        }
      }
      return LibraryEntry(
        name: name,
        relativePath: rel,
        absolutePath: absolutePath,
        size: stat.size,
        modified: stat.modified,
      );
    } catch (_) {
      // 这个文件读不了（不存在 / 权限 / 已删除）→ 返回 null。
      // 刻意不在这里打日志：本文件不许 import Flutter（见文件头约束），
      // 由调用方（ArtifactOpener，UI 层）打印。
      return null;
    }
  }
}

/// 一次扫描的结果（**全部字段都是实测值**，没有推测项）。
class LibraryScan {
  LibraryScan({
    required this.root,
    required this.rootExists,
    required this.entries,
    required this.truncated,
    required this.dirsVisited,
    required this.dirsSkipped,
    required this.errors,
    required this.elapsed,
  });

  /// 扫描的根目录（当前工作区）
  final String root;

  /// 根目录是否真实存在
  final bool rootExists;

  /// 扫到的文件（未排序；排序由 [sortByModifiedDesc] / [groupByDirectory] 决定）
  final List<LibraryEntry> entries;

  /// 是否因为达到「500 个」上限而提前停止
  final bool truncated;

  /// 真正进入过的目录数
  final int dirsVisited;

  /// 被跳过的目录数（隐藏目录 + [kLibrarySkipDirs]）
  final int dirsSkipped;

  /// 读不了的目录 / 文件（`路径: 原因`），界面要如实显示，不能静默吞掉
  final List<String> errors;

  /// 扫描耗时
  final Duration elapsed;

  int get total => entries.length;

  /// 扫描本身是否失败（根目录不存在，或者发生过读取错误）。
  /// 注意：**有错误不等于没数据** —— 出错时 [entries] 里仍然是真实条目的子集。
  bool get hasProblems => !rootExists || errors.isNotEmpty;
}

/// 工作区文件扫描器。
///
/// 口径（交付里也要写清）：
///   * 深度 ≤ [kLibraryMaxDepth]（目录层数，根目录下的文件算第 1 层）
///   * 最多 [kLibraryMaxFiles] 个文件，到顶就停并置 `truncated = true`
///   * 跳过隐藏目录（名字以 `.` 开头，覆盖 `.git` / `.dart_tool` / `.gradle`
///     以及各种隐藏缓存目录）+ [kLibrarySkipDirs] 里的目录名
///   * 不跟随符号链接（避免环）
///   * 单个目录读失败只记录到 [LibraryScan.errors] 并继续，不整体失败
class LibraryScanner {
  const LibraryScanner._();

  static Future<LibraryScan> scan(
    String root, {
    int maxDepth = kLibraryMaxDepth,
    int maxFiles = kLibraryMaxFiles,
  }) async {
    final started = DateTime.now();
    final entries = <LibraryEntry>[];
    final errors = <String>[];
    final rootDir = Directory(root);

    var rootExists = false;
    try {
      rootExists = await rootDir.exists();
    } catch (e) {
      errors.add(tr('{0}: 无法判断目录是否存在（{1}）', [root, e]));
    }
    if (!rootExists) {
      return LibraryScan(
        root: root,
        rootExists: false,
        entries: entries,
        truncated: false,
        dirsVisited: 0,
        dirsSkipped: 0,
        errors: errors,
        elapsed: DateTime.now().difference(started),
      );
    }

    var dirsVisited = 0;
    var dirsSkipped = 0;
    var truncated = false;

    // 广度优先：队列里是「待进入的目录 + 它内部的文件属于第几层」。
    final queue = <({Directory dir, int level})>[(dir: rootDir, level: 1)];

    while (queue.isNotEmpty && !truncated) {
      final current = queue.removeAt(0);
      dirsVisited++;
      List<FileSystemEntity> children;
      try {
        // followLinks: false —— 符号链接既可能指向外面，也可能成环，一律不跟。
        children = await current.dir.list(followLinks: false).toList();
      } catch (e) {
        errors.add(tr('{0}: 无法列出目录（{1}）', [current.dir.path, e]));
        continue;
      }

      for (final child in children) {
        final baseName = _baseName(child.path);
        if (child is Directory) {
          if (baseName.startsWith('.') || kLibrarySkipDirs.contains(baseName)) {
            dirsSkipped++;
            continue;
          }
          if (current.level < maxDepth) {
            queue.add((dir: child, level: current.level + 1));
          }
          continue;
        }
        if (child is! File) continue; // Link / 其它实体：跳过
        if (baseName.startsWith('.') && kLibrarySkipFiles.contains(baseName)) {
          continue;
        }

        try {
          final stat = await child.stat();
          entries.add(LibraryEntry(
            name: baseName,
            relativePath: _relative(root, child.path),
            absolutePath: child.path,
            size: stat.size,
            modified: stat.modified,
          ));
        } catch (e) {
          errors.add(tr('{0}: 无法读取文件信息（{1}）', [child.path, e]));
          continue;
        }

        if (entries.length >= maxFiles) {
          truncated = true;
          break;
        }
      }
    }

    final scan = LibraryScan(
      root: root,
      rootExists: true,
      entries: entries,
      truncated: truncated,
      dirsVisited: dirsVisited,
      dirsSkipped: dirsSkipped,
      errors: errors,
      elapsed: DateTime.now().difference(started),
    );
    return scan;
  }

  static String _baseName(String path) {
    final i = path.lastIndexOf(RegExp(r'[/\\]'));
    return i < 0 ? path : path.substring(i + 1);
  }

  /// 相对路径一律用 `/` 分隔（界面显示不随平台变）。
  static String _relative(String root, String path) {
    final normalizedRoot = root.endsWith('/') || root.endsWith('\\')
        ? root.substring(0, root.length - 1)
        : root;
    var rel = path;
    if (path.startsWith(normalizedRoot)) {
      rel = path.substring(normalizedRoot.length);
    }
    rel = rel.replaceAll('\\', '/');
    while (rel.startsWith('/')) {
      rel = rel.substring(1);
    }
    return rel;
  }
}

/// 「最近」口径：**按 mtime 倒序**（最新改动的在最前），同时间按路径升序稳定排序。
List<LibraryEntry> sortByModifiedDesc(List<LibraryEntry> list) {
  final out = List<LibraryEntry>.of(list);
  out.sort((a, b) {
    final byTime = b.modified.compareTo(a.modified);
    if (byTime != 0) return byTime;
    return a.relativePath.compareTo(b.relativePath);
  });
  return out;
}

/// 「我的资料」口径：**按所在目录分组**，根目录那组排最前，其余目录按路径升序；
/// 组内按文件名（大小写不敏感）升序。
List<({String dir, List<LibraryEntry> items})> groupByDirectory(
  List<LibraryEntry> list,
) {
  final map = <String, List<LibraryEntry>>{};
  for (final e in list) {
    map.putIfAbsent(e.directoryRelative, () => <LibraryEntry>[]).add(e);
  }
  final dirs = map.keys.toList()
    ..sort((a, b) {
      if (a.isEmpty != b.isEmpty) return a.isEmpty ? -1 : 1;
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
  return [
    for (final d in dirs)
      (
        dir: d,
        items: (map[d]!
          ..sort(
              (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()))),
      ),
  ];
}

/// 搜索：文件名 / 相对路径的**模糊匹配**（大小写不敏感的子串匹配）。
///
/// 不是正则、不做模糊纠错 —— 用户输入什么就按字面找什么，避免"看起来匹配了
/// 其实不是你要的"。查询串按空白切成多个词时要求**全部命中**（AND）。
List<LibraryEntry> filterEntries(List<LibraryEntry> list, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return list;
  final terms = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  if (terms.isEmpty) return list;
  return [
    for (final e in list)
      if (_matchesAll(e, terms)) e,
  ];
}

bool _matchesAll(LibraryEntry e, List<String> terms) {
  final haystack = '${e.relativePath}\n${e.name}'.toLowerCase();
  for (final t in terms) {
    if (!haystack.contains(t)) return false;
  }
  return true;
}

/// 人类可读体积。基数 1024，单位 B / KB / MB / GB。
///
/// 只保留一位小数（`4.6 KB`），1 KB 以下直接给字节数（`812 B`）——
/// 体积是**估读用**的信息，不需要更多精度。
String humanSize(int bytes) {
  if (bytes < 0) return tr('未知');
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

/// 相对时间：`刚刚` / `3 分钟前` / `2 小时前` / `5 天前` / `2026-05-01`。
///
/// 30 天以内说相对时间（人脑能感知），更早直接给日期（"37 天前"没有信息量）。
/// 时间戳在未来（设备时钟被改过）时如实说 `刚刚`，不显示负数。
String relativeTime(DateTime when, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final diff = ref.difference(when);
  if (diff.isNegative || diff.inMinutes < 1) return tr('刚刚');
  if (diff.inMinutes < 60) return tr('{0} 分钟前', [diff.inMinutes]);
  if (diff.inHours < 24) return tr('{0} 小时前', [diff.inHours]);
  if (diff.inDays < 30) return tr('{0} 天前', [diff.inDays]);
  return '${when.year}-${_twoDigits(when.month)}-${_twoDigits(when.day)}';
}

String _twoDigits(int n) => n.toString().padLeft(2, '0');

/// 文本预览结果。
typedef LibraryPreview = ({
  String text,

  /// 因为超过 [kLibraryPreviewMaxBytes] 被截断
  bool truncated,

  /// 文件总字节数
  int totalBytes,

  /// 前 512 字节出现 NUL —— 扩展名像文本、内容其实是二进制（如实上报，
  /// 由界面照实提示，不要硬把乱码当正文渲染）
  bool looksBinary,
});

/// 读文件前 [maxBytes] 字节做预览（默认 64 KB）。
///
/// 只用 `RandomAccessFile` 读前 N 字节 —— 不把整个文件读进内存，
/// 因为工作区里可能有几百 MB 的产物。
Future<LibraryPreview> readTextPreview(
  String path, {
  int maxBytes = kLibraryPreviewMaxBytes,
}) async {
  final file = File(path);
  final raf = await file.open();
  try {
    final total = await raf.length();
    final take = total > maxBytes ? maxBytes : total;
    final bytes = await raf.read(take);
    final head = bytes.length > 512 ? bytes.sublist(0, 512) : bytes;
    final looksBinary = head.contains(0);
    var text = utf8.decode(bytes, allowMalformed: true);
    // UTF-8 BOM 去掉，否则预览第一行会带一个不可见字符
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    return (
      text: text,
      truncated: total > take,
      totalBytes: total,
      looksBinary: looksBinary,
    );
  } finally {
    await raf.close();
  }
}

/// 从 `$filesDir/workspaces.json` 解析出**当前工作区目录**。
///
/// 为什么读这个文件：工作区是 `WorkspaceStore` 的真相，它在用户切换工作区时
/// 就把 `current` 落盘了（见 `workspace_store.dart`）。资料库只是**只读**
/// 这个登记表，绝不写它 —— 避免出现"两个 Store 各写一半"的第二个真相。
///
/// 为什么不像 `expert_page.dart` 那样由外层传 `workspacePath`：
/// `LibraryPage` 在 `app_shell.dart` 里是 `const LibraryPage()`，本轮改动被
/// 约束在"只改 library_page.dart + 新增本文件"，所以这里自己解析。
/// 以后若要改成传参，把本函数换成入参即可（UI 侧只有一处调用）。
///
/// 返回 `(path, source)`：`source` 是**给人看的来源说明**，界面上会显示，
/// 便于用户核对"你到底扫的是哪个目录"。
({String path, String source}) resolveWorkspaceFromFilesDir(String filesDir) {
  final fallback = '$filesDir/workspace';
  if (filesDir.isEmpty) {
    return (path: fallback, source: tr('未知（拿不到 App 私有目录，退回默认工作区路径）'));
  }
  final registry = File('$filesDir/workspaces.json');
  try {
    if (registry.existsSync()) {
      final raw = jsonDecode(registry.readAsStringSync());
      if (raw is Map) {
        final current = raw['current'];
        if (current is String &&
            current.isNotEmpty &&
            Directory(current).existsSync()) {
          return (path: current, source: tr('工作区登记表 workspaces.json（当前工作区）'));
        }
        // current 指向的目录不在磁盘上（被删了 / 换机恢复）→ 按登记表顺序
        // 找第一个真实存在的，而不是直接报"空"。
        final list = raw['workspaces'];
        if (list is List) {
          for (final item in list) {
            final p = item is Map ? item['path'] : null;
            if (p is String && p.isNotEmpty && Directory(p).existsSync()) {
              return (
                path: p,
                source: tr('工作区登记表 workspaces.json（current 已不存在，取第一条存在的）'),
              );
            }
          }
        }
      }
    }
  } catch (_) {
    // 登记表坏了不该让资料库打不开 —— 走下面的默认工作区。
    return (path: fallback, source: tr('工作区登记表读取失败，退回默认工作区路径'));
  }
  return (path: fallback, source: tr('默认工作区（登记表里还没有可用的目录）'));
}
