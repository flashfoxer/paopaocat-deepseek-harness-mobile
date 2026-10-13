import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../i18n/dsh_i18n.dart' show tr;
import 'agnes_builtin.dart';
import 'atomic_file.dart';

/// 「影视」页用的**图像 / 视频模型**清单：读写 `<filesDir>/media-models.json`。
///
/// ## 为什么和 `models.json`（会话模型）分开（2026-10-11 用户提的设计问题）
///
/// 用户原话：「模型页是否增加一个图形和视频的设置页，用户设置好后可以在影视工具里
/// 选择图形和视频大模型」。
///
/// 这两类模型在**生命周期上就不一样**：
///   * 会话模型必须走 `/chat/completions`，会被写进 DSH 的 overlay，住在会话的模型面板里；
///   * 图像/视频模型走的是 `/images/generations` 与 `/videos`，**永远不该出现在会话里**
///     （用户早先明确要求过：内置端口"不需要显示出来"；真选了它也聊不了天）。
///
/// 所以刻意**分文件、分清单、分选择**：会话那条路一个字节都不用改，
/// 也就不存在"图像模型漏进会话面板"这种事故。
class MediaModelSpec {
  const MediaModelSpec({
    required this.provider,
    required this.id,
    required this.baseUrl,
    this.label,
    this.apiKeyEnv,
    this.kind = 'image',
    this.builtin = false,
  });

  /// 厂家 id（也是 `ProviderKeys` 里读 Key 用的 id）：内置的是 `agnes`。
  final String provider;

  /// 发给上游的模型名（如 `agnes-image-2.5-flash`）。
  final String id;

  /// OpenAI 兼容的端点根（`.../v1`）。图像走 `{baseUrl}/images/generations`。
  final String baseUrl;

  /// 界面上显示的名字（空则显示 id）。
  final String? label;

  /// 凭据环境变量名（**不是** Key 本身）。运行时按这里的名字注入。
  final String? apiKeyEnv;

  /// `image` | `video`。
  final String kind;

  /// 是不是 App 内置的那两条（Agnes 官方免费档）。内置项**只能选、不能删**。
  final bool builtin;

  String get route => '$provider/$id';
  String get displayName =>
      (label != null && label!.trim().isNotEmpty) ? label!.trim() : id;
  bool get isImage => kind == 'image';
  bool get isVideo => kind == 'video';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'provider': provider,
        'id': id,
        'baseUrl': baseUrl,
        'kind': kind,
        if ((label ?? '').trim().isNotEmpty) 'label': label!.trim(),
        if ((apiKeyEnv ?? '').trim().isNotEmpty) 'apiKeyEnv': apiKeyEnv!.trim(),
      };

  static MediaModelSpec? fromJson(Object? raw, {String fallbackKind = 'image'}) {
    if (raw is! Map) return null;
    final provider = '${raw['provider'] ?? ''}'.trim();
    final id = '${raw['id'] ?? ''}'.trim();
    final baseUrl = '${raw['baseUrl'] ?? ''}'.trim();
    if (provider.isEmpty || id.isEmpty) return null;
    final kind = '${raw['kind'] ?? fallbackKind}'.trim();
    return MediaModelSpec(
      provider: provider,
      id: id,
      baseUrl: baseUrl.isEmpty ? AgnesBuiltin.baseUrl : baseUrl,
      label: '${raw['label'] ?? ''}'.trim(),
      apiKeyEnv: '${raw['apiKeyEnv'] ?? ''}'.trim(),
      kind: (kind == 'video') ? 'video' : 'image',
    );
  }
}

/// `media-models.json` 的内容。
class MediaModelConfig {
  const MediaModelConfig({
    this.custom = const <MediaModelSpec>[],
    this.selectedImage,
    this.selectedVideo,
  });

  /// **用户自己加的**（不含内置）。内置两条由 [MediaModels.builtins] 现算。
  final List<MediaModelSpec> custom;

  /// 选中的 route（`agnes/agnes-image-2.5-flash`）。null = 用内置默认。
  final String? selectedImage;
  final String? selectedVideo;

  MediaModelConfig copyWith({
    List<MediaModelSpec>? custom,
    String? selectedImage,
    String? selectedVideo,
    bool clearImage = false,
    bool clearVideo = false,
  }) =>
      MediaModelConfig(
        custom: custom ?? this.custom,
        selectedImage: clearImage ? null : (selectedImage ?? this.selectedImage),
        selectedVideo: clearVideo ? null : (selectedVideo ?? this.selectedVideo),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': 1,
        'custom': <Map<String, dynamic>>[for (final m in custom) m.toJson()],
        if ((selectedImage ?? '').isNotEmpty) 'selectedImage': selectedImage,
        if ((selectedVideo ?? '').isNotEmpty) 'selectedVideo': selectedVideo,
      };
}

