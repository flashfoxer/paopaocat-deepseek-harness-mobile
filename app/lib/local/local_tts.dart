import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// 本机离线配音：**sherpa-onnx（Apache-2.0）+ 中文 VITS 模型**。
///
/// ## 为什么有这一层（2026-10-13，用户要求「B 方案」）
///
/// 用户的手机（nubia NX809J / Android 16）**一个 TTS 引擎都没有** ——
/// `android.speech.tts.TextToSpeech` 在那台机器上根本起不来，
/// 于是口播/短剧的配音「完全无法使用」。云端（MiMo / MiniMax）要 Key，
/// 而「本机能出声」这件事只有自己带引擎才能保证。
///
/// ## 选型与实测（不是拍脑袋，数字都在 `docs/本机离线配音-验证.md`）
///
/// * 引擎：**sherpa-onnx** —— Apache-2.0，官方提供 Android 预编译库
///   （pub 包 `sherpa_onnx` + 按 ABI 拆分的 `sherpa_onnx_android_arm64`），
///   **不用自己写 JNI**；arm64 三个 .so 合计 25.93 MB（其中 onnxruntime 21.22）。
/// * 模型：**vits-icefall-zh-aishell3**（就是 sherpa-onnx 官方 Android TTS 示例
///   用的那个中文 int8 多说话人模型）：`model.onnx` 29.07 MB + 词典与 tokens 等，
///   **必需文件合计 31.24 MB**。
/// * **172 MB 的 `rule.far` 刻意不装**：实测带它反而把带数字的句子读得**更短**
///   （6.5s vs 13.3s）而且加载慢 3 倍；数字/日期的读法由 4 个小 fst
///   （合计约 0.2 MB）负责，效果更好。
/// * 实时率：x86 桌面 2 线程约 17–20×（10 秒中文约 0.5 秒）、模型加载 0.38–0.49s。
///   **手机上的实际速度未实测**，真机要自己量。
///
/// ## 用法
///
/// ```dart
/// final tts = LocalTts(filesDir);
/// if (!tts.installed) { /* 提示先下载模型 */ }
/// await tts.synthesizeToWav(text: '你好', outPath: '/abs/out.wav');
/// ```
///
/// **引擎是常驻的**（第一次构造时加载，之后一直复用）—— 每句都新建会让每句都
/// 多花 0.4–0.5 秒。应用退到后台/退出由系统回收，这里只提供 [dispose]。
class LocalTts {
  LocalTts(this.filesDir);

  /// 应用私有目录（与 media / workspaces 同级，见 `DshHost.getPaths()` 的 filesDir）。
  final String filesDir;

  // ────────────────────────────────────────── 模型身份（改模型只改这里）

  /// 模型目录名（同时决定下载 URL 与落盘目录）。
  static const String modelId = 'vits-icefall-zh-aishell3';

  /// **必需**文件：缺任何一个都不能工作。
  static const List<String> requiredFiles = <String>[
    'model.onnx',
    'lexicon.txt',
    'tokens.txt',
  ];

  /// 可选的小规则 fst：用来把数字/日期读成汉字（**推荐装**，合计约 0.2 MB）。
  static const List<String> ruleFstFiles = <String>[
    'date.fst',
    'number.fst',
    'phone.fst',
    'new_heteronym.fst',
  ];

  /// 解包时**跳过**的文件名（见 [TtsModelInstaller]）。
  ///
  /// `rule.far` 172 MB，而实测**对我们没用**：带它反而把带数字的句子读得**更短**
  /// （6.5s vs 13.3s）、引擎加载还慢 3 倍（数字/日期的读法由 [ruleFstFiles]
  /// 那 4 个小 fst 负责）。不跳过的话解包峰值占用 204 MB，跳过只有 32 MB。
  static const List<String> skipFiles = <String>['rule.far'];

  /// 说话人表（174 个数据集说话人，**行号即 sid**）。
  static const String speakersFile = 'speakers.txt';

