/// Office 文档脚本（`assets/toolbox/make-xlsx.mjs` / `read-xlsx.mjs` /
/// `office-zip.mjs`）的**端到端**测试。
///
/// ## 为什么这几条必须钉住
///
/// 这三个脚本是"手机上**没有 python / openpyxl / pandas**"之后**唯一**能读写表格的
/// 东西（见 AGENTS.md 的「本机可用的执行环境」）。它们坏掉的方式很隐蔽：
///   * 手写 zip 的 CRC / 偏移写错 → 文件能生成、我们自己的读脚本也可能读回来，
///     但 **Excel / WPS 打不开**（"文件已损坏"）；
///   * 数字与文本判错 → `007` 变成 `7`、邮编/工号/电话被吃掉前导零；
///   * CSV 引号规则写错 → 带逗号/引号的字段被拆成两列（**静默串列**）。
///
/// 所以这里用**真 node 进程**跑一遍完整链路（CSV → xlsx → CSV/JSON），
/// 并额外做两条独立校验：
///   * `unzip -t`（系统 unzip 校验 CRC 与压缩数据完整性 —— 这不是我们自己的代码）；
///   * 文件头必须是 `PK`（zip 魔数）。
///
/// ⚠️ 本机**没有** Excel / LibreOffice / openpyxl，所以"第三方表格软件能不能打开"
///    这一步只能你到手机上验 —— 这里能证明的是：结构合法、CRC 正确、语义自洽。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 工具箱目录（测试的工作目录就是 app/）。
const String toolbox = 'assets/toolbox';