/// 静态入口：读 / 写 / 取候选 / 取选中。
class MediaModels {
  MediaModels._();

  /// 内置厂家 id（Agnes）。
  static const String builtinProvider = AgnesBuiltin.providerId;

  /// 内置的两条：Agnes 的图像与视频模型（官方免费档，见 [AgnesBuiltin]）。
  ///
  /// 它们**永远在候选里**（用户删不掉）—— 否则新用户第一次进影视页会发现
  /// "一个模型都没有"，而他其实什么都没配错。
  static List<MediaModelSpec> builtins() => const <MediaModelSpec>[
        MediaModelSpec(
          provider: builtinProvider,
          id: AgnesBuiltin.imageModel,
          baseUrl: AgnesBuiltin.baseUrl,
          label: '${AgnesBuiltin.imageModel}（内置·免费）',
          apiKeyEnv: 'AGNES_API_KEY',
          kind: 'image',
          builtin: true,
        ),
        MediaModelSpec(
          provider: builtinProvider,
          id: AgnesBuiltin.videoModel,
          baseUrl: AgnesBuiltin.baseUrl,
          label: '${AgnesBuiltin.videoModel}（内置·免费）',
          apiKeyEnv: 'AGNES_API_KEY',
          kind: 'video',
          builtin: true,
        ),
      ];

  /// **外部厂商的端点预设**（用户 2026-10-11：「视频和图形大模型是可以添加外部厂商，
  /// 这样吧直接内置外边厂商的端点」）。
  ///
  /// ## 这里只内置**端点**，模型名给"建议值"让用户改
  ///
  /// 端点是稳定的（各家文档里的 OpenAI 兼容入口），模型名会随厂商上下架 ——
  /// 所以预设里带一个建议模型名（表单里预填、可改），而不是硬写死。
  ///
  /// ## ⚠️ 必须如实标注的一点（2026-10-11 用户纠正后改过）
  ///
  /// 请求形状**按各家文档写**（`assets/toolbox/media-vendors.mjs` 是唯一来源：
  /// Agnes 用 `size` 档位 + `extra_body`，OpenAI 兼容那几家用像素 `size`，
  /// 万相是星号尺寸 + 异步任务，MiniMax 图像吃 `aspect_ratio`…）。
  /// 但本机**没有这些厂家的 Key、也没有安卓真机** —— 所以这些预设是
  /// "**端点内置好了，能不能通要试**"，失败会把上游原话显示出来。
  /// 绝不能在界面上写成"选好就能用"。
  ///
  /// 「这家能接受哪些档位」在 [MediaVendors]（界面据此渲染选项）。
  static const List<({String vendor, String provider, String baseUrl, String model, String note})>
      externalPresets = <({String vendor, String provider, String baseUrl, String model, String note})>[
    (
      vendor: 'OpenAI',
      provider: 'openai',
      baseUrl: 'https://api.openai.com/v1',
      model: 'gpt-image-1',
      note: 'size 要用 1024x1024 这类像素值，不是 1K/2K',
    ),
    (
      vendor: '智谱 GLM',
      provider: 'zhipu',
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      model: 'cogview-4',
      note: '端点与其他厂商不同（/paas/v4）',
    ),
    (
      vendor: '通义万相（阿里云）',
      provider: 'dashscope',
      // ⚠️ 端点必须是**站点根**，不能填 `/compatible-mode/v1`。
      //    万相的生图/生视频**没有** OpenAI 兼容入口：走的是
      //    `/api/v1/services/aigc/text2image/image-synthesis` 这套异步协议。
      //    填成 compatible-mode 时拼出来是
      //    `.../compatible-mode/v1/api/v1/services/...` → 必然 404，
      //    而且看起来像"万相接不通"。（照着形状表逐条核对时改掉的。）
      baseUrl: 'https://dashscope.aliyuncs.com',
      model: 'wanx2.1-t2i-turbo',
      note: '万相走异步任务（不是 OpenAI 兼容入口），尺寸用 1024*1024 这种写法',
    ),
    (
      vendor: '豆包 Seedream（火山方舟）',
      provider: 'doubao',
      baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
      model: 'doubao-seedream-3-0-t2i-250415',
      note: '模型名要用控制台里的接入点/模型 id',
    ),
    (
      vendor: 'MiniMax',
      provider: 'minimax',
      // ⚠️ 国内站是 `api.minimax.cn`（`api.minimax.chat` 是国际站）——
      //    站点用错的表现是"Key 无效 / 404"，很难一眼看出。
      baseUrl: 'https://api.minimax.cn/v1',
      model: 'image-01',
      note: '图像用 aspect_ratio，不用 size',
    ),
    (
      vendor: '硅基流动 SiliconFlow',
      provider: 'siliconflow',
      baseUrl: 'https://api.siliconflow.cn/v1',
      model: 'Kwai-Kolors/Kolors',
      note: '聚合平台，模型名照它站内的写',
    ),
  ];

