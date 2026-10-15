// 「会话里能用什么」这两件事的**配置片段生成**（见 `data/session_capabilities.dart`）：
//   ① 联网搜索的后端改钉到 AnySearch（免 Key）；
//   ② 子智能体的开关与"子会话用哪个模型"。
//
// 为什么要单独钉住它们：这两段是**写进 overlay 的 YAML**，而写错的后果不是"功能不好用"，
// 是**整个会话起不来**：
//   * 引用一个运行时里**不存在**的插件（老运行包）→ 插件解析失败；
//   * patch 只写半段 config → 那一行被**整段替换**成残缺配置（patch 的语义是替换不是合并）；
//   * 数值/名字不加引号 → YAML 当整数解析，DSH 校验"必须是字符串"直接失败
//     （2026-10-10 真机事故：「轮换池叫 001 就所有模型都不能用」）。
// 所以这些断言都是"防整机坏掉"的，不是洁癖。

import 'dart:io';

import 'package:dsh_mobile/data/session_capabilities.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('运行时里有没有 AnySearch 后端插件（决定敢不敢在 overlay 里引用它）', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('dsh-cap-'));
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('没有插件 → false（老运行包绝不能写那两行）', () {
      expect(SessionCapabilities.runtimeHasAnysearchPlugin(tmp.path), isFalse);
      expect(SessionCapabilities.runtimeHasAnysearchPlugin(''), isFalse);
    });

    test('插件到位 → true（认的就是解包后的 node_modules 路径）', () {
      Directory('${tmp.path}/${SessionCapabilities.anysearchPluginRelPath}')
          .createSync(recursive: true);
      expect(SessionCapabilities.runtimeHasAnysearchPlugin(tmp.path), isTrue);
    });
  });

  group('联网搜索：改钉到 AnySearch 的片段', () {
    final patch = SessionCapabilities.nativeWebSearchPatch();

    test('必须覆盖 web 这一行，而且**整段**重写（searchProvider + fetchProvider）', () {
      expect(patch, contains('- id: web'));
      expect(patch, contains('searchProvider: anysearch'));
      expect(patch, contains('fetchProvider: http'),
          reason: 'patch 是整段 config 替换：漏掉 fetchProvider 会让抓网页那半边退化');
    });

    test('必须把后端插件 insert 进组合，并点名 apiKeyEnv', () {
      expect(patch, contains('- insert:'));
      expect(patch, contains('web-search-anysearch'));
      expect(patch, contains('"ANYSEARCH_API_KEY"'));
    });

    test('不许出现旧后端的钉死值（否则等于没换）', () {
      expect(patch, isNot(contains('searchProvider: deepseek-official')));
    });
  });

  group('子智能体：开关与指定模型', () {
    test('开着 + 跟随会话 → 不写任何片段（保持出厂）', () {
      expect(SessionCapabilities.subagentPatch(enabled: true), '');
      expect(SessionCapabilities.subagentPatch(enabled: true, provider: '', model: ''), '');
      expect(SessionCapabilities.subagentPatch(enabled: true, provider: 'a', model: ''), '');
    });

    test('关掉 → 服务与工具一起 disabled（不留"半个还活着"）', () {
      final patch = SessionCapabilities.subagentPatch(enabled: false);
      for (final id in <String>[
        'tool-subagent',
        'tool-subagent-fork',
        'tool-subagent-control',
        'tool-subagent-list-agents',
        'subagent-spawn-in-process',
        'subagent-fork-in-process',
      ]) {
        expect(patch, contains('- id: $id'), reason: '$id 必须一起关');
      }
      expect(patch, contains('disabled: true'));
    });

    test('指定模型 → 覆盖 tool-subagent，且把出厂那几项**写全**', () {
      final patch = SessionCapabilities.subagentPatch(
        enabled: true,
        provider: 'com',
        model: 'deepseek-v4.1-flash',
      );
      expect(patch, contains('- id: tool-subagent'));
      expect(patch, contains('provider: spawn'), reason: '整段替换，provider 必须重写');
      expect(patch, contains('toolName: subagent'));
      expect(patch, contains('backgroundMode: continuable'));
      expect(patch, contains('      provider: "com"'));
      expect(patch, contains('      model: "deepseek-v4.1-flash"'));
      // fork 那一档刻意不动：它的语义是继承父会话历史，换模型会让 KV 缓存失效
      expect(patch, isNot(contains('tool-subagent-fork')));
    });

    test('值必须加引号（纯数字名字不加引号会被 YAML 当整数，整机模型全挂）', () {
      final patch = SessionCapabilities.subagentPatch(
        enabled: true,
        provider: '001',
        model: '002',
      );
      expect(patch, contains('provider: "001"'));
      expect(patch, contains('model: "002"'));
      expect(patch, isNot(contains('provider: 001')));
    });
  });
}
