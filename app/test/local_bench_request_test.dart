import 'package:dsh_mobile/local/loose_chat_templates.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/local/local_model_server.dart';

/// 本地模型服务里那几个"改错了会安静地坏掉"的地方，钉死成回归测试。
///
/// 为什么值得单独一个文件：这三处都属于**只在真机上才暴露**的问题 ——
/// 测速请求写错一个字（少 `stream:false`），表现是"Gemma 4 的测速永远失败"，
/// 而 App 不会崩、不报错，只是那个按钮没用。没有人会在编译期发现它。
void main() {
  group('测速请求体', () {
    test('必须显式非流式：litert-lm 那条桥默认走 SSE，不写这行测速永远失败', () {
      final body = LocalModelServer.benchRequestBody('gemma-4-e2b', 48);
      expect(body['stream'], false,
          reason: '桥的默认值是 stream=true，而本地测速按普通 JSON 解析');
      expect(body['stateless'], true,
          reason: '必须告诉桥"这是测速" —— 否则它会顺手续用/重写主会话缓存');
    });

    test('测速不许动主会话缓存（stateless），否则点一次测速 = 下一句变慢', () {
      final body = LocalModelServer.benchRequestBody('local', 32);
      expect(body['stateless'], isTrue);
      expect(body['max_tokens'], 32);
      expect(body['temperature'], 0);
    });

    test('模型名按调用方给的传，不硬编码（否则日志里分不清测的是谁）', () {
      expect(LocalModelServer.benchRequestBody('qwen2.5-1.5b', 8)['model'],
          'qwen2.5-1.5b');
    });

    test('只带一条 user 消息（测速要的是生成速度，不是长上下文处理）', () {
      final msgs =
          LocalModelServer.benchRequestBody('local', 8)['messages'] as List;
      expect(msgs, hasLength(1));
      expect((msgs.first as Map)['role'], 'user');
    });
  });

  group('推理后端的两个引擎名', () {
    test('CPU / GPU 在 litert-lm 里的名字是 cpu / gpu', () {
      expect(LocalModelBackend.cpu.liteRtName, 'cpu');
      expect(LocalModelBackend.vulkan.liteRtName, 'gpu');
    });

    test('llama.cpp 那条路只有 CPU 用 -ngl 0，GPU 按尽量上 GPU', () {
      expect(LocalModelBackend.cpu.ngl, '0');
      expect(LocalModelBackend.vulkan.ngl, '99');
    });

    test('两档都有中文名（界面直接显示，不能有空标签）', () {
      for (final b in LocalModelBackend.values) {
        expect(b.label.trim(), isNotEmpty);
      }
    });
  });

  group('会话缓存那一行文案', () {
    test('还没对话时说明白，不显示 "0 次 · 0 次"', () {
      expect(
        LocalModelServer.liteRtCacheLine(
            reuseCount: 0, rebuildCount: 0, reason: 'first'),
        contains('还没开始对话'),
      );
    });

    test('有复用就把数字摆出来（这是"到底快在哪"的凭据）', () {
      final line = LocalModelServer.liteRtCacheLine(
          reuseCount: 12, rebuildCount: 3, reason: 'system');
      expect(line, contains('12'));
      expect(line, contains('3'));
    });

    test('重建原因翻成人话，并且能看出来是哪一类', () {
      expect(LocalModelServer.rebuildReasonText('system'), contains('系统提示'));
      expect(LocalModelServer.rebuildReasonText('params'), contains('模型'));
      expect(LocalModelServer.rebuildReasonText('history'), contains('历史'));
      expect(LocalModelServer.rebuildReasonText('partial'), contains('没回完'));
    });

    test('首轮重建不算"原因"（不该在界面上显示一行噪音）', () {
      expect(LocalModelServer.rebuildReasonText('first'), isEmpty);
      // 未知代码也不硬翻（宁可不说，也不要编一个原因给用户）。
      expect(LocalModelServer.rebuildReasonText('???'), isEmpty);
    });
  });

  group('Gemma 兼容对话模板', () {
    test('gemma 家族必须换模板（官方模板只认首条 system，DSH 会发多条）', () {
      expect(
          needsLooseChatTemplate(
              family: 'gemma-3-1b', fileName: 'gemma-3-1b-it-Q4_K_M.gguf'),
          isTrue);
      // ⚠️ Gemma 4 **故意不下药**：它是另一套模板格式（llama.cpp 为它单写了 gemma4
      // 解析器），套 Gemma 3 的 <start_of_turn> 模板很可能答歪。它要真不兼容，
      // 靠"启动自检"在界面上给红字，而不是赌一次模板替换。
      expect(
          needsLooseChatTemplate(
              family: 'gemma-4-e2b-qat', fileName: 'gemma-4-E2B_q4_0-it.gguf'),
          isFalse);
      expect(
          needsLooseChatTemplate(
              family: 'gemma4-e2b', fileName: 'gemma4-E2B-gpu.gguf'),
          isFalse);
      // 用户自己导入的文件名也要能命中（大小写不敏感）
      expect(
          needsLooseChatTemplate(
              family: '', fileName: 'GEMMA-3-4B-it-Q4_K_M.gguf'),
          isTrue);
    });

    test('别的模型不许套 Gemma 模板（模板写死了 <start_of_turn>，套错会答非所问）', () {
      expect(
          needsLooseChatTemplate(
              family: 'qwen2.5-1.5b',
              fileName: 'qwen2.5-1.5b-instruct-q4_k_m.gguf'),
          isFalse);
      expect(
          needsLooseChatTemplate(
              family: 'smolvlm', fileName: 'SmolVLM-500M-Instruct-Q8_0.gguf'),
          isFalse);
      // litert-lm 那类（`.litertlm`）走的是另一条引擎，不该命中
      expect(needsLooseChatTemplate(family: 'gemma-x', fileName: 'x.litertlm'),
          isTrue,
          reason:
              '家族名含 gemma 就算命中；但 litert-lm 那条路不会调用这个参数（见 ensureRunning 的 engine 分支）');
    });

    test('模板必须保留 Gemma 的对话标记（改坏它模型就答不出人话）', () {
      expect(kLooseGemmaTemplate, contains('<start_of_turn>'));
      expect(kLooseGemmaTemplate, contains('<end_of_turn>'));
      expect(kLooseGemmaTemplate, contains('add_generation_prompt'));
    });

    test('模板里绝不能再有那条"角色必须交替"的硬校验（这是 400 的根因）', () {
      expect(kLooseGemmaTemplate.contains('raise_exception'), isFalse,
          reason: '只要还留着 raise_exception，真机上就还会 400');
      expect(kLooseGemmaTemplate.contains('must alternate'), isFalse);
    });

    test('首条 system 仍按官方做法并进第一个 user（否则系统提示会丢）', () {
      expect(kLooseGemmaTemplate,
          contains("loop_messages[0]['role'] == 'system'"));
      expect(kLooseGemmaTemplate, contains('first_user_prefix'));
    });
  });
}