  /// 图像预设的 note 登记表（测试用它核对"预设里出现的 note 都登记过"）。
  ///
  /// 为什么要登记：这些 note 是**数据表里的字面量**，界面用
  /// `context.tr(presetNote)` 显示，而 i18n 扫描器只认源码里 `tr('字面量')`
  /// 这种写法 —— 写在 `const` 记录里的字符串它**看不见**，于是切英/日/韩时
  /// 这些说明会**还是中文**（不报错，只是"没翻"）。
  /// 见下面的 [_presetNoteAnchors]：那一段的唯一作用就是让扫描器看得到。
  static const List<String> presetNoteKeys = <String>[
    'size 要用 1024x1024 这类像素值，不是 1K/2K',
    '端点与其他厂商不同（/paas/v4）',
    '万相走异步任务（不是 OpenAI 兼容入口），尺寸用 1024*1024 这种写法',
    '模型名要用控制台里的接入点/模型 id',
    '图像用 aspect_ratio，不用 size',
    '聚合平台，模型名照它站内的写',
  ];

  /// ⚠️ **i18n 扫描器的锚点**（不要删）。
  ///
  /// 与 [presetNoteKeys]、以及上面 `externalPresets` 里各家 `note` 的文本
  /// **三处必须逐字一致**：改了 note 就要同步改这两处
  ///（`media_models_test.dart` 的「图像预设说明」会核对，
  ///  `node install/i18n/check-tables.mjs` 会报漂移）。
  // ignore: unused_element
  static void _presetNoteAnchors() {
    tr('size 要用 1024x1024 这类像素值，不是 1K/2K');
    tr('端点与其他厂商不同（/paas/v4）');
    tr('万相走异步任务（不是 OpenAI 兼容入口），尺寸用 1024*1024 这种写法');
    tr('模型名要用控制台里的接入点/模型 id');
    tr('图像用 aspect_ratio，不用 size');
    tr('聚合平台，模型名照它站内的写');
  }

  /// **外部厂商的视频预设**（2026-10-11：视频也有内置外部厂商了）。
  ///
  /// 这里删掉了 0.61 那句"视频没有内置外部厂商"—— 那句话现在已经不对了：
  /// 脚本侧 `media-vendors.mjs` 有 5 套视频形状（Agnes / 豆包 Seedance /
  /// MiniMax / 通义万相 DashScope / 硅基流动），界面按厂家换档位。
  ///
  /// 端点的出处是 `media-vendors.mjs` 的 `base`（**同一份，别各写一份**）：
  /// 万相 `https://dashscope.aliyuncs.com`（不是 compatible-mode）、
  /// MiniMax `https://api.minimax.cn/v1`（视频提交在 /v2，脚本自己换根）、
  /// 硅基流动 `https://api.siliconflow.cn/v1`、
  /// 豆包 `https://ark.cn-beijing.volces.com/api/v3`。
  ///
  /// 建议模型名只是**预填值**（可改）：
  ///   * 豆包 Seedance 要照控制台里的**接入点 id** 填（`doubao-seedance-1-0-pro`
  ///     是常见的接入点名，各家账号里不一定一样）；
  ///   * 万相是 `wan2.7-t2v`、MiniMax 是 `MiniMax-H3`、
  ///     硅基流动是 `Wan-AI/Wan2.2-T2V-A14B`。
  static const List<({String vendor, String provider, String baseUrl, String model, String note})>
      externalVideoPresets = <({String vendor, String provider, String baseUrl, String model, String note})>[
    (
      vendor: '豆包 Seedance（火山方舟）',
      provider: 'doubao',
      baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
      model: 'doubao-seedance-1-0-pro',
      note: '',
    ),
    (
      vendor: 'MiniMax',
      provider: 'minimax',
      baseUrl: 'https://api.minimax.cn/v1',
      model: 'MiniMax-H3',
      note: '',
    ),
    (
      vendor: '通义万相（阿里云百炼）',
      provider: 'dashscope',
      baseUrl: 'https://dashscope.aliyuncs.com',
      model: 'wan2.7-t2v',
      note: '',
    ),
    (
      vendor: '硅基流动 SiliconFlow',
      provider: 'siliconflow',
      baseUrl: 'https://api.siliconflow.cn/v1',
      model: 'Wan-AI/Wan2.2-T2V-A14B',
      note: '',
    ),
  ];

