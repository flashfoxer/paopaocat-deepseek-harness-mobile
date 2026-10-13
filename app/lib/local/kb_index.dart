/// 知识库的**检索索引**（自研，不依赖任何数据库）。
///
/// ## 为什么不用 SQLite / FTS5
///
/// ① App 现在**没有任何数据库依赖**，为一个功能引一套原生库不划算；
/// ② Android 各版本自带的 SQLite 是否编了 FTS5 不能保证（真机上跑不出来才发现就晚了）。
///
/// ## 用什么方案：分块 + 签名（MinHash）
///
/// 把资料切成 ~400–600 字的块，每块只存一个**很短的签名**（24 个 32 位哈希 = 96 字节），
/// 签名取的是"该块所有词/双字哈希里最小的 24 个"（MinHash 的经典做法）。
///
/// 查的时候：把问题也切成同样的词，算哈希 → **在签名文件上扫一遍**（线性、顺序读），
/// 数一数"问题里有多少哈希出现在这一块的签名里" → 按命中数排序取前 N 块。
///
/// 这样做的三个好处，正是手机需要的：
///   1. **构建可以流式**：一边读资料一边写索引，内存只占一个块 + 一个签名；
///      500 MB 的百科也能在手机上建（不必先把整库读进内存）。
///   2. **索引很小**：约原文的 5%~10%（27 万条约 30 MB）。
///   3. **查询很快**：扫 30 MB 顺序文件 + 交集，几百毫秒级；命中后再按偏移
///      从 `chunks.bin` 里只读那几块文本。
///
/// 代价（如实说）：这是**近似**检索 —— MinHash 只保"大致像不像"，不做精确词频打分。
/// 对"读着资料回答问题"这个用途完全够；要精确排序就得上真正的倒排/FTS。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../data/atomic_file.dart';

const String _kMagic = 'DSHKB1'; // 6 字节 + 2 字节 0 补齐 = 8 字节（下面按 8 算偏移）
/// 索引头长度：8 字节 magic + 24 字节字段 = 32 字节。**改这个必须同时改读的那边。**
const int _kHeaderLen = 32;
const int _kVersion = 2; // v2：签名从 MinHash 换成 Bloom 位签名（见下）

/// 索引里的一个块（检索结果）。
class KbChunkHit {
  const KbChunkHit({
    required this.text,
    required this.score,
    required this.chunkId,
    this.source = '',
  });

  final String text;
  final int score;
  final int chunkId;

  /// 这一段来自哪个知识库（多包时用；单包为空）。
  ///
  /// 为什么必须带上：用户装了两包以上时，光看正文分不清答案是从哪本书里来的；
  /// 界面/注入的参考资料里都会写出来，方便他自己核对。
  final String source;

  KbChunkHit withSource(String name) => KbChunkHit(
      text: text, score: score, chunkId: chunkId, source: name);
}

/// 索引元信息（落盘 `index_meta.json`，界面用来显示"建了没有、多大"）。
/// 切片口径的版本号 —— 写进 `index_meta.json`，用来认出**老索引**。
///
/// * `1` = 老切法：把整份语料当一条连续的流，只按长度切，**跨文档合并**
///   （实测 12 篇无关文档被并成 2 块，一块里 9 篇）→ 检索基本失效；
/// * `2` = 2026-10-12 起：**空行 = 文档硬边界，绝不跨边界合并**。
///
/// 为什么要版本号：块的切法在**建索引时**就烧进 `chunks.bin` 了，
/// 升级 App **不会**让已有索引变好 —— 必须让用户看到"重建一下"。
/// 所以老索引（没有这个字段 = 1）要在界面上如实标出来。
const int kChunkModeDocBoundary = 2;

/// 老索引（2026-10-12 之前建的）用的切片口径。
const int kChunkModeLegacy = 1;

class KbIndexMeta {
  const KbIndexMeta({
    required this.chunks,
    required this.sourceBytes,
    required this.signatureSize,
    required this.builtAt,
    required this.sourceFile,
    this.chunkMode = kChunkModeDocBoundary,
  });

  final int chunks;
  final int sourceBytes;
  final int signatureSize;
  final DateTime builtAt;
  final String sourceFile;

  /// 这个索引是用哪套切片口径建的（见 [kChunkModeDocBoundary]）。
  /// 老文件里没有这个字段 → [kChunkModeLegacy]。
  final int chunkMode;

  /// 是不是"跨文档合并"那套老切法建的（是的话检索会不准，该重建）。
  bool get isLegacyChunking => chunkMode < kChunkModeDocBoundary;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'chunks': chunks,
        'sourceBytes': sourceBytes,
        'signatureSize': signatureSize,
        'builtAt': builtAt.toIso8601String(),
        'sourceFile': sourceFile,
        'chunkMode': chunkMode,
      };

  static KbIndexMeta? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return KbIndexMeta(
      chunks: (raw['chunks'] as num?)?.toInt() ?? 0,
      sourceBytes: (raw['sourceBytes'] as num?)?.toInt() ?? 0,
      signatureSize: (raw['signatureSize'] as num?)?.toInt() ?? 0,
      builtAt: DateTime.tryParse((raw['builtAt'] as String?) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      sourceFile: (raw['sourceFile'] as String?) ?? '',
      // ⚠️ 老文件里**没有**这个字段 → 1（老切法）。
      //    不能默认成新版：否则老索引会被误判成"已经好了"，用户永远看不到重建提示，
      //    这次修复对已有知识库就等于没做。
      chunkMode: (raw['chunkMode'] as num?)?.toInt() ?? kChunkModeLegacy,
    );
  }
}