  /// 官方发布包（sherpa-onnx 的 GitHub 发布资源）。
  ///
  /// ⚠️ 实测记录：`github.com` 的网页在本机**打不开**，但**发布资源能下**
  /// （走 `release-assets.githubusercontent.com`）。如果用户网络下不动，
  /// 界面上要给"手动放进来"的路子（见 [installed] 的说明）。
  static const String downloadUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/$modelId.tar.bz2';

  /// 发布包大小（实测 31,559,701 字节）—— 用来显示进度、以及**判断下载完整性**。
  static const int downloadBytes = 31559701;

  /// 发布包 sha256（本机实测，2026-10-13）。下完先核对它，再解包 ——
  /// 一个 31 MB 的文件半途断掉是很常见的事，而**解出来的模型坏没坏很难发现**
  /// （可能只是某几个音发错，用户根本归因不了）。
  static const String downloadSha256 =
      'ab468db3a3308cdd861495e0db2f25d79418a0c00639f74944c7cdf5dd8c6ec1';

  // ────────────────────────────────────────── 路径

  /// 模型目录：`<filesDir>/tts/<modelId>`。
  String get modelDir => '$filesDir/tts/$modelId';

  String filePath(String name) => '$modelDir/$name';

  /// 缺哪些文件（空 = 装好了）。
  ///
  /// 手动安装的路子：把发布包解开，把这几个文件放进 [modelDir] 即可
  /// （界面上会把绝对路径显示出来，方便他照抄）。
  List<String> get missingFiles => <String>[
        for (final f in requiredFiles)
          if (!File(filePath(f)).existsSync()) f,
      ];

  /// 模型是否可用（必需文件齐）。
  bool get installed => missingFiles.isEmpty;

  /// 规则 fst 是否齐（不齐只是数字读法打折，不影响出声）。
  bool get hasRuleFsts =>
      ruleFstFiles.every((f) => File(filePath(f)).existsSync());

  // ────────────────────────────────────────── 引擎

  sherpa.OfflineTts? _engine;

  /// 取引擎（第一次调用会加载模型；之后复用）。
  sherpa.OfflineTts engine() {
    final cached = _engine;
    if (cached != null) return cached;
    final missing = missingFiles;
    if (missing.isNotEmpty) {
      throw LocalTtsException(
        LocalTtsError.notInstalled,
        '模型文件不齐，缺：${missing.join('、')}（目录 $modelDir）',
      );
    }
    final ruleFsts = <String>[
      for (final f in ruleFstFiles)
        if (File(filePath(f)).existsSync()) filePath(f),
    ].join(',');
    try {
      final built = sherpa.OfflineTts(
        sherpa.OfflineTtsConfig(
          model: sherpa.OfflineTtsModelConfig(
            vits: sherpa.OfflineTtsVitsModelConfig(
              model: filePath('model.onnx'),
              lexicon: filePath('lexicon.txt'),
              tokens: filePath('tokens.txt'),
            ),
            // 2 线程是"不抢手机"的折中：桌面实测 2 线程已到 17–20×，
            // 线程再多收益有限（4 线程只从 11.4× 提到 13.4×），
            // 而手机上多线程会和界面抢 CPU、还更费电。
            numThreads: 2,
            // 生产环境关掉引擎的逐句 debug 输出（否则每句都往诊断日志里灌）。
            debug: false,
            provider: 'cpu',
          ),
          ruleFsts: ruleFsts,
          maxNumSenetences: 1,
        ),
      );
      _engine = built;
      return built;
    } catch (e) {
      throw LocalTtsException(LocalTtsError.loadFailed, '离线配音引擎加载失败：$e');
    }
  }

