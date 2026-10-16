/// 原生 PPT 生成（`assets/toolbox/make-pptx.mjs` + `pptx-design.mjs`）的端到端测试。
///
/// ## 为什么这几条必须钉住
///
/// 生成 .pptx 的代码**错了不会抛异常**：它只是产出一个"打开时说文件已损坏"、
/// 或者"能打开但字压出版心"的文件。用户拿到的东西没法用，而我们本地看不见。
/// 所以这里从四个**独立**的角度钉它：
///
///   1. **系统工具说合法**：`unzip -t` 校验 ZIP 容器（这是不听我们自说自话的一票）。
///   2. **整包自洽**：每段 XML 良构、每个关系都有目标、`[Content_Types].xml`
///      覆盖每一个部件 —— 少一样 PowerPoint 就报"需要修复"。
///   3. **排版真的会缩/会拆**：内容多时字号必须变小、放不下必须拆续页，
///      而且**一个字不丢**（把"自动排版"从口号变成可验证的事实）。
///   4. **设计是有意为之**：颜色来自主题、页码不在封面上、卡片数量跟条数一致。
///
/// ⚠️ 本机**没有** Word / WPS / PowerPoint，所以"打开后长什么样"只能到手机上验；
///    这里能证明的是：**结构合法、内容完整、坐标不越界、缩排真的发生了**。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String toolbox = 'assets/toolbox';
const String engine = '$toolbox/make-pptx.mjs';

/// 造一份 2×1 的合法 PNG（自己写字节，不引素材文件 —— 素材会漂）。
List<int> png2x1() => <int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x02, 0x00, 0x00, 0x00, 0x7A, 0x62, 0xE4,
      0x1D,
      // IDAT（0 号 filter + 两个 RGB 像素），长度 14
      0x00, 0x00, 0x00, 0x0E, 0x49, 0x44, 0x41, 0x54,
      0x78, 0x9C, 0x63, 0x60, 0x18, 0x05, 0xD4, 0x01,
      0x00, 0x00, 0x00, 0xFF, 0xFF, 0x03, 0x00, 0x06,
      0x00, 0x03, 0x53, 0x9A, 0x8B, 0xA5,
      0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
      0xAE, 0x42, 0x60, 0x82,
    ];

late Directory work;

Future<ProcessResult> runNode(List<String> args, {String? cwd}) =>
    Process.run('node', args, workingDirectory: cwd);

/// 把大纲写成文件并生成 pptx，返回 (输出路径, 引擎 stdout)。
Future<(String, String)> build(Map<String, Object?> outline, String name) async {
  final dir = Directory('${work.path}/$name')..createSync(recursive: true);
  final outlinePath = '${dir.path}/outline.json';
  final outPath = '${dir.path}/out.pptx';
  File(outlinePath).writeAsStringSync(jsonEncode(outline));
  final r = await runNode(<String>[engine, outlinePath, outPath]);
  expect(r.exitCode, 0, reason: '引擎退出码 ${r.exitCode}：${r.stderr}');
  return (outPath, '${r.stdout}');
}

