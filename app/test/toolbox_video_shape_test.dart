/// 「视频请求到底长什么样」—— 多厂家改造的**形状回归**。
///
/// ## 为什么必须有这个测试
///
/// 用户 2026-10-11 纠正：「本 App 的视频请求只认 Agnes 那套形状，实际是那个内置的
/// 会话限制了你的使用…影视这个工具实际是可以使用多个厂家」。也就是说，
/// 以前换厂家只换了 base URL 和 Key，**端点、参数名、返回结构全不对** ——
/// 这种事在真机上的表现只是"生成失败"，看不出是形状错了。
///
/// 形状是**最容易错、又最难在编译期发现**的东西：写错一个字段名，
/// 代码照样跑、照样发请求，只是上游回 400。所以这里用 `--print-request`
/// （干跑，不发网络请求、不需要 Key）把每一家的端点与请求体钉住。
///
/// ⚠️ 这个测试**只证明形状与我们认定的文档一致**，不证明上游收不收 ——
/// 本机没有这些厂家的 Key，也没有安卓设备。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 找脚本。`flutter test` 的工作目录是 `app/`。
File? _script() {
  for (final p in <String>[
    'assets/toolbox/make-video.mjs',
    '../app/assets/toolbox/make-video.mjs',
  ]) {
    final f = File(p);
    if (f.existsSync()) return f;
  }
  return null;
}

