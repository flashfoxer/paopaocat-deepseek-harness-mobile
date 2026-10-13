import 'package:dsh_mobile/protocol/bridge_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// 指纹比较是 wss 的安全核心：用户会从终端复制各种格式的指纹，
/// 归一化错误会导致"证书永远对不上"或"本该拒绝却放行"。
void main() {
  group('指纹归一化', () {
    test('忽略大小写、冒号、空格与前后空白', () {
      const expected = 'AABBCCDD';
      for (final input in [
        'AA:BB:CC:DD',
        'aa:bb:cc:dd',
        'Aa:Bb:Cc:Dd',
        'aabbccdd',
        'AA BB CC DD',
        '  aa:bb:cc:dd  ',
        'AA-BB-CC-DD',
      ]) {
        expect(
          BridgeClient.normalizeFingerprint(input),
          expected,
          reason: '输入 $input 应归一化为 $expected',
        );
      }
    });

    test('不同指纹不会被误判为相同', () {
      expect(
        BridgeClient.normalizeFingerprint('AA:BB:CC:DD'),
        isNot(BridgeClient.normalizeFingerprint('AA:BB:CC:DE')),
      );
    });

    test('真实长度的 SHA-256 指纹可以正确归一化', () {
      const real =
          '94:E2:FF:B8:E2:77:C5:57:CA:D0:C9:E8:31:BD:3D:99:DE:70:61:F5:F2:FA:D6:44:7A:9C:2F:3C:AE:18:EC:4D';
      final normalized = BridgeClient.normalizeFingerprint(real);
      expect(normalized.length, 64, reason: 'SHA-256 去掉分隔符后应为 64 个 hex 字符');
      expect(normalized, matches(RegExp(r'^[0-9A-F]{64}$')));
    });
  });
}