Future<ProcessResult> runNode(List<String> args, {String? cwd}) =>
    Process.run('node', args, workingDirectory: cwd);

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('dsh-xlsx-'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File write(String name, String content) {
    final f = File('${tmp.path}/$name')..writeAsStringSync(content);
    return f;
  }

  group('CSV → xlsx → CSV：往返必须一致（带引号/逗号/前导零也要对）', () {
    test('真实往返：引号、逗号、空值、前导零编号', () async {
      const csv = '姓名,数量,单价,备注\n'
          '张三,2,3.5,"含,逗号"\n'
          '李四,10,1.25,"带""引号""的"\n'
          '王五,007,,编号要留前导零\n';
      final inFile = write('in.csv', csv);
      final outFile = '${tmp.path}/out.xlsx';

      final mk = await runNode(['$toolbox/make-xlsx.mjs', inFile.path, outFile]);
      expect(mk.exitCode, 0, reason: '生成失败：${mk.stderr}\n${mk.stdout}');
      expect('${mk.stdout}', contains('[xlsx] ok rows=4 cols=4'));

      final xlsx = File(outFile);
      expect(xlsx.existsSync(), isTrue);
      // zip 魔数：xlsx 就是个 zip（PK\x03\x04）
      expect(xlsx.readAsBytesSync().sublist(0, 2), <int>[0x50, 0x4B]);

      final rd = await runNode(['$toolbox/read-xlsx.mjs', outFile]);
      expect(rd.exitCode, 0, reason: '读回失败：${rd.stderr}');
      final back = '${rd.stdout}'.trim();
      expect(back, csv.trim(),
          reason: '往返不一致 —— 引号/逗号/空值/前导零里有一处错了');
      // 前导零那条要特别确认：007 不能被当成数字变成 7
      expect(back, contains('007'));
      expect(back, isNot(contains(',7,')));
    });

    test('UNZIP -T：系统 unzip 独立校验 CRC 与压缩数据（不是我们自己的代码）',
        () async {
      final inFile = write('a.csv', 'a,b\n1,2\n');
      final out = '${tmp.path}/a.xlsx';
      final mk = await runNode(['$toolbox/make-xlsx.mjs', inFile.path, out]);
      expect(mk.exitCode, 0, reason: '${mk.stderr}');

      // 有 unzip 才验（别的机器上可能没有 —— 那是环境问题，不是脚本错）
      final has = await Process.run('sh', ['-c', 'command -v unzip']);
      if (has.exitCode != 0) {
        markTestSkipped('这台机器没有 unzip，跳过独立校验');
        return;
      }
      final t = await Process.run('unzip', ['-t', out]);
      expect(t.exitCode, 0, reason: 'unzip -t 报错 = 手写 zip 的 CRC/偏移有问题：${t.stdout}${t.stderr}');
      expect('${t.stdout}', contains('No errors detected'));
      // 六个必需部件都要在
      for (final part in <String>[
        '[Content_Types].xml',
        '_rels/.rels',
        'xl/workbook.xml',
        'xl/_rels/workbook.xml.rels',
        'xl/styles.xml',
        'xl/worksheets/sheet1.xml',
      ]) {
        expect('${t.stdout}', contains(part), reason: '缺部件 $part');
      }
    });

    test('数字仍是数字、文本仍是文本（这决定表里能不能直接求和）', () async {
      final inFile = write('n.csv', '项目,值\n数量,3.5\n编号,007\n空,\n');
      final out = '${tmp.path}/n.xlsx';
      await runNode(['$toolbox/make-xlsx.mjs', inFile.path, out]);
      final rd = await runNode(['$toolbox/read-xlsx.mjs', out, '--format', 'json']);
      final rows = jsonDecode('${rd.stdout}') as List<dynamic>;
      expect(rows.length, 3);
      expect((rows[0] as Map)['值'], 3.5, reason: '数字应该还是数字');
      expect((rows[1] as Map)['值'], '007', reason: '前导零编号必须是文本');
      expect((rows[2] as Map)['值'], '');
    });
  });

  group('JSON → xlsx，以及命令行契约', () {
    test('对象数组：表头取并集（键不齐也不丢列）', () async {
      final inFile = write('d.json',
          '[{"名":"甲","量":1},{"名":"乙","价":9.9}]');
      final out = '${tmp.path}/d.xlsx';
      final mk = await runNode(['$toolbox/make-xlsx.mjs', inFile.path, out,
        '--sheet', '数据']);
      expect(mk.exitCode, 0, reason: '${mk.stderr}');
      expect('${mk.stdout}', contains('sheet=数据'));

      final rd = await runNode(['$toolbox/read-xlsx.mjs', out]);
      final lines = '${rd.stdout}'.trim().split('\n');
      expect(lines.first, '名,量,价', reason: '表头应该是三个键的并集');
      expect(lines[1], '甲,1,');
      expect(lines[2], '乙,,9.9');
    });

    test('--list 列出工作表；--sheet 支持名字与序号', () async {
      final inFile = write('x.csv', 'a\n1\n');
      final out = '${tmp.path}/x.xlsx';
      await runNode(['$toolbox/make-xlsx.mjs', inFile.path, out, '--sheet', '报表']);
      final list = await runNode(['$toolbox/read-xlsx.mjs', out, '--list']);
      expect('${list.stdout}', contains('报表'));
      // 序号 1 与名字都能选中
      for (final sel in <List<String>>[
        ['--sheet', '1'],
        ['--sheet', '报表'],
      ]) {
        final r = await runNode(['$toolbox/read-xlsx.mjs', out, ...sel]);
        expect(r.exitCode, 0, reason: '${sel.join(' ')} 选不中：${r.stderr}');
        expect('${r.stdout}', contains('a'));
      }
    });

    test('--out 写到文件，并且成功标记走 stderr（stdout 留给数据）', () async {
      final inFile = write('o.csv', 'p,q\n1,2\n');
      final out = '${tmp.path}/o.xlsx';
      final dst = '${tmp.path}/back.csv';
      await runNode(['$toolbox/make-xlsx.mjs', inFile.path, out]);
      final rd = await runNode(['$toolbox/read-xlsx.mjs', out, '--out', dst]);
      expect(File(dst).readAsStringSync().trim(), 'p,q\n1,2');
      expect('${rd.stderr}', contains('[xlsx] ok'), reason: '成功标记应在 stderr');
      expect('${rd.stdout}', isEmpty, reason: '写了文件就不该再打到 stdout');
    });
  });

  group('失败要说人话（不许静默成功）', () {
    test('输入不存在 / 不是 xlsx / 没数据 → 非 0 退出 + 中文原因', () async {
      final missing = await runNode(['$toolbox/read-xlsx.mjs', '${tmp.path}/nope.xlsx']);
      expect(missing.exitCode, isNot(0));
      expect('${missing.stderr}', contains('不存在'));

      final notZip = write('fake.xlsx', '这不是一个 zip');
      final bad = await runNode(['$toolbox/read-xlsx.mjs', notZip.path]);
      expect(bad.exitCode, isNot(0));
      expect('${bad.stderr}', contains('不是一个能读的 xlsx'));

      final empty = write('empty.csv', '\n');
      final none = await runNode(['$toolbox/make-xlsx.mjs', empty.path, '${tmp.path}/e.xlsx']);
      expect(none.exitCode, isNot(0));
      expect('${none.stderr}', contains('没有数据行'));
    });

    test('工作表名里的 Excel 非法字符会被替换（不是让 Excel 去报错）', () async {
      final inFile = write('s.csv', 'a\n1\n');
      final out = '${tmp.path}/s.xlsx';
      final mk = await runNode([
        '$toolbox/make-xlsx.mjs', inFile.path, out, '--sheet', 'a/b[c]:d*e?f',
      ]);
      expect(mk.exitCode, 0, reason: '${mk.stderr}');
      // 读回来时工作表名里不该还有 / [ ] : * ?
      final list = await runNode(['$toolbox/read-xlsx.mjs', out, '--list']);
      final name = '${list.stdout}'.split('\n').first.split('\t').last;
      for (final bad in <String>['/', '[', ']', ':', '*', '?']) {
        expect(name.contains(bad), isFalse, reason: '工作表名里还有非法字符 $bad');
      }
    });
  });

  group('Markdown → docx', () {
    const md = '# 季度总结\n'
        '\n'
        '本季度做了三件事，**重点**是第一件。\n'
        '\n'
        '## 一、交付\n'
        '\n'
        '- 完成了 `read-xlsx.mjs`\n'
        '- 修掉了 *旧 bug*\n'
        '\n'
        '| 项目 | 数量 |\n'
        '|---|---|\n'
        '| 表格 | 12 |\n'
        '\n'
        '> 改最少，效果最大。\n'
        '\n'
        '```sh\n'
        'node make-xlsx.mjs in.csv out.xlsx\n'
        '```\n';

    test('生成真 .docx：合法 zip（unzip -t 独立校验）+ 必需部件齐全', () async {
      final inFile = write('in.md', md);
      final out = '${tmp.path}/out.docx';
      final mk = await runNode(['$toolbox/make-docx.mjs', inFile.path, out,
        '--title', '季度总结']);
      expect(mk.exitCode, 0, reason: '生成失败：${mk.stderr}');
      expect('${mk.stdout}', contains('[docx] ok'));
      expect('${mk.stdout}', contains('tables=1'));

      final docx = File(out);
      expect(docx.readAsBytesSync().sublist(0, 2), <int>[0x50, 0x4B]);

      final has = await Process.run('sh', ['-c', 'command -v unzip']);
      if (has.exitCode != 0) {
        markTestSkipped('这台机器没有 unzip，跳过独立校验');
        return;
      }
      final t = await Process.run('unzip', ['-t', out]);
      expect(t.exitCode, 0, reason: 'unzip -t 报错：${t.stdout}${t.stderr}');
      for (final part in <String>[
        '[Content_Types].xml',
        '_rels/.rels',
        'docProps/core.xml',
        'word/styles.xml',
        'word/document.xml',
      ]) {
        expect('${t.stdout}', contains(part), reason: '缺部件 $part');
      }
    });

    test('正文真的进去了：标题/加粗/列表/表格/引用/代码块都在（用系统 unzip 抽出来看）',
        () async {
      final inFile = write('b.md', md);
      final out = '${tmp.path}/b.docx';
      await runNode(['$toolbox/make-docx.mjs', inFile.path, out]);
      final has = await Process.run('sh', ['-c', 'command -v unzip']);
      if (has.exitCode != 0) {
        markTestSkipped('这台机器没有 unzip');
        return;
      }
      final xml = await Process.run('unzip', ['-p', out, 'word/document.xml']);
      expect(xml.exitCode, 0);
      final x = '${xml.stdout}';
      // 逐项：文字在不在
      for (final kw in <String>['季度总结', '一、交付', 'read-xlsx.mjs', '改最少，效果最大', '表格']) {
        expect(x, contains(kw), reason: '正文缺了「$kw」');
      }
      // 结构：真表格、加粗、等宽、缩进
      expect(x, contains('<w:tbl>'), reason: '表格没生成成真 <w:tbl>');
      expect(x, contains('<w:b/>'), reason: '标题/加粗没写进去');
      expect(x, contains('Consolas'), reason: '代码块/行内等宽没写进去');
      expect(x, contains('<w:ind'), reason: '列表/引用的缩进没写进去');
      // 围栏代码块里的内容要原样进（且不能把 ``` 也写进去）
      expect(x, contains('make-xlsx.mjs'), reason: '代码块内容丢了');
      expect(x, isNot(contains('```')), reason: '围栏标记本身不该进文档');
    });

    test('空输入要报错，不是产出一个空文档', () async {
      final inFile = write('e.md', '   \n');
      final r = await runNode(['$toolbox/make-docx.mjs', inFile.path, '${tmp.path}/e.docx']);
      expect(r.exitCode, isNot(0));
      expect('${r.stderr}', contains('空的'));
    });

    test('--title 会写进 docProps（Word 的"属性"里能看到）', () async {
      final inFile = write('t.md', '正文\n');
      final out = '${tmp.path}/t.docx';
      await runNode(['$toolbox/make-docx.mjs', inFile.path, out, '--title', '我的报告']);
      final has = await Process.run('sh', ['-c', 'command -v unzip']);
      if (has.exitCode != 0) { markTestSkipped('没有 unzip'); return; }
      final core = await Process.run('unzip', ['-p', out, 'docProps/core.xml']);
      expect('${core.stdout}', contains('我的报告'));
    });
  });

  test('Office 那几个脚本都在落盘表里（否则设备上根本找不到它们）', () {
    final table = File('lib/local/android_toolbox.dart').readAsStringSync();
    for (final s in <String>[
      'assets/toolbox/office-zip.mjs',
      'assets/toolbox/make-xlsx.mjs',
      'assets/toolbox/read-xlsx.mjs',
      'assets/toolbox/make-docx.mjs',
      'assets/toolbox/read-docx.mjs',
    ]) {
      expect(table, contains("'$s'"), reason: '$s 没写进 AndroidToolbox.assets');
    }
  });
}