// ───────────────────────────────── 分词 ─────────────────────────────────
//
// 中文走**双字（bigram）**：不做词典分词也能用，而且对未登录词（地名、人名）友好
// —— "晋城"就是"晋城"这一个双字，不需要知道它是个词。
// 英文/数字走**整词**（小写）：够区分，也省签名位。

bool _isCjk(int r) =>
    (r >= 0x4E00 && r <= 0x9FFF) || // 基本汉字
    (r >= 0x3400 && r <= 0x4DBF) || // 扩展 A
    (r >= 0xF900 && r <= 0xFAFF); // 兼容汉字

bool _isWordChar(int r) =>
    (r >= 0x30 && r <= 0x39) || // 0-9
    (r >= 0x61 && r <= 0x7A) || // a-z（已小写）
    (r >= 0x41 && r <= 0x5A); // A-Z

/// 把一段文字切成"词"列表（中文双字 + 英文整词）。
List<String> tokenizeForIndex(String text) {
  final out = <String>[];
  final runes = text.runes.toList(growable: false);
  var i = 0;
  while (i < runes.length) {
    final r = runes[i];
    if (_isCjk(r)) {
      // 连续汉字段：取所有相邻双字
      var j = i;
      while (j < runes.length && _isCjk(runes[j])) {
        j++;
      }
      for (var k = i; k + 1 < j; k++) {
        out.add(String.fromCharCodes(runes.sublist(k, k + 2)));
      }
      if (j - i == 1) out.add(String.fromCharCode(rune0(runes[i])));
      i = j;
      continue;
    }
    if (_isWordChar(r)) {
      var j = i;
      while (j < runes.length && _isWordChar(runes[j])) {
        j++;
      }
      final w = String.fromCharCodes(runes.sublist(i, j)).toLowerCase();
      if (w.length >= 2) out.add(w);
      i = j;
      continue;
    }
    i++;
  }
  return out;
}

/// `String.fromCharCode` 的包装（Dart 里 runes 已是 code point）。
int rune0(int r) => r;

