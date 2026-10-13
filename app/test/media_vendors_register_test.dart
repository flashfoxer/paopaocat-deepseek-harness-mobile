// 厂家注册地址 / 端点表的**两侧一致**测试。
//
// 背景（用户 2026-10-12）：「再查一下图形/视频的模型端点是否真实，最好查看这几家的
// 技术文档，也可以给注册地址」。
//
// 这张表的**唯一来源**是 `assets/toolbox/media-vendors.mjs`（真正拼请求的那份），
// 但 Dart 侧（设置页要给「去哪拿 Key」链接）读不了 .mjs，只能镜像一份。
// 两份漂了就会：界面给一个地址、实际请求发到另一个域名 —— 这种错最难查。
// 所以这里把 Dart 的镜像表**逐条对着脚本正文核**（脚本就在仓库里，测试能读）。
import 'dart:io';

import 'package:dsh_mobile/data/media_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Dart 的注册地址表与 media-vendors.mjs 逐条一致', () {
    final f = File('assets/toolbox/media-vendors.mjs');
    expect(f.existsSync(), isTrue, reason: '脚本不在 → 这个测试就失去意义了');
    final src = f.readAsStringSync();

    for (final id in MediaVendors.ids) {
      final url = MediaVendors.registerUrl(id);
      if (id == MediaVendors.unknown) {
        expect(url, isEmpty, reason: '自定义厂家没有注册地址（**不猜**）');
        continue;
      }
      expect(url, isNotEmpty, reason: '$id 在 Dart 侧没有注册地址');
      // 逐字出现在脚本正文里 —— 两边有一边改了另一边就红。
      expect(src.contains(url), isTrue,
          reason: '$id 的注册地址「$url」在 media-vendors.mjs 里找不到 —— 两边漂了');
    }
  });

  test('每家（除自定义）在脚本里都真的有 register 字段', () {
    final src = File('assets/toolbox/media-vendors.mjs').readAsStringSync();
    // 数一数 register: '...' 出现了几次 —— 7 家支持的厂家都要有。
    final n = RegExp(r"register:\s*'https://").allMatches(src).length;
    expect(n, MediaVendors.ids.length - 1,
        reason: '脚本里 register 字段 $n 个，应当是 ${MediaVendors.ids.length - 1} 个'
            '（除自定义厂家外每家一个）');
  });

  test('注册地址都是 https 且指向各自的控制台域名（不是随便一个地址）', () {
    // 这几条是"用户点了会不会到对的地方"的硬约束：
    // 域名必须和这家厂家的 API 域名同源（不然就是给了个不相干的网站）。
    const want = <String, String>{
      'agnes': 'platform.agnes-ai.cn',
      'openai': 'platform.openai.com',
      'zhipu': 'open.bigmodel.cn',
      'dashscope': 'bailian.console.aliyun.com',
      'doubao': 'console.volcengine.com',
      'minimax': 'platform.minimax.cn',
      'siliconflow': 'cloud.siliconflow.cn',
    };
    want.forEach((id, host) {
      final url = MediaVendors.registerUrl(id);
      expect(url.startsWith('https://'), isTrue, reason: '$id 不是 https');
      expect(url.contains(host), isTrue,
          reason: '$id 的注册地址应当是 $host 下的页面，实际是 $url');
    });
  });
}
