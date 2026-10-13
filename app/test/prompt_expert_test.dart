/// 「提示词助手」的测试。
///
/// ## 最要紧的一条：模型**只许返回提示词本身**
///
/// 结果会被**直接写进输入框**。模型要是回一句"好的，这是为你写的专业提示词：…"，
/// 用户就得自己删一遍 —— 那比不打字还累。所以系统提示里明确禁止，
/// 并且 [cleanPrompt] 兜底剥壳。这里把常见几种"多说话"的形状都钉住。
library;

import 'package:dsh_mobile/data/prompt_expert.dart';
import 'package:dsh_mobile/i18n/tables/en_table.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('cleanPrompt：剥掉模型多写的壳（兜底）', () {
    test('常见前缀 + 中文引号', () {
      expect(cleanPrompt('好的，这是为你写的提示词："一只橘猫坐在窗台上看雨"'),
          '一只橘猫坐在窗台上看雨');
    });

    test('markdown 代码围栏', () {
      expect(cleanPrompt('```\n一只橘猫坐在窗台上看雨\n```'), '一只橘猫坐在窗台上看雨');
      expect(cleanPrompt('```text\n一只橘猫\n```'), '一只橘猫');
    });

    test('成对引号被剥掉（不成对的不动）', () {
      expect(cleanPrompt('「一只橘猫」'), '一只橘猫');
      expect(cleanPrompt('“一只橘猫”'), '一只橘猫');
      // 单边引号不该被吃掉（那可能是提示词的合法内容）
      expect(cleanPrompt('"一只橘猫'), '"一只橘猫');
    });

    test('末尾多出来的"解释段"被去掉', () {
      const raw = '一只橘猫坐在窗台上看雨，柔和光线，写实风格\n\n'
          '这段提示词突出了氛围，希望你喜欢。';
      final out = cleanPrompt(raw);
      expect(out, '一只橘猫坐在窗台上看雨，柔和光线，写实风格');
    });

    test('换行被压成一行（输入框是单段文本，多行会被脚本当成同一段也难看）', () {
      expect(cleanPrompt('一只橘猫\n坐在窗台上\n看雨'), '一只橘猫 坐在窗台上 看雨');
    });

    test('本来就干净的提示词不要被改动', () {
      const clean = '一只橘猫坐在窗台上看雨，午后暖光，写实风格';
      expect(cleanPrompt(clean), clean);
    });
  });

  group('专家表', () {
    test('6 类专家，key 唯一（与桌面插件「提示词专家」一一对应）', () {
      expect(kPromptExperts.length, 6);
      expect(kPromptExperts.map((e) => e.key).toSet().length, 6);
      expect(kPromptExperts.map((e) => e.key).toList(),
          <String>['t2i', 'i2i', 't2v', 'sheet', 'drama', 'anchor']);
    });

    test('每条系统提示都明确要求"只输出正文"（否则结果不能直接填进输入框）', () {
      for (final e in kPromptExperts) {
        expect(e.system.contains('只输出'), isTrue,
            reason: '${e.key} 的 system 没有约束输出形状');
        expect(e.system.contains('不要解释'), isTrue,
            reason: '${e.key} 的 system 没有禁止解释');
      }
    });

    test('视频专家的 system 里有"只写一个连续动作"这条硬约束', () {
      final t2v = kPromptExperts.firstWhere((e) => e.key == 't2v');
      expect(t2v.system.contains('一个连续动作'), isTrue);
    });

    test('⚠️ 专家的名字/例子必须能在译文表里查到（i18n 锚点没被删）', () {
      // 这些文案是"数据形式"写在 kPromptExperts 里的，扫描器只能靠
      // prompt_expert.dart 里那段锚点看到它们。锚点一旦被删，
      // 这里会立刻红 —— 而不是等到"切日语时专家列表还是中文"才发现。
      for (final e in kPromptExperts) {
        expect(kEnTable.containsKey(e.name), isTrue,
            reason: '${e.name} 不在英文表里（i18n 锚点被删了？）');
        expect(kEnTable.containsKey(e.hint), isTrue,
            reason: '${e.hint} 不在英文表里（i18n 锚点被删了？）');
      }
      expect(kEnTable['文生图专家'], isNotEmpty);
    });
  });
}