/// FNV-1a 32 位：够快、够散。
int hashTerm(String term) {
  var h = 0x811c9dc5;
  for (final c in term.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

/// 第二个哈希（Bloom 要两个独立的位置）：换个种子。
int hashTerm2(String term) {
  var h = 0x7fed3c15;
  for (final c in term.codeUnits) {
    h ^= c;
    h = (h * 0x85ebca6b) & 0xFFFFFFFF;
  }
  return h;
}

/// 每块签名占多少个 32 位字。32 个字 = 1024 位 = 128 字节/块。
///
/// 为什么是这个数：一块约 500 字 → 约 180 个词，每个词打 2 个点 →
/// 填充率约 30%，误判率约 9%。**真命中一定命中**（不像 MinHash 会漏），
/// 误判只会多排几个不相关的块进来 —— 反正我们取前 3 块喂给模型。
///
/// ⚠️ **为什么不用 MinHash**：一开始我用的是"取最小的 24 个哈希"（MinHash）。
/// 实测直接翻车：一块有 ~180 个词，签名只留 24 个 → 某个具体词**落在签名里的
/// 概率只有 ~13%**，问"晋城是什么"一条都搜不出来（测试抓到的）。
/// MinHash 适合"估两个集合的相似度"，**不适合"查某个词在不在这一段里"**。
const int kBloomWords = 32;
const int _kBloomBits = kBloomWords * 32;

/// 一个词的哈希 → 它在签名里的两个位（返回两个 0.._kBloomBits-1）。
List<int> bloomBitsOf(String term) => <int>[
      hashTerm(term) % _kBloomBits,
      hashTerm2(term) % _kBloomBits,
    ];

/// 把一串词打成位签名（每词 2 个位）。
Uint32List bloomOf(Iterable<String> terms, {int words = kBloomWords}) {
  final out = Uint32List(words);
  final bits = words * 32;
  for (final t in terms) {
    final h1 = hashTerm(t) % bits;
    final h2 = hashTerm2(t) % bits;
    out[h1 >> 5] |= 1 << (h1 & 31);
    out[h2 >> 5] |= 1 << (h2 & 31);
  }
  return out;
}

/// 一个"查询位"被打中的个数（[bits] 是词 → 位的平铺列表：词0位0、词0位1、词1位0…）。
int bloomHits(Uint32List bloom, List<int> bits) {
  var n = 0;
  for (final b in bits) {
    if ((bloom[b >> 5] & (1 << (b & 31))) != 0) n++;
  }
  return n;
}

// ───────────────────────────────── 切片 ─────────────────────────────────

/// 把整份语料切成若干块。
///
/// ## ⚠️ 这里修的是一个**致命**的检索质量问题（用户 2026-10-12）
///
/// 用户原话：「貌似本地大模型调用知识库是没什么效用的，感觉回答得乱七八糟」。
///
/// 改之前：本函数把整份语料当成**一条连续的流**，只按长度（`maxChars`）切，
/// **从不看文档边界** —— 于是连续几篇互不相关的文档被合并进同一块。
/// 实测（12 篇互不相关的短文档 / 722 字）：
///
/// ```
/// 切出 2 块：
///   [0] 545 字 · 含 9 篇 → [机场, 红烧肉, 月球, 公司简介, 量子纠缠,
///                            煮米饭, 报销流程, 长城, 咖啡因]
///   [1] 176 字 · 含 3 篇 → [产品线, 光合作用, 办公楼]
/// ```
///
/// 后果是双重的、而且是**致命**的：
///   1. **一块不是语义单元** —— 它同时讲红烧肉和量子纠缠。任何问句都会命中它，
///      因为它什么都沾一点。检索排名因此基本没有意义（实测 top-1 命中 1/11）。
///   2. **小知识库会被整份塞进提示词** —— 只有 2~3 块时 `topK: 3` 等于"全部返回"，
///      模型收到一大坨无关材料，还要"优先依据它们回答" → 就是"回答得乱七八糟"。
///
/// 改之后：**空行 = 硬边界，绝不跨边界合并**。一篇文档（或一段）先独立成块；
/// 只有**同一段内部**才允许按长度合并/再切。文档太长时在段内按句号继续切。
///
/// 为什么用空行：两条输入路径本来就都带它 ——
///   * JSON 数组抽取：每篇文档之间写 `\n\n`（见 [KbIndexer.build] 的抽取状态机）；
///   * `.txt` / `.md` 导入：空行本来就是自然段分隔。
///
/// ⚠️ **老索引不会自动变好**：块的切法在建索引时就烧进 `chunks.bin` 了。
/// 这个修复只影响**之后重建的**索引 —— 界面必须提示用户重建（见 `KbIndexMeta.chunkMode`）。
List<String> chunkText(String text, {int minChars = 200, int maxChars = 600}) {
  final chunks = <String>[];
  // 硬边界：2 个及以上的换行（容忍 `\r\n` 与流式读取时多补的换行）。
  for (final seg in text.split(RegExp(r'\n\s*\n'))) {
    final s = seg.trim();
    if (s.isEmpty) continue;
    chunks.addAll(_chunkSegment(s, minChars: minChars, maxChars: maxChars));
  }
  return chunks;
}

/// 切**一段**（一篇文档 / 一个自然段）：段内按长度合并，超长则按句号再切。
///
/// 只被 [chunkText] 调用 —— 边界由调用方负责，这里**不认识**硬边界。
List<String> _chunkSegment(String text, {int minChars = 200, int maxChars = 600}) {
  final chunks = <String>[];
  final buf = StringBuffer();
  void flush() {
    final s = buf.toString().trim();
    if (s.isNotEmpty) chunks.add(s);
    buf.clear();
  }

  for (final para in text.split('\n')) {
    final p = para.trim();
    if (p.isEmpty) continue;
    if (buf.length + p.length + 1 > maxChars && buf.length >= minChars) flush();
    if (p.length > maxChars) {
      // 单个超长段落（没有换行的长文）：按句号/分号切
      for (final sentence in p.split(RegExp(r'(?<=[。！？；.!?])'))) {
        if (buf.length + sentence.length > maxChars && buf.length >= minChars) {
          flush();
        }
        buf.write(sentence);
      }
      if (buf.length >= minChars) flush();
      continue;
    }
    if (buf.isNotEmpty) buf.write('\n');
    buf.write(p);
    if (buf.length >= maxChars) flush();
  }
  flush();
  return chunks;
}

// ───────────────────────────────── 构建 ─────────────────────────────────

/// 建索引的结果（给界面显示）。
class KbBuildResult {
  const KbBuildResult({
    required this.chunks,
    required this.sourceBytes,
    required this.elapsed,
    required this.cancelled,
  });
  final int chunks;
  final int sourceBytes;
  final Duration elapsed;
  final bool cancelled;
}

/// 流式建索引：一边读 [sourcePath] 一边写 `<outDir>/index.bin` 与 `chunks.bin`。
///
/// 支持两种输入形状（都能流式处理，不必整份解析）：
///   * **JSON 数组**（我们的百科包）：抽 `"<textField>": "..."` 里的字符串；
///   * **纯文本 / JSONL**：按行（或整段）处理。
///
/// [onProgress] 收到 0~1 的进度（按已读字节算）。
class KbIndexer {
  /// 每块签名的字数（见 [kBloomWords]）。
  static const int defaultSignature = kBloomWords;

  static Future<KbBuildResult> build({
    required String sourcePath,
    required String outDir,
    String textField = 'completion',
    int signatureSize = defaultSignature,
    int minChars = 200,
    int maxChars = 600,
    bool Function()? isCancelled,
    void Function(double progress)? onProgress,
  }) async {
    final sw = Stopwatch()..start();
    final src = File(sourcePath);
    final total = src.existsSync() ? src.lengthSync() : 0;
    final dir = Directory(outDir);
    if (!dir.existsSync()) await dir.create(recursive: true);

    // 先写"块文本"到一个临时文件；索引签名写另一个临时文件。都写完再原子改名。
    final chunkFile = File('$outDir/chunks.bin.part');
    final indexFile = File('$outDir/index.bin.part');
    final chunkSink = chunkFile.openWrite();
    final indexSink = indexFile.openWrite();

    // 头部先占位（写完回来补 chunkCount）
    indexSink.add(_header(chunkCount: 0, signatureSize: signatureSize));

    var chunkCount = 0;
    var chunkOffset = 0;
    final pending = StringBuffer();

    Future<void> flushChunks() async {
      if (pending.isEmpty) return;
      final text = pending.toString();
      pending.clear();
      for (final c in chunkText(text, minChars: minChars, maxChars: maxChars)) {
        final bytes = utf8.encode('$c\n');
        chunkSink.add(bytes);
        final sig = bloomOf(tokenizeForIndex(c), words: signatureSize);
        // 每块：offset u32 · length u32 · 位签名（signatureSize × u32）
        indexSink.add(_u32(chunkOffset));
        indexSink.add(_u32(bytes.length));
        indexSink.add(sig.buffer.asUint8List(sig.offsetInBytes, sig.lengthInBytes));
        chunkOffset += bytes.length;
        chunkCount++;
      }
    }

    // 源里**根本没有这个字段**（用户导入的 .txt / .md）→ 整段当文本处理。
    // 判断只看开头 64 KB：JSON 数组的字段就在最前面，够用且不用把整文件读一遍。
    final head = await _readHead(src, 65536);
    final plainText = !head.contains('"$textField"');

    var read = 0;
    var cancelled = false;
    var inStr = false;
    var esc = false;
    // 抽取状态机：找 `"<field>"` 后面的字符串字面量
    final fieldPat = '"$textField"';
    final tail = StringBuffer(); // 跨批次的尾巴（避免字段被切断）

    final input = src.openRead();
    await for (final buf in input) {
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        break;
      }
      read += buf.length;
      onProgress?.call(total <= 0 ? 0 : (read / total).clamp(0.0, 1.0));

      final text = tail.toString() + utf8.decode(buf, allowMalformed: true);
      tail.clear();

      // 纯文本：整段收下，按块大小刷出去，不做任何字段抽取。
      if (plainText) {
        pending.write(text);
        pending.write('\n');
        if (pending.length >= maxChars * 4) await flushChunks();
        continue;
      }

      var i = 0;
      while (i < text.length) {
        if (!inStr) {
          final at = text.indexOf(fieldPat, i);
          if (at < 0) {
            // 没找到字段 → 只保留尾巴（可能字段名被切断）
            final keep = fieldPat.length + 2;
            tail.write(text.substring(i < text.length - keep ? text.length - keep : i));
            break;
          }
          var j = at + fieldPat.length;
          while (j < text.length && text[j] != ':') {
            j++;
          }
          j++;
          while (j < text.length && (text[j] == ' ' || text[j] == '\n')) {
            j++;
          }
          if (j >= text.length) {
            tail.write(text.substring(at));
            break;
          }
          if (text[j] != '"') {
            i = j;
            continue;
          }
          inStr = true;
          esc = false;
          i = j + 1;
          continue;
        }
        // 在字符串里：逐字符找结尾引号，边走边把内容收进 pending
        final start = i;
        var done = false;
        while (i < text.length) {
          final c = text[i];
          if (esc) {
            esc = false;
            i++;
            continue;
          }
          if (c == '\\') {
            esc = true;
            i++;
            continue;
          }
          if (c == '"') {
            done = true;
            break;
          }
          i++;
        }
        final raw = text.substring(start, i);
        pending.write(_unescapeJson(raw));
        // ⚠️ **两个**换行 = 文档硬边界。`chunkText` 靠它把"一篇文档"和
        //    "下一篇文章"分开 —— 写一个换行的话两篇会被合并进同一块
        //    （那正是"知识库没什么效用"的根因，见 chunkText 的文档）。
        pending.write('\n\n');
        if (!done) {
          // 字符串跨批次了：把已读部分留着，下一批继续
          tail.write(text.substring(start));
          break;
        }
        inStr = false;
        i++;
        if (pending.length >= maxChars * 4) await flushChunks();
      }
      if (pending.length >= maxChars * 4) await flushChunks();
    }
    await flushChunks();

    // 补头部
    await indexSink.flush();
    await chunkSink.flush();
    await indexSink.close();
    await chunkSink.close();

    final tmpIndex = File('$outDir/index.bin.part');
    final tmpChunks = File('$outDir/chunks.bin.part');
    // 头 8 字节先写的是 chunkCount=0；用 RandomAccessFile 就地改成真实值。
    final raf = await tmpIndex.open(mode: FileMode.append);
    await raf.close();
    await _patchChunkCount(tmpIndex, chunkCount);

    final finalIndex = File('$outDir/index.bin');
    final finalChunks = File('$outDir/chunks.bin');
    if (finalIndex.existsSync()) await finalIndex.delete();
    if (finalChunks.existsSync()) await finalChunks.delete();
    await tmpIndex.rename(finalIndex.path);
    await tmpChunks.rename(finalChunks.path);

    final meta = KbIndexMeta(
      chunks: chunkCount,
      sourceBytes: read,
      signatureSize: signatureSize,
      builtAt: DateTime.now(),
      sourceFile: src.uri.pathSegments.last,
      chunkMode: kChunkModeDocBoundary,
    );
    await writeStringAtomic(
        File('$outDir/index_meta.json'), jsonEncode(meta.toJson()));

    // 新的 index.bin 已经落位 → 清掉检索缓存（审计 P0-7）。
    //
    // 缓存本来用 `(size, mtime)` 判失效，正常重建两个都会变；但"重建后长度恰好
    // 相同、且 mtime 落在同一秒"理论上可能，那时取到旧索引的后果是
    // **检索结果莫名其妙不对**（很难查）。显式清一次，代价只是下次重读一遍。
    KbRetriever.clearCache();

    return KbBuildResult(
      chunks: chunkCount,
      sourceBytes: read,
      elapsed: sw.elapsed,
      cancelled: cancelled,
    );
  }

  static Future<String> _readHead(File f, int maxBytes) async {
    try {
      final raf = await f.open();
      try {
        final n = await f.length() < maxBytes ? await f.length() : maxBytes;
        final b = await raf.read(n);
        return utf8.decode(b, allowMalformed: true);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return '';
    }
  }

  static Uint8List _header({required int chunkCount, required int signatureSize}) {
    final b = BytesBuilder();
    final magic = Uint8List(8);
    magic.setRange(0, 6, utf8.encode(_kMagic)); // 后两字节保持 0
    b.add(magic);
    final u = Uint8List(24);
    final dv = ByteData.view(u.buffer);
    dv.setUint16(0, _kVersion, Endian.little);
    dv.setUint16(2, signatureSize, Endian.little);
    dv.setUint32(4, chunkCount, Endian.little);
    dv.setUint32(8, 0, Endian.little);
    dv.setUint32(12, 0, Endian.little);
    dv.setUint32(16, 0, Endian.little);
    dv.setUint32(20, 0, Endian.little);
    b.add(u);
    return b.toBytes();
  }

  /// 把头部里的 chunkCount（偏移 8+4=12）改成真实值。
  static Future<void> _patchChunkCount(File f, int count) async {
    final raf = await f.open(mode: FileMode.append);
    try {
      final b = ByteData(4)..setUint32(0, count, Endian.little);
      await raf.setPosition(12);
      await raf.writeFrom(b.buffer.asUint8List());
    } finally {
      await raf.close();
    }
  }

  static Uint8List _u32(int v) {
    final b = ByteData(4)..setUint32(0, v & 0xFFFFFFFF, Endian.little);
    return b.buffer.asUint8List();
  }

  static String _unescapeJson(String s) {
    if (!s.contains('\\')) return s;
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c != '\\' || i + 1 >= s.length) {
        b.write(c);
        continue;
      }
      final n = s[++i];
      switch (n) {
        case 'n':
          b.write('\n');
          break;
        case 't':
          b.write('\t');
          break;
        case 'r':
          b.write('\r');
          break;
        case '"':
          b.write('"');
          break;
        case '\\':
          b.write('\\');
          break;
        case '/':
          b.write('/');
          break;
        case 'u':
          if (i + 4 < s.length) {
            final hex = s.substring(i + 1, i + 5);
            final code = int.tryParse(hex, radix: 16);
            if (code != null) {
              b.writeCharCode(code);
              i += 4;
              break;
            }
          }
          b.write('u');
          break;
        default:
          b.write(n);
      }
    }
    return b.toString();
  }
}

