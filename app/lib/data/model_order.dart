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

/// **免 Key / 免费通道**的厂家 id。
///
/// 这些通道里出来的模型**全都是免费的**，哪怕名字里一个 `free` 都没有 ——
/// 真实例子：zen 通道的 `big-pickle`（它出现在那个"只列免费模型"的 `/v1/models` 里，
/// 2026-10-16 实测）。只看名字里的 `free` 会把它排到最后，与"免费的放前面"正好相反。
const Set<String> kFreeChannelProviders = <String>{'zen', 'polli'};

/// 这个模型算不算"免费档"。
///
/// 判据有三条，命中任一即算（**从强到弱**）：
///   1. **来自免 Key 通道**（[kFreeChannelProviders]，id 形如 `zen/big-pickle`）——
///      最可靠：那个通道里没有收费模型；
///   2. id 里含 `free`（`mimo-v2.6-flash-free`）；
///   3. 显示名里含 `free`（`MiMo Free` / `Muse Spark (free)`）。
///
/// 为什么三条都要：只看名字会漏掉 `big-pickle` 这种；只看 id 会漏掉名字里才写的；
/// 只看通道则漏掉用户自己配的"xxx-free"厂家。
bool looksFreeModel(String id, [String? name]) {
  final lower = id.toLowerCase();
  final slash = lower.indexOf('/');
  if (slash > 0 && kFreeChannelProviders.contains(lower.substring(0, slash))) {
    return true;
  }
  if (lower.contains('free')) return true;
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
