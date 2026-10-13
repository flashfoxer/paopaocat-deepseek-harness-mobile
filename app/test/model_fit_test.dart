import 'dart:io';

import 'package:dsh_mobile/local/model_fit.dart';
import 'package:dsh_mobile/local/model_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

OnDeviceModel _model({
  int minRamGb = 6,
  int bytes = 1100000000,
  String engine = 'llama.cpp',
  List<ModelCompanion> companions = const <ModelCompanion>[],
  String? blockedReason,
}) =>
    OnDeviceModel(
      id: 'm',
      family: 'm',
      name: '测试模型',
      kind: 'text',
      engine: engine,
      format: 'gguf',
      fileName: 'm.gguf',
      bytes: bytes,
      quant: 'Q4',
      license: 'Apache-2.0',
      minRamGb: minRamGb,
      sources: const <ModelSource>[],
      companions: companions,
      blockedReason: blockedReason,
    );

void main() {
  group('按配置预估匹配度', () {
    test('引擎没随包 → 无法运行（图形/视频现在就是这一档）', () {
      final r = estimateFit(
        model: _model(engine: 'stable-diffusion.cpp'),
        profile: const DeviceProfile(ramGb: 12),
        engineBundled: false,
      );
      expect(r.fit, ModelFit.unsupported);
      expect(r.reason, contains('未随包'));
      expect(r.reason, contains('stable-diffusion.cpp'));
      expect(r.measured, isFalse);
    });

    test('内存不够 → 无法运行，且理由里有具体数字', () {
      final r = estimateFit(
        model: _model(minRamGb: 8),
        profile: const DeviceProfile(ramGb: 4),
        engineBundled: true,
      );
      expect(r.fit, ModelFit.unsupported);
      expect(r.reason, contains('4 GB'));
      expect(r.reason, contains('8 GB'));
    });

    test('内存读不到 → 不给绿灯（保守给"勉强"）', () {
      final r = estimateFit(
        model: _model(minRamGb: 4),
        profile: const DeviceProfile(ramGb: 0),
        engineBundled: true,
      );
      expect(r.fit, ModelFit.barely);
      expect(r.reason, contains('读不到'));
    });

    test('余量不足 2 GB → 勉强运行', () {
      final r = estimateFit(
        model: _model(minRamGb: 6),
        profile: const DeviceProfile(ramGb: 7), // 余量 1 GB
        engineBundled: true,
      );
      expect(r.fit, ModelFit.barely);
      expect(r.reason, contains('余量不足'));
    });

    test('余量刚好 2 GB → 流畅运行（边界）', () {
      final r = estimateFit(
        model: _model(minRamGb: 6),
        profile: const DeviceProfile(ramGb: 8),
        engineBundled: true,
      );
      expect(r.fit, ModelFit.smooth);
    });

    test('内存够但文件 2 GB+ 且是 8 GB 机 → 降一档', () {
      final r = estimateFit(
        model: _model(minRamGb: 6, bytes: 2200000000), // 2.2e9 > 2 GiB 阈值
        profile: const DeviceProfile(ramGb: 8),
        engineBundled: true,
      );
      expect(r.fit, ModelFit.barely);
      expect(r.reason, contains('文件偏大'));
    });

    test('12 GB 机上 2 GB+ 的文件不再降档（余量足够）', () {
      final r = estimateFit(
        model: _model(minRamGb: 6, bytes: 2200000000),
        profile: const DeviceProfile(ramGb: 12),
        engineBundled: true,
      );
      expect(r.fit, ModelFit.smooth);
    });
  });

  group('按实测速度判档', () {
    test('< 5 tok/s → 无法运行（红色），理由带实测数', () {
      final r = fitFromMeasurement(tokensPerSecond: 3.2, promptMs: 900);
      expect(r.fit, ModelFit.unsupported);
      expect(r.reason, contains('3.2 tok/s'));
      expect(r.measured, isTrue);
    });

    test('5–10 tok/s → 勉强运行', () {
      final r = fitFromMeasurement(tokensPerSecond: 7.5, promptMs: 300);
      expect(r.fit, ModelFit.barely);
      expect(r.reason, contains('7.5 tok/s'));
    });

    test('≥ 10 tok/s → 流畅运行', () {
      final r = fitFromMeasurement(tokensPerSecond: 18.0, promptMs: 120);
      expect(r.fit, ModelFit.smooth);
      expect(r.reason, contains('首字'));
    });

    test('边界：正好 5 与正好 10 分别落在"勉强"与"流畅"', () {
      expect(fitFromMeasurement(tokensPerSecond: 5.0, promptMs: 0).fit,
          ModelFit.barely);
      expect(fitFromMeasurement(tokensPerSecond: 10.0, promptMs: 0).fit,
          ModelFit.smooth);
    });
  });

  group('实测记录落盘', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('dsh-fit-'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('存了能读回来（跨实例，模拟重启）', () async {
      final a = BenchStore(dir: tmp.path);
      await a.save(BenchRecord(
        modelId: 'qwen2.5-1.5b',
        tokensPerSecond: 12.3,
        promptMs: 210,
        at: DateTime(2026, 10, 6, 22, 30),
      ));
      final b = BenchStore(dir: tmp.path);
      final rec = (await b.load(refresh: true))['qwen2.5-1.5b']!;
      expect(rec.tokensPerSecond, 12.3);
      expect(rec.promptMs, 210);
      expect(rec.at.year, 2026);
    });

    test('文件坏了当作空表，不炸', () async {
      File('${tmp.path}/bench.json').writeAsStringSync('{不是 JSON');
      expect(await BenchStore(dir: tmp.path).load(refresh: true), isEmpty);
    });

    test('记录能直接喂给判档函数', () async {
      final store = BenchStore(dir: tmp.path);
      await store.save(BenchRecord(
        modelId: 'm',
        tokensPerSecond: 4.0,
        promptMs: 500,
        at: DateTime.now(),
      ));
      final rec = (await store.load())['m']!;
      final fit = fitFromMeasurement(
          tokensPerSecond: rec.tokensPerSecond, promptMs: rec.promptMs);
      expect(fit.fit, ModelFit.unsupported);
      expect(fit.measured, isTrue);
    });
  });
  test('本体不大但伴生文件很大 → 按总大小降档（多模态的实际占用）', () {
    final r = estimateFit(
      model: _model(
        minRamGb: 6,
        bytes: 1200000000, // 本体 1.2 GB：单独看不算大
        companions: <ModelCompanion>[
          const ModelCompanion(
            fileName: 'mmproj.gguf',
            bytes: 1200000000, // + 1.2 GB → 总计 2.4 GB > 2 GiB
            sources: <ModelSource>[],
          ),
        ],
      ),
      profile: const DeviceProfile(ramGb: 8),
      engineBundled: true,
    );
    expect(r.fit, ModelFit.barely);
    expect(r.reason, contains('文件偏大'));
  });
  test('有已知缺口（blockedReason）→ 直接如实说，不给绿', () {
    final r = estimateFit(
      model: _model(
        minRamGb: 4,
        engine: 'stable-diffusion.cpp',
        blockedReason: '还需要 VAE（2.4 GB）与 T5 文本编码器',
      ),
      profile: const DeviceProfile(ramGb: 12), // 内存明明很够
      engineBundled: true, // 引擎也随包了
    );
    expect(r.fit, ModelFit.unsupported, reason: '引擎有、内存够，但还缺外部文件 → 不能算绿');
    expect(r.reason, contains('VAE'));
    expect(r.reason, contains('需要内存'), reason: '内存信息不能被缺口短路掉');
  });

  test('缺口说明为空字符串时不生效（等于没写）', () {
    final r = estimateFit(
      model: _model(blockedReason: '   '),
      profile: const DeviceProfile(ramGb: 12),
      engineBundled: true,
    );
    expect(r.fit, ModelFit.smooth);
  });
}