// ───────────────────────────────── 查询 ─────────────────────────────────

/// 打开一个已建好的索引并按签名检索。
class KbRetriever {
  KbRetriever._(this._indexBytes, this._chunks, this.chunkCount,
      this.signatureSize, this._perChunk);

  final Uint8List _indexBytes;
  final File _chunks;
  final int chunkCount;
  final int signatureSize;
  final int _perChunk; // 每块的索引字节数 = 8 + 4*signatureSize

  /// 索引字节缓存（审计 P0-7）。
  ///
  /// ## 为什么必须有
  ///
  /// `open()` 原来**每次调用**都把整份 `index.bin` 读进内存。实测那包的索引是
  /// **34,618,424 字节 / 轮**（32 B 头 + 254,547 块 × 136 B），而本地对话
  /// **每一轮都会调它**（见 `local_chat_page` 的检索段）—— 用户每问一句就白读
  /// 35 MB，而同一次会话里索引根本不会变。
  ///
  /// ## 失效判据
  ///
  /// `(size, mtime)` 一起比：重建索引、导入新包、删除重下都会改这两个值。
  /// 单看 mtime 不稳（有些文件系统是秒级粒度，同秒重建看不出来）；
  /// 单看 size 也不稳（重建后长度可能恰好相同 —— 那正是 P0-4 里 sha256 要解决的
  /// 同一类问题）。两者一起比，代价是两个整数。
  ///
  /// ## 为什么要有预算
  ///
  /// 一个 500 MB 知识库的索引就 35 MB；用户还可能有法条/成语/诗词几个包。
  /// 全留会吃掉太多内存，所以 **LRU + 48 MB 预算**：够放下维基那包加所有小包，
  /// 再多就淘汰最久没用的那个。
  static const int _cacheBudgetBytes = 48 * 1024 * 1024;