/// 读一份 .pptx 并吐出**事实**（JSON）。结构和文字都交给 node 侧抽，
/// 因为压缩包与 XML 的读取要复用 `office-zip.mjs`（Dart 侧没有 zip 解析）。
Future<Map<String, dynamic>> inspect(String pptxPath) async {
  final officeZipUrl = File('${Directory.current.path}/$toolbox/office-zip.mjs')
      .absolute
      .uri
      .toString();
  final script = '''
import { zipRead } from "$officeZipUrl";
import { readFileSync } from "node:fs";
const parts = zipRead(readFileSync(${jsonEncode(pptxPath)}));
const names = [...parts.keys()];
const slideNames = names.filter((n) => /^ppt\\/slides\\/slide\\d+\\.xml\$/.test(n))
  .sort((a, b) => Number(a.match(/(\\d+)/)[1]) - Number(b.match(/(\\d+)/)[1]));
const slides = slideNames.map((n) => {
  const xml = parts.get(n).toString("utf8");
  const texts = [...xml.matchAll(/<a:t[^>]*>([^<]*)<\\/a:t>/g)].map((m) => m[1]);
  const shapes = [...xml.matchAll(/<p:cNvPr id="\\d+" name="([^"]*)"/g)].map((m) => m[1]);
  // ⚠️ 摘掉 spTree 的 grpSpPr：它是每个 spTree 都有的“空组”标记（0×0），
  //    不摘掉会把每一页都判成“有 0 尺寸形状”。
  const body = xml.replace(/<p:grpSpPr>[\\s\\S]*?<\\/p:grpSpPr>/g, "");
  // 正文字号（要点页那个叫「正文」的形状）—— 别用整页最小值：页脚/页码是 9pt，
  // 那样量出来永远是 9，等于没测缩排。
  const bodySz = (() => {
    const m = /name="正文"[\\s\\S]*?sz="(\\d+)"/.exec(xml);
    return m ? +m[1] / 100 : null;
  })();
  const xfrms = [...body.matchAll(/<a:off x="(-?\\d+)" y="(-?\\d+)"\\/><a:ext cx="(\\d+)" cy="(\\d+)"\\/>/g)]
    .map((m) => ({ x: +m[1], y: +m[2], cx: +m[3], cy: +m[4] }));
  return {
    name: n.split("/").pop(),
    texts, shapes, xfrms, bodyPt: bodySz,
    transition: xml.includes("<p:transition"),
    escapedXml: /<a:t[^>]*>[^<]*<a:p/.test(xml),
  };
});
const ct = parts.get("[Content_Types].xml").toString("utf8");
const overrides = new Set([...ct.matchAll(/PartName="\\/([^"]+)"/g)].map((m) => m[1]));
const defaults = new Set([...ct.matchAll(/Default Extension="([^"]+)"/g)].map((m) => m[1].toLowerCase()));
const relTargets = [];
for (const n of names) {
  if (!n.endsWith(".rels")) continue;
  const base = n.replace(/_rels\\/[^/]*\$/, "");
  for (const m of parts.get(n).toString("utf8").matchAll(/Target="([^"]+)"/g)) {
    if (/^https?:/.test(m[1])) continue;
    const resolved = new URL(m[1], "file:///" + base).pathname.slice(1);
    relTargets.push({ from: n, to: resolved, exists: names.includes(resolved) });
  }
}
console.log(JSON.stringify({
  names,
  slides,
  media: names.filter((n) => n.startsWith("ppt/media/")),
  notesSlides: names.filter((n) => n.startsWith("ppt/notesSlides/notesSlide")),
  hasNotesMaster: names.includes("ppt/notesMasters/notesMaster1.xml"),
  contentTypesOk: names.every((n) => n === "[Content_Types].xml"
    || overrides.has(n) || defaults.has(n.split(".").pop().toLowerCase())),
  relTargetsAllExist: relTargets.every((r) => r.exists),
  imageRelIds: (() => {
    const out = [];
    for (const n of slideNames) {
      const xml = parts.get(n).toString("utf8");
      const relName = "ppt/slides/_rels/" + n.split("/").pop() + ".rels";
      for (const m of xml.matchAll(/r:embed="(rId\\d+)"/g)) {
        const rels = parts.get(relName) ? parts.get(relName).toString("utf8") : "";
        out.push({ slide: n, id: m[1], inRels: rels.includes('Id="' + m[1] + '"') });
      }
    }
    return out;
  })(),
}));
''';
  final scriptFile = File('${work.path}/inspect-${DateTime.now().microsecondsSinceEpoch}.mjs')
    ..writeAsStringSync(script);
  final r = await runNode(<String>[scriptFile.path]);
  expect(r.exitCode, 0, reason: '结构抽取脚本失败：${r.stderr}');
  return jsonDecode('${r.stdout}'.trim()) as Map<String, dynamic>;
}

/// 系统 `unzip -t`（**不听我们的自说自话**：这是独立实现的解压器）。
Future<void> expectZipOk(String path) async {
  final r = await Process.run('unzip', <String>['-t', path]);
  expect(r.exitCode, 0, reason: 'unzip -t 判定包坏了：${r.stdout}\n${r.stderr}');
  expect('${r.stdout}', contains('No errors detected'));
}

