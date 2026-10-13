import 'configured_models.dart';
import 'media_port_rule.dart';

/// 「这个模型能不能当**聊天模型**用」—— 也就是能不能走 `/chat/completions`。
///
/// ## 为什么单独抽一个文件（用户 2026-10-12 报的那个 400）
///
/// Agnes 的**图像 / 视频**模型是**内置端口**（见 `data/agnes_builtin.dart`）：
/// 它们不走 `/chat/completions`，走的是 `/images/generations` 与 `/videos`。
/// 把它们的名字发给 `/chat/completions`，上游只会回一个 **400**。
///
/// 这条规则原本**只写在设置页**（`model_settings_panel` 的 `_isChatModel`），
/// 挡的是"**写进** `models.json`"这一步。问题是：清单里**已经存在**的媒体模型
/// 它管不着 —— 老版本（这条规则加进来之前）写进去的条目还在，用户手填的也在。
/// 于是「影视工具 → 提示词专家」按清单顺序挑第一个模型时，
/// 完全可能挑中一个图像模型 → 400，而界面上只说"HTTP 400"，
/// 用户只能猜（原话：「怀疑没有接文本模型」）。
///
/// 所以规则上提到这里，**两个调用点共用一份**，不允许各写一套：
///   * 设置页：登记前过滤（不要写进清单）
///   * 提示词专家：挑选前过滤（清单里已有的也别用）
///
/// 单一实现的理由很实际：这两处**必须**永远一致。一边改一边忘，
/// 就会重新出现"清单里有媒体模型 → 挑中 → 400"这条链路。
bool isChatModelFor(String providerId, String modelId) {
  // 判定本体在 `media_port_rule.dart`（叶子文件）—— 因为**数据层读配置时也要用
  // 同一份规则**（`configured_models.dart` 不能反过来 import 这个文件，会成环）。
  // 这里只补一步 provider id 归一化。
  return !isMediaPortModel(
      ConfiguredModels.sanitizeProviderId(providerId), modelId);
}


/// 这个厂家的**协议形状**能不能配 `/chat/completions` 用。
///
/// `models.json` 里的 `api` 字段是 DSH 侧的协议实现名，默认
/// `openai-completions`。别的形状（例如将来加的 `anthropic-messages`）
/// 路径和请求体都不一样，硬拼 `/chat/completions` 必然失败 ——
/// 与其发出去换一个看不懂的 4xx，不如在挑选阶段就跳过。
bool isOpenAiCompatible(ProviderSpec p) {
  final api = p.api.trim();
  return api.isEmpty || api == 'openai-completions';
}