  /// path -> 缓存项。用 Map 的插入顺序当 LRU 顺序（命中时先 remove 再 put）。
  static final Map<String, _CachedIndex> _cache = <String, _CachedIndex>{};
  static int _cachedBytes = 0;

  /// 清空缓存（重建索引之后显式调一次；测试也用它隔离）。
  static void clearCache() {
    _cache.clear();
    _cachedBytes = 0;
  }

  /// 仅供测试：当前缓存占用字节数 / 缓存了几个索引。
  static int get cachedBytesForTest => _cachedBytes;
  static int get cachedCountForTest => _cache.length;

  static Future<KbRetriever?> open(String dir) async {
    final idx = File('$dir/index.bin');
    final ch = File('$dir/chunks.bin');
    if (!idx.existsSync() || !ch.existsSync()) return null;

    // 缓存命中就连文件都不读（这正是这一条要省掉的那 35 MB）。
    final stat = idx.statSync();
    final stamp = '${stat.size}:${stat.modified.millisecondsSinceEpoch}';
    final cached = _cache[idx.path];
    if (cached != null && cached.stamp == stamp) {
      _cache.remove(idx.path);
      _cache[idx.path] = cached; // 挪到队尾 = 最近使用
      return cached.retriever;
    }

    final bytes = await idx.readAsBytes();
    if (bytes.length < _kHeaderLen) return null;
    if (utf8.decode(bytes.sublist(0, 6), allowMalformed: true) != _kMagic) {
      return null;
    }
    final dv = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
    final sig = dv.getUint16(10, Endian.little);
    final count = dv.getUint32(12, Endian.little);
    if (sig == 0 || count == 0) return null;
    final per = 8 + 4 * sig;
    if (bytes.length < _kHeaderLen + per * count) return null;

    final entry = _CachedIndex(
      stamp: stamp,
      retriever: KbRetriever._(bytes, ch, count, sig, per),
      bytes: bytes.length,
    );
    final old = _cache.remove(idx.path);
    if (old != null) _cachedBytes -= old.bytes;
    _cache[idx.path] = entry;
    _cachedBytes += entry.bytes;
    // 淘汰到预算以内（至少留一个：单个超预算也得能查）。
    while (_cachedBytes > _cacheBudgetBytes && _cache.length > 1) {
      final oldest = _cache.keys.first;
      _cachedBytes -= _cache.remove(oldest)!.bytes;
    }
    return entry.retriever;
  }