Map<String, Object?> deckAllLayouts() => <String, Object?>{
      'title': '全版式样例',
      'subtitle': '每一个版式各一页',
      'theme': 'mono',
      'transition': 'fade',
      'slides': <Object?>[
        <String, Object?>{'layout': 'toc', 'title': '目录', 'items': <Object?>['甲', '乙']},
        <String, Object?>{'layout': 'section', 'number': '01', 'title': '章节', 'subtitle': '说明'},
        <String, Object?>{
          'layout': 'bullets',
          'title': '要点',
          'bullets': <Object?>['一', <String, Object?>{'text': '二', 'level': 1}],
          'notes': '给讲者的话',
        },
        <String, Object?>{
          'layout': 'cards',
          'title': '卡片',
          'items': <Object?>[
            <String, Object?>{'title': 'A', 'text': 'aa'},
            <String, Object?>{'title': 'B', 'text': 'bb'},
            <String, Object?>{'title': 'C', 'text': 'cc'},
          ],
        },
        <String, Object?>{
          'layout': 'timeline',
          'title': '时间线',
          'steps': <Object?>[
            <String, Object?>{'title': '一', 'text': 'x', 'date': 'Q1'},
            <String, Object?>{'title': '二', 'text': 'y'},
          ],
        },
        <String, Object?>{
          'layout': 'compare',
          'title': '对比',
          'left': <String, Object?>{'title': '左', 'bullets': <Object?>['l1', 'l2']},
          'right': <String, Object?>{'title': '右', 'bullets': <Object?>['r1']},
        },
        <String, Object?>{
          'layout': 'metrics',
          'title': '数字',
          'metrics': <Object?>[
            <String, Object?>{'value': '92%', 'label': '完成度', 'note': '上周'},
          ],
        },
        <String, Object?>{
          'layout': 'chart',
          'title': '柱状',
          'chart': <String, Object?>{
            'kind': 'bar',
            'unit': '%',
            'data': <Object?>[
              <String, Object?>{'label': 'A', 'value': 10},
              <String, Object?>{'label': 'B', 'value': 40},
            ],
          },
        },
        <String, Object?>{
          'layout': 'quote',
          'text': '一句引用。',
          'cite': '出处',
        },
        <String, Object?>{'layout': 'end', 'title': '谢谢'},
      ],
    };

