/// 「生图请求到底长什么样」—— 多厂家改造的**形状回归**。
///
/// ## 为什么必须有这个测试
///
/// 用户 2026-10-11 纠正：「影视这个工具实际是可以使用多个厂家」。在那之前，
/// `make-image.mjs` 只会发 Agnes 那一套（`size` 用档位 `1K/2K`、
/// `response_format` 与参考图放在 `extra_body` 里），换厂家只换了 base URL 和 Key ——
/// **端点、参数名、返回结构全不对**，上游只会回 400/404，界面上看就是"生成失败"，
/// 完全看不出是形状错了。
///
/// 形状是**最容易错、又最难在编译期发现**的东西：写错一个字段名，代码照样跑、
/// 照样发请求。所以这里用 `--print-request`（干跑：不发网络请求、不需要 Key）
/// 把每一家的端点与请求体钉住。
///
/// ⚠️ 这个测试**只证明形状与我们认定的文档/已投产实现一致**，不证明上游收不收 ——
/// 本机没有这些厂家的 Key，也没有安卓设备。
///
/// ⚠️ **最重要的一条是 Agnes 的逐字回归**：那一家的形状已经验证可用，
/// 改造不许把它改坏（body 是逐字比对，不是"包含"）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 找脚本。`flutter test` 的工作目录是 `app/`；从仓库根跑也认。
File? _script() {
  for (final p in <String>[
    'assets/toolbox/make-image.mjs',
    '../app/assets/toolbox/make-image.mjs',
    'app/assets/toolbox/make-image.mjs',
  ]) {
    final f = File(p);
    if (f.existsSync()) return f;
  }
  return null;
}

/// 造一张假的参考图（内容无所谓，形状测试只看它有没有被正确编码/放进哪个字段）。
File _tempRef() {
  final f = File(
    '${Directory.systemTemp.path}/dsh-shape-ref-${DateTime.now().microsecondsSinceEpoch}.png',
  );
  f.writeAsBytesSync(<int>[0x78]); // 'x' → base64 是 eA==
  addTearDown(() {
    if (f.existsSync()) f.deleteSync();
  });
  return f;
}

/// 跑一次干跑，返回 stdout+stderr。node 不存在 / 脚本找不到 → null（调用方跳过）。
///
/// 环境里**显式清空** AGNES_*：本机真配过 Key/端点时也不能影响形状判断。
Future<String?> _dryRun(
  List<String> args, {
  Map<String, String> env = const <String, String>{},
}) async {
  final script = _script();
  if (script == null) return null;
  try {
    final r = await Process.run(
      'node',
      <String>[script.path, '一只猫', '--print-request', ...args],
      environment: <String, String>{
        'AGNES_BASE_URL': '',
        'AGNES_API_KEY': 'dummy-for-dry-run',
        'AGNES_API_KEYS': '',
        'AGNES_IMAGE_MODEL': '',
        ...env,
      },
    );
    return '${r.stdout}\n${r.stderr}';
  } on ProcessException {
    return null; // 本机没装 node → 跳过
  }
}

/// 从干跑输出里取某一行的值（例如 `[print-request] submit POST <url>`）。
String? _line(String out, String prefix) {
  for (final l in out.split('\n')) {
    if (l.startsWith(prefix)) return l.substring(prefix.length).trim();
  }
  return null;
}