  /// 检索前 [topK] 块。
  ///
  /// **两段式**（这是被测试逼出来的设计）：
  ///   1. **预筛**：用位签名在 30 MB 的签名文件上顺序扫一遍，取位命中数最高的
  ///      [candidates] 块。位签名有误判（约 9%），所以这一步**只求别漏**。
  ///   2. **精排**：把这几百块（几十 KB）读出来，按**真实词重叠**打分排序。
  ///
  /// 为什么必须有第二段：Bloom 的误判让"命中位数"区分度不够 —— 实测随机块的
  /// 平均命中数只比真正相关块低一点点，靠阈值或单靠位数排序都会把相关块挤出去。
  /// 位签名只当"别漏"的筛子，真正的排序交给原文。
  ///
  /// ## [candidates] 为什么是 400（审计 P0-8）
  ///
  /// 实测 `hit > 0` 的**通过率高达 89–99%** —— 也就是说位签名几乎筛不掉东西。
  /// 只取前 80 个进精排，等于让"位命中数"这个区分度很差的指标决定谁能进精排，
  /// 相关块很容易被挤在门外。取 400 只是把精排的输入放宽（多读几百个小块，
  /// 几十 KB），召回明显更稳；最终结果仍由**真实词重叠**决定。
  Future<List<KbChunkHit>> search(
    String query, {
    int topK = 3,
    int candidates = 400,
  }) async {
    final qTerms = tokenizeForIndex(query).toSet();
    if (qTerms.isEmpty) return const <KbChunkHit>[];
    final qBits = <int>[
      for (final t in qTerms) ...bloomBitsOf(t),
    ];
    if (qBits.isEmpty) return const <KbChunkHit>[];

    // ── ① 预筛：单遍扫签名 + **有界最小堆** ──────────────────────────────
    //
    // 改造前三件浪费（审计 P0-8，都发生在**每轮**检索里）：
    //   * `Map<int,int> pre` 会装下 22.6–25.2 万个条目（通过率 89–99%），
    //     每个 key/value 都要装箱；
    //   * `pre.entries.toList()` 再复制一份；
    //   * 对这份列表**完整排序**（O(n log n)）只是为取前 80 个。
    // 现在只维护一个容量 [candidates] 的堆，内存是常数、时间是 O(n log k)。
    final dv = ByteData.view(
        _indexBytes.buffer, _indexBytes.offsetInBytes, _indexBytes.length);
    final top = _TopK(candidates);
    for (var i = 0; i < chunkCount; i++) {
      final base = _kHeaderLen + i * _perChunk + 8;
      var hit = 0;
      for (final bit in qBits) {
        final word = dv.getUint32(base + (bit >> 5) * 4, Endian.little);
        if ((word & (1 << (bit & 31))) != 0) hit++;
      }
      if (hit > 0) top.offer(hit, i);
    }
    if (top.length == 0) return const <KbChunkHit>[];
    // 出堆顺序 = 命中数降序；命中数相同时 chunkId 升序（**显式 tie-break**）。
    final ranked = top.sortedDescending();

    // ── ② 精排：读原文、数真实词重叠 ─────────────────────────────────────
    final raf = await _chunks.open();
    final precise = <KbChunkHit>[];
    try {
      for (var i = 0; i < ranked.length; i++) {
        final id = ranked[i].$1;
        final base = _kHeaderLen + id * _perChunk;
        final off = dv.getUint32(base, Endian.little);
        final len = dv.getUint32(base + 4, Endian.little);
        await raf.setPosition(off);
        final bytes = await raf.read(len);
        final text = utf8.decode(bytes, allowMalformed: true).trim();
        final terms = tokenizeForIndex(text).toSet();
        var overlap = 0;
        for (final t in qTerms) {
          if (terms.contains(t)) {
            // 长词（英文整词/多字）比双字更有信息量，给更高权重。
            overlap += t.length >= 3 ? 3 : 1;
          }
        }
        if (overlap > 0) {
          precise.add(KbChunkHit(text: text, score: overlap, chunkId: id));
        }
      }
    } finally {
      await raf.close();
    }
    if (precise.isEmpty) return const <KbChunkHit>[];
    // tie-break 也显式化：分数相同取 chunkId 小的那个。
    // （`List.sort` 在 Dart 里**不保证稳定**，不定 tie-break 的话同样输入
    //   可能给出不同顺序 —— 那对"可复现"和测试都是麻烦。）
    precise.sort((a, b) {
      final c = b.score.compareTo(a.score);
      return c != 0 ? c : a.chunkId.compareTo(b.chunkId);
    });

    // ── ③ 相关度门槛：沾上一个「怎么」不算"查到了" ────────────────────────
    //
    // 以前 `overlap > 0` 就入选。对**大语料**那等于没有门槛：中文里
    // 「怎么 / 可以 / 什么」这类二元词几乎任何 600 字段落里都有，于是任何问题
    // 都能凑出 2 段语义不相关的资料 —— 而调用方会把它当成"知识库查到的"，
    // 提示词还命令模型「优先依据它们回答」。用户 2026-10-12 的原话：
    // 「本地大模型还是有问题，重建以后链接知识库答得乱七八糟」。
    //
    // 门槛为什么**跟语料规模挂钩**（合成语料实测，见 `kb_index_test.dart`
    // 的「相关度门槛」探针组）：
    //   * 40 篇无关语料 + 1 篇相关：相关段得 **2~4 分**、随机段**一律 1 分**、
    //     部分无关问句直接 **0 段**；
    //   * 但在 3 段的**小语料**里，"共享一个二元词"本身就是强证据
    //     （别的段是 0 分）—— 用户自己导入的笔记正是这种形态。
    // 所以：大语料要求**两个词**同时对得上；小语料维持原来的宽松口径，
    // 不把本来能用的东西改坏。
    //
    // 再加一条**相对**门槛：达不到最好那一段 2/3 分数的，是"顺带沾上"的尾巴
    // （探针里就是"相关段 2 分 + 随机段 1 分"这种形态）。
    //
    // 全都过不了 → 返回空 → 调用方**不注入**，模型按自己知道的答。
    // 这比硬塞两段无关材料要诚实得多。
    // ⚠️ 名字不能叫 `top` —— 上面那个有界最小堆已经占了（`final top = _TopK(...)`）。
    final best = precise.first.score;
    final need = chunkCount >= _kBigCorpusChunks ? 2 : 1;
    final keep = <KbChunkHit>[
      for (final h in precise)
        if (h.score >= need && h.score * 3 >= best * 2) h,
    ];
    if (keep.isEmpty) return const <KbChunkHit>[];
    return keep.length <= topK ? keep : keep.sublist(0, topK);
  }
}

