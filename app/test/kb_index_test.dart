/// 知识库检索索引的回归测试。
///
/// 这一段代码里有**两个最容易悄悄坏掉**的地方，所以都要钉住：
///   1. **流式抽取状态机**（从 JSON 里一边读一边抽 `completion` 字符串，含跨批次、
///      转义、UTF-8 边界）—— 抽错一个字符，检索就会"看着有、却搜不到"；
///   2. **签名/交集**（MinHash 的最小 N 个哈希 + 升序归并）—— 这块错了不会报错，
///      只会"搜出来的是不相关的块"，最难发现。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/local/kb_index.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('分词（中文双字 + 英文整词）', () {
    test('中文取相邻双字，英文取整词（小写）', () {
      final t = tokenizeForIndex('晋城 Jincheng 是 City');
      expect(t, contains('晋城'));
      expect(t, contains('jincheng'));
      expect(t, contains('city'));
      // 单个汉字不成双字，但仍要留下（否则单字查询永远搜不到）
      expect(t, contains('是'));
    });

    test('标点/空白不进词表', () {
      final t = tokenizeForIndex('晋城，山西省。');
      expect(t.any((w) => w.contains('，')), isFalse);
      expect(t, contains('晋城'));
      expect(t, contains('山西'));
    });
  });

  group('切片', () {
    test('优先在换行处断开，且不超过上限', () {
      final text =
          List<String>.generate(20, (i) => '第 $i 段：${'甲' * 50}').join('\n');
      final chunks = chunkText(text, minChars: 100, maxChars: 200);
      expect(chunks.length, greaterThan(1));
      for (final c in chunks) {
        expect(c.length, lessThanOrEqualTo(400)); // 允许单段略超，但不该失控
      }
    });

    test('没有换行的超长段也能切开（按句号）', () {
      final text = List<String>.generate(30, (i) => '这是第 $i 句话，用来验证按句切分。').join();
      final chunks = chunkText(text, minChars: 100, maxChars: 200);
      expect(chunks.length, greaterThan(1));
    });
  });

  group('位签名（Bloom）', () {
    test('同一个词一定命中（不像 MinHash 会漏）', () {
      final bloom = bloomOf(<String>['晋城', '山西', 'zhongyuan']);
      // 把"晋城"这一个词的位打出来，必须全部命中
      final bits = bloomBitsOf('晋城');
      expect(bloomHits(bloom, bits), bits.length);
    });

    test('签名里没有的词基本不命中（可能有个别误判，但不会全中）', () {
      final bloom = bloomOf(<String>['晋城', '山西']);
      final bits = bloomBitsOf('香港');
      expect(bloomHits(bloom, bits), lessThan(bits.length));
    });

    test('词序不影响签名', () {
      final a = bloomOf(<String>['晋城', '山西', 'zhongyuan']);
      final b = bloomOf(<String>['zhongyuan', '晋城', '山西']);
      expect(a, equals(b));
    });
  });

  group('建索引 + 检索（真写文件、真读回来）', () {
    test('问“晋城是什么”能命中晋城那一块', () async {
      final dir = Directory.systemTemp.createTempSync('kbidx_');
      final src = File('${dir.path}/data.json');
      src.writeAsStringSync(jsonEncode(<Object>[
        <String, String>{
          'completion': '昭通机场（ZPZT）是位于中国云南昭通的民用机场，始建于1935年，'
              '1960年3月开通往返航班，1986年停止使用，1991年11月扩建。',
          'source': 'wikipedia.zh2307',
        },
        <String, String>{
          'completion': '晋城位于山西省东南部，古称泽州，是华夏文明发祥地之一。'
              '晋城下辖城区、泽州县、高平市、阳城县、陵川县、沁水县，境内有太行山。',
          'source': 'wikipedia.zh2307',
        },
        <String, String>{
          'completion': '黄大仙文化公园是香港一个公园，位于九龙黄大仙摩士公园，'
              '原址为摩士二号公园的苗圃，后改建为以中国文化为主题的公园。',
          'source': 'wikipedia.zh2307',
        },
      ]));

      final built = await KbIndexer.build(
          sourcePath: src.path, outDir: '${dir.path}/idx');
      expect(built.cancelled, isFalse);
      expect(built.chunks, greaterThan(0));

      final meta = await readIndexMeta('${dir.path}/idx');
      expect(meta, isNotNull);
      expect(meta!.chunks, built.chunks);
      expect(meta.sourceFile, 'data.json');

      final ret = await KbRetriever.open('${dir.path}/idx');
      expect(ret, isNotNull);
      final hits = await ret!.search('晋城是什么', topK: 3);
      expect(hits, isNotEmpty, reason: '一条都没命中');
      expect(hits.first.text, contains('晋城'));
      expect(hits.first.score, greaterThan(0));

      // 不相关的问法不该把"晋城"那一段排第一
      final other = await ret.search('黄大仙公园在哪', topK: 1);
      expect(other.first.text, contains('黄大仙'));
    });

    test('JSON 转义与换行能正确还原（\\n / \\" / \\uXXXX）', () async {
      final dir = Directory.systemTemp.createTempSync('kbidx2_');
      final src = File('${dir.path}/d.json');
      // 手写 JSON（不走 jsonEncode，确保能测到 raw 转义序列）
      src.writeAsStringSync(
          '[{"completion":"第一行\\n第二行 说“晋城”\\u4e00\\u4e8c三四","source":"x"}]');
      await KbIndexer.build(sourcePath: src.path, outDir: '${dir.path}/idx');
      final ret = await KbRetriever.open('${dir.path}/idx');
      expect(ret, isNotNull);
      final hits = await ret!.search('第一行第二行', topK: 1);
      expect(hits, isNotEmpty);
      // 关键：\n 变成了真换行、\uXXXX 变成了汉字 —— 而不是留下 "\n" 四个字符
      expect(hits.first.text.contains('第一行'), isTrue);
      expect(hits.first.text.contains(r'\n'), isFalse);
      expect(hits.first.text.contains('一二'), isTrue);
    });

    test('取消：中途停下要如实报 cancelled（界面别假装建好了）', () async {
      final dir = Directory.systemTemp.createTempSync('kbidx3_');
      final src = File('${dir.path}/big.json');
      final buf = StringBuffer('[');
      for (var i = 0; i < 2000; i++) {
        buf.write('{"completion":"第 $i 条：${'测试内容' * 20}"}');
        if (i < 1999) buf.write(',');
      }
      buf.write(']');
      src.writeAsStringSync(buf.toString());

      var n = 0;
      final built = await KbIndexer.build(
        sourcePath: src.path,
        outDir: '${dir.path}/idx',
        isCancelled: () => ++n > 2, // 读两三批就取消
      );
      expect(built.cancelled, isTrue);
    });

    test('formatKbContext：带编号、并且明确要求“别编”', () {
      final text = formatKbContext(const <KbChunkHit>[
        KbChunkHit(text: '晋城位于山西省东南部。', score: 5, chunkId: 1),
      ]);
      expect(text, contains('[1] 晋城位于山西省东南部。'));
      expect(text, contains('不要编造'));
      expect(formatKbContext(const <KbChunkHit>[]), isEmpty);
    });

    test('没有索引目录时 open 返回 null（界面据此显示“还没建索引”）', () async {
      final dir = Directory.systemTemp.createTempSync('kbidx4_');
      expect(await KbRetriever.open('${dir.path}/nothing'), isNull);
      expect(await readIndexMeta('${dir.path}/nothing'), isNull);
    });

    test('纯文本（非 JSON）也能建：按行处理', () async {
      final dir = Directory.systemTemp.createTempSync('kbidx5_');
      final src = File('${dir.path}/notes.txt');
      src.writeAsStringSync(
          '今天去了晋城的皇城相府，很有历史感。\n\n另一段：这里还有珏山和青莲寺，'
          '都是全国重点文物保护单位。\n');
      final built = await KbIndexer.build(
        sourcePath: src.path,
        outDir: '${dir.path}/idx',
        textField: 'completion', // 文本里没有这个字段 → 走"整段"兜底
      );
      expect(built.chunks, greaterThan(0));
      final ret = await KbRetriever.open('${dir.path}/idx');
      expect(ret, isNotNull);
      final hits = await ret!.search('皇城相府', topK: 1);
      expect(hits, isNotEmpty);
      expect(hits.first.text, contains('皇城相府'));
    });
  });

  group('索引缓存（审计 P0-7：原来每轮都整份重读 35 MB）', () {
    /// 建一份小索引，返回它的目录。
    Future<Directory> buildSmall(String tag) async {
      final dir = Directory.systemTemp.createTempSync('kbcache_$tag');
      final src = File('${dir.path}/d.json');
      src.writeAsStringSync(jsonEncode(<Object>[
        <String, String>{'completion': '晋城位于山西省东南部，古称泽州。', 'source': 'x'},
        <String, String>{'completion': '昭通机场位于云南昭通。', 'source': 'x'},
      ]));
      await KbIndexer.build(sourcePath: src.path, outDir: '${dir.path}/idx');
      return dir;
    }

    setUp(KbRetriever.clearCache);

    test('第二次 open 命中缓存，返回**同一个实例**（省掉那 35 MB 读盘）', () async {
      final dir = await buildSmall('a');
      final a = await KbRetriever.open('${dir.path}/idx');
      final b = await KbRetriever.open('${dir.path}/idx');
      expect(a, isNotNull);
      expect(identical(a, b), isTrue,
          reason: '每次 open 都新建 = 每轮白读整份索引（P0-7 回归）');
      expect(KbRetriever.cachedCountForTest, 1);
      expect(KbRetriever.cachedBytesForTest, greaterThan(0));
    });

    test('索引文件变了（重建）→ 缓存失效，拿到新实例', () async {
      final dir = await buildSmall('b');
      final a = await KbRetriever.open('${dir.path}/idx');
      expect(a, isNotNull);

      // 换内容重建（长度也会变，size 或 mtime 至少一个变）
      final src = File('${dir.path}/d.json');
      src.writeAsStringSync(jsonEncode(<Object>[
        <String, String>{'completion': '晋城位于山西省东南部，古称泽州，有皇城相府。', 'source': 'x'},
        <String, String>{'completion': '昭通机场位于云南昭通，始建于1935年。', 'source': 'x'},
        <String, String>{'completion': '黄大仙文化公园在香港九龙。', 'source': 'x'},
      ]));
      await KbIndexer.build(sourcePath: src.path, outDir: '${dir.path}/idx');

      final b = await KbRetriever.open('${dir.path}/idx');
      expect(identical(a, b), isFalse, reason: '索引变了还复用旧对象 = 检索结果不对');
      // 新索引要能查到新内容，证明拿到的确实是重建后的那份
      final hits = await b!.search('皇城相府', topK: 3);
      expect(hits, isNotEmpty);
      expect(hits.first.text, contains('皇城相府'));
    });

    test('clearCache 之后缓存归零，且还能正常重新打开', () async {
      final dir = await buildSmall('c');
      await KbRetriever.open('${dir.path}/idx');
      expect(KbRetriever.cachedCountForTest, 1);

      KbRetriever.clearCache();
      expect(KbRetriever.cachedCountForTest, 0);
      expect(KbRetriever.cachedBytesForTest, 0);

      final again = await KbRetriever.open('${dir.path}/idx');
      expect(again, isNotNull);
      expect(KbRetriever.cachedCountForTest, 1);
    });

    test('重复 open 同一个包不会把占用算重（内存记账要准）', () async {
      final dir = await buildSmall('d');
      await KbRetriever.open('${dir.path}/idx');
      final once = KbRetriever.cachedBytesForTest;
      await KbRetriever.open('${dir.path}/idx');
      await KbRetriever.open('${dir.path}/idx');
      expect(KbRetriever.cachedBytesForTest, once,
          reason: '重复命中不该重复累加 —— 否则预算会被虚耗，早早把能用的缓存淘汰掉');
      expect(KbRetriever.cachedCountForTest, 1);
    });

    test('目录里没有索引 → 返回 null，且不往缓存里塞东西', () async {
      final dir = Directory.systemTemp.createTempSync('kbcache_e');
      KbRetriever.clearCache();
      expect(await KbRetriever.open('${dir.path}/nope'), isNull);
      expect(KbRetriever.cachedCountForTest, 0);
    });
  });

  group('预筛的 tie-break 是显式的（审计 P0-8）', () {
    /// 造一份"多块并列"的索引。
    ///
    /// ⚠️ 构造上有讲究：`KbIndexer` 不是按条目切块 —— 它把内容攒到
    /// ≥2400 字符再按 600 字切（`chunkText(minChars: 200, maxChars: 600)`）。
    /// 所以"12 条短条目"会被并成**一块**（第一版就是这么写的，结果只出 1 条命中）。
    /// 这里改成一条足够长的文本，让「晋城」反复出现在多个块里 →
    /// 多块分数相同（都只命中一个双字词）= 精排必然并列。
    Future<Directory> buildTied() async {
      final dir = Directory.systemTemp.createTempSync('kbtie_');
      final buf = StringBuffer();
      for (var i = 0; i < 40; i++) {
        buf.write('晋城位于山西省东南部，古称泽州，是华夏文明发祥地之一。');
        buf.write('第$i段补充说明，用来把内容撑到切块长度以上。');
        buf.write('太行山南麓的陉道与关隘在此交汇，泽州古城保存完好。\n');
      }
      final src = File('${dir.path}/d.json');
      src.writeAsStringSync(jsonEncode(<Object>[
        <String, String>{'completion': buf.toString(), 'source': 'x'},
      ]));
      await KbIndexer.build(sourcePath: src.path, outDir: '${dir.path}/idx');
      return dir;
    }

    test('同一查询跑两次，结果顺序完全一致（可复现）', () async {
      final dir = await buildTied();
      KbRetriever.clearCache();
      final r = (await KbRetriever.open('${dir.path}/idx'))!;
      final a = await r.search('晋城', topK: 5);
      final b = await r.search('晋城', topK: 5);
      expect(a.map((h) => h.chunkId).toList(), b.map((h) => h.chunkId).toList(),
          reason: '同样输入给出不同顺序 = 没有 tie-break（旧代码靠不稳定的 sort）');
    });

    test('分数并列时取 chunkId **小**的那个（显式规则）', () async {
      final dir = await buildTied();
      KbRetriever.clearCache();
      final r = (await KbRetriever.open('${dir.path}/idx'))!;
      final hits = await r.search('晋城', topK: 12);
      expect(hits.length, greaterThan(1));
      // 全是同样文本 → 分数全等 → 按 chunkId 升序
      final ids = hits.map((h) => h.chunkId).toList();
      final sorted = List<int>.from(ids)..sort();
      expect(ids, sorted, reason: '并列时没有按 chunkId 升序 —— tie-break 没生效');
      for (var i = 1; i < hits.length; i++) {
        expect(hits[i].score, hits[0].score);
      }
    });

    test('candidates 够大时不会把相关块挤掉（晋城那条回归）', () async {
      final dir = await buildTied();
      KbRetriever.clearCache();
      final r = (await KbRetriever.open('${dir.path}/idx'))!;
      final hits = await r.search('晋城是什么地方', topK: 3);
      expect(hits, isNotEmpty);
      expect(hits.first.text, contains('晋城'));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 文档边界（2026-10-12 用户：「本地大模型调用知识库是没什么效用的，
  // 感觉回答得乱七八糟」→ 挖出来的**根因**）
  //
  // 改之前：`chunkText` 把整份语料当成**一条连续的流**，只按长度切，
  // 从不看文档边界 —— 连续几篇互不相关的文档被合并进同一块。实测：
  //
  //   12 篇互不相关的短文档 / 722 字 →
  //     [0] 545 字 · 含 9 篇 → [机场, 红烧肉, 月球, 公司简介, 量子纠缠,
  //                              煮米饭, 报销流程, 长城, 咖啡因]
  //     [1] 176 字 · 含 3 篇 → [产品线, 光合作用, 办公楼]
  //
  // 后果致命：一块同时讲红烧肉和量子纠缠 → 任何问句都命中它 →
  // 检索排名失去意义（实测 top-1 命中 1/11，修完 15/16）。
  // 而且小知识库只有 2~3 块时，`topK: 3` 等于把整份知识库塞给模型。
  //
  // 这一组测试就是钉死"**空行 = 硬边界，绝不跨边界合并**"。
  // ══════════════════════════════════════════════════════════════════════════
  group('切片必须尊重文档边界（跨文档合并 = 检索失准的根因）', () {
    // 每篇自带一个【标记】，用来数"这一块里塞了几篇"。
    List<String> docs(int n) => <String>[
          for (var i = 0; i < n; i++)
            '【第$i篇】${'这一篇只讲第 $i 件事，' * 8}',
        ];

    test('12 篇短文档 → 12 块，每块只含 1 篇（改之前是 2 块，一块含 9 篇）', () {
      final d = docs(12);
      final chunks = chunkText(d.join('\n\n'));
      expect(chunks.length, 12, reason: '被合并了 —— 文档边界没生效');
      for (final c in chunks) {
        final tags = RegExp(r'【第(\d+)篇】').allMatches(c).map((m) => m.group(1)).toList();
        expect(tags.length, 1, reason: '这一块里塞了 ${tags.length} 篇（$tags）—— 跨文档合并了');
      }
    });

    test('空行（硬边界）多种写法都认：\n\n / 空行带空格 / \r\n\r\n', () {
      for (final sep in <String>['\n\n', '\n   \n', '\r\n\r\n', '\n\n\n']) {
        final chunks = chunkText('【甲】${'甲的内容。' * 10}$sep【乙】${'乙的内容。' * 10}');
        expect(chunks.length, 2, reason: '分隔符 $sep 没被当成硬边界');
        expect(chunks[0], contains('【甲】'));
        expect(chunks[1], contains('【乙】'));
      }
    });

    test('单换行**不是**硬边界：同一篇里的软换行仍然可以合并成一块', () {
      final chunks = chunkText('第一行\n第二行\n第三行');
      expect(chunks.length, 1, reason: '同一篇里的软换行不该拆成多块');
      expect(chunks.single, contains('第一行'));
      expect(chunks.single, contains('第三行'));
    });

    test('一篇超长文档仍然在**篇内**按句号切开，且不越界', () {
      final chunks = chunkText('【长文】${'这是一句很长的话。' * 200}');
      expect(chunks.length, greaterThan(1), reason: '超长文档没切开');
      for (final c in chunks) {
        expect(c.length, lessThanOrEqualTo(700), reason: '切完还是超长');
        expect(RegExp(r'【第').allMatches(c).length, 0);
      }
    });

    test('短文档不会被丢掉（硬边界优先于 minChars）', () {
      final chunks = chunkText('【短甲】就一句。\n\n【短乙】也就一句。');
      expect(chunks.length, 2);
      expect(chunks[0], contains('就一句'));
      expect(chunks[1], contains('也就一句'));
    });
  });

  group('老索引要能被认出来（升级 App 不会让已有索引变好）', () {
    test('meta 里没有 chunkMode（老文件）→ 判定为旧切法', () {
      final m = KbIndexMeta.fromJson(<String, dynamic>{
        'chunks': 123,
        'sourceBytes': 456,
        'signatureSize': 8,
        'builtAt': DateTime(2026, 10, 1).toIso8601String(),
        'sourceFile': 'wiki.json',
      });
      expect(m, isNotNull);
      expect(m!.chunkMode, kChunkModeLegacy,
          reason: '默认成新版的话，老索引会被误判成"已经好了"，用户永远看不到重建提示');
      expect(m.isLegacyChunking, isTrue);
    });

    test('新写的 meta 带上当前口径，且判定为不旧', () {
      final m = KbIndexMeta.fromJson(<String, dynamic>{
        'chunks': 1,
        'sourceBytes': 2,
        'signatureSize': 8,
        'builtAt': DateTime(2026, 10, 12).toIso8601String(),
        'sourceFile': 'a.json',
        'chunkMode': kChunkModeDocBoundary,
      });
      expect(m!.isLegacyChunking, isFalse);
      expect(m.toJson()['chunkMode'], kChunkModeDocBoundary,
          reason: 'toJson 漏了它 → 落盘后又变回"老索引"，会永远提示重建');
    });

    test('真建一次索引 → 落盘的 meta 就是新口径', () async {
      final dir = Directory.systemTemp.createTempSync('kbm-');
      addTearDown(() { if (dir.existsSync()) dir.deleteSync(recursive: true); });
      final src = File('${dir.path}/d.json');
      src.writeAsStringSync('["${'甲。' * 40}", "${'乙。' * 40}"]');
      await KbIndexer.build(sourcePath: src.path, outDir: '${dir.path}/idx');
      final meta = await readIndexMeta('${dir.path}/idx');
      expect(meta, isNotNull);
      expect(meta!.isLegacyChunking, isFalse, reason: '新建的索引被判成旧切法了');
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 相关度门槛（用户 2026-10-12：「本地大模型还是有问题，重建以后链接知识库
  // 答得乱七八糟」）
  //
  // 以前 `overlap > 0` 就入选。对内置知识库那种 25 万段的语料，**等于没有门槛**：
  // 「怎么 / 可以 / 什么」这类二元词几乎任何 600 字段落都有 → 任何问题都能凑出
  // 2 段语义不相关的资料，而提示词又命令模型「优先依据它们回答」→ 答案全是编的。
  //
  // 这一组用**合成语料**把口径钉死（用户批准方案时明确要的：「用合成语料探针
  // 先量出来」）。实测分布：
  //   相关段 **2~4 分** · 随机段**一律 1 分** · 部分无关问句直接 **0 段**。
  // 门槛因此分两层：大语料要**两个词**对得上；达不到最好那段 2/3 分数的尾巴丢掉。
  // ══════════════════════════════════════════════════════════════════════════
  group('相关度门槛', () {
    // 一篇"什么话题都沾一点、但什么都不讲"的维基式填充文。
    // 刻意塞进「怎么办」—— 它只和「红烧肉怎么做」共享一个「怎么」，
    // 正好是"沾上一个通用词就当成查到了"的那种假命中。
    String filler(String topic) =>
        '$topic是一件很有意思的事情，我们可以从很多角度来看它，'
        '遇到问题怎么办是很多人关心的事，不同的人会有不同的理解，'
        '总的来说它和我们的日常生活有密切的关系，也值得进一步了解，'
        '如果你对这个话题感兴趣，可以查阅更多的资料，这里只是简单介绍，'
        '具体的内容还需要看专业的书籍。';

    /// 241 段（> `_kBigCorpusChunks` 的 200，走大语料口径）。
    /// 第 7 篇的主题故意叫「长城」——「长城是」会和「晋城是什么」共享「城是」，
    /// 制造出一条 1 分的随机尾巴，用来验证相对门槛真的把它砍掉了。
    Future<KbRetriever> buildBig() async {
      final dir = Directory.systemTemp.createTempSync('kbrel_');
      final src = File('${dir.path}/d.json');
      final parts = <String>[
        for (var i = 0; i < 240; i++)
          jsonEncode(<String, String>{
            'completion': filler(i == 7 ? '长城' : '第$i号话题'),
            'source': 'f$i',
          }),
        jsonEncode(<String, String>{
          'completion': '晋城是山西省下辖的地级市，古称泽州，下辖城区、泽州县、高平市。',
          'source': 'jin',
        }),
      ];
      src.writeAsStringSync('[${parts.join(',')}]');
      await KbIndexer.build(sourcePath: src.path, outDir: '${dir.path}/idx');
      final r = await KbRetriever.open('${dir.path}/idx');
      expect(r, isNotNull);
      return r!;
    }

    test('大语料 + 无关问句 → 一段都不给（不再硬塞 2 段无关材料）', () async {
      final r = await buildBig();
      final hits = await r.search('红烧肉怎么做', topK: 3);
      expect(hits, isEmpty,
          reason: '只共享一个「怎么」也被当成"查到了" —— 门槛没生效');
    });

    test('大语料 + 相关问句 → 命中正确那段，且分数过门槛', () async {
      final r = await buildBig();
      final hits = await r.search('晋城是什么', topK: 3);
      expect(hits, isNotEmpty, reason: '真相关的也一起被门槛挡了 —— 调过头了');
      expect(hits.first.text, contains('晋城'));
      expect(hits.first.score, greaterThanOrEqualTo(2));
    });

    test('"相关段 2 分 + 随机段 1 分" → 随机尾巴必须被砍掉', () async {
      final r = await buildBig();
      final hits = await r.search('晋城是什么', topK: 3);
      for (final h in hits) {
        expect(h.text, contains('晋城'),
            reason: '把只沾了一个通用词的段也注进去了（分数 ${h.score}）：'
                '${h.text.substring(0, 24)}');
      }
    });

    test('小语料口径**不变**：用户自己导入的笔记不许被大语料门槛连坐', () async {
      final dir = Directory.systemTemp.createTempSync('kbrel_small_');
      final src = File('${dir.path}/d.json');
      src.writeAsStringSync(jsonEncode(<Object>[
        <String, String>{'completion': '昭通机场位于云南昭通。', 'source': 'a'},
        <String, String>{
          'completion': '晋城位于山西省东南部，古称泽州，是华夏文明发祥地之一。',
          'source': 'b',
        },
      ]));
      await KbIndexer.build(sourcePath: src.path, outDir: '${dir.path}/idx');
      final r = await KbRetriever.open('${dir.path}/idx');
      final hits = await r!.search('晋城是什么', topK: 3);
      expect(hits, isNotEmpty,
          reason: '小语料被大语料的门槛连坐了 —— 用户自己的笔记反而查不到了');
      expect(hits.first.text, contains('晋城'));
    });

    test('交给模型的材料措辞必须是条件式的（无关时允许忽略）', () {
      // 为什么用读源码：这条是"给模型的措辞"，没有可断言的返回值；
      // 而它恰恰是"答得乱七八糟"的第二个根因（无条件命令模型用资料）。
      final kb = File('lib/local/kb_index.dart').readAsStringSync();
      expect(kb.contains('如果和问题无关：直接忽略它'), isTrue,
          reason: '又变回"无条件命令模型依据资料回答"了');
      expect(kb.contains('请优先依据它们回答；'), isFalse,
          reason: '旧的无条件措辞还在');
      final sys = File('lib/local/local_chat.dart').readAsStringSync();
      expect(sys.contains('如果它和问题无关：直接忽略'), isTrue,
          reason: '系统提示又变成无条件命令了');
    });
  });
}
