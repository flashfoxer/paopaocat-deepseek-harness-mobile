/// 模型列表的排序规则：**带 free 字样的排前面**。
///
/// ## 为什么单独一个文件
///
/// 这条规则要在**三处**保持一致，否则界面上会出现"同一个列表两种顺序"：
///   * `data/model_fetcher.dart` —— 「获取模型」拉回来的清单；
///   * `state/model_store.dart` —— 会话里点模型名的选择面板（也决定设置页的展示）；
///   * `ui/pages/model_settings_panel.dart` —— 保存进 `models.json` 时的顺序。
///
/// 规则本身只有一行判断，抄三遍必然跑偏，所以抽出来共用。
///
/// 用户 2026-10-16 原话：「所有模型全部可以获取，而且**带 free 字样的放到前边**」。
library;

/// 这个模型算不算"免费档"。
///
/// [id] 与 [name] **两处都看**、不分大小写：有的厂家把 free 写进 id
/// （`mimo-v2.6-flash-free`），有的写在显示名（`MiMo Free` / `Muse Spark (free)`）。
/// 只看 id 会漏掉第二种，只看 name 会漏掉第一种。
bool looksFreeModel(String id, [String? name]) {
  if (id.toLowerCase().contains('free')) return true;
  final n = name?.toLowerCase() ?? '';
  return n.contains('free');
}

/// 比较两个模型：**带 free 的排前面**，同类里按 id 字典序（大小写不敏感）。
///
/// 返回负数表示 [aId] 应该排在前面（与 `List.sort` 的约定一致）。
int compareModelsFreeFirst({
  required String aId,
  String? aName,
  required String bId,
  String? bName,
}) {
  final fa = looksFreeModel(aId, aName);
  final fb = looksFreeModel(bId, bName);
  if (fa != fb) return fa ? -1 : 1;
  return aId.toLowerCase().compareTo(bId.toLowerCase());
}

/// 把一串模型按「free 优先」排好序返回（不改原列表）。
///
/// [idOf] / [nameOf] 让这个函数能直接用在各种模型类型上（`ModelEntry` /
/// `ModelSpec` / `FetchedModel` 的字段名都不一样）。
List<T> sortModelsFreeFirst<T>(
  Iterable<T> items, {
  required String Function(T) idOf,
  String? Function(T)? nameOf,
}) {
  final list = items.toList();
  list.sort((a, b) => compareModelsFreeFirst(
        aId: idOf(a),
        aName: nameOf?.call(a),
        bId: idOf(b),
        bName: nameOf?.call(b),
      ));
  return list;
}
