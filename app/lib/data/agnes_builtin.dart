import 'configured_models.dart';
import 'media_port_rule.dart';

import '../i18n/dsh_i18n.dart';

/// 内置的 **Agnes（免费）** 能力：文生图 / 文生视频。
///
/// 用户 2026-10-04 的要求原文：
/// 「模型内置 agnes 特别注明免费，并附带注册地址，并把生视频和生图的模型端口
///   内置，用户提出生成图片或视频会自动调用这两个。」
///
/// ## 这些值是从哪来的（别凭记忆改）
/// 全部来自 Agnes 官方文档（我逐页读过）：
///   * 图片：https://agnes-ai.cn/zh-Hans/docs/agnes-image-25-flash
///     `POST https://api.agnes-ai.cn/v1/images/generations`，
///     body `{model, prompt, size, ratio?, extra_body:{response_format}}`，
///     响应 `data[0].url` 或 `data[0].b64_json`。
///     **官方原文**：「所有支持的输出分辨率档位和输入参考图片当前均免费。」
///   * 视频：https://agnes-ai.cn/zh-Hans/docs/agnes-video-25-flash
///     创建 `POST https://api.agnes-ai.cn/v1/videos`（`seconds` 是字符串、
///     `size` 只能是 `"720P"`），轮询
///     `GET https://api/…/agnesapi?video_id=<ID>&model_name=agnes-video-2.5-flash`，
///     完成时取**顶层 `url`**。**官方原文**：原价 ¥0.15/秒，现价 **¥0/秒**，
///     并注明「免费政策如有调整，以 Agnes AI 平台最新公告为准」。
///   * 注册地址：https://platform.agnes-ai.cn （文档「快速开始」给的开发者控制台）
///
/// ⚠️ **"免费"这句话的口径要照抄官方的限定**：是"当前/限时免费，政策调整以平台
/// 公告为准"，不是"永久免费"。界面上也必须这么写 —— 这是诚实性要求，
/// 不能让用户以为这是一张永久免费无限量的门票。
class AgnesBuiltin {
  AgnesBuiltin._();

  /// 出厂内置的厂家 id。它同时决定了凭据环境变量名（`AGNES_API_KEY`）——
  /// 因为 [ConfiguredModels.envNameFor] 是按 provider id 推的。
  /// ⚠️ 值在 `media_port_rule.dart`（叶子文件），这里只**引用**。
  /// 搬出去的理由与"数据层也要用这条规则"有关，见那个文件的头部注释。
  static const String providerId = kAgnesProviderId;

  static String get label => tr('Agnes（免费）');

  /// API 端点（OpenAI 兼容风格）。
  static const String baseUrl = 'https://api.agnes-ai.cn/v1';

  /// 视频任务的轮询端点（注意：不在 `/v1` 下，是站点根路径）。
  static const String videoPollBase = 'https://api.agnes-ai.cn/agnesapi';

  /// 免费注册 / 拿 API Key 的地方（界面上要直接给这个地址）。
  static const String registerUrl = 'https://platform.agnes-ai.cn';

  /// 官方文档入口（用户 2026-10-04 亲口给的就是这个）。
  static const String docsUrl = 'https://www.agnes-ai.cn/doc';

  /// 官方列出的三个"免费"模型（文本/图像/视频）。
  static const String textModel = kAgnesTextModel;
  static const String imageModel = kAgnesImageModel;
  static const String videoModel = kAgnesVideoModel;

  /// 界面上"免费"那句话的**完整**说法（含官方的免责限定）。
  static String get freeNote => tr(
      'Agnes 官方当前把这几个模型标为免费：文本 agnes-3.0-flash、图像 agnes-image-2.5-flash（官方原文：所有输出分辨率档位与输入参考图片当前均免费）、视频 agnes-video-2.5-flash（官方原文：原价 ¥0.15/秒，现价 ¥0/秒）。这是**限时/当前**的优惠价，官方注明"免费政策如有调整，以平台最新公告为准"，不要当成永久免费无限量。');

  /// 注册引导（设置页直接用）。
  static String get registerHint => tr(
      '还没有 Key？到 {0} 免费注册 → 控制台「API Keys」创建密钥（sk- 开头）→ 粘贴到这里。', [registerUrl]);

  /// 生成内置 provider 定义（设置页"一键添加 Agnes"用）。
  static ProviderSpec providerSpec() => ConfiguredModels.provider(
        id: providerId,
        label: label,
        baseUrl: baseUrl,
      );
}