  static File fileOf(String filesDir) => File('$filesDir/media-models.json');

  /// 读盘。坏文件**不当作空**（挪到 `.corrupt` 并记下来），与 models.json 同一纪律。
  static String? lastReadError;

  static MediaModelConfig read(String filesDir) {
    final f = fileOf(filesDir);
    lastReadError = null;
    if (!f.existsSync()) return const MediaModelConfig();
    try {
      final raw = f.readAsStringSync();
      if (raw.trim().isEmpty) return const MediaModelConfig();
      final json = jsonDecode(raw);
      if (json is! Map) {
        lastReadError = '影视模型配置不是 JSON 对象，已忽略（原文件另存为 .corrupt）';
        quarantineCorrupt(f);
        return const MediaModelConfig();
      }
      final list = json['custom'];
      final custom = <MediaModelSpec>[];
      if (list is List) {
        for (final e in list) {
          final m = MediaModelSpec.fromJson(e);
          if (m != null) custom.add(m);
        }
      }
      final si = '${json['selectedImage'] ?? ''}'.trim();
      final sv = '${json['selectedVideo'] ?? ''}'.trim();
      return MediaModelConfig(
        custom: custom,
        selectedImage: si.isEmpty ? null : si,
        selectedVideo: sv.isEmpty ? null : sv,
      );
    } catch (e) {
      debugPrint('[dsh-media-models] 读 media-models.json 失败：$e');
      lastReadError = '影视模型配置读不出来：$e（原文件另存为 .corrupt）';
      quarantineCorrupt(f);
      return const MediaModelConfig();
    }
  }

  static Future<void> save({
    required String filesDir,
    required MediaModelConfig config,
  }) async {
    await writeStringAtomic(
        fileOf(filesDir), const JsonEncoder.withIndent('  ').convert(config.toJson()));
  }

  /// 候选（内置 + 用户加的），按 kind 过滤。内置排在最前。
  static List<MediaModelSpec> choices(MediaModelConfig cfg, String kind) {
    final out = <MediaModelSpec>[
      for (final b in builtins())
        if (b.kind == kind) b,
      for (final c in cfg.custom)
        if (c.kind == kind) c,
    ];
    return out;
  }

  /// 当前选中的那条（选过但已不存在时回落到内置默认 —— 不让界面停在一个死引用上）。
  static MediaModelSpec selected(MediaModelConfig cfg, String kind) {
    final list = choices(cfg, kind);
    final want = kind == 'video' ? cfg.selectedVideo : cfg.selectedImage;
    for (final m in list) {
      if (want != null && m.route == want) return m;
    }
    return list.first;
  }

  /// 写选择（route）。传 null 表示回到内置默认。
  static Future<void> select({
    required String filesDir,
    required String kind,
    required String? route,
  }) async {
    final cfg = read(filesDir);
    await save(
      filesDir: filesDir,
      config: kind == 'video'
          ? cfg.copyWith(selectedVideo: route, clearVideo: route == null)
          : cfg.copyWith(selectedImage: route, clearImage: route == null),
    );
  }

  /// 加一条自定义模型（同 route 覆盖旧的）。
  static Future<void> add({
    required String filesDir,
    required MediaModelSpec model,
  }) async {
    final cfg = read(filesDir);
    final next = <MediaModelSpec>[
      for (final m in cfg.custom)
        if (m.route != model.route) m,
      model,
    ];
    // 新加的如果正好是当前 kind 的第一条自定义项，顺手把它选上（用户的意图很明确）。
    await save(
      filesDir: filesDir,
      config: cfg.copyWith(
        custom: next,
        selectedImage: model.isImage ? model.route : null,
        selectedVideo: model.isVideo ? model.route : null,
      ),
    );
  }

  /// 删一条自定义模型（内置删不掉；删掉的正好是选中项 → 选择回到默认）。
  static Future<void> remove({
    required String filesDir,
    required String route,
  }) async {
    final cfg = read(filesDir);
    final next = <MediaModelSpec>[
      for (final m in cfg.custom)
        if (m.route != route) m,
    ];
    await save(
      filesDir: filesDir,
      config: MediaModelConfig(
        custom: next,
        selectedImage: cfg.selectedImage == route ? null : cfg.selectedImage,
        selectedVideo: cfg.selectedVideo == route ? null : cfg.selectedVideo,
      ),
    );
  }
}

