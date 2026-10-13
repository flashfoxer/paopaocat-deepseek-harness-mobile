// ignore_for_file: unused_element
//
// ⚠️ 这个文件**故意不 import 任何东西**（叶子文件）—— 别往里加 import。
//
// 为什么必须这样（用户 2026-10-12 排查「还有什么忘了修的」时发现的方向问题）：
// 规则现在要在**数据层**（`configured_models.dart` 读配置时）也生效；
// 而 `agnes_builtin.dart` 因为要用 `ConfiguredModels.envNameFor`
// **反过来 import 了 `configured_models.dart`**。规则要是继续留在
// `agnes_builtin.dart` 里，`configured_models` 一 import 它就成环。
// 所以把"值 + 判定"下沉到这里，`AgnesBuiltin` 改成**引用**这几个常量 ——
// 值仍然只有一份，不会两边漂。

/// 出厂内置的 Agnes 厂家 id。
const String kAgnesProviderId = 'agnes';

/// Agnes 官方列出的三个"免费"模型（文本 / 图像 / 视频）。
const String kAgnesTextModel = 'agnes-3.0-flash';
const String kAgnesImageModel = 'agnes-image-2.5-flash';
const String kAgnesVideoModel = 'agnes-video-2.5-flash';

/// `providerId` 名下的 `modelId` 是不是**媒体端口**模型。
///
/// Agnes 的图像 / 视频模型是**内置端口**：它们不走 `/chat/completions`，
/// 走的是 `/images/generations` 与 `/videos`。把它们的名字发给
/// `/chat/completions`，上游只会回一个 **400**。
bool isMediaPortModel(String providerId, String modelId) {
  if (providerId.trim().toLowerCase() != kAgnesProviderId) return false;
  final id = modelId.trim().toLowerCase();
  if (id == kAgnesImageModel || id == kAgnesVideoModel) return true;
  // 故意写得宽一点：官方以后换成 `agnes-image-3` 这种新名字也照样挡住，
  // 不会悄悄漏回来。
  return id.contains('image') || id.contains('video');
}

/// 同上，但吃的是 `provider/modelId` 这种 route（用于清掉指向媒体模型的选中项）。
bool isMediaPortRoute(String route) {
  final i = route.indexOf('/');
  if (i <= 0) return false;
  return isMediaPortModel(route.substring(0, i), route.substring(i + 1));
}
