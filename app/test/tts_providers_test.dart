/// 配音（口播/短剧）三家供应商的**契约测试**。
///
/// ## 为什么这几条值得钉住
///
/// 配音这三家有两类**不会报错的坏法**：
///
/// 1. **解码方式错了** —— MiniMax 的 `data.audio` 是 **hex**，MiMo 的是 **base64**。
///    用错解出来的字节照样能写进文件、合成时也不一定立刻炸，只是"播出来是噪音/放不了"。
///    所以解码器单独钉，长度奇数、含非 hex 字符都要明确返回 null。
/// 2. **接口上没有的参数被"以为有"** —— MiMo 官方**没有数值语速参数**，只有自然语言指令。
///    代码里如果给 MiMo 发 `speed: 1.2`，服务端不会报错、也不会有任何效果，用户只会觉得
///    "这个语速开关是假的"。所以三档 → 指令词的映射必须钉住。
///
/// 另外供应商/音色/语速都是**落盘偏好**（`AppSettings`），默认值必须是"人人可用"的那家。
library;

import 'dart:io';

import 'package:dsh_mobile/data/tts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('配音来源', () {
    test('默认仍是手机自带的 TTS（不能因为加了云厂商就改默认）', () {
      expect(TtsSource.system.index, 0);
      expect(TtsSource.values.first, TtsSource.system);
    });

    test('四家都在枚举里（system / local / mimo / minimax）', () {
      // 2026-10-13 加了 `local`（本机离线，零 Key）——它必须是**独立的**一档，
      // 不能借 system 的名义（两者的失败方式完全不同：
      // 系统那档依赖"这台手机有没有 TTS 引擎"，离线这档依赖"模型装没装"）。
      expect(
        TtsSource.values.map((v) => v.name).toSet(),
        <String>{'system', 'local', 'mimo', 'minimax'},
      );
    });

    test('输出后缀：只有 MiniMax 出 mp3，其余 wav', () {
      expect(ttsExtensionFor(TtsSource.minimax), '.mp3');
      expect(ttsExtensionFor(TtsSource.mimo), '.wav');
      expect(ttsExtensionFor(TtsSource.system), '.wav');
      // 与两家声明的格式常量必须一致（改一处忘一处 = 后缀和内容不符）
      expect(ttsExtensionFor(TtsSource.minimax), '.$kMinimaxAudioFormat');
      expect(ttsExtensionFor(TtsSource.mimo), '.$kMimoAudioFormat');
    });
  });

  group('MiniMax 的 hex 解码', () {
    test('正常 hex → 字节', () {
      expect(minimaxHexToBytes('00ff10'), <int>[0, 255, 16]);
      expect(minimaxHexToBytes(' 4a4b '), <int>[0x4a, 0x4b]);
      // 大小写都要认（服务端回的是小写，但不该依赖这一点）
      expect(minimaxHexToBytes('AbCd'), <int>[0xab, 0xcd]);
    });

    test('奇数长度 → null（半个字节 = 数据被截断，不能猜）', () {
      expect(minimaxHexToBytes('abc'), isNull);
    });

    test('含非 hex 字符 → null（返回的不是音频时要说实话，不能产出垃圾文件）', () {
      expect(minimaxHexToBytes('zz'), isNull);
      expect(minimaxHexToBytes('12g4'), isNull);
      // base64 的典型字符（MiniMax 不用这个；混进来必须失败）
      expect(minimaxHexToBytes('++//'), isNull);
    });

    test('空串 → null', () {
      expect(minimaxHexToBytes(''), isNull);
      expect(minimaxHexToBytes('   '), isNull);
    });
  });

  group('MiMo 的语速（只能翻成自然语言指令）', () {
    test('三档都在 0.5~2.0 且各有指令词', () {
      expect(kSpeedPresets.length, 3);
      for (final p in kSpeedPresets) {
        expect(p.speed, inInclusiveRange(0.5, 2.0), reason: '${p.label} 的倍率出界');
        expect(p.label, isNotEmpty);
        expect(p.mimoHint, isNotEmpty, reason: '${p.label} 没有给 MiMo 的指令词');
      }
    });

    test('倍率 → 最近那一档的指令词（不许返回空）', () {
      expect(mimoSpeedHint(0.85), kSpeedPresets[0].mimoHint);
      expect(mimoSpeedHint(1.0), kSpeedPresets[1].mimoHint);
      expect(mimoSpeedHint(1.2), kSpeedPresets[2].mimoHint);
      // 界面上是滑杆（0.5~2.0），任何取值都要能落到某一档
      for (final v in <double>[0.5, 0.7, 0.95, 1.05, 1.5, 2.0]) {
        expect(mimoSpeedHint(v), isNotEmpty, reason: '倍率 $v 没有落到任何一档');
      }
    });
  });

  group('MiMo 音色表（来自官方文档，不许凭印象加）', () {
    test('9 条、id 唯一、都有显示名', () {
      expect(kMimoVoices.length, 9);
      expect(kMimoVoices.map((v) => v.id).toSet().length, 9, reason: '有重复的音色 id');
      for (final v in kMimoVoices) {
        expect(v.id.trim(), isNotEmpty);
        expect(v.label.trim(), isNotEmpty, reason: '${v.id} 没有显示名');
      }
    });

    test('默认音色必须在表里，且名字和官方一致（`mimo_default`）', () {
      expect(kMimoVoices.first.id, 'mimo_default');
      // 官方文档里的中文音色（ID 就是中文词本身，不能"翻译"）
      for (final id in <String>['冰糖', '茉莉', '苏打', '白桦']) {
        expect(kMimoVoices.map((v) => v.id), contains(id));
      }
    });

    test('MiniMax 只写死一个默认音色（官方 CLI 的默认值）', () {
      expect(kMinimaxDefaultVoice.id, 'English_expressive_narrator');
      expect(kMinimaxDefaultVoice.id.trim(), isNotEmpty);
    });
  });

  group('没配 Key 时说人话（指到设置里的哪一家）', () {
    test('选 MiniMax 但没配 Key → 说清是 MiniMax、并指到设置', () async {
      final r = await synthesizeSpeech(
        text: '你好',
        outPath: '${Directory.systemTemp.path}/mm.mp3',
        source: TtsSource.minimax,
      );
      expect(r.ok, isFalse);
      expect(r.error, contains('MiniMax'));
      expect(r.error, contains('设置'), reason: '要告诉用户去哪填：${r.error}');
    });

    test('拉取音色但没配 Key → 返回空表 + 原因（不许编一份清单）', () async {
      final r = await fetchMinimaxVoices();
      expect(r.voices, isEmpty);
      expect(r.error, isNotNull);
      expect(r.error, contains('MiniMax'));
    });
  });

  // 落盘偏好的白名单：`AppSettings` 只认这几个来源 id，改枚举名要同步改那张表
  group('来源 id 与设置层白名单一致', () {
    test('枚举名 == AppSettings.kTtsSourceIds', () {
      // 这里刻意用字面量比对（不 import 设置层）：名字就是**存储在磁盘上的字面量**，
      // 改名字 = 老用户的偏好静默失效，所以必须是一条"改了就红"的断言。
      expect(
        TtsSource.values.map((v) => v.name).toSet(),
        <String>{'system', 'local', 'mimo', 'minimax'},
      );
    });
  });
}