/// 跑一次干跑，返回 stdout+stderr。node 不存在就返回 null（调用方跳过）。
Future<String?> _dryRun(List<String> args) async {
  final script = _script();
  if (script == null) return null;
  try {
    final r = await Process.run(
      'node',
      <String>[script.path, '一只猫在跑', '/tmp/dsh-test-out.mp4', '--print-request', ...args],
      environment: <String, String>{'AGNES_API_KEY': 'dummy-for-dry-run'},
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

  group('多厂家视频形状（干跑 --print-request，不发网络请求）', () {
    test('Agnes 的形状与改造前逐字一致（这是回归保护，最重要的一条）', () async {
      final out = await _dryRun(<String>['--provider', 'agnes']);
      if (out == null) return markTestSkipped('本机没有 node');
      expect(_line(out, '[print-request] submit'),
          'POST https://api.agnes-ai.cn/v1/videos');
      expect(_line(out, '[print-request] poll'),
          contains('/agnesapi?video_id='),
          reason: 'Agnes 的查询端点在**站点根**，不在 /v1 下');
      final body = _line(out, '[print-request] body')!;
      expect(body, contains('"size":"720P"'));
      expect(body, contains('"seconds":"5"'),
          reason: 'Agnes 的 seconds 要**字符串**，发数字会被拒');
      expect(body, contains('"aspect_ratio":"16:9"'));
      expect(body, contains('"n":1'));
    });

    test('豆包 Seedance：方舟自己的 tasks 端点 + content[] 结构（不是顶层 prompt）', () async {
      final out = await _dryRun(<String>['--provider', 'doubao']);
      if (out == null) return markTestSkipped('本机没有 node');
      expect(_line(out, '[print-request] submit'),
          'POST https://ark.cn-beijing.volces.com/api/v3/contents/generations/tasks');
      expect(_line(out, '[print-request] poll'),
          'GET https://ark.cn-beijing.volces.com/api/v3/contents/generations/tasks/TASKID');
      final body = _line(out, '[print-request] body')!;
      expect(body, contains('"content":[{"type":"text","text":"一只猫在跑"}]'),
          reason: 'Seedance 的提示词在 content[] 里，不是顶层 prompt');
      expect(body, contains('"duration":5'));
      expect(body, isNot(contains('"prompt"')),
          reason: '顶层 prompt 是 Agnes 的形状，豆包不认');
    });

    test('豆包带首帧 → content[] 里多一个 image_url 且 role=first_frame', () async {
      final out = await _dryRun(<String>[
        '--provider', 'doubao',
        '--first-frame', '/tmp/dsh-test-frame.png',
        '--mode', 'keyframe',
      ]);
      if (out == null) return markTestSkipped('本机没有 node');
      final body = _line(out, '[print-request] body')!;
      expect(body, contains('"type":"image_url"'));
      expect(body, contains('"role":"first_frame"'));
    });

    // ⚠️ 2026-10-12 改：这条原来是「提交在 v2、**查进度在 v1**」，
    //    并把它当成"两个根不一样"的**特性**钉住了 —— 其实那是 bug：
    //    任务是 v2 建的，却去 v1 查，永远查不到。
    //
    //    逐条对过官方文档后（platform.minimax.cn/docs/api-reference/
    //    video-generation-v2-create 与 video-generation-v2-query）：
    //      * 创建 `POST https://api.minimax.cn/v2/video_generation`
    //      * 查询 `GET  https://api.minimax.cn/v2/query/video_generation/{task_id}`
    //        —— task_id 是**路径段**（v1 那个老接口才是 `?task_id=`）
    //      * body 是 `{model, content[], duration, resolution, ratio}`，
    //        **没有** `prompt` 字段（v1 才有）。发 prompt 会被上游回
    //        `invalid params, content must include a non-empty text item (2013)`。
    test('MiniMax：创建与查进度都在 v2（H3），提示词进 content[]', () async {
      final out = await _dryRun(<String>['--provider', 'minimax']);
      if (out == null) return markTestSkipped('本机没有 node');
      expect(_line(out, '[print-request] submit'),
          'POST https://api.minimax.cn/v2/video_generation');
      expect(_line(out, '[print-request] poll'),
          'GET https://api.minimax.cn/v2/query/video_generation/TASKID',
          reason: 'v2 建的任务必须查 v2 —— 原来打的是 v1，查不到');
      final body = _line(out, '[print-request] body')!;
      expect(body, contains('"content":[{"type":"text","text":"一只猫在跑"}]'),
          reason: 'v2 的提示词在 content[] 里，不是顶层 prompt');
      expect(body, isNot(contains('"prompt"')),
          reason: 'v2 没有 prompt 字段 —— 带了会被回 2013 参数错');
      // ⚠️ 这里**不是** 720P：MiniMax v2 的 `resolution` 枚举只有
      //    480P / 768P / 2K（官方文档 API 里写死的 enum），**没有 720P**。
      //    干跑没有显式传档位，落到了通用兜底值 720P —— 形状表会把它兜成
      //    768P（H3 与 H3-Max **唯一都支持**的那一档）。见下面那条专门的测试。
      expect(body, contains('"resolution":"768P"'),
          reason: 'MiniMax 收到非法的 720P 必须兜成合法档位');
      expect(body, contains('"ratio":"16:9"'));
      expect(body, contains('"duration":5'));
    });

    test('MiniMax：非法的 720P 会被兜成 768P（v2 枚举里没有 720P）', () async {
      final out = await _dryRun(<String>[
        '--provider', 'minimax',
        '--resolution', '720P',
      ]);
      if (out == null) return markTestSkipped('本机没有 node');
      final body = _line(out, '[print-request] body')!;
      // 依据：官方 v2 文档 `resolution` 枚举 = 480P / 768P / 2K。
      // Agnes 与万相才用 720P —— 通用兜底值落到 MiniMax 上是**非法参数**，
      // 上游只会回一个参数错误（很容易被误当成"模型不支持"）。
      expect(body, contains('"resolution":"768P"'),
          reason: '非法档位没被兜住 —— 上游会回参数错');
      expect(body, isNot(contains('"resolution":"720P"')));
      // 合法档位不许被动过
      final ok = await _dryRun(<String>[
        '--provider', 'minimax',
        '--resolution', '2K',
      ]);
      expect(_line(ok!, '[print-request] body'),
          contains('"resolution":"2K"'),
          reason: '合法档位被改写了');
    });

    test('MiniMax 带首帧 → content[] 里 role=first_frame，且比例强制 adaptive', () async {
      final out = await _dryRun(<String>[
        '--provider', 'minimax',
        '--first-frame', '/tmp/dsh-test-frame.png',
        '--mode', 'keyframe',
      ]);
      if (out == null) return markTestSkipped('本机没有 node');
      final body = _line(out, '[print-request] body')!;
      expect(body, contains('"role":"first_frame"'),
          reason: 'v2 的首帧是 content[] 的一项，不是顶层 first_frame');
      // 注意断言的是**顶层键** `"first_frame":`（带冒号）——
      // `"role":"first_frame"` 里也含 `"first_frame"` 这个词，不带冒号会误判。
      expect(body, isNot(contains('"first_frame":')),
          reason: '顶层 first_frame 是 v1 的字段 —— v2 不认');
      expect(body, contains('"ratio":"adaptive"'),
          reason: '图生视频时文档要求 ratio=adaptive（由首帧决定）');
    });

    test('万相（DashScope）：异步端点 + input/parameters 结构 + /api/v1/tasks 轮询', () async {
      final out = await _dryRun(<String>['--provider', 'dashscope']);
      if (out == null) return markTestSkipped('本机没有 node');
      expect(_line(out, '[print-request] submit'),
          'POST https://dashscope.aliyuncs.com/api/v1/services/aigc/video-generation/video-synthesis');
      expect(_line(out, '[print-request] poll'),
          'GET https://dashscope.aliyuncs.com/api/v1/tasks/TASKID');
      final body = _line(out, '[print-request] body')!;
      expect(body, contains('"input":{"prompt":"一只猫在跑"}'));
      expect(body, contains('"parameters":'));
      expect(body, contains('"resolution":"720P"'));
    });

    test('硅基流动：POST /video/submit → POST /video/status（body 带 requestId）', () async {
      final out = await _dryRun(<String>['--provider', 'siliconflow']);
      if (out == null) return markTestSkipped('本机没有 node');
      expect(_line(out, '[print-request] submit'),
          'POST https://api.siliconflow.cn/v1/video/submit');
      final poll = _line(out, '[print-request] poll')!;
      expect(poll, startsWith('POST https://api.siliconflow.cn/v1/video/status'));
      expect(poll, contains('"requestId":"TASKID"'),
          reason: '这家查进度是 POST，任务 id 放在 body 里');
      final body = _line(out, '[print-request] body')!;
      expect(body, contains('"image_size":"1280x720"'),
          reason: '这家要具体像素，不是 720P 这种档位');
      expect(body, isNot(contains('"duration"')),
          reason: '这家没有时长参数 —— 不发，免得被当成无效字段');
    });

    test('OpenAI 没接视频 → 明说"没接"，而不是发一个必然失败的请求', () async {
      final out = await _dryRun(<String>['--provider', 'openai']);
      if (out == null) return markTestSkipped('本机没有 node');
      expect(out, contains('video=unsupported'));
      expect(out, isNot(contains('[print-request] submit')),
          reason: '不支持就不该打印出一个端点来（那会让人以为能用）');
    });

    test('⚠️ 选外部厂家但不填端点 → 不许发到 Agnes 的域名去（这是个真踩过的坑）', () async {
      // 曾经的写法 `process.env.AGNES_BASE_URL || DEFAULT_BASE_URL` 会让
      // 豆包/万相/硅基流动全部发到 api.agnes-ai.cn，报错看起来却像"这家的 Key 不对"。
      for (final entry in <MapEntry<String, String>>[
        const MapEntry('doubao', 'ark.cn-beijing.volces.com'),
        const MapEntry('dashscope', 'dashscope.aliyuncs.com'),
        const MapEntry('siliconflow', 'api.siliconflow.cn'),
      ]) {
        final out = await _dryRun(<String>['--provider', entry.key]);
        if (out == null) return markTestSkipped('本机没有 node');
        expect(out, contains(entry.value),
            reason: '${entry.key} 的端点必须默认取这家的地址');
        expect(_line(out, '[print-request] submit'), isNot(contains('agnes-ai.cn')),
            reason: '${entry.key} 绝不能发到 Agnes 的域名');
      }
    });

    test('自定义厂家（认不出）不填端点 → 明确报错 exit 2，不要拼出没有主机名的地址', () async {
      final script = _script();
      if (script == null) return markTestSkipped('本机找不到脚本');
      ProcessResult r;
      try {
        r = await Process.run(
          'node',
          <String>[script.path, '一只猫', '/tmp/dsh-test-out.mp4', '--provider', 'unknown'],
          environment: <String, String>{'AGNES_API_KEY': 'dummy'},
        );
      } on ProcessException {
        return markTestSkipped('本机没有 node');
      }
      expect(r.exitCode, 2);
      final all = '${r.stdout}${r.stderr}';
      expect(all, contains('端点'));
      expect(all, isNot(contains('Invalid URL')),
          reason: '要给人话，不要让 node 抛 Invalid URL 让用户猜');
    });

    test('用户自己填的端点要生效（App 会把所选模型的 baseUrl 注入 AGNES_BASE_URL）', () async {
      final script = _script();
      if (script == null) return markTestSkipped('本机找不到脚本');
      ProcessResult r;
      try {
        r = await Process.run(
          'node',
          <String>[
            script.path, '一只猫', '/tmp/dsh-test-out.mp4',
            '--provider', 'doubao', '--print-request',
          ],
          environment: <String, String>{
            'AGNES_API_KEY': 'dummy',
            'AGNES_BASE_URL': 'https://my-gateway.example.com/api/v3',
          },
        );
      } on ProcessException {
        return markTestSkipped('本机没有 node');
      }
      expect(r.stdout, contains('https://my-gateway.example.com/api/v3/contents/generations/tasks'),
          reason: '用户/App 显式给了端点就必须用它（版本段不许重复拼）');
      expect(r.stdout, isNot(contains('volces.com')));
    });

    test('参数校验按厂家分：Agnes 只认 4–12 秒，别家不该被 Agnes 的尺子拦下', () async {
      final script = _script();
      if (script == null) return markTestSkipped('本机找不到脚本');
      Future<ProcessResult> run(List<String> extra) async {
        return Process.run(
          'node',
          <String>[script.path, '一只猫', '/tmp/dsh-test-out.mp4', ...extra],
          environment: <String, String>{'AGNES_API_KEY': 'dummy'},
        );
      }

      ProcessResult r;
      try {
        // Agnes：20 秒非法（官方 4–12）
        r = await run(<String>['--provider', 'agnes', '--seconds', '20']);
        expect(r.exitCode, 2);
        expect('${r.stdout}${r.stderr}', contains('4–12'));

        // 豆包：20 秒合法（Seedance 能到 30 秒）→ 干跑应当成功
        r = await run(<String>['--provider', 'doubao', '--seconds', '20', '--print-request']);
        expect(r.exitCode, 0,
            reason: '拿 Agnes 的 4–12 去拦豆包，会把本来合法的参数判成错误');
        expect(r.stdout, contains('"duration":20'));
      } on ProcessException {
        return markTestSkipped('本机没有 node');
      }
    });
  }, skip: available ? false : '找不到 make-video.mjs');
}
