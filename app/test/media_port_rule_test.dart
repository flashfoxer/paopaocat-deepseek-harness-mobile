/// 媒体端口模型**不许进会话清单**（用户 2026-10-12 排查时发现）。
///
/// ## 为什么非有不可
///
/// Agnes 的图像 / 视频模型走 `/images/generations` 与 `/videos`，
/// 拿去打 `/chat/completions` **必然 400**。写入侧（设置页）早就过滤了，
/// 但**读取侧原来不过滤** → 老版本写进去的残留 / 手填的条目会一直留在
/// 「会话模型面板」里，选中就 400 —— 与「影视 → 提示词专家」那个 400
/// 是**同一条链路，只是入口不同**。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/data/agnes_builtin.dart';
import 'package:dsh_mobile/data/chat_model_rule.dart';
import 'package:dsh_mobile/data/configured_models.dart';
import 'package:dsh_mobile/data/media_port_rule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('规则本体', () {
    test('Agnes 的图像 / 视频是媒体端口，文本不是', () {
      expect(isMediaPortModel('agnes', AgnesBuiltin.imageModel), isTrue);
      expect(isMediaPortModel('agnes', AgnesBuiltin.videoModel), isTrue);
      expect(isMediaPortModel('agnes', AgnesBuiltin.textModel), isFalse);
    });

    test('以后换成 agnes-image-3 这种新名字也照样挡住（不许静默漏回来）', () {
      expect(isMediaPortModel('agnes', 'agnes-image-3'), isTrue);
      expect(isMediaPortModel('agnes', 'agnes-video-4-pro'), isTrue);
      expect(isMediaPortModel('agnes', 'agnes-3.0-pro'), isFalse);
    });

    test('别的厂家的 image/video 命名不受影响（规则只针对 Agnes 内置端口）', () {
      expect(isMediaPortModel('siliconflow', 'image-model-x'), isFalse);
      expect(isMediaPortModel('custom', 'video-anything'), isFalse);
    });

    test('route 形态同口径', () {
      expect(isMediaPortRoute('agnes/${AgnesBuiltin.imageModel}'), isTrue);
      expect(isMediaPortRoute('rotate/cat'), isFalse);
      expect(isMediaPortRoute('agnes'), isFalse);
    });

    test('值只有一份：AgnesBuiltin 与叶子文件必须一致（防两边漂）', () {
      expect(AgnesBuiltin.providerId, kAgnesProviderId);
      expect(AgnesBuiltin.textModel, kAgnesTextModel);
      expect(AgnesBuiltin.imageModel, kAgnesImageModel);
      expect(AgnesBuiltin.videoModel, kAgnesVideoModel);
    });

    test('isChatModelFor 与 isMediaPortModel 口径一致（两个调用点不许分叉）', () {
      for (final id in <String>[
        AgnesBuiltin.textModel,
        AgnesBuiltin.imageModel,
        AgnesBuiltin.videoModel,
        'agnes-image-3',
        'agnes-3.0-pro',
      ]) {
        expect(isChatModelFor('agnes', id), !isMediaPortModel('agnes', id),
            reason: '两边对「$id」的判断不一致');
      }
    });
  });

  group('读配置时就把残留滤掉（一个点管住会话面板 / overlay / 报告）', () {
    /// 造一份"老版本留下的"配置：agnes 名下混着图像 / 视频模型。
    Map<String, dynamic> cfgWithResidue({String? selected}) => <String, dynamic>{
          'version': 2,
          'selected': selected ?? 'agnes/${AgnesBuiltin.textModel}',
          'providers': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'agnes',
              'label': 'Agnes（免费）',
              'baseUrl': AgnesBuiltin.baseUrl,
              'api': 'openai-completions',
              'apiKeyEnv': 'AGNES_API_KEY',
            },
          ],
          'models': <Map<String, dynamic>>[
            <String, dynamic>{
              'provider': 'agnes',
              'id': AgnesBuiltin.textModel,
            },
            <String, dynamic>{
              'provider': 'agnes',
              'id': AgnesBuiltin.imageModel,
            },
            <String, dynamic>{
              'provider': 'agnes',
              'id': AgnesBuiltin.videoModel,
            },
          ],
          'groups': <Map<String, dynamic>>[],
        };

    String writeCfg(Map<String, dynamic> cfg) {
      final dir = Directory.systemTemp.createTempSync('media-filter-');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      File('${dir.path}/models.json').writeAsStringSync(jsonEncode(cfg));
      return dir.path;
    }

    test('残留的图像 / 视频模型不再出现在 `models` 里', () {
      final dir = writeCfg(cfgWithResidue());
      final cfg = ConfiguredModels.readConfig(dir);
      expect(cfg.models.map((m) => m.id), <String>[AgnesBuiltin.textModel],
          reason: '媒体模型还留在会话清单里 —— 选中就是 400');
    });

    test('也不出现在会话模型面板（`choices`）里', () {
      final dir = writeCfg(cfgWithResidue());
      final cfg = ConfiguredModels.readConfig(dir);
      final routes = cfg.choices.map((c) => c.route).toList();
      expect(routes, contains('agnes/${AgnesBuiltin.textModel}'));
      expect(routes, isNot(contains('agnes/${AgnesBuiltin.imageModel}')),
          reason: '图像模型出现在会话面板里了');
      expect(routes, isNot(contains('agnes/${AgnesBuiltin.videoModel}')),
          reason: '视频模型出现在会话面板里了');
    });

    test('选中项正好是被滤掉的媒体模型 → 一并清掉（不留"当前模型找不到"）', () {
      final dir = writeCfg(
          cfgWithResidue(selected: 'agnes/${AgnesBuiltin.imageModel}'));
      final cfg = ConfiguredModels.readConfig(dir);
      expect(cfg.selected, isNull,
          reason: 'selected 还指着一个已经不在清单里的模型');
    });

    test('正常配置一条都不许少（别把过滤写成误伤）', () {
      final dir = writeCfg(cfgWithResidue());
      final cfg = ConfiguredModels.readConfig(dir);
      expect(cfg.models, hasLength(1));
      expect(cfg.selected, 'agnes/${AgnesBuiltin.textModel}',
          reason: '没被滤掉的选中项也被动了');
      expect(cfg.providers, hasLength(1));
    });
  });
}