/// 一家的**图像档位**（界面据此渲染"清晰度 / 画面比例 / 参考图"）。
typedef MediaImageOptions = ({
  List<String> sizes,
  List<String> ratios,
  bool refs,
  String note,
});

/// 一家的**视频档位**（界面据此渲染"分辨率 / 画幅 / 时长 / 首帧"）。
typedef MediaVideoOptions = ({
  List<String> resolutions,
  List<String> ratios,
  MediaSecondsRange? seconds,
  bool firstFrame,
  String note,
});

/// 时长可选范围：`min`–`max` 秒，默认 `def`（界面按它生成 chip，**不是**写死一张表）。
typedef MediaSecondsRange = ({int min, int max, int def});

/// 「这家能接受哪些档位」的**纯数据 + 纯函数**表。
///
/// ## 为什么必须有这一份（用户 2026-10-11 明确纠正）
///
/// 用户原话：「本 App 的视频请求只认 Agnes 那套形状实际是那个内置的会话限制了你的
/// 使用…**影视这个工具实际是可以使用多个厂家**」。
///
/// 他是对的 —— 脚本侧已经按厂家换请求形状（`assets/toolbox/media-vendors.mjs`，
/// 那是**唯一来源**）。但"换形状"只解决一半：**界面上还得只给这家能接受的档位**。
/// 否则用户会把 Agnes 的 `1K/2K` 发给一家只认 `1024x1024` 的厂家，或者给一家
/// **没有时长参数**的厂家一个时长选择器 —— 那不叫"能选"，那是**必然失败**。
///
/// ## 与脚本的分工（别搞混）
///
///   * `media-vendors.mjs`：**怎么发**（端点、字段名、轮询、尺寸分隔符）。
///   * 这里：**这家支持哪些档位**（界面据此渲染选项）。
///
/// 厂家 id 两边必须一致：[ids] 就是 `VENDORS` 的 key
/// （`agnes / openai / zhipu / dashscope / doubao / minimax / siliconflow / unknown`）。
///
/// ## 纪律
///
/// * **不抛异常**：认不出的厂家（用户自己填的 id）一律走 [unknown] 的档位。
/// * **没有的档位就返回空表**，界面据此**不显示那一项**（而不是给个没用的选项）。
/// * 万相图像的尺寸在 Dart 侧用 `x` 写（`1024x1024`），脚本会转成它要的
///   `1024*1024`（见 media-vendors.mjs 的 `sizeSep`）—— **不要**在界面里写星号。
/// * 本文件里的档位**只在 Dart 侧用**：`make-image.mjs` / `make-video.mjs`
///   收到的仍然是"用户选中的那一个值"，换算/回落在调用方（影视页）。
class MediaVendors {
  MediaVendors._();

  // ── 厂家 id（与 media-vendors.mjs 的 VENDORS key 逐字一致）────────────
  static const String agnes = 'agnes';
  static const String openai = 'openai';
  static const String zhipu = 'zhipu';
  static const String dashscope = 'dashscope';
  static const String doubao = 'doubao';
  static const String minimax = 'minimax';
  static const String siliconflow = 'siliconflow';

  /// 认不出的厂家（用户自己填的 id）走这一家的档位。
  static const String unknown = 'unknown';

  /// 支持的厂家 id（顺序即界面展示顺序，与脚本的 `VENDOR_IDS` 相同）。
  static const List<String> ids = <String>[
    agnes,
    openai,
    zhipu,
    dashscope,
    doubao,
    minimax,
    siliconflow,
    unknown,
  ];

  /// 厂家的**注册 / 拿 Key** 地址（用户 2026-10-12：「也可以给注册地址」）。
  ///
  /// ⚠️ 与 `assets/toolbox/media-vendors.mjs` 的 `register` 字段**必须逐字一致** ——
  /// 唯一来源是那边，这里只是 Dart 侧的镜像（Dart 读不了 .mjs）。
  /// `test/media_vendors_register_test.dart` 会把这份表和脚本正文对一遍，
  /// 改了一边另一边会红。
  static const Map<String, String> registerUrls = <String, String>{
    agnes: 'https://platform.agnes-ai.cn',
    openai: 'https://platform.openai.com/signup',
    zhipu: 'https://open.bigmodel.cn/',
    dashscope: 'https://bailian.console.aliyun.com/',
    doubao: 'https://console.volcengine.com/ark',
    minimax:
        'https://platform.minimax.cn/user-center/basic-information/interface-key',
    siliconflow: 'https://cloud.siliconflow.cn/',
  };

