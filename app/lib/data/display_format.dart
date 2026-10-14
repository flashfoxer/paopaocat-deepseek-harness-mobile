/// 界面上「数字怎么显示」的小工具。
///
/// 为什么单独一个文件：token 用量在会话列表、会话页顶栏都要显示，
/// 两处口径必须一致（同一份数据两种写法，用户一眼就看出不一致）。
library;

/// token 用量的紧凑写法：`987` / `1.2k` / `34k` / `1.2M`。
///
/// 用 **1024 进制**，与「设置 → 应用信息」里体积那套（`formatBytes`）保持同一口径 ——
/// 一个 App 里不该有两套 k/M 的算法。
///
/// 取不到用量时**不要**调用它（[DshSession.tokensLabel] 会返回空串），
/// 显示一个编出来的 `0 tok` 比什么都不显示更糟。
String formatTokens(int n) {
  if (n < 0) return '0';
  if (n < 1000) return '$n';
  if (n < 1024 * 1024) {
    final k = n / 1024;
    return k < 10 ? '${k.toStringAsFixed(1)}k' : '${k.round()}k';
  }
  final m = n / (1024 * 1024);
  return m < 10 ? '${m.toStringAsFixed(1)}M' : '${m.round()}M';
}
