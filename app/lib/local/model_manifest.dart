/// 随包的**模型清单**：端侧可下载模型的唯一数据源。
///
/// ## 为什么要清单，而不是硬编码 URL
///
/// 1. **多源**：同一个模型文件在不同站点速度差 10 倍以上（实测 ModelScope 4.66 MB/s
///    vs hf-mirror 377 KB/s）。硬编码一个地址意味着那个站一挂、全体用户下载失败。
/// 2. **机型匹配**：Gemma 4 这类模型是按 SoC 分发的（`_qualcomm_sm8750`、`_Google_Tensor_G6`、
///    通用 `-gpu` 版）。同一份清单要能表达"这台机器该下哪个文件"。
/// 3. **可校验**：字节数与 sha256 写在清单里，下载完才允许加载 —— 否则一个半截文件
///    会让推理引擎崩在莫名其妙的地方。
///
/// 数据文件：`assets/models/model_manifest.json`。sha256 由
/// `install/models/refresh-manifest.mjs` 从真实源站抓取后回填。
///
/// ## ⚠️ 命名纪律（踩过）
///
/// 本项目里 `data/model_catalog.dart` 已有 `ModelEntry`、`state/model_store.dart`
/// 已有 `ModelStore`（都是"DSH 的模型配置"）。所以本模块一律用端侧专用名：
/// `OnDeviceModel` / `OnDeviceManifest` / `LocalModelStore` ——
/// 同名类一旦被同一个文件同时 import，就是一条 ambiguous import 编译错误，
/// 而且错在 import 处、与真正改动的文件无关，很难指认。
library;

import 'dart:convert';

/// 一条下载源。
///
/// `priority` 越小越优先（0 = 主源）。**它只是"起跑顺序"**，真正选谁由
/// [ModelDownloader] 现场测速决定 —— 网络状况会变，写死在清单里没有意义。
class ModelSource {
  const ModelSource({
    required this.label,
    required this.url,
    this.priority = 0,
  });

  final String label;
  final String url;
  final int priority;