  /// 这家的注册地址；没有（自定义厂家）返回空串 —— 调用方据此**不显示链接**。
  static String registerUrl(String id) => registerUrls[id] ?? '';

  // ── 共用的比例组 ──────────────────────────────────────────────────────
  /// Agnes 图像的比例（影视页原来写死的就是这一组，照抄过来）。
  static const List<String> agnesImageRatios = <String>[
    '1:1', '3:4', '4:3', '16:9', '9:16',
  ];

  /// Agnes 视频的画幅（原来生视频页写死的那一组）。
  static const List<String> agnesVideoRatios = <String>['16:9', '9:16', '1:1'];

  /// MiniMax 图像吃 `aspect_ratio`（**不吃** size）。
  static const List<String> minimaxImageRatios = <String>[
    '1:1', '16:9', '4:3', '3:4', '9:16',
  ];

  /// MiniMax 视频的 ratio（与图像同一组）。
  static const List<String> minimaxVideoRatios = minimaxImageRatios;

  /// 豆包 Seedance 的 ratio（官方支持到 21:9）。
  static const List<String> doubaoVideoRatios = <String>[
    '16:9', '9:16', '1:1', '4:3', '3:4', '21:9',
  ];

  /// 万相视频的 ratio（DashScope 的 `parameters.ratio`）。
  static const List<String> dashscopeVideoRatios = <String>[
    '16:9', '9:16', '1:1', '4:3', '3:4',
  ];

  /// 硅基流动视频的比例（脚本按它换算成 `image_size`，见 `ratioToPixels`）。
  static const List<String> siliconflowVideoRatios = dashscopeVideoRatios;

  // ── 说明文字（界面用 `context.tr(note)` 显示）──────────────────────────
  //
  // ⚠️ 这些是**界面文案**，改一条就要同步改 [_i18nAnchors]（那边是给 i18n 扫描器
  //    看的字面量）—— 否则切外语时这一行还是中文。
  static const String noteAgnesImage =
      'Agnes 的 size 是档位（1K/2K/3K/4K），不是像素值；参考图放 extra_body。';
  static const String noteOpenaiImage =
      'OpenAI 的 size 用像素值（1024x1024 这类），比例由尺寸表达；带参考图走 /images/edits multipart。';
  static const String noteZhipuImage =
      '智谱的 size 用像素值，比例由尺寸表达；参考图放顶层 image 数组。';
  static const String noteDoubaoImage =
      'Seedream 的 size 用像素值，比例由尺寸表达；参考图放顶层 image 数组。';
  static const String noteDashscopeImage =
      '万相没有比例参数：比例由尺寸表达（1280x720 就是 16:9），而且走异步任务。';
  static const String noteMinimaxImage =
      'MiniMax 吃 aspect_ratio，不吃 size，也不吃参考图。';
  static const String noteSiliconflowImage =
      '按 OpenAI 兼容形状发：size 用像素值，参考图放顶层 image 数组。';
  static const String noteUnknownImage =
      '认不出的厂家按 OpenAI 兼容形状试：size 用像素值。';

  static const String noteAgnesVideo = 'Agnes 的分辨率只认 720P 这一档。';
  static const String noteDoubaoVideo =
      '豆包 Seedance 的分辨率由模型与比例决定，这里不能选。';
  static const String noteMinimaxVideo =
      'MiniMax 的分辨率：H3 只支持 768P / 2K，H3-Max 只支持 480P / 768P（两边都能用的是 768P）；时长 H3 是 4–15 秒、H3-Max 是 5–15 秒（它不支持 4 秒）。';
  static const String noteDashscopeVideo =
      '万相只有文生视频（不吃首帧图），分辨率 720P / 1080P。';
  static const String noteSiliconflowVideo =
      '硅基流动没有时长参数：时长由模型决定，分辨率按比例换算成 image_size。';

  /// 上面每一条 note 的登记表（测试用它核对"矩阵里出现的 note 都登记过"）。
  static const List<String> noteKeys = <String>[
    noteAgnesImage,
    noteOpenaiImage,
    noteZhipuImage,
    noteDoubaoImage,
    noteDashscopeImage,
    noteMinimaxImage,
    noteSiliconflowImage,
    noteUnknownImage,
    noteAgnesVideo,
    noteDoubaoVideo,
    noteMinimaxVideo,
    noteDashscopeVideo,
    noteSiliconflowVideo,
  ];

