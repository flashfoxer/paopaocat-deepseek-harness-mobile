/// Word 文档（`.docx`）**读**的那一半（`assets/toolbox/read-docx.mjs`）的端到端测试。
///
/// ## 为什么这几条必须钉住
///
/// 0.71 先做了「写」（`make-docx.mjs`）。只有"写"的时候，**读**这条路上的错
/// 大多看不出来：技能里写着"读不了 .docx，请把正文粘贴过来"，模型照做，
/// 用户也不会知道其实能读。所以这一轮补的是**读**，并且用三条独立的证据钉住它：
///
///   1. **往返一致**：Markdown → docx → Markdown **逐字相同**。
///      这条最值钱 —— 它同时证明"写"和"读"两边的语义对得上（标题层级、两种列表、
///      嵌套、表格、引用、代码块、分隔线、行内粗斜等宽）。任一边偷懒，它就红。
///   2. **能读别家写的**：这条**不能**只用手写的小 XML 糊过去，也不能只喂我们自己
///      产出的文件 —— 真实 Word/WPS 的写法有好几种变体，所以测试里现造一份
///      "Word 会写的样子"：只给 `styleId` 的标题、中文样式名（`标题 2`）、
///      **显式关闭**的加粗（`<w:b w:val="0"/>`）、外链超链接、两级项目符号、
///      `gridSpan` 合并单元格、以及一张图。这些都是真文件里常见的形状。
///   3. **失败要说人话**：拿 `.xlsx` 冒充 `.docx`、拿老式 `.doc` 当新格式，
///      必须给中文原因（含"是不是 .doc 老格式"），而不是抛一句英文栈。
///
/// ⚠️ 本机**没有** Word / WPS / LibreOffice，所以"Word 打开我们的 docx 长什么样"
///    这一步只能到手机上验；这里能证明的是：**结构合法、语义自洽、能读回来**。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 工具箱目录（测试的工作目录就是 app/）。
const String toolbox = 'assets/toolbox';

Future<ProcessResult> runNode(List<String> args, {String? cwd}) =>
    Process.run('node', args, workingDirectory: cwd);