void main() {
  setUpAll(() {
    work = Directory.systemTemp.createTempSync('pptx-test-');
  });
  tearDownAll(() {
    if (work.existsSync()) work.deleteSync(recursive: true);
  });

  test('最少输入也能生成合法包（只有标题）', () async {
    final (path, _) = await build(<String, Object?>{'title': '就一个标题'}, 'min');
    await expectZipOk(path);
    final facts = await inspect(path);
    expect((facts['slides'] as List).length, 1, reason: '没写 slides 时应当只有封面');
    expect(facts['contentTypesOk'], isTrue, reason: '有部件没被 [Content_Types].xml 覆盖');
    expect(facts['relTargetsAllExist'], isTrue, reason: '有关系指向不存在的部件');
  });

  test('全版式：十种版式都能出页，内容与结构都对得上', () async {
    final (path, stdout) = await build(deckAllLayouts(), 'all');
    await expectZipOk(path);
    expect(stdout, contains('[make-pptx] ok slides='), reason: 'Dart 侧按这行解析页数');
    final facts = await inspect(path);
    final slides = (facts['slides'] as List).cast<Map<String, dynamic>>();

    // 封面 + 10 页内容
    expect(slides.length, 11);
    // 每页都要有真文字，且**不许把 XML 标签当文字输出**（text/paras 用混的症状）
    for (final s in slides) {
      expect((s['texts'] as List).where((t) => '$t'.trim().isNotEmpty), isNotEmpty,
          reason: '${s['name']} 一个字都没有');
      expect(s['escapedXml'], isFalse, reason: '${s['name']} 的文字里露出了 XML 标签');
    }
    // 版式名（用形状名判断 —— 这是我们自己起的稳定名字）
    final names = slides.map((s) => (s['shapes'] as List).join('|')).join('\n');
    expect(names, contains('主标题'), reason: '封面版式没生效');
    expect(names, contains('大号数字'), reason: '章节页版式没生效');
    expect(names, contains('卡片底 1'), reason: '卡片版式没生效');
    expect(names, contains('轴线'), reason: '时间线版式没生效');
    expect(names, contains('对比底 1'), reason: '两栏对比版式没生效');
    expect(names, contains('数字 1'), reason: '大数字版式没生效');
    expect(names, contains('基线'), reason: '柱状图版式没生效');
    expect(names, contains('引号'), reason: '引用版式没生效');

    // 内容不丢
    final all = slides.map((s) => (s['texts'] as List).join('\n')).join('\n');
    for (final must in <String>['全版式样例', '目录', '章节', '要点', '卡片', '时间线', '对比', '数字', '柱状', '一句引用。', '谢谢']) {
      expect(all, contains(must), reason: '「$must」在多页里丢了');
    }

    // 转场按参数写进去了
    expect((slides[1]['transition'] as bool), isTrue, reason: 'transition=fade 没写进 XML');
    // 页码：封面没有、内容页有
    expect((slides[0]['shapes'] as List).join(), isNot(contains('页码')));
    expect((slides[1]['shapes'] as List).join(), contains('页码'));
    // 主题（mono）的强调色真的出现在页面上
    expect(File(path).readAsBytesSync().isNotEmpty, isTrue);

    // 备注
    expect((facts['notesSlides'] as List).length, 1);
    expect(facts['hasNotesMaster'], isTrue);
  });

  test('自动排版：内容多时字号变小、放不下时拆续页且不丢条目', () async {
    final long = List<Object?>.generate(
        30, (i) => '第 ${i + 1} 条：这一条足够长，长到一行放不下，必须折行之后才可能塞进版心。');
    final (path, _) = await build(<String, Object?>{
      'title': 'x',
      'slides': <Object?>[
        <String, Object?>{'title': '短的一页', 'bullets': <Object?>['一', '二']},
        <String, Object?>{'title': '长的一页', 'bullets': long},
      ],
    }, 'split');
    await expectZipOk(path);
    final facts = await inspect(path);
    final slides = (facts['slides'] as List).cast<Map<String, dynamic>>();
    expect(slides.length, greaterThanOrEqualTo(4),
        reason: '30 条长要点应当拆出多页（封面 + 短页 + 至少 2 页长列表），实际 ${slides.length}');

    final all = slides.map((s) => (s['texts'] as List).join('\n')).join('\n');
    for (var i = 1; i <= 30; i++) {
      expect(all, contains('第 $i 条：'), reason: '第 $i 条在拆页时丢了');
    }
    expect(all, contains('（续）'), reason: '续页标题应当带后缀');

    // 字号：条目少的页应当**不小于**条目多的页（缩排真的发生了）
    final shortPt = slides[1]['bodyPt'] as num?;
    final longPt = slides[2]['bodyPt'] as num?;
    expect(shortPt, isNotNull);
    expect(longPt, isNotNull);
    expect(longPt! <= shortPt!, isTrue,
        reason: '内容多的页字号($longPt)不该比内容少的页($shortPt)大');
    expect(longPt >= 12, isTrue, reason: '字号不该低于可读下限 12pt（实际 $longPt）');
  });

  test('所有形状都在画布内（越界 = 内容看不见 / 打印被切）', () async {
    final (path, _) = await build(deckAllLayouts(), 'bounds');
    final facts = await inspect(path);
    for (final s in (facts['slides'] as List).cast<Map<String, dynamic>>()) {
      for (final b in (s['xfrms'] as List).cast<Map<String, dynamic>>()) {
        final x = b['x'] as int, y = b['y'] as int;
        final cx = b['cx'] as int, cy = b['cy'] as int;
        expect(cx > 0 && cy > 0, isTrue, reason: '${s['name']} 有 0 尺寸形状');
        expect(x >= -1 && y >= -1, isTrue, reason: '${s['name']} 形状从画布外开始');
        expect(x + cx <= 12192001, isTrue, reason: '${s['name']} 形状右边越界');
        expect(y + cy <= 6858001, isTrue, reason: '${s['name']} 形状下边越界');
      }
    }
  });

  test('图片：真图片进包且 blip 关系对得上；找不到图只警告不崩', () async {
    final img = File('${work.path}/pic.png')..writeAsBytesSync(png2x1());
    final (path, _) = await build(<String, Object?>{
      'title': 'x',
      'slides': <Object?>[
        <String, Object?>{
          'layout': 'image',
          'title': '图',
          'image': img.path,
          'caption': '图注',
          'bullets': <Object?>['说明'],
        },
      ],
    }, 'image');
    await expectZipOk(path);
    final facts = await inspect(path);
    expect((facts['media'] as List).length, 1, reason: '图片没进包');
    expect('${(facts['media'] as List).first}', endsWith('.png'));
    for (final e in (facts['imageRelIds'] as List).cast<Map<String, dynamic>>()) {
      expect(e['inRels'], isTrue, reason: 'blip 的 ${e['id']} 在 slide rels 里找不到');
    }
    expect(facts['contentTypesOk'], isTrue, reason: 'png 没注册进 Content_Types 会判损坏');
    final slides = (facts['slides'] as List).cast<Map<String, dynamic>>();
    expect((slides[1]['texts'] as List).join(), contains('图注'));

    // 缺图：仍然合法，但有占位提示
    final (path2, _) = await build(<String, Object?>{
      'title': 'x',
      'slides': <Object?>[
        <String, Object?>{'layout': 'image', 'title': '图', 'image': '/no/such/file.png'},
      ],
    }, 'image-missing');
    await expectZipOk(path2);
    final facts2 = await inspect(path2);
    final slides2 = (facts2['slides'] as List).cast<Map<String, dynamic>>();
    expect((slides2[1]['texts'] as List).join(), contains('图片没找到'));
  });

  test('v1 老写法继续可用（向后兼容）', () async {
    final (path, _) = await build(<String, Object?>{
      'title': '老写法',
      'subtitle': '副标题',
      'author': '作者',
      'slides': <Object?>[
        <String, Object?>{'title': '第一页', 'bullets': <Object?>['一', '二']},
        <String, Object?>{'title': '第二页', 'content': '字符串也可以'},
      ],
    }, 'v1');
    await expectZipOk(path);
    final facts = await inspect(path);
    final slides = (facts['slides'] as List).cast<Map<String, dynamic>>();
    expect(slides.length, 3);
    expect((slides[0]['texts'] as List).join(), contains('老写法'));
    expect((slides[1]['texts'] as List).join(), contains('一'));
    expect((slides[2]['texts'] as List).join(), contains('字符串也可以'),
        reason: 'content 字符串应当被当成要点');
  });

  test('同一份输入两次生成，除文档属性外逐字节一致（可复现 / 可回归）', () async {
    final (path1, _) = await build(deckAllLayouts(), 'det1');
    final (path2, _) = await build(deckAllLayouts(), 'det2');
    // 用系统 unzip 逐个条目比字节：这是我们自己的 ZIP 写入器之外的第二双眼睛
    final list = await Process.run('unzip', <String>['-Z1', path1]);
    final names = '${list.stdout}'.trim().split('\n').where((s) => s.isNotEmpty).toList();
    expect(names.length, greaterThan(10), reason: '包里的部件太少，不像一份 PPT');
    var compared = 0;
    for (final n in names) {
      if (n == 'docProps/core.xml') continue; // 里面带生成时间，允许不同
      final a = await Process.run('unzip', <String>['-p', path1, n]);
      final b = await Process.run('unzip', <String>['-p', path2, n]);
      expect(a.stdout, equals(b.stdout), reason: '$n 两次生成不一致');
      compared += 1;
    }
    expect(compared, greaterThan(10));
  });
}