  /// 合成一句话，**写成 WAV 文件**，返回该文件路径。
  ///
  /// [speed] 大于 1 更快（与 sherpa-onnx 的语义一致）。
  String synthesizeToWav({
    required String text,
    required String outPath,
    int sid = 0,
    double speed = 1.0,
  }) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw LocalTtsException(LocalTtsError.emptyText, '没有可配音的文本。');
    }
    final engine = this.engine();
    if (sid < 0 || (engine.numSpeakers > 0 && sid >= engine.numSpeakers)) {
      throw LocalTtsException(
        LocalTtsError.badSpeaker,
        '说话人编号超出范围：$sid（这个模型有 ${engine.numSpeakers} 个）',
      );
    }
    final sherpa.GeneratedAudio audio;
    try {
      audio = engine.generate(text: trimmed, sid: sid, speed: speed);
    } catch (e) {
      throw LocalTtsException(LocalTtsError.generateFailed, '离线合成失败：$e');
    }
    if (audio.samples.isEmpty) {
      throw LocalTtsException(LocalTtsError.generateFailed, '离线合成返回了空音频。');
    }
    final bytes = pcm16WavBytes(audio.samples, audio.sampleRate);
    final out = File(outPath);
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(bytes, flush: true);
    return outPath;
  }

  /// 说话人列表（`speakers.txt` 的**行号就是 sid**；空表就退化成"只有 0 号"）。
  ///
  /// ⚠️ 这些名字是 aishell3 数据集里的说话人编号（`SSB0005` 这种），
  /// **我们无法从中判断男女**——所以界面上不许编"女声/男声"，只能让用户试听。
  List<String> speakers() {
    final f = File(filePath(speakersFile));
    if (!f.existsSync()) return const <String>['0'];
    final lines = f
        .readAsLinesSync()
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return const <String>['0'];
    return lines;
  }

  /// 释放引擎（下次用会重新加载）。
  void dispose() {
    _engine = null;
  }
}

/// 离线配音的错误类型（界面按它给不同的提示，而不是把底层异常甩给用户）。
enum LocalTtsError {
  /// 模型文件不齐（要引导去下载/手动放进目录）。
  notInstalled,

  /// 引擎加载失败（库没编进去 / ABI 不匹配 / 文件损坏）。
  loadFailed,

  /// 合成失败。
  generateFailed,

  /// 空文本。
  emptyText,

  /// 说话人编号越界。
  badSpeaker,
}

class LocalTtsException implements Exception {
  LocalTtsException(this.error, this.message);
  final LocalTtsError error;
  final String message;
  @override
  String toString() => 'LocalTtsException(${error.name}): $message';
}

/// Float32 单声道采样 → **16-bit PCM WAV** 字节。
///
/// 为什么自己写：`package:sherpa_onnx` 只在 web 侧有个 `writeWave` 占位
/// （非 web 平台直接 `UnsupportedError`），而我们要的正好是"写成一个
/// ffmpeg 能吃、用户也能双击播放"的文件。
///
/// 格式：44 字节标准头（RIFF/WAVE/fmt 16/data），单声道、16 位、[sampleRate]。
/// 采样值按 [-1, 1] 截断后转 int16 —— **不截断会回绕**（1.2 → 一个大负数），
/// 听感上是刺耳的爆音，这种 bug 很难归因。
Uint8List pcm16WavBytes(Float32List samples, int sampleRate) {
  final dataBytes = samples.length * 2;
  final out = ByteData(44 + dataBytes);

  void writeAscii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      out.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  writeAscii(0, 'RIFF');
  out.setUint32(4, 36 + dataBytes, Endian.little); // 除 'RIFF'+size 之外的字节数
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  out.setUint32(16, 16, Endian.little); // fmt 块长度
  out.setUint16(20, 1, Endian.little); // PCM
  out.setUint16(22, 1, Endian.little); // 单声道
  out.setUint32(24, sampleRate, Endian.little);
  out.setUint32(28, sampleRate * 2, Endian.little); // 字节率 = 采样率×声道×位深/8
  out.setUint16(32, 2, Endian.little); // 块对齐
  out.setUint16(34, 16, Endian.little); // 位深
  writeAscii(36, 'data');
  out.setUint32(40, dataBytes, Endian.little);

  var pos = 44;
  for (final s in samples) {
    final clamped = s.isNaN ? 0.0 : s.clamp(-1.0, 1.0).toDouble();
    // 32767 而不是 32768：避免 1.0 转成 32768 溢出成 -32768。
    out.setInt16(pos, (clamped * 32767).round(), Endian.little);
    pos += 2;
  }
  return out.buffer.asUint8List();
}