void main() {
  final available = _script() != null;

  group('多厂家生图形状（干跑 --print-request，不发网络请求）', () {
    test('Agnes 的形状与改造前逐字一致（这是回归保护，最重要的一条）', () async {
      final out = await _dryRun(<String>[
        '--provider', 'agnes',
        '--model', 'agnes-image-2.5-flash',
        '--size', '2K',
        '--ratio', '16:9',
      ]);
      if (out == null) return markTestSkipped('本机没有 node');
      expect(_line(out, '[print-request] submit'),
          'POST https://api.agnes-ai.cn/v1/images/generations');
      expect(_line(out, '[print-request] multipart'), 'false');
      // 这一行是改造前 make-image.mjs 里那段写死的构造逐字拼出来的结果：
      // size 是**档位**、response_format 在 extra_body 里（放顶层是官方点名的错误写法）。
      expect(
        _line(out, '[print-request] body'),
        '{"model":"agnes-image-2.5-flash","prompt":"一只猫","size":"2K","ratio":"16:9",'
        '"extra_body":{"response_format":"url"}}',
      );
    });

    test('Agnes 带参考图 → 参考图进 extra_body.image（不是顶层）', () async {
      final ref = _tempRef();
      final out = await _dryRun(<String>[
        '--provider', 'agnes',
        '--model', 'agnes-image-2.5-flash',
        '--size', '2K',
        '--ratio', '16:9',
        '--ref', ref.path,
      ]);
      if (out == null) return markTestSkipped('本机没有 node');
      expect(
        _line(out, '[print-request] body'),
        '{"model":"agnes-image-2.5-flash","prompt":"一只猫","size":"2K","ratio":"16:9",'
        '"extra_body":{"response_format":"url","image":["data:image/png;base64,eA=="]}}',
        reason: '参考图必须在 extra_body.image 里，且是 data URI',
      );
    });

    test('OpenAI 兼容四家：端点各不同、size 用像素、response_format 在顶层', () async {
      // 只有 OpenAI 官方那家**不传** `response_format`（gpt-image-1 默认就回 b64_json，
      // 传了反而会被拒）；其余兼容实现都认顶层 `response_format`。
      for (final (id, url, wantsResponseFormat) in <(String, String, bool)>[
        ('openai', 'https://api.openai.com/v1/images/generations', false),
        ('zhipu', 'https://open.bigmodel.cn/api/paas/v4/images/generations', true),
        ('doubao', 'https://ark.cn-beijing.volces.com/api/v3/images/generations', true),
        ('siliconflow', 'https://api.siliconflow.cn/v1/images/generations', true),
      ]) {
        final out = await _dryRun(<String>[
          '--provider', id,
          '--model', 'test-model',
          '--size', '1024x1024',
        ]);
        if (out == null) return markTestSkipped('本机没有 node');
        expect(_line(out, '[print-request] submit'), 'POST $url',
            reason: '$id 的端点');
        expect(_line(out, '[print-request] multipart'), 'false');
        final body = _line(out, '[print-request] body')!;
        expect(body, contains('"size":"1024x1024"'),
            reason: '$id 的 size 是像素，不是 1K/2K 档位');
        if (wantsResponseFormat) {
          expect(body, contains('"response_format":"url"'), reason: id);
        } else {
          expect(body, isNot(contains('response_format')),
              reason: '$id（gpt-image-1）不接受 response_format，发了会被拒');
        }
        expect(body, isNot(contains('extra_body')),
            reason: 'extra_body 是 Agnes 的形状，别家不认');
      }
    });

    test('OpenAI 带参考图 → /images/edits 的 multipart（字段名 image）', () async {
      final ref = _tempRef();
      final out = await _dryRun(<String>[
        '--provider', 'openai',
        '--model', 'gpt-image-1',
        '--size', '1024x1024',
        '--ref', ref.path,
      ]);
      if (out == null) return markTestSkipped('本机没有 node');
      expect(_line(out, '[print-request] submit'),
          'POST https://api.openai.com/v1/images/edits',
          reason: 'OpenAI 没有顶层 image 参数，带参考图必须走 edits 的 multipart');
      expect(_line(out, '[print-request] multipart'), 'true');
      expect(_line(out, '[print-request] multipart-fields'), 'image');
      final body = _line(out, '[print-request] body')!;
      expect(body, contains('"size":"1024x1024"'));
      expect(body, isNot(contains('response_format')),
          reason: 'gpt-image-1 不接受 response_format，发了会被拒');
    });

    test('MiniMax：/v1/image_generation，比例用 aspect_ratio（不是 ratio/size）', () async {
      final out = await _dryRun(<String>[
        '--provider', 'minimax',
        '--model', 'image-01',
        '--ratio', '16:9',
      ]);
      if (out == null) return markTestSkipped('本机没有 node');
      expect(_line(out, '[print-request] submit'),
          'POST https://api.minimax.cn/v1/image_generation');
      final body = _line(out, '[print-request] body')!;
      expect(body, contains('"aspect_ratio":"16:9"'));
      expect(body, isNot(contains('"size"')),
          reason: '这家没有 size 参数，尺寸由 aspect_ratio 决定');
    });

    test('万相（DashScope）：异步端点 + 轮询 + **不发 ratio**（它没这个参数）', () async {
      final out = await _dryRun(<String>[
        '--provider', 'dashscope',
        '--model', 'wanx2.1-t2i-turbo',
        '--size', '1024*1024',
        '--ratio', '16:9',
      ]);
      if (out == null) return markTestSkipped('本机没有 node');
      expect(
        _line(out, '[print-request] submit'),
        'POST https://dashscope.aliyuncs.com/api/v1/services/aigc/text2image/image-synthesis',
      );
      expect(_line(out, '[print-request] async'), 'true');
      expect(_line(out, '[print-request] poll'),
          'GET https://dashscope.aliyuncs.com/api/v1/tasks/TASKID',
          reason: '万相是"创建任务 → 轮询 /api/v1/tasks/{id}"的异步协议');
      expect(_line(out, '[print-request] headers'), contains('x-dashscope-async'),
          reason: '缺这个头会被判成同步调用而报错');
      final body = _line(out, '[print-request] body')!;
      expect(body, contains('"input":{"prompt":"一只猫"}'));
      expect(body, contains('"size":"1024*1024"'),
          reason: '万相的尺寸用 * 分隔（界面要按这家给尺寸）');
      expect(body, isNot(contains('"ratio"')),
          reason: '万相没有 ratio 参数 —— 多发一个上游不认的字段，'
              '轻则报参数错误，重则被静默忽略让人以为生效了');
    });

    test('认不出的厂家：按 OpenAI 兼容形状发（用用户填的端点）', () async {
      final out = await _dryRun(
        <String>['--model', 'my-image-1', '--size', '1024x1024'],
        env: <String, String>{'AGNES_BASE_URL': 'https://my-gateway.example.com/v1'},
      );
      if (out == null) return markTestSkipped('本机没有 node');
      expect(_line(out, '[print-request] provider'), startsWith('unknown'));
      expect(_line(out, '[print-request] submit'),
          'POST https://my-gateway.example.com/v1/images/generations',
          reason: '猜不出厂家时按最普遍的 OpenAI 兼容形状试，但端点要用用户填的');
      final body = _line(out, '[print-request] body')!;
      expect(body, contains('"response_format":"url"'));
      expect(body, isNot(contains('extra_body')));
    });

    test('自定义厂家没填端点 → exit 2 且是人话（不要让 node 抛 Invalid URL）', () async {
      final script = _script();
      if (script == null) return markTestSkipped('本机找不到脚本');
      ProcessResult r;
      try {
        r = await Process.run(
          'node',
          <String>[
            script.path, '一只猫', '/tmp/dsh-shape-out.png',
            '--provider', 'unknown', '--model', 'my-image-1',
          ],
          environment: <String, String>{
            'AGNES_BASE_URL': '',
            'AGNES_API_KEY': 'dummy',
            'AGNES_API_KEYS': '',
          },
        );
      } on ProcessException {
        return markTestSkipped('本机没有 node');
      }
      expect(r.exitCode, 2);
      final all = '${r.stdout}${r.stderr}';
      expect(all, contains('端点'));
      expect(all, isNot(contains('Invalid URL')));
    });

    test('Key 缺失时按**实际厂家**报错，并说清去「云端大模型」按厂家 id 配', () async {
      final script = _script();
      if (script == null) return markTestSkipped('本机找不到脚本');
      ProcessResult r;
      try {
        r = await Process.run(
          'node',
          <String>[
            script.path, '一只猫', '/tmp/dsh-shape-out.png',
            '--provider', 'openai', '--model', 'gpt-image-1',
          ],
          environment: <String, String>{
            'AGNES_BASE_URL': '',
            'AGNES_API_KEY': '',
            'AGNES_API_KEYS': '',
          },
        );
      } on ProcessException {
        return markTestSkipped('本机没有 node');
      }
      expect(r.exitCode, 2);
      final all = '${r.stdout}${r.stderr}';
      expect(all, contains('「OpenAI」'),
          reason: '报错要说清是哪一家，不能一律说 Agnes');
      expect(all, contains('openai'),
          reason: '要给出厂家 id，用户才能在设置里对号入座');
      expect(all, contains('云端大模型'));
    });
  }, skip: available ? false : '找不到 make-image.mjs');
}