  factory ModelSource.fromJson(Map<String, dynamic> json) => ModelSource(
        label: (json['label'] as String?) ?? json['url'] as String,
        url: json['url'] as String,
        priority: (json['priority'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'label': label,
        'url': url,
        'priority': priority,
      };
}

/// 这台机器的画像（RAM / SoC / ABI）—— 用来从清单里挑"该下哪个"。
///
/// ⚠️ 现有 `DshHost.deviceInfo()` **缺总内存与 SoC 型号**（只有 SDK 版本等）。
/// 所以这里刻意做成纯函数：调用方把两个数传进来，缺失时按最保守的档处理
/// （`ramGb: 0` 会导致所有条目都不可用，提示用户手动指定）。
class DeviceProfile {
  const DeviceProfile({
    required this.ramGb,
    this.soc = '',
    this.abi = 'arm64-v8a',
  });

  /// 设备物理内存总量（GB）。**不是**"可用内存"。
  final int ramGb;

  /// SoC 型号（如 `SM8750`、`Google Tensor G6`）。空串 = 未知。
  final String soc;

  /// 目前只发 arm64-v8a。
  final String abi;

  /// 从宿主给的 `deviceInfo()` 结果构造画像。
  ///
  /// 为什么要这一步：内存总量与芯片型号是**平台给的**，而"该下哪个文件"是**清单说了算**。
  /// 中间用一个纯函数把两者接起来，是为了能在测试里直接构造各种设备形态
  /// （4GB 千元机 / 8GB 骁龙 / Pixel），而不必真的插一台设备。
  ///
  /// 缺字段时**保守处理**：内存读不到给 0（清单会一条都不匹配 → UI 提示用户手动指定），
  /// 绝不给一个"看起来合理"的默认值 —— 猜错内存会让用户下到跑不动的模型。
  factory DeviceProfile.fromDeviceInfo(Map<String, dynamic> info) {
    final ram = (info['totalRamGb'] as num?)?.toInt() ?? 0;
    final soc = <String>[
      if ((info['soc'] as String?)?.trim().isNotEmpty ?? false)
        info['soc'] as String,
      // 机型名兜底：有些 ROM 的机型串里带芯片信息（如 "SM-S9280"）。
      if ((info['model'] as String?)?.trim().isNotEmpty ?? false)
        info['model'] as String,
    ].join(' ');
    final abis = (info['abis'] as List?)
            ?.map((e) => e.toString())
            .toList(growable: false) ??
        const <String>[];
    final abi = abis.contains('arm64-v8a')
        ? 'arm64-v8a'
        : (abis.isNotEmpty ? abis.first : 'arm64-v8a');
    return DeviceProfile(ramGb: ram, soc: soc, abi: abi);
  }

  /// 归一化：小写 + 去掉空格/横杠/下划线，便于"snapdragon 8 elite" 这类写法互相匹配。
  static String normalize(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[\s\-_]+'), '');

  @override
  String toString() => 'DeviceProfile(ram=${ramGb}GB, soc=$soc, abi=$abi)';
}

/// 清单里的一条模型。
/// 伴生文件（mmproj 视觉编码器）——见 [OnDeviceModel.companions]。
class ModelCompanion {
  const ModelCompanion({
    required this.fileName,
    required this.bytes,
    required this.sources,
    this.sha256,
  });

  final String fileName;
  final int bytes;
  final List<ModelSource> sources;
  final String? sha256;

  /// 与 [OnDeviceModel.sortedSources] 同样的语义：按 priority 排（选源时用）。
  /// ⚠️ 解析时不排序、**用到时才排** —— 解析顺序保持文件原样，便于对比清单。
  List<ModelSource> get sortedSources => List<ModelSource>.from(sources)
    ..sort((a, b) => a.priority.compareTo(b.priority));

  factory ModelCompanion.fromJson(Map<String, dynamic> j) => ModelCompanion(
        fileName: (j['fileName'] as String?) ?? '',
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        sha256: (j['sha256'] as String?)?.trim(),
        sources: ((j['sources'] as List?) ?? const <dynamic>[])
            .map((e) =>
                ModelSource.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(growable: false),
      );
}

class OnDeviceModel {
  const OnDeviceModel({
    required this.id,
    required this.family,
    required this.name,
    required this.kind,
    required this.engine,
    required this.format,
    required this.fileName,
    required this.bytes,
    required this.quant,
    required this.license,
    required this.minRamGb,
    required this.sources,
    this.sha256,
    this.socMatch = const <String>[],
    this.abi = 'arm64-v8a',
    this.note,
    this.companions = const <ModelCompanion>[],
    this.blockedReason,
    this.kvTokens = 0,
  });

  /// 清单内唯一 id。
  final String id;

  /// 同一模型的不同机型/量化版本共享一个 family —— `bestFor()` 按它分组择优。
  final String family;

  final String name;

  /// `text` / `vision` / `image` / `video`。
  final String kind;

  /// `litert-lm`（本 App 目前**只有它随包**）/ `llama.cpp`（0.47 起不随包）/
  /// `stable-diffusion.cpp`（2026-10-11 已删除）。解析层仍然容忍这三种取值。
  final String engine;

  /// `gguf` / `litertlm` / `safetensors` / `pth`。
  final String format;

  final String fileName;

  /// 精确字节数（来自源站 API，不是估算）。下载后必须一致。
  final int bytes;

  /// **伴生文件**：多模态模型的"眼睛"。
  ///
  /// 多模态光有本体不懂图 —— 视觉编码器（mmproj，llama.cpp 的说法）是**单独一个
  /// 文件**，启动时必须用 `--mmproj` 指着它。所以清单里一个多模态条目其实是
  /// "本体 + 编码器"两个文件，下载要一起下、校验要一起校验。
  final List<ModelCompanion> companions;

  /// **还差东西才能跑**的说明（清单里写死的已知缺口）。
  ///
  /// 为什么要有这个字段：引擎补上了、内存也够，模型却因为**还缺 VAE / T5 文本编码器**
  /// 这类外部文件跑不起来。没有这个字段，它就会被判成"绿"——那是在骗用户。
  /// 有了它，提示框会如实写清"还缺什么、多大"。
  final String? blockedReason;

  /// **这个模型文件物理上能装下多少 token**（KV cache 的格数）。0 = 清单没写（按用户的档位来）。
  ///
  /// 为什么必须有这个字段（真机 2026-10-09 抓到）：
  /// LiteRT-LM 的会话状态容量由**模型文件自己**决定，**不是启动参数说了算**。
  /// 真机日志：`Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm`（文件名里的
  /// `ekv4096` = 只有 4096 格）被按 `maxNumTokens=16384` 启动 → 两轮就把缓存吃到
  /// 3920/4096 → 第三轮报
  /// `Status Code: 9 · Prefill input length exceeds available state entries
  /// (remaining capacity: 176)`，整轮失败。
  ///
  /// 更早的坑是它的**镜像**：overlay 里 `contextWindow` 写得比引擎能装的**小** →
  /// DSH 把 maxTokens clamp 成 1 → 空回复（见 local_model_spec.dart 的注释）。
  /// 所以两边必须用**同一个数**：引擎的 `maxNumTokens` 与 overlay 的 `contextWindow`
  /// 都取 `min(用户档位, kvTokens)`。
  final int kvTokens;

  /// 本体 + 所有伴生文件的总字节数（判断"文件偏大"要用总大小，不是本体）。
  int get totalBytes => bytes + companions.fold<int>(0, (a, c) => a + c.bytes);

  final String quant;

  /// 许可标识（如 `Apache-2.0`、`Gemma Terms`）。UI 上要如实展示。
  final String license;

  /// 最低要求的内存档（GB）。
  final int minRamGb;

  /// 机型专属匹配串（归一化后做子串匹配）；**空 = 通用版**。
  final List<String> socMatch;

  final String abi;
  final String? sha256;
  final String? note;

  final List<ModelSource> sources;

  bool get isUniversal => socMatch.isEmpty;

  /// sha256 缺失时不能在发布版里放行（见 [OnDeviceManifest.requireHash]）。
  bool get hasHash => (sha256 ?? '').isNotEmpty;

  bool fitsRam(int ramGb) => ramGb >= minRamGb;

  /// 这台设备的 SoC 是否命中专属列表。
  bool matchesSoc(String soc) {
    if (isUniversal) return false;
    final n = DeviceProfile.normalize(soc);
    if (n.isEmpty) return false;
    return socMatch
        .map(DeviceProfile.normalize)
        .any((p) => p.isNotEmpty && n.contains(p));
  }

  /// 按 priority 排序后的源副本。
  List<ModelSource> get sortedSources => List<ModelSource>.from(sources)
    ..sort((a, b) => a.priority.compareTo(b.priority));

  factory OnDeviceModel.fromJson(Map<String, dynamic> json) => OnDeviceModel(
        id: json['id'] as String,
        family: (json['family'] as String?) ?? json['id'] as String,
        name: json['name'] as String,
        kind: (json['kind'] as String?) ?? 'text',
        engine: (json['engine'] as String?) ?? 'llama.cpp',
        format: (json['format'] as String?) ?? 'gguf',
        fileName: json['fileName'] as String,
        bytes: (json['bytes'] as num?)?.toInt() ?? 0,
        quant: (json['quant'] as String?) ?? '',
        license: (json['license'] as String?) ?? 'unknown',
        minRamGb: (json['minRamGb'] as num?)?.toInt() ?? 4,
        socMatch: ((json['socMatch'] as List?) ?? const <dynamic>[])
            .map((e) => e.toString())
            .toList(growable: false),
        abi: (json['abi'] as String?) ?? 'arm64-v8a',
        sha256: (json['sha256'] as String?)?.trim(),
        note: json['note'] as String?,
        blockedReason: (json['blockedReason'] as String?)?.trim(),
        kvTokens: (json['kvTokens'] as num?)?.toInt() ?? 0,
        sources: ((json['sources'] as List?) ?? const <dynamic>[])
            .map((e) =>
                ModelSource.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(growable: false),
        companions: ((json['companions'] as List?) ?? const <dynamic>[])
            .map((e) =>
                ModelCompanion.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(growable: false),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'family': family,
        'name': name,
        'kind': kind,
        'engine': engine,
        'format': format,
        'fileName': fileName,
        'bytes': bytes,
        'quant': quant,
        'license': license,
        'minRamGb': minRamGb,
        'socMatch': socMatch,
        'abi': abi,
        'sha256': sha256,
        if (kvTokens > 0) 'kvTokens': kvTokens,
        if (note != null) 'note': note,
        'sources': sources.map((s) => s.toJson()).toList(),
      };
}

/// 解析后的清单。
class OnDeviceManifest {
  const OnDeviceManifest({
    required this.version,
    required this.models,
    this.updatedAt = '',
    this.requireHash = false,
  });

  final int version;
  final String updatedAt;

  /// 发布版置 true：没有 sha256 的条目**不允许下载**（宁可提示"清单待更新"，
  /// 也不让用户装进一个无法校验的模型）。
  final bool requireHash;

  final List<OnDeviceModel> models;

  static const OnDeviceManifest empty =
      OnDeviceManifest(version: 0, models: <OnDeviceModel>[]);

  static OnDeviceManifest parse(String text) {
    final raw = jsonDecode(text);
    if (raw is! Map) {
      throw const FormatException('模型清单根节点必须是对象');
    }
    final json = Map<String, dynamic>.from(raw);
    final list = (json['models'] as List?) ?? const <dynamic>[];
    return OnDeviceManifest(
      version: (json['version'] as num?)?.toInt() ?? 0,
      updatedAt: (json['updatedAt'] as String?) ?? '',
      requireHash: json['requireHash'] == true,
      models: list
          .map((e) =>
              OnDeviceModel.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(growable: false),
    );
  }

  OnDeviceModel? byId(String id) {
    for (final m in models) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// 这台设备**能装**的条目（内存够 + 机型对得上）。
  ///
  /// 专属版与通用版会同时出现 —— 怎么挑由 [bestFor] 决定，这里只做过滤。
  List<OnDeviceModel> availableFor(DeviceProfile p) => models
      .where((m) =>
          m.abi == p.abi &&
          m.fitsRam(p.ramGb) &&
          (m.isUniversal || m.matchesSoc(p.soc)))
      .toList(growable: false);

  /// 同一 family 里给这台机器挑最合适的一条。
  ///
  /// 优先级：**机型专属命中 > 通用版**；同为专属或同为通用时，**取文件最小的**
  /// （先保证装得下、下得动，再谈性能）。
  OnDeviceModel? bestFor(String family, DeviceProfile p) {
    final candidates =
        availableFor(p).where((m) => m.family == family).toList();
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final sa = a.matchesSoc(p.soc) ? 0 : 1;
      final sb = b.matchesSoc(p.soc) ? 0 : 1;
      if (sa != sb) return sa.compareTo(sb);
      return a.bytes.compareTo(b.bytes);
    });
    return candidates.first;
  }

  /// 清单里出现过的 family（去重，保持出现顺序）——UI 列表用。
  List<String> get families {
    final seen = <String>{};
    final out = <String>[];
    for (final m in models) {
      if (seen.add(m.family)) out.add(m.family);
    }
    return out;
  }
}
