import 'package:dsh_mobile/local/diagnostics_log.dart';
import 'package:flutter_test/flutter_test.dart';

/// 报告格式是**给人和大模型读**的接口，格式错了排查就会费劲，
/// 所以解析、分级、聚合、脱敏这几步都单独测。
void main() {
  group('拆行', () {
    test('标准行：时间 / 标签 / 级别 / 正文', () {
      final p = DiagnosticsLog.parseLine(
          '00:53:05.284 [dsh-image] ERR [E] get sd version from file failed');
      expect(p.ts, '00:53:05.284');
      expect(p.tag, 'dsh-image');
      expect(p.lvl, 'E');
      expect(p.msg, contains('get sd version'));
    });

    test('双括号标签（[[tag]]）也能拆', () {
      final p = DiagnosticsLog.parseLine(
          '00:53:05.272 [[dsh-image]]   vae_on_cpu: false,');
      expect(p.tag, 'dsh-image');
      expect(p.lvl, 'I');
    });

    test('裸行不丢：塞进 msg，标签记 raw', () {
      final p = DiagnosticsLog.parseLine('随便一行原生输出');
      expect(p.tag, 'raw');
      expect(p.msg, '随便一行原生输出');
    });
  });

  group('分级', () {
    test('明确信号才算错误', () {
      expect(DiagnosticsLog.levelOf('请求 6959 tokens 超出…失败'), 'E');
      expect(DiagnosticsLog.levelOf('未捕获异常：xxx'), 'E');
      expect(DiagnosticsLog.levelOf('引擎不存在：…'), 'E');
      expect(DiagnosticsLog.levelOf('WARN 超时'), 'W');
      expect(DiagnosticsLog.levelOf('启动：libsdserver.so --model …'), 'I');
    });

    test('「失败 0」不算错误（它是零失败的自证，不是失败）', () {
      // 真机报告曾因此每次挂一条假错误，把真错误淹没。
      expect(
          DiagnosticsLog.levelOf(
              '内置技能：新增 0 / 更新 0 / 保留用户改动 0 / 失败 0（根目录 /x/skills）'),
          'I');
      expect(DiagnosticsLog.levelOf('错误: 0'), 'I');
      // 有真实失败次数仍然要判 E；`0x800` 这种也不能被误当成零失败。
      expect(DiagnosticsLog.levelOf('重试 3 次后失败 1 次'), 'E');
      expect(DiagnosticsLog.levelOf('写入失败 0x80070005'), 'E');
    });
  });

  group('归一化与聚合', () {
    test('只有数字不同的同类错误并成一条', () {
      final a = DiagnosticsLog.normalize(
          'request (6959 tokens) exceeds the available context size (2048 tokens)');
      final b = DiagnosticsLog.normalize(
          'request (7005 tokens) exceeds the available context size (2048 tokens)');
      expect(a, b);
    });

    test('聚合给出次数与首末时间', () {
      final ev = DiagnosticsLog.keyEventsFrom(<String>[
        '00:53:17.021 [print:chat] prompt failed（第 1 次）: request (6959 tokens) 超出上下文',
        '00:53:30.499 [print:chat] prompt failed（第 1 次）: request (6972 tokens) 超出上下文',
        '00:53:31.330 [print:chat] prompt failed（第 2 次）: request (6979 tokens) 超出上下文',
        '00:53:47.250 [print:dsh-settings-tab] 打开「本地大模型」',
      ]);
      expect(ev.length, 1, reason: '三条同类错误应聚合为一条（那条普通日志不算）');
      expect(ev.single.count, 3);
      expect(ev.single.lvl, 'E');
      expect(ev.single.first, '00:53:17.021');
      expect(ev.single.last, '00:53:31.330');
    });

    test('没有错误时聚合为空（报告里写"本次运行没有错误或警告"）', () {
      expect(DiagnosticsLog.keyEventsFrom(<String>['00:00:01.000 [x] 一切正常']),
          isEmpty);
    });
  });

  group('明细', () {
    test('带 seq 与管道分隔', () {
      final d = DiagnosticsLog.detailLinesFrom(<String>[
        '00:53:05.272 [dsh-image] 启动：libsdserver.so --model a.gguf',
      ]);
      expect(d.single, startsWith('0001|00:53:05.272|I|dsh-image|'));
    });

    test('会话内容转储被省略（隐私 + 体积）', () {
      final dump = '{"title":"你好","messages":[{"role":"user","text":"'
          '${'很长很长的对话内容' * 300}"}]}';
      final d = DiagnosticsLog.detailLinesFrom(
          <String>['00:54:18.496 [print:dsh-proc] $dump']);
      expect(d.single, contains('会话内容已省略'));
      expect(d.single.length, lessThan(120));
    });

    test('超长行被截断并标注', () {
      final d = DiagnosticsLog.detailLinesFrom(
          <String>['00:00:01.000 [x] ${'内容' * 400}'],
          maxMsg: 50);
      expect(d.single, contains('已截断'));
    });
  });

  group('URL 内嵌凭据也要脱敏（审计 P2）', () {
    test('https://user:pass@host 里的口令不能出现在日志里', () {
      final out = DiagnosticsLog.redact(
          '连接 https://alice:s3cr3t-pw@example.com/v1/chat 失败');
      expect(out, isNot(contains('s3cr3t-pw')));
      expect(out, isNot(contains('alice')));
      expect(out, contains(DiagnosticsLog.redactedMarker));
      // scheme 与主机必须保留 —— 否则排障时看不出连的是哪儿
      expect(out, contains('https://'));
      expect(out, contains('example.com/v1/chat'));
    });

    test('其它 scheme 同样处理（ws / http / socks5）', () {
      for (final u in <String>[
        'ws://bob:hunter2@10.0.0.5:8790/bridge',
        'http://carol:pw123@127.0.0.1:8080/x',
        'socks5://dave:pa55@127.0.0.1:1080',
      ]) {
        final out = DiagnosticsLog.redact('用 $u 连');
        expect(out, isNot(contains('hunter2')));
        expect(out, isNot(contains('pw123')));
        expect(out, isNot(contains('pa55')));
      }
    });

    test('普通 URL（没有凭据）**不**被改动', () {
      const u = 'https://api.agnes-ai.cn/v1/chat/completions';
      expect(DiagnosticsLog.redact('请求 $u'), contains(u));
      // 带用户名但没有口令（少见但要容错）不该被吃掉主机
      expect(DiagnosticsLog.redact('http://example.com/a:b@c'),
          contains('example.com'));
    });

    test('⚠️ 证书指纹与 sha256 **必须**保留（否则配对时用户没法核对）', () {
      // 这一条是"故意不加裸 hex 脱敏"的理由 —— 把它钉住，免得以后有人好心加。
      const fp = 'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99';
      expect(DiagnosticsLog.redact('指纹 $fp'), contains(fp));
      const sha = '3a4dcb0e1b37436358d6cc5de28300071d55367395381958eba9fd38b3d78e32';
      expect(DiagnosticsLog.redact('sha256=$sha'), contains(sha));
    });
  });
}
