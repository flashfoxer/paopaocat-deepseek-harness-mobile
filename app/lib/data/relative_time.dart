import '../i18n/dsh_i18n.dart' show tr;

/// 把时间戳渲染成**给人看的**相对时间标签。
///
/// 输出形状：`刚刚` / `12 分钟前` / `3 小时前` / `2 天前` / `2026-09-28 14:02`。
///
/// ## 为什么单独抽出来（别在各页各写一份）
///
/// 这个格式原来只活在 `workspace_store.dart` 的 `createdLabel` 里，于是：
///   * 「工作区的历史会话」有时间；
///   * 「会话列表」**没有** —— 用户实际反馈："会话的历史纪录，显示不出会话的时间"，
///     那一页的列表项显示的是工作目录和一个序号（`lastSeq`，对用户没有意义）。
/// 同一件事两处写法，一处有、一处没有 —— 所以这里抽成唯一实现，两处都用它。
///
/// ## 单位
///
/// 入参是 **epoch 毫秒**（桥那边是 `Date.now()`、ACP 也是毫秒）。传 null 或 <= 0
/// 时返回空串 —— 调用方据此**不显示**这一行，而不是显示"1970 年"。
///
/// [now] 只为测试注入固定"当前时间"，正常调用不用传。
String relativeTimeLabel(DateTime? t, {DateTime? now}) {
  if (t == null) return '';
  final at = now ?? DateTime.now();
  final diff = at.difference(t);
  // 未来时间（设备时钟被改过/服务端时钟偏快）也显示"刚刚"，不说"-3 分钟前"。
  if (diff.isNegative) return tr('刚刚');
  if (diff.inMinutes < 1) return tr('刚刚');
  if (diff.inMinutes < 60) return tr('{0} 分钟前', <Object?>[diff.inMinutes]);
  if (diff.inHours < 24) return tr('{0} 小时前', <Object?>[diff.inHours]);
  if (diff.inDays < 7) return tr('{0} 天前', <Object?>[diff.inDays]);
  String two(int v) => v.toString().padLeft(2, '0');
  // 绝对时间用 `yyyy-MM-dd HH:mm`：不写"3 月 5 日"这种各语言不同的月名，
  // 免得再多 12 条翻译，而且这个形状在所有语言里都读得懂。
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}';
}

/// epoch 毫秒 → 标签；`<= 0`（桥没给时间）返回空串。
String relativeTimeLabelFromMs(int ms, {DateTime? now}) =>
    ms <= 0 ? '' : relativeTimeLabel(DateTime.fromMillisecondsSinceEpoch(ms), now: now);
