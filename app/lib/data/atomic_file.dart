/// 落盘纪律：**原子写** + **坏文件不当成空**（审计 P0-9 / P2）。
///
/// ## 为什么需要它
///
/// 本仓库原来到处是这种写法：
///
/// ```dart
/// await file.writeAsString(jsonEncode(payload));   // ← 直接覆盖目标文件
/// ```
///
/// 它有两个能**静默吞掉用户数据**的问题，而且**第二个更致命**：
///
/// 1. **非原子**：`writeAsString` 是先截断再写。进程在这中间被杀（Android 上随时
///    可能）、或磁盘写满，目标文件就留成**半份 JSON**。
/// 2. **坏文件被当成"空配置"**：读取侧 `catch { return empty; }` —— 于是
///    「半份 JSON」→ 下次启动读成空 → **下一次保存把这份空写回去** →
///    用户的厂家、模型、定时任务**全没了，且没有任何提示**。
///
/// 这个仓库对**模型/知识库下载**恰恰是用 `.part → 校验 → rename` 的
/// （见 `model_downloader.dart`），说明这个模式本来就是这里的既定做法 ——
/// 只是配置文件这些"小东西"被漏掉了。
///
/// ## 用法
///
/// ```dart
/// await writeStringAtomic(file, jsonEncode(payload));
/// ```
///
/// 读取侧遇到解析失败时，**不要** `return empty`，用 [quarantineCorrupt]：
///
/// ```dart
/// } catch (e) {
///   quarantineCorrupt(f);          // 把坏文件挪到 .corrupt，保住用户的原始字节
///   lastReadError = '...';         // 并且**必须让界面说出来**
///   return Config.empty;
/// }
/// ```
///
/// 为什么"挪走"而不是"就这么留着"：留着的话下一次保存仍然会覆盖它 ——
/// 挪走之后，即使我们随后写了一份空配置，用户原来的字节还在 `.corrupt` 里，
/// 可以人工恢复。这一条是 P0-9 里"数据全没了"的那个洞的**真正堵点**。
library;

import 'dart:io';

/// 坏文件的保留后缀。只保留**最近一次**的坏文件（不堆积）。
const String kCorruptSuffix = '.corrupt';

/// 原子写（异步）：先写 `<path>.part`，flush 之后再 `rename` 覆盖目标。
///
/// 为什么 `rename` 是原子的：同目录内它是 POSIX `rename(2)` ——
/// 要么看到旧文件、要么看到新文件，**不会看到半份**。
/// 所以 `.part` 必须与目标**同目录**（跨文件系统的 rename 不是原子的、还会失败）。
/// ⚠️ 临时文件名**必须唯一**（真机 2026-10-16 踩过）：
///
/// 原来固定用 `<目标>.part`，于是**并发保存同一个目标**时两次写共用同一个临时文件 ——
/// 先完成的那次把它 rename 走，另一个就 `PathNotFoundException:
/// Cannot rename file to '.../<id>.json', path = '.../<id>.json.part'`，
/// 且**这一次的更新就丢了**（真机日志里产物索引就这样丢过一次，
/// 前后两次保存只差 21 毫秒；同一天还出现过多组相隔 12~21ms 的成对保存）。
///
/// 现在每次写都带一个唯一后缀（微秒 + 进程号 + 自增序号），互不干扰。
Future<void> writeStringAtomic(File target, String contents) async {
  final parent = target.parent;
  if (!parent.existsSync()) parent.createSync(recursive: true);
  final part = File('${target.path}.part.${_uniquePartSuffix()}');
  await part.writeAsString(contents, flush: true);
  try {
    // rename 覆盖已存在的目标：Android/Linux 上直接成功。
    await part.rename(target.path);
  } catch (e) {
    // 失败时把自己这个临时文件清掉，不留垃圾（唯一名不会互相覆盖，但会堆积）。
    try {
      if (part.existsSync()) part.deleteSync();
    } catch (_) {}
    rethrow;
  }
}

/// 自增序号：同一微秒内的两次调用也不会撞名。
int _partSeq = 0;

String _uniquePartSuffix() {
  _partSeq = (_partSeq + 1) & 0xffffff;
  return '${DateTime.now().microsecondsSinceEpoch}-$pid-$_partSeq';
}

/// 原子写（同步版）。给那些本来就同步的调用点用。
void writeStringAtomicSync(File target, String contents) {
  final parent = target.parent;
  if (!parent.existsSync()) parent.createSync(recursive: true);
  final part = File('${target.path}.part.${_uniquePartSuffix()}');
  part.writeAsStringSync(contents, flush: true);
  try {
    part.renameSync(target.path);
  } catch (e) {
    try {
      if (part.existsSync()) part.deleteSync();
    } catch (_) {}
    rethrow;
  }
}

/// 把一个**读不出来的**文件挪到一边，返回被挪到的位置（失败返回 null）。
///
/// 关键点：调它之前**不要**先删除或覆盖原文件。它的作用就是把用户那半份
/// 原始字节留下来，避免"读坏 → 写成空 → 原始数据永久消失"这条链。
///
/// 只保留最近一次：先删掉旧的 `.corrupt`，再改名。不堆积垃圾文件。
///
/// ⚠️ 调用方要自己排除"0 字节 / 全空白"那种情形 —— 那没有内容可丢，
/// 应当按"还没配过"处理，而不是报一个损坏。各调用点都照这个口径做。
File? quarantineCorrupt(File target) {
  try {
    if (!target.existsSync()) return null;
    final dest = File('${target.path}$kCorruptSuffix');
    try {
      if (dest.existsSync()) dest.deleteSync();
    } catch (_) {
      // 删不掉旧的也无所谓，下面 rename 会覆盖（同目录）。
    }
    return target.renameSync(dest.path);
  } catch (_) {
    return null;
  }
}
