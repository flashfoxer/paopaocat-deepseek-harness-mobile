/// 界面文案查表。
///
/// ## 为什么用「中文原文」当 key，而不是 `settings.title` 这种符号名
///
/// 三条理由，都是这个项目的实际情况决定的：
///
///   1. **不会漏**。符号 key 是人工起的名字，起错/漏配一条，界面上就是空白或
///      key 本身漏出来。中文原文当 key 时，**漏翻译只会退回中文**（见
///      [DshStrings.translate] 的 `?? zh`）—— 最坏情况是"这一条还是中文"，
///      而不是坏掉。
///   2. **改代码时看得懂**。`context.tr('设置')` 一眼知道这行在干嘛；
///      `context.tr('settingsTitle')` 得跳去表里查。
///   3. **配合替换脚本**。全量替换是脚本按字符串字面量做的，原文即 key
///      时脚本只需要「包一层」，不需要额外维护一张 key 映射表。
///
/// 代价：同一句话在两处写法略有不同会各占一条。这是可接受的 ——
/// 反正它们本来也可能需要不同的译文。
///
/// ## 占位符
///
/// 带变量的句子在源码里写成 `context.tr('共 {0} 条', [n])`。
/// 中文表就是 key 本身，所以中文侧同样走 `_fill` 把 `{0}` 填进去。
/// **不要**在 key 里塞 Dart 插值（`'共 $n 条'`）—— 那样表里查不到，
/// 因为每次 n 不同，字面量就不同。
library;

import 'package:flutter/widgets.dart';

import 'app_language.dart';
import 'tables/en_table.dart';
import 'tables/ja_table.dart';
import 'tables/ko_table.dart';

/// 当前语言下的文案表。中文即原文（不出表），外语各一张 const 表。
const Map<AppLanguage, Map<String, String>> _tables =
    <AppLanguage, Map<String, String>>{
  AppLanguage.zh: <String, String>{},
  AppLanguage.en: kEnTable,
  AppLanguage.ja: kJaTable,
  AppLanguage.ko: kKoTable,
};

/// 查表 + 填占位符的纯函数。
class DshStrings {
  DshStrings._();

  static AppLanguage _current = AppLanguage.fallback;

  /// 当前语言。由 `main.dart` 在顶层 build 里喂进来（与 `DshColors.applySkin`
  /// 同一处、同一时机）—— 这一层 build 之后整棵树重算，于是新语言生效。
  static AppLanguage get current => _current;

  static void setCurrent(AppLanguage language) {
    _current = language;
  }

  /// 把中文原文翻成 [language]。查不到就原样返回中文（**绝不返回空串**）。
  static String translate(
    AppLanguage language,
    String zh, [
    List<Object?>? args,
  ]) {
    if (language == AppLanguage.zh) return _fill(zh, args);
    return _fill(_tables[language]?[zh] ?? zh, args);
  }

  /// 已翻译条目数（自检用：`flutter analyze` 之外，界面上也能看到覆盖率）。
  static int translatedCount(AppLanguage language) =>
      _tables[language]?.length ?? 0;

  static String _fill(String s, List<Object?>? args) {
    if (args == null || args.isEmpty) return s;
    var out = s;
    for (var i = 0; i < args.length; i++) {
      out = out.replaceAll('{$i}', '${args[i]}');
    }
    return out;
  }
}

/// **没有 BuildContext 的地方**用它：data 层拼装文案、类的静态常量、
/// 初始化阶段。有 context 时一律用 [`BuildContext.tr`]，见下面的说明。
String tr(String zh, [List<Object?>? args]) =>
    DshStrings.translate(DshStrings.current, zh, args);

/// 把语言灌进树里。
///
/// ## 为什么必须有这一层（这不是多余的仪式）
///
/// Flutter 里 `const Text('中文')` 在父级重建时**会被原样复用、跳过 rebuild**，
/// 所以「把中文换成 `tr('中文')`」这种改法在 const 位置会失效：切了语言、
/// 那一行字不变。本项目已经因为这个栽过一次 —— `main.dart` 里那句
/// 「⚠️ 这里**不能**写 const：底色要随皮肤变化」就是同一个坑。
///
/// 走 InheritedWidget 的依赖通知则是**强制重建**：语言一换，依赖它的 element
/// 被 markNeedsBuild，于是 `build()` 重新执行 —— 哪怕这个 widget 自己是 const。
/// 这正是 Flutter 官方 `Localizations` 用的机制。
///
/// 所以纪律是：**UI 层写 `context.tr(...)`，不写全局 `tr(...)`**。
/// 全局那个只留给拿不到 context 的 data 层。
class DshI18n extends InheritedWidget {
  const DshI18n({
    super.key,
    required this.language,
    required super.child,
  });

  final AppLanguage language;

  String t(String zh, [List<Object?>? args]) =>
      DshStrings.translate(language, zh, args);

  @override
  bool updateShouldNotify(DshI18n oldWidget) => oldWidget.language != language;
}

extension DshTrX on BuildContext {
  /// UI 层统一入口：`context.tr('设置')`、`context.tr('共 {0} 条', [n])`。
  ///
  /// 它刻意走 [DshI18n] 的依赖（拿不到时才退回全局当前语言，例如被放在
  /// 还没有 [DshI18n] 的测试里）—— 依赖关系是**语言切换能刷新 const widget**
  /// 的唯一保证，别图省事换成全局 `tr`。
  String tr(String zh, [List<Object?>? args]) =>
      dependOnInheritedWidgetOfExactType<DshI18n>()?.t(zh, args) ??
      DshStrings.translate(DshStrings.current, zh, args);
}