/// 有界最小堆：只保留"最好"的 [capacity] 个 `(hit, chunkId)`。
///
/// "最好" = `hit` 大；`hit` 相同 = `chunkId` 小（显式 tie-break）。
/// 堆顶是当前保留集合里**最差**的那个 —— 新候选只要比它好就顶替它，
/// 于是内存是 O(k)、时间是 O(n log k)，不用为一个 Map + 全排序付出代价。
///
/// 为什么不用 `Map` + `sort`：见 `KbRetriever.search` 里那段说明（审计 P0-8）。
class _TopK {
  _TopK(this.capacity)
      : assert(capacity > 0),
        _hit = <int>[],
        _id = <int>[];

  final int capacity;
  final List<int> _hit;
  final List<int> _id;

  int get length => _hit.length;

  /// `a` 是不是比 `b` **更差**（更差 = 更靠近堆顶）。
  static bool _worse(int h1, int i1, int h2, int i2) =>
      h1 < h2 || (h1 == h2 && i1 > i2);

  bool _isWorseAt(int a, int b) =>
      _worse(_hit[a], _id[a], _hit[b], _id[b]);

  void _swap(int a, int b) {
    final h = _hit[a];
    _hit[a] = _hit[b];
    _hit[b] = h;
    final i = _id[a];
    _id[a] = _id[b];
    _id[b] = i;
  }