/// 造"别家写的" .docx 用的脚本：**复用同一个 zip 库**（`office-zip.mjs`），
/// 所以不依赖 python / zip 命令，也不骗自己"外面有工具能造"。
///
/// 用绝对 `file://` URL 引 office-zip.mjs —— 脚本落在临时目录里，
/// 相对 import 会找不到（Node 的 ESM 相对路径是相对**脚本文件**，不是 cwd）。
String fixtureScript(String officeZipUrl) => '''
import { zipWrite } from "$officeZipUrl";
import { writeFileSync } from "node:fs";

const W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
const R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
const P = "http://schemas.openxmlformats.org/package/2006/relationships";
const HEAD = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';

// ── ① "Word 会写的样子"：样式里只有 styleId / 中文样式名 / 显式关加粗 / 外链 /
//      两级项目符号 / gridSpan / 一张图
const doc = HEAD
  + '<w:document xmlns:w="' + W + '" xmlns:r="' + R + '"><w:body>'
  + '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>项目立项书</w:t></w:r></w:p>'
  + '<w:p><w:pPr><w:pStyle w:val="2"/></w:pPr><w:r><w:rPr><w:b w:val="0"/></w:rPr><w:t>背景</w:t></w:r></w:p>'
  + '<w:p><w:r><w:t>我们要做一个 </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>移动端</w:t></w:r>'
  + '<w:r><w:t> 工具，参考 </w:t></w:r>'
  + '<w:hyperlink r:id="rId9"><w:r><w:t>官网</w:t></w:r></w:hyperlink><w:r><w:t>。</w:t></w:r></w:p>'
  + '<w:p><w:pPr><w:pStyle w:val="ListParagraph"/><w:numPr><w:ilvl w:val="0"/>'
  + '<w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>第一点</w:t></w:r></w:p>'
  + '<w:p><w:pPr><w:numPr><w:ilvl w:val="1"/><w:numId w:val="1"/></w:numPr></w:pPr>'
  + '<w:r><w:t>子点</w:t></w:r></w:p>'
  + '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr></w:pPr>'
  + '<w:r><w:t>甲</w:t></w:r></w:p>'
  + '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr></w:pPr>'
  + '<w:r><w:t>乙</w:t></w:r></w:p>'
  + '<w:tbl>'
  + '<w:tr><w:tc><w:p><w:r><w:t>模块</w:t></w:r></w:p></w:tc>'
  + '<w:tc><w:p><w:r><w:t>工时</w:t></w:r></w:p></w:tc></w:tr>'
  + '<w:tr><w:tc><w:tcPr><w:gridSpan w:val="2"/></w:tcPr><w:p><w:r><w:t>合计</w:t></w:r></w:p></w:tc></w:tr>'
  + '<w:tr><w:tc><w:p><w:r><w:t>只有一格</w:t></w:r></w:p></w:tc></w:tr>'
  + '</w:tbl>'
  + '<w:p><w:r><w:drawing><wp:inline xmlns:wp="urn:wp">'
  + '<a:blip xmlns:a="urn:a" r:embed="rId8"/></wp:inline></w:drawing></w:r></w:p>'
  + '</w:body></w:document>';

const styles = HEAD
  + '<w:styles xmlns:w="' + W + '">'
  + '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>'
  + '<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/>'
  + '<w:outlineLvl w:val="0"/></w:style>'
  + '<w:style w:type="paragraph" w:styleId="2"><w:name w:val="标题 2"/>'
  + '<w:outlineLvl w:val="1"/></w:style>'
  + '</w:styles>';

const numbering = HEAD
  + '<w:numbering xmlns:w="' + W + '">'
  + '<w:abstractNum w:abstractNumId="0">'
  + '<w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl>'
  + '<w:lvl w:ilvl="1"><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum>'
  + '<w:abstractNum w:abstractNumId="1">'
  + '<w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>'
  + '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
  + '<w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>'
  + '</w:numbering>';

const rels = HEAD
  + '<Relationships xmlns="' + P + '">'
  + '<Relationship Id="rId1" Type="' + R + '/styles" Target="styles.xml"/>'
  + '<Relationship Id="rId2" Type="' + R + '/numbering" Target="numbering.xml"/>'
  + '<Relationship Id="rId8" Type="' + R + '/image" Target="media/image1.png"/>'
  + '<Relationship Id="rId9" Type="' + R + '/hyperlink" Target="https://example.com/"'
  + ' TargetMode="External"/>'
  + '</Relationships>';

const contentTypes = HEAD
  + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
  + '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
  + '<Default Extension="xml" ContentType="application/xml"/>'
  + '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
  + '</Types>';

const rootRels = HEAD
  + '<Relationships xmlns="' + P + '"><Relationship Id="rId1" Type="' + R
  + '/officeDocument" Target="word/document.xml"/></Relationships>';

// 1×1 的透明 PNG（真图片字节，用来证明 --extract-images 真把图写出来了）
const png = Buffer.from(
  "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
  + "0000000a49444154789c63000100000500010d0a2db40000000049454e44ae426082", "hex");

writeFileSync(process.argv[2], zipWrite([
  ["[Content_Types].xml", contentTypes],
  ["_rels/.rels", rootRels],
  ["word/document.xml", doc],
  ["word/styles.xml", styles],
  ["word/numbering.xml", numbering],
  ["word/_rels/document.xml.rels", rels],
  ["word/media/image1.png", png],
]));

// ── ② 没有样式表的老文件：只能靠"全加粗 + 字号"兜底认标题
const legacyDoc = HEAD
  + '<w:document xmlns:w="' + W + '"><w:body>'
  + '<w:p><w:r><w:rPr><w:b/><w:sz w:val="40"/></w:rPr><w:t>大标题</w:t></w:r></w:p>'
  + '<w:p><w:r><w:rPr><w:b/><w:sz w:val="22"/></w:rPr><w:t>加粗的正文行，不该被当成标题</w:t></w:r></w:p>'
  + '</w:body></w:document>';
writeFileSync(process.argv[3], zipWrite([
  ["[Content_Types].xml", contentTypes],
  ["_rels/.rels", rootRels],
  ["word/document.xml", legacyDoc],
]));
console.log("fixtures ok");
''';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('dsh-docx-'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File write(String name, String content) =>
      File('${tmp.path}/$name')..writeAsStringSync(content);

  /// 代表的 Markdown：把"写"支持的全套语法各用一次（含嵌套列表）。
  const String md = '# 季度总结\n'
      '\n'
      '本季度做了三件事，**重点**是第一件。\n'
      '\n'
      '## 一、交付\n'
      '\n'
      '- 完成了 `read-xlsx.mjs`\n'
      '- 修掉了 *旧 bug*\n'
      '  - 这是嵌套项\n'
      '- 又一条\n'
      '\n'
      '1. 第一\n'
      '2. 第二\n'
      '\n'
      '| 项目 | 数量 |\n'
      '|---|---|\n'
      '| 表格 | 12 |\n'
      '\n'
      '> 改最少，效果最大。\n'
      '\n'
      '```\n'
      'node make-xlsx.mjs in.csv out.xlsx\n'
      '```\n'
      '\n'
      '---\n'
      '\n'
      '收尾。\n';

  group('Markdown → docx → Markdown（往返一致）', () {
    test('往返**逐字一致**：标题/段落/行内/嵌套列表/两种列表/表格/引用/代码块/分隔线', () async {
      final src = write('rt.md', md);
      final docx = '${tmp.path}/rt.docx';
      final mk = await runNode(['$toolbox/make-docx.mjs', src.path, docx]);
      expect(mk.exitCode, 0, reason: 'make-docx 失败：${mk.stderr}');

      final rd = await runNode(['$toolbox/read-docx.mjs', docx]);
      expect(rd.exitCode, 0, reason: 'read-docx 失败：${rd.stderr}');
      expect('${rd.stderr}', contains('[docx] ok op=read'));

      // 逐字比较：两边任何一处语义偷懒（丢了层级、把列表变成文字前缀、
      // 把引用当普通段落…）都会在这里露出来。
      expect('${rd.stdout}', md, reason: '往返不一致 —— 说明"写"或"读"有一边丢了语义');
    });

    test('标题是**真标题样式**（Word 的导航窗格/大纲视图/自动目录都靠它）', () async {
      final src = write('h.md', md);
      final docx = '${tmp.path}/h.docx';
      await runNode(['$toolbox/make-docx.mjs', src.path, docx]);

      final has = await Process.run('sh', ['-c', 'command -v unzip']);
      if (has.exitCode != 0) {
        markTestSkipped('这台机器没有 unzip，跳过结构抽检');
        return;
      }
      final parts = await Process.run('unzip', ['-l', docx]);
      for (final p in <String>[
        'word/styles.xml', 'word/numbering.xml',
        'word/_rels/document.xml.rels', '[Content_Types].xml',
      ]) {
        expect('${parts.stdout}', contains(p), reason: '缺部件 $p（Word 可能忽略编号）');
      }

      final xml = await Process.run('unzip', ['-p', docx, 'word/document.xml']);
      final x = '${xml.stdout}';
      expect(x, contains('<w:pStyle w:val="Heading1"/>'));
      expect(x, contains('<w:pStyle w:val="Heading2"/>'));
      // ⚠️ 标题**不能**给 run 加直接加粗：那样读回来会变成 `# **标题**`
      expect(x, isNot(contains('<w:rPr><w:b/></w:rPr><w:t xml:space="preserve">季度总结')));

      final styles = await Process.run('unzip', ['-p', docx, 'word/styles.xml']);
      final s = '${styles.stdout}';
      expect(s, contains('<w:name w:val="heading 1"/>'));
      expect(s, contains('<w:outlineLvl w:val="0"/>'), reason: '没写大纲级别，导航窗格不会有层级');
      expect(s, contains('w:styleId="Quote"'));
      expect(s, contains('w:styleId="CodeBlock"'));

      // ⚠️ `[Content_Types].xml` 里的方括号在 unzip 里是**通配符**，
      //    不转义的话 `unzip -p` 会匹配不到、静默回空字符串（这条断言就这么假绿过一次）。
      final ct = await Process.run(
          'unzip', ['-p', docx, r'\[Content_Types\].xml']);
      expect('${ct.stdout}', contains('/word/numbering.xml'),
          reason: 'Content_Types 里没声明 numbering，严格的阅读器会整个忽略列表');
    });

    test('列表是**真项目符号与编号**（numbering.xml + numPr），不再是"• "文字前缀', () async {
      final src = write('l.md', md);
      final docx = '${tmp.path}/l.docx';
      await runNode(['$toolbox/make-docx.mjs', src.path, docx]);
      final has = await Process.run('sh', ['-c', 'command -v unzip']);
      if (has.exitCode != 0) { markTestSkipped('没有 unzip'); return; }

      final xml = await Process.run('unzip', ['-p', docx, 'word/document.xml']);
      final x = '${xml.stdout}';
      expect(x, contains('<w:numPr>'), reason: '没有 numPr，Word 里就是普通段落');
      expect(x, contains('<w:numId w:val="1"/>'), reason: '无序列表该用 numId=1');
      expect(x, contains('<w:numId w:val="2"/>'), reason: '有序列表该用 numId=2');
      expect(x, contains('<w:ilvl w:val="1"/>'), reason: '嵌套的第二级没写进去');
      // 老做法（文字前缀）必须消失，否则 Word 里会出现"• • 文字"
      expect(x, isNot(contains('• ')), reason: '还在用"• "文字前缀冒充项目符号');

      final num = await Process.run('unzip', ['-p', docx, 'word/numbering.xml']);
      expect('${num.stdout}', contains('w:numFmt w:val="bullet"'));
      expect('${num.stdout}', contains('w:numFmt w:val="decimal"'));
    });

    test('代码块的语言标记会丢 —— 如实钉住这个已知损失', () async {
      final src = write('c.md', '```sh\nnode a.mjs\n```\n');
      final docx = '${tmp.path}/c.docx';
      await runNode(['$toolbox/make-docx.mjs', src.path, docx]);
      final rd = await runNode(['$toolbox/read-docx.mjs', docx]);
      expect('${rd.stdout}', contains('```\nnode a.mjs\n```'));
      // docx 里没有放语言的位置 → 读回来不该假装有 `sh`
      expect('${rd.stdout}', isNot(contains('```sh')));
    });
  });

  group('read-docx 能读**别家写的** .docx（Word / WPS 形状）', () {
    late String wordlike;
    late String legacy;

    Future<void> makeFixtures() async {
      final libUrl = Uri.file(
              '${Directory.current.path}/$toolbox/office-zip.mjs')
          .toString();
      final script = File('${tmp.path}/fixtures.mjs')
        ..writeAsStringSync(fixtureScript(libUrl));
      wordlike = '${tmp.path}/wordlike.docx';
      legacy = '${tmp.path}/legacy.docx';
      final r = await runNode([script.path, wordlike, legacy]);
      expect(r.exitCode, 0, reason: '造测试用 .docx 失败：${r.stderr}');
    }

    test('样式名（中文）/ 只有 styleId / 显式关加粗 / 外链 / 两级项目符号 / gridSpan 都认得',
        () async {
      await makeFixtures();
      final rd = await runNode(['$toolbox/read-docx.mjs', wordlike]);
      expect(rd.exitCode, 0, reason: '${rd.stderr}');
      final out = '${rd.stdout}';

      // ① 标题：一个靠 styleId（Heading1）、一个靠**中文样式名**（标题 2）
      expect(out, contains('# 项目立项书'), reason: '只有 styleId 的标题没认出来');
      expect(out, contains('## 背景'), reason: '中文样式名（标题 2）的标题没认出来');
      // ② 行内加粗 + 外链超链接（URL 只在 rels 里）
      expect(out, contains('**移动端**'));
      expect(out, contains('[官网](https://example.com/)'),
          reason: '超链接没从 rels 里取到目标');
      // ③ 两级项目符号 + 数字编号（数值由顺序算出来）
      expect(out, contains('- 第一点'));
      expect(out, contains('  - 子点'), reason: '第二级缩进没体现');
      expect(out, contains('1. 甲'));
      expect(out, contains('2. 乙'));
      // ④ 表格：gridSpan 的格子按占位补空、格子少的行补齐到表宽
      expect(out, contains('| 模块 | 工时 |'));
      expect(out, contains('| 合计 |  |'), reason: 'gridSpan=2 没按两列补空');
      expect(out, contains('| 只有一格 |  |'), reason: '只有一格的行动格数没补齐');
      // ⑤ 图片：默认**只标注不抽**
      expect(out, contains('<!-- 图片未提取：media/image1.png -->'));
      expect(Directory('${tmp.path}/imgs').existsSync(), isFalse);
    });

    test('图片：给 --extract-images 才真把图写出来，Markdown 指向它', () async {
      await makeFixtures();
      final outMd = '${tmp.path}/wordlike.md';
      final imgs = '${tmp.path}/imgs';
      final rd = await runNode([
        '$toolbox/read-docx.mjs', wordlike,
        '--extract-images', imgs, '--out', outMd,
      ]);
      expect(rd.exitCode, 0, reason: '${rd.stderr}');
      expect('${rd.stderr}', contains('images=1'), reason: '成功标记里要如实报图片数');

      final png = File('$imgs/media_image1.png');
      expect(png.existsSync(), isTrue, reason: '图片没被写出来');
      expect(png.readAsBytesSync().sublist(0, 4), <int>[0x89, 0x50, 0x4E, 0x47],
          reason: '写出来的不是 PNG 字节');
      expect(File(outMd).readAsStringSync(), contains('![](/'),
          reason: '抽出来了却没在 Markdown 里指过去');
    });

    test('没有样式表的老文件：只能靠"全加粗 + 大字号"兜底，且不许把加粗正文当标题', () async {
      await makeFixtures();
      final rd = await runNode(['$toolbox/read-docx.mjs', legacy]);
      expect(rd.exitCode, 0, reason: '${rd.stderr}');
      expect('${rd.stdout}', contains('# 大标题'), reason: '兜底规则没生效');
      expect('${rd.stdout}', contains('加粗的正文行，不该被当成标题'),
          reason: '加粗正文被误当成标题了（字号 22 = 正文）');
      expect('${rd.stdout}', isNot(contains('# 加粗的正文行')));
    });

    test('--format json 给结构化块、--format txt 去掉行内标记', () async {
      await makeFixtures();
      final j = await runNode(['$toolbox/read-docx.mjs', wordlike, '--format', 'json']);
      expect(j.exitCode, 0);
      expect('${j.stdout}', contains('"type": "heading"'));
      expect('${j.stdout}', contains('"level": 1'));
      expect('${j.stdout}', contains('"type": "list"'));
      expect('${j.stdout}', contains('"ordered": true'));
      expect('${j.stdout}', contains('"type": "table"'));
      expect('${j.stdout}', contains('"type": "image"'));
      // JSON 必须真能解析（不是"看起来像 JSON"）
      expect(() => jsonDecodeAsMap('${j.stdout}'), returnsNormally);

      final t = await runNode(['$toolbox/read-docx.mjs', wordlike, '--format', 'txt']);
      expect('${t.stdout}', contains('移动端'));
      expect('${t.stdout}', isNot(contains('**移动端**')), reason: 'txt 里不该留 Markdown 标记');
      expect('${t.stdout}', contains('模块\t工时'), reason: 'txt 里表格该是制表符分隔');
    });
  });

  group('失败与参数要说人话', () {
    test('拿 .xlsx 冒充 .docx → 非 0 退出 + 中文原因 + 提示可能是 .doc 老格式', () async {
      final csv = write('a.csv', 'a,b\n1,2\n');
      final xlsx = '${tmp.path}/a.xlsx';
      await runNode(['$toolbox/make-xlsx.mjs', csv.path, xlsx]);

      final r = await runNode(['$toolbox/read-docx.mjs', xlsx]);
      expect(r.exitCode, isNot(0));
      expect('${r.stderr}', contains('错误：'));
      expect('${r.stderr}', contains('document.xml'));
      expect('${r.stderr}', contains('.doc'), reason: '要提示"是不是 .doc 老格式"');
    });

    test('不是 zip 的输入也报中文错，不抛英文栈', () async {
      final fake = write('fake.docx', '这不是一个 zip 文件');
      final r = await runNode(['$toolbox/read-docx.mjs', fake.path]);
      expect(r.exitCode, isNot(0));
      expect('${r.stderr}', contains('错误：'));
      expect('${r.stderr}', contains('docx'));
    });

    test('--format 只认 md / txt / json；--out 写出文件并在标记里给绝对路径', () async {
      final bad = await runNode([
        '$toolbox/read-docx.mjs', 'x.docx', '--format', 'pdf',
      ]);
      expect(bad.exitCode, 2, reason: '参数错该是退出码 2');

      final src = write('o.md', '# 标题\n\n正文。\n');
      final docx = '${tmp.path}/o.docx';
      await runNode(['$toolbox/make-docx.mjs', src.path, docx]);
      final out = '${tmp.path}/sub/out.md';
      final r = await runNode(['$toolbox/read-docx.mjs', docx, '--out', out]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect('${r.stderr}', contains('out=$out'));
      expect(File(out).existsSync(), isTrue, reason: '--out 没建目录或没写文件');
      expect(File(out).readAsStringSync(), '# 标题\n\n正文。\n');
    });
  });

  test('读脚本也在落盘表里（否则设备上根本找不到它）', () {
    final table = File('lib/local/android_toolbox.dart').readAsStringSync();
    expect(table, contains("'assets/toolbox/read-docx.mjs'"));
  });
}

/// JSON 解析（放成小函数是为了让 expect 的 reason 能看清失败位置）。
Map<String, dynamic> jsonDecodeAsMap(String s) =>
    (const JsonDecoder().convert(s) as Map).cast<String, dynamic>();
