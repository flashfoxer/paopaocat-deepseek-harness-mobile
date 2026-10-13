import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/data/artifacts.dart';

/// 产物的口径测试：**「产物这里就应该是产生的文件」**（用户 2026-10-04 定）。
///
/// 这条口径的来历是实测踩坑：用户让模型画图，产物列表里立刻冒出三个东西，
/// 到图片生成完都点不开，最后他只能在资料库找到图。那三个是 `make-image`
/// 技能文档正文里的**示例占位名**被正则捞出来的。
///
/// 所以这里钉住两段链路：
///   1. [extractArtifactCandidates] 只负责捞候选 —— 并且要能挡住"代码片段被
///      当成文件名"这种明显误捞；
///   2. [verifyProducedArtifacts] 决定它算不算产物：**真存在 + 本次会话写出来的**。
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dsh-artifact-test-');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<File> write(String name, {DateTime? modified, int bytes = 32}) async {
    final f = File('${tmp.path}/$name');
    await f.writeAsBytes(List<int>.filled(bytes, 0x41));
    if (modified != null) await f.setLastModified(modified);
    return f;
  }

  group('候选提取', () {
    test('真实文件名会被捞成候选', () {
      final c = extractArtifactCandidates(
        title: 'bash',
        output: '已生成 /data/user/0/pkg/files/workspaces/ws/橘猫.png（812.4KB）',
      );
      expect(c.map((a) => a.fullName), contains('橘猫.png'));
      // 带路径的候选要把路径整段留着（核实阶段直接 stat，不猜目录）
      expect(c.firstWhere((a) => a.fullName == '橘猫.png').path,
          '/data/user/0/pkg/files/workspaces/ws/橘猫.png');
    });

    test('write 工具的 rawInput（file_path）能捞出候选 —— 「生成了 txt 却看不到」的根因链路', () {
      // ACP 的 `tool_call`（首次）里带 rawInput，写文件类工具的参数就在这里；
      // 而 `tool_call_update`（完成）**通常不带** —— 所以 App 必须把首次那份
      // 缓存下来（见 `chat_page.dart` 的 `_toolRawById`）。否则完成时只拿得到
      // 一句 "File written successfully."，文件就永远进不了产物列表。
      final c = extractArtifactCandidates(
        title: 'write',
        rawInput: <String, dynamic>{
          'file_path':
              '/data/user/0/com.dshmobile.dsh_mobile/files/workspace/会议纪要.txt',
          'content': '第一行\n第二行',
        },
        output: 'File written successfully.',
      );
      expect(
        c.map((a) => a.fullName),
        contains('会议纪要.txt'),
        reason: 'rawInput 里的 file_path 必须能捞成候选，否则产物会漏',
      );
      expect(
        c.firstWhere((a) => a.fullName == '会议纪要.txt').path,
        '/data/user/0/com.dshmobile.dsh_mobile/files/workspace/会议纪要.txt',
      );
    });

    test('只有一句「写好了」而没有路径/文件名时，捞不到东西（这正是必须缓存 rawInput 的原因）', () {
      // 模拟"完成通知丢了 rawInput"的现场：只剩输出文本
      final c = extractArtifactCandidates(
        title: 'write',
        rawInput: null,
        output: 'File written successfully.',
      );
      expect(
        c.where((a) => a.extension == 'txt'),
        isEmpty,
        reason: '输出里没有文件名时本来就捞不到 —— 所以才要靠 rawInput',
      );
    });

    test('技能文档正文里的示例占位名会被捞成候选（这是误捞的源头）', () {
      // 真实 make-image/SKILL.md 里的那两行示例命令
      const doc = '''
```sh
node "\$DSH_ANDROID_TOOLBOX/make-image.mjs" "提示词" "输出.png"
node "\$DSH_ANDROID_TOOLBOX/make-image.mjs" "换背景" "输出.png" --ref "参考图.png"
```
''';
      final names = extractArtifactCandidates(title: 'skill', output: doc)
          .map((a) => a.fullName)
          .toSet();
      expect(names, containsAll(<String>['输出.png', '参考图.png']));
      // 注意：捞到**不等于**是产物 —— 下面「核实」那组证明它们进不了列表
    });

    test('代码片段不会被当成文件名（名字里带引号/括号/等号的一律丢）', () {
      final c = extractArtifactCandidates(
        title: 'bash',
        output:
            "node -e \"const b=require('node:fs').readFileSync('输出.png');console.log(b.length)\"",
      );
      expect(c, isEmpty);
    });
  });

  group('核实成产物：真存在 + 本次会话写出来的', () {
    test('会话开始后写出来的文件 → 算产物，并带上真实路径与体积', () async {
      final started = DateTime.now();
      final f = await write('橘猫.png',
          modified: started.add(const Duration(seconds: 1)), bytes: 2048);

      final out = await verifyProducedArtifacts(
        [const Artifact(name: '橘猫', extension: 'png')],
        cwd: tmp.path,
        since: started,
      );

      expect(out, hasLength(1));
      expect(out.single.name, '橘猫');
      expect(out.single.extension, 'png');
      expect(out.single.path, f.path);
      expect(out.single.sizeLabel, '2.0KB');
    });

    test('技能文档里的示例占位名：文件根本不存在 → 不算产物', () async {
      final started = DateTime.now();
      final out = await verifyProducedArtifacts(
        [
          const Artifact(name: '输出', extension: 'png'),
          const Artifact(name: '参考图', extension: 'png'),
        ],
        cwd: tmp.path,
        since: started,
      );
      expect(out, isEmpty);
    });

    test('已存在但**不是这次会话写的**文件不算产物（那只是被提到过）', () async {
      final f = await write('旧材料.md', modified: DateTime(2020));
      final started = DateTime.now();

      final out = await verifyProducedArtifacts(
        [Artifact(name: '旧材料', extension: 'md', path: f.path)],
        cwd: tmp.path,
        since: started,
      );
      expect(out, isEmpty);
    });

    test('绝对路径候选直接按路径核实（不按 cwd 拼）', () async {
      final started = DateTime.now();
      final nested = await Directory('${tmp.path}/子目录').create();
      final f = File('${nested.path}/分镜.md');
      await f.writeAsString('x');
      await f.setLastModified(started.add(const Duration(seconds: 1)));

      final out = await verifyProducedArtifacts(
        [Artifact(name: '分镜', extension: 'md', path: f.path)],
        cwd: tmp.path,
        since: started,
      );
      expect(out.single.path, f.path);
      expect(out.single.name, '分镜');
    });

    test('目录不算产物（只认文件）', () async {
      final started = DateTime.now();
      final d = await Directory('${tmp.path}/输出.png').create();

      final out = await verifyProducedArtifacts(
        [Artifact(name: '输出', extension: 'png', path: d.path)],
        cwd: tmp.path,
        since: started,
      );
      expect(out, isEmpty);
    });

    test('重复候选按真实路径去重（同一个文件只出一条）', () async {
      final started = DateTime.now();
      final f = await write('图.png',
          modified: started.add(const Duration(seconds: 1)));

      final out = await verifyProducedArtifacts(
        [
          Artifact(name: '图', extension: 'png', path: f.path),
          Artifact(name: '图', extension: 'png', path: f.path),
        ],
        cwd: tmp.path,
        since: started,
      );
      expect(out, hasLength(1));
    });
  });

  test('体积文案', () {
    expect(formatSizeLabel(812), '812B');
    expect(formatSizeLabel(2048), '2.0KB');
    expect(formatSizeLabel(3 * 1024 * 1024), '3.0MB');
  });
}