  void _siftUp(int i) {
    while (i > 0) {
      final p = (i - 1) ~/ 2;
      if (!_isWorseAt(i, p)) break;
      _swap(i, p);
      i = p;
    }
  }

  void _siftDown(int i) {
    final n = _hit.length;
    while (true) {
      final l = 2 * i + 1;
      if (l >= n) break;
      final r = l + 1;
      var child = l;
      if (r < n && _isWorseAt(r, l)) child = r; // 取两个子里更差的那个
      if (!_isWorseAt(child, i)) break;
      _swap(i, child);
      i = child;
    }
  }

  /// 提一个候选。返回 true 表示它被采用了。
  bool offer(int hit, int chunkId) {
    if (hit <= 0) return false;
    if (_hit.length < capacity) {
      _hit.add(hit);
      _id.add(chunkId);
      _siftUp(_hit.length - 1);
      return true;
    }
    // 不比堆顶（当前最差）好就丢掉。
    if (!_worse(_hit[0], _id[0], hit, chunkId)) return false;
    _hit[0] = hit;
    _id[0] = chunkId;
    _siftDown(0);
    return true;
  }

  /// 取出来并按"最好在前"排好：hit 降序、hit 相同则 id 升序。
  List<(int, int)> sortedDescending() {
    final n = _hit.length;
    final out = List<(int, int)>.generate(n, (i) => (_id[i], _hit[i]));
    out.sort((a, b) {
      final c = b.$2.compareTo(a.$2);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    return out;
  }
}

/// 把检索到的段落拼成"参考资料"块（注入到那一轮的问题前面）。
///
/// 措辞与联网搜索那边**刻意保持一致**：都明确要求"只依据资料、不要编" ——
/// 小模型最容易犯的正是"资料里没有的部分自己圆一段"。
/// 从「包名 → 索引 meta」里挑出**旧切法**建的包（对话页据此提示"去重建"）。
///
/// 为什么独立成函数：这条提示的触发条件**必须能被单测钉住**。
/// 旧切法的索引会把 0.66 新加的相关度门槛**废掉** —— 旧切法把好几篇互不相关的
/// 文章揉进同一块（实测 12 篇 → 2 块，一块里 9 篇），那个块跟**任何**问句都能
/// 对上 ≥2 个词，正好过门槛。这不是门槛的问题（它没权力判断一块里混了几篇），
/// 是索引本身没重建。所以"该提示却没提示"是一个**真缺陷**，
/// 不能只靠界面上肉眼看（知识库页会说，但用户碰得最多的是对话页）。
List<String> legacyChunkPackNames(Map<String, KbIndexMeta?> byName) => <String>[
      for (final e in byName.entries)
        if (e.value?.isLegacyChunking == true) e.key,
    ];

/// 超过这么多段就算"大语料" —— 相关度门槛要按**两个词**算（见 `search` 的 ③）。
///
/// 200 只是个分界：用户自己导入的笔记通常几十段，内置知识库是 25 万段。
const int _kBigCorpusChunks = 200;

String formatKbContext(List<KbChunkHit> hits, {int maxChunks = 3}) {
  if (hits.isEmpty) return '';
  final buf = StringBuffer()
    // ⚠️ 措辞必须是**条件式**的（用户 2026-10-12：知识库答得乱七八糟）。
    //    以前写的是「请优先依据它们回答」—— 那是**无条件命令**：检索一旦没查到
    //    相关的（大语料里很常见），模型也被要求拿这两段无关材料去答，
    //    于是"编"出一段看起来像在回答、其实跟问题无关的话。
    //    现在明确给它"忽略"这个选项，而且把"忽略"写成**正常做法**，
    //    否则小模型宁可硬凑也不肯说"这段资料用不上"。
    ..writeln('下面是本地知识库检索到的资料，它**可能**和问题有关，也可能完全无关。')
    ..writeln('如果确实相关：优先依据它回答，它没提到的部分不要编造，直接说不确定。')
    ..writeln('如果和问题无关：直接忽略它，按你自己知道的回答，不要被它带偏。')
    ..writeln();
  var i = 0;
  for (final h in hits.take(maxChunks)) {
    i++;
    buf.writeln(h.source.isEmpty ? '[$i] ${h.text}' : '[$i]（来自《${h.source}》）${h.text}');
    buf.writeln();
  }
  return buf.toString().trimRight();
}

/// 读一个已建索引的元信息（没有就返回 null）。
Future<KbIndexMeta?> readIndexMeta(String dir) async {
  try {
    final f = File('$dir/index_meta.json');
    if (!f.existsSync()) return null;
    return KbIndexMeta.fromJson(jsonDecode(await f.readAsString()));
  } catch (_) {
    return null;
  }
}

/// 缓存项：`stamp` 是判定失效用的 `(size, mtime)` 指纹，`bytes` 是它占的内存量。
class _CachedIndex {
  const _CachedIndex({
    required this.stamp,
    required this.retriever,
    required this.bytes,
  });

  final String stamp;
  final KbRetriever retriever;
  final int bytes;
}
