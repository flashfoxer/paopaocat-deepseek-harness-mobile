import 'dart:convert';

import 'package:dsh_mobile/local/acp_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// 钉死"到底在跑哪个模型"这件事的解析契约。
///
/// 为什么值得单独测：用户实测反馈「切换模型时选一次不行，需要选第二次才可以切换模型」，
/// 修法之一是**不再相信界面上的选中项**，改成以运行时返回的 `configOptions` 为唯一判据
/// （见 `AcpClient.setSessionModel` / `chat_page._switchModelInPlace`）。
/// 这个解析错了，修法就变成"永远说没切成功"，反而更糟。
///
/// 形态来源（`@deepseek-ai/dsh-acp/lib/index.js` 的 `AcpModelControl.state()`）：
/// ```
/// [{ id: "model", currentValue: '["provider","model"]', type: "select", options: [...] }]
/// ```
void main() {
  group('AcpClient.modelRouteFromConfigOptions', () {
    test('从 model 配置项里取出 provider/model', () {
      final options = <dynamic>[
        <String, dynamic>{
          'id': 'model',
          'name': 'Model',
          'type': 'select',
          'currentValue': jsonEncode(<String>['agnes', 'agnes-3.0-flash']),
          'options': <dynamic>[],
        },
      ];
      expect(
        AcpClient.modelRouteFromConfigOptions(options),
        'agnes/agnes-3.0-flash',
      );
    });

    test('model 前面还有别的配置项时也能找到（顺序无关）', () {
      final options = <dynamic>[
        <String, dynamic>{'id': 'mode', 'currentValue': 'code'},
        <String, dynamic>{
          'id': 'model',
          'currentValue': jsonEncode(<String>['deepseek', 'deepseek-chat']),
        },
        <String, dynamic>{'id': 'reasoning_effort', 'currentValue': 'high'},
      ];
      expect(
        AcpClient.modelRouteFromConfigOptions(options),
        'deepseek/deepseek-chat',
      );
    });

    test('模型 id 里带斜杠也不会被截断（只按数组取）', () {
      final options = <dynamic>[
        <String, dynamic>{
          'id': 'model',
          'currentValue':
              jsonEncode(<String>['com', 'deepseek/deepseek-v4-pro']),
        },
      ];
      expect(
        AcpClient.modelRouteFromConfigOptions(options),
        'com/deepseek/deepseek-v4-pro',
      );
    });

    test('取不到就返回 null —— 绝不猜一个模型出来', () {
      expect(AcpClient.modelRouteFromConfigOptions(null), isNull);
      expect(AcpClient.modelRouteFromConfigOptions('x'), isNull);
      expect(AcpClient.modelRouteFromConfigOptions(<dynamic>[]), isNull);
      // 只有别的不相关配置项
      expect(
        AcpClient.modelRouteFromConfigOptions(<dynamic>[
          <String, dynamic>{'id': 'reasoning_effort', 'currentValue': 'high'},
        ]),
        isNull,
      );
      // currentValue 不是我们认识的 JSON 数组
      expect(
        AcpClient.modelRouteFromConfigOptions(<dynamic>[
          <String, dynamic>{'id': 'model', 'currentValue': '没有这种事'},
        ]),
        isNull,
      );
      // 数组只有一项（残缺）
      expect(
        AcpClient.modelRouteFromConfigOptions(<dynamic>[
          <String, dynamic>{
            'id': 'model',
            'currentValue': jsonEncode(<String>['only-provider']),
          },
        ]),
        isNull,
      );
      // currentValue 不是字符串
      expect(
        AcpClient.modelRouteFromConfigOptions(<dynamic>[
          <String, dynamic>{
            'id': 'model',
            'currentValue': <String>['a', 'b']
          },
        ]),
        isNull,
      );
    });

    test('modelOptionValue 与 DSH 的 modelValue() 逐字一致', () {
      // 运行时用的就是 `JSON.stringify([provider, model])`（逗号后无空格）。
      // 差一个空格，set_config_option 就会报 unknown model option。
      expect(
        AcpClient.modelOptionValue('agnes', 'agnes-model'),
        '["agnes","agnes-model"]',
      );
    });
  });
}