  /// ⚠️ **i18n 扫描器的锚点**（不要删）。
  ///
  /// 上面每家的 `note` 都会被界面用 `context.tr(note)` 显示，而扫描器只收集源码里
  /// `tr('字面量')` 这种写法 —— 写在数据表里的字符串它看不见，于是切到英/日/韩时
  /// 这些说明会**还是中文**。这一段只负责"让扫描器看得到"。
  ///
  /// **两处必须逐字一致**：改了 note 就要同步改这里（`media_models_test.dart`
  /// 的「厂家参数矩阵」会核对，`node install/i18n/check-tables.mjs` 会报漂移）。
  // ignore: unused_element
  static void _i18nAnchors() {
    tr('Agnes 的 size 是档位（1K/2K/3K/4K），不是像素值；参考图放 extra_body。');
    tr('OpenAI 的 size 用像素值（1024x1024 这类），比例由尺寸表达；带参考图走 /images/edits multipart。');
    tr('智谱的 size 用像素值，比例由尺寸表达；参考图放顶层 image 数组。');
    tr('Seedream 的 size 用像素值，比例由尺寸表达；参考图放顶层 image 数组。');
    tr('万相没有比例参数：比例由尺寸表达（1280x720 就是 16:9），而且走异步任务。');
    tr('MiniMax 吃 aspect_ratio，不吃 size，也不吃参考图。');
    tr('按 OpenAI 兼容形状发：size 用像素值，参考图放顶层 image 数组。');
    tr('认不出的厂家按 OpenAI 兼容形状试：size 用像素值。');
    tr('Agnes 的分辨率只认 720P 这一档。');
    tr('豆包 Seedance 的分辨率由模型与比例决定，这里不能选。');
    tr('MiniMax 的分辨率：H3 只支持 768P / 2K，H3-Max 只支持 480P / 768P（两边都能用的是 768P）；时长 H3 是 4–15 秒、H3-Max 是 5–15 秒（它不支持 4 秒）。');
    tr('万相只有文生视频（不吃首帧图），分辨率 720P / 1080P。');
    tr('硅基流动没有时长参数：时长由模型决定，分辨率按比例换算成 image_size。');
  }

  /// 规范厂家 id：认不出的（含空串、大小写混写）一律落到 [unknown]，**不抛异常**。
  static String normalize(String provider) {
    final p = provider.trim().toLowerCase();
    return ids.contains(p) ? p : unknown;
  }

  /// 这家**能不能生图**（界面据此隐藏入口，而不是给一个必然失败的按钮）。
  ///
  /// 目前 `media-vendors.mjs` 里每家的 `image` 都不为 null（含 [unknown]），
  /// 所以恒为 true —— 保留这个函数是为了"将来某家不接图像"时界面自动跟上，
  /// 而不是让界面写死 `true`。
  static bool supportsImage(String provider) {
    final o = imageOptions(provider);
    return o.sizes.isNotEmpty || o.ratios.isNotEmpty;
  }

  /// 这家**能不能生视频**（`openai` / [unknown] 不能 —— 本 App 里没接）。
  static bool supportsVideo(String provider) => videoOptions(provider) != null;

  /// 这家的图像档位。**永远返回一份**（认不出的走 [unknown]）。
  static MediaImageOptions imageOptions(String provider) {
    switch (normalize(provider)) {
      case agnes:
        return (
          sizes: const <String>['1K', '2K', '3K', '4K'],
          ratios: agnesImageRatios,
          refs: true,
          note: noteAgnesImage,
        );
      case openai:
        // gpt-image-1 的档：比例由 size 表达（这家没有 ratio 参数）。
        return (
          sizes: const <String>['1024x1024', '1536x1024', '1024x1536'],
          ratios: const <String>[],
          refs: true,
          note: noteOpenaiImage,
        );
      case zhipu:
        return (
          sizes: const <String>['1024x1024', '1344x768', '768x1344'],
          ratios: const <String>[],
          refs: true,
          note: noteZhipuImage,
        );
      case doubao:
        // Seedream：照桌面版影视工具的 IMAGE_MODEL_SIZE_SUPPORTED 抄。
        return (
          sizes: const <String>[
            '1024x1024', '864x1152', '1152x864', '1280x720', '720x1280',
          ],
          ratios: const <String>[],
          refs: true,
          note: noteDoubaoImage,
        );
      case dashscope:
        // 万相：**没有 ratio 参数**（比例由 size 表达）；这里写 `x`，脚本转 `*`。
        return (
          sizes: const <String>[
            '1024x1024', '1280x720', '720x1280', '768x1152',
          ],
          ratios: const <String>[],
          refs: true,
          note: noteDashscopeImage,
        );
      case minimax:
        // MiniMax：吃 aspect_ratio，**不吃** size（所以 sizes 是空的）。
        return (
          sizes: const <String>[],
          ratios: minimaxImageRatios,
          refs: false,
          note: noteMinimaxImage,
        );
      case siliconflow:
      default:
        return (
          sizes: const <String>[
            '1024x1024', '1280x720', '720x1280', '960x1280', '1280x960',
          ],
          ratios: const <String>[],
          refs: true,
          note: noteSiliconflowImage,
        );
    }
  }

