/// App 界面语言。
///
/// ## 这个开关**只管 App 自己画的界面**
///
/// 泡泡猫 DSH 手机版是电脑上那台 DSH 的**客户端**。界面上有两类文字，来源不同：
///
///   1. **App 自己画的** —— 导航名、设置页、按钮、说明文案、内置错误提示……
///      这些在本 App 的代码里，**跟随本开关切换**。
///   2. **电脑端回传的** —— 会话消息、技能名、专家库（321 名）、内置会话模板、
///      后端报错、更新日志的正文…… 这些是电脑上那台 DSH 给的，**保持原文**。
///
/// 所以切到 English 之后，界面是英文、但电脑上跑出来的内容仍是中文。
/// 这不是没做完，是这类客户端的固有边界：**App 无权替电脑端决定用什么语言**。
/// 设置页里会把这句话如实写给用户看（见 `settings_tab.dart` 的语言说明）。
///
/// ## 显示名为什么用各自的母语
///
/// 「语言」这一组按钮上写的是 `中文 / English / 日本語 / 한국어`，
/// 而不是「中文 / 英语 / 日语 / 韩语」。原因很实在：**一个人要找自己的语言时，
/// 认的是自己语言的字**。如果界面已经切成日文、把韩语写成「韓国語（カタカナ）」，
/// 韩国用户反而要在日文里找韩语名。母语显示是这类选择器的通行做法。
enum AppLanguage {
  zh('zh', '中文', '简体中文'),
  en('en', 'English', '英语'),
  ja('ja', '日本語', '日语'),
  ko('ko', '한국어', '韩语');

  const AppLanguage(this.id, this.nativeName, this.zhName);

  /// 落盘用的稳定 id（存 SharedPreferences，**不要改**，改了老用户的设置会丢）。
  final String id;

  /// 选择器上显示的名字（各自母语）。
  final String nativeName;

  /// 中文名。给「已落盘」那行等需要中文说明的地方用。
  final String zhName;

  /// 默认语言。**刻意保持中文**：本 App 的主要使用者是中文用户，
  /// 而且电脑端回传的内容也是中文 —— 默认跟随界面语言最不突兀。
  static const AppLanguage fallback = AppLanguage.zh;

  /// 由落盘 id 反查。磁盘上写了个不认识的值（或老版本没这个键）就退回默认，
  /// 绝不把语言留在一个"空"的状态上 —— 与 `AppSettings` 处理皮肤是同一套纪律。
  static AppLanguage byId(String? id) {
    for (final l in AppLanguage.values) {
      if (l.id == id) return l;
    }
    return fallback;
  }
}