  /// 这家的视频档位；**这家在本 App 里没接视频时返回 null**
  /// （`openai` 只有图像、[unknown] 按 OpenAI 兼容试也只有图像）。
  static MediaVideoOptions? videoOptions(String provider) {
    switch (normalize(provider)) {
      case agnes:
        // 脚本现在只认 720P 这一档（media-vendors.mjs 的 agnes 视频形状）。
        return (
          resolutions: const <String>['720P'],
          ratios: agnesVideoRatios,
          seconds: (min: 1, max: 10, def: 5),
          firstFrame: true,
          note: noteAgnesVideo,
        );
      case doubao:
        // Seedance：这份请求**不发分辨率**（由模型/比例决定）——
        // 所以 resolutions 是空的，界面据此不显示那一行（而不是给个没用的选项）。
        // 时长取宽：官方 2.0 是 4–15 秒、2.5 是 4–30 秒。
        return (
          resolutions: const <String>[],
          ratios: doubaoVideoRatios,
          seconds: (min: 4, max: 30, def: 5),
          firstFrame: true,
          note: noteDoubaoVideo,
        );
      case minimax:
        return (
          // ⚠️ 顺序有讲究：`_vidResolution` 的兜底是 `resolutions.first`，
          //    所以第一项必须是**两个模型都支持**的那一档。
          //    官方文档（2026-10-12 核对）：H3 只支持 768P / 2K；
          //    H3-Max 只支持 480P / 768P。**唯一交集 = 768P**。
          //    以前 480P 排第一：默认模型是 MiniMax-H3，而 H3 不支持 480P
          //    → 一上来就发一个非法档位（上游只会回参数错误）。
          resolutions: const <String>['768P', '480P', '2K'],
          ratios: minimaxVideoRatios,
          // 官方文档：H3 是 4~15 秒；H3-Max 是 5~15 秒（不支持 4 秒）。
          // 以前写 6~10（v1 Hailuo 的旧口径），把合法的 4 秒和 11~15 秒都挡了。
          seconds: (min: 4, max: 15, def: 6),
          firstFrame: true,
          note: noteMinimaxVideo,
        );
      case dashscope:
        // 万相视频只有文生（没有首帧图这一项）→ firstFrame = false。
        return (
          resolutions: const <String>['720P', '1080P'],
          ratios: dashscopeVideoRatios,
          seconds: (min: 2, max: 15, def: 5),
          firstFrame: false,
          note: noteDashscopeVideo,
        );
      case siliconflow:
        // 硅基流动**没有时长参数**（seconds = null）→ 界面不显示时长。
        return (
          resolutions: const <String>[],
          ratios: siliconflowVideoRatios,
          seconds: null,
          firstFrame: true,
          note: noteSiliconflowVideo,
        );
      case openai:
      case unknown:
      default:
        return null;
    }
  }

  /// 时长 chip 的取值：从 (min, max, 默认) **生成**，不是写死一张表。
  ///
  /// 规则：两端与默认值一定在；中间按"最多约 8 个 chip"挑步长，
  /// 保证每一家给出的都是**它真能吃**的值。这家没有时长参数时返回空表
  /// （界面据此**不显示**时长那一行）。
  static List<String> secondsChoices(String provider) {
    final range = videoOptions(provider)?.seconds;
    if (range == null) return const <String>[];
    final span = range.max - range.min;
    if (span <= 0) return <String>['${range.def}'];
    var step = 1;
    if (span > 7) {
      final raw = (span / 6).ceil();
      if (raw <= 2) {
        step = 2;
      } else if (raw <= 3) {
        step = 3;
      } else if (raw <= 5) {
        step = 5;
      } else {
        step = 10;
      }
    }
    final set = <int>{range.min, range.def, range.max};
    for (var s = range.min; s <= range.max; s += step) {
      set.add(s);
    }
    final list = set.where((s) => s >= range.min && s <= range.max).toList()
      ..sort();
    return <String>[for (final s in list) '$s'];
  }
}
