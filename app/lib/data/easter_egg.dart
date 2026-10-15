import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 隐藏彩蛋的开关。
///
/// ## 是什么彩蛋（用户 2026-10-15 亲口定的）
///
/// 用户原话：「**zen 这个设置还是你说的，作为一个彩蛋吧**」+「**菜单是连点 6 下
/// 猫咪就会出现**」；同一天晚上用户又把它定了细节：「**点击第 7 下，会有一个长震动，
/// 猫咪的左上右都会弹出泡泡，泡泡显示「有彩蛋，在设置里」**」。
///
/// 所以最终口径是：**第 [tapsToUnlock] 下（7 下）**既**解锁**、又**当场表演**
/// （长震 + 左/上/右三个泡泡一起弹「有彩蛋，在设置里」）—— 设置页「模型」组里
/// 会同时多出「实验通道 · OpenCode Zen（第三方通道）」。
///
/// 表演见 `ui/widgets/mascot_speech.dart` 的 `_onTapCat`（第 8 下起回到普通泡泡）。
///
/// ## 为什么用"连点"而不是藏在一个子菜单里
///
/// 那条通道 2026-10-13/14 被上游连续收紧四次后基本已死（社区里做得最扎实的那个
/// 插件都直接放弃了）。它留在设置页明面上只会让人"配了却用不了"，而完全删掉又浪费 ——
/// 万一上游哪天又放开，一个开关就能用回来。彩蛋正好是"不碍事、但还在"的形态。
///
/// 连点那只猫是最自然的位置：猫本来就是首页可点的东西（点一下会说一句话，
/// 见 `ui/widgets/mascot_speech.dart`），连点到第 7 下不会误触发、也不用教。
///
/// ## 状态存哪
///
/// `SharedPreferences`（一条 bool）。**不放进 `AppSettings`**：它是"用户自己藏了
/// 什么"的私事，与皮肤/字号/语言那些设置的生命周期不同（那些每次启动都要读来建主题，
/// 这个读了也只是决定"多不多一块设置"）。
class EasterEggStore extends ChangeNotifier {
  EasterEggStore._();

  /// 全局单例：写它的是首页那只猫，读它的是设置页 —— 两边都在 widget 树深处，
  /// 为这个多穿两层回调不值得（[ChangeNotifier] 已经能通知到）。
  static final EasterEggStore instance = EasterEggStore._();

  static const String _kZenUnlocked = 'dsh_easter_zen_unlocked';

  /// 连点多少下解锁（用户指定：**7 下**）。
  ///
  /// ⚠️ 这个数字与 `MascotSpeech` 的"表演"共用：改这里就等于改"第几下长震 + 三泡泡"。
  static const int tapsToUnlock = 7;

  /// 连点的间隔上限：超过这个时间就从头数。
  ///
  /// 为什么要有它：没有这个的话，用户「今天点 3 下、明天点 3 下」也会解锁 ——
  /// 那就不像彩蛋了。1.2 秒比"连点"稍宽一点（手指反应慢的人也不会被卡）。
  static const Duration tapWindow = Duration(milliseconds: 1200);

  bool _zenUnlocked = false;

  /// Zen 那条实验通道解锁了没有。
  bool get zenUnlocked => _zenUnlocked;

  /// 启动时读一次。读失败按"没解锁"处理（不够惊喜总好过误开一条已死的通道）。
  Future<void> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      _zenUnlocked = sp.getBool(_kZenUnlocked) ?? false;
      notifyListeners();
    } catch (e) {
      debugPrint('[dsh-easter] 读彩蛋状态失败（按未解锁处理）：$e');
    }
  }

  /// 解锁（幂等：已经解锁时什么都不做，不重复落盘、不发通知）。
  Future<void> unlockZen() async {
    if (_zenUnlocked) return;
    _zenUnlocked = true;
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_kZenUnlocked, true);
      debugPrint('[dsh-easter] 彩蛋已解锁：设置 → 模型 里会出现「实验通道」');
    } catch (e) {
      // 落盘失败不回滚内存状态：这一次能看见就算数，下次启动再发现"又没了"也比
      // "点了 6 下什么都不发生"好排查（debugPrint 里留了痕）。
      debugPrint('[dsh-easter] 写彩蛋状态失败（本次仍生效）：$e');
    }
  }

  /// 测试用：把状态清回未解锁。
  @visibleForTesting
  Future<void> resetForTest() async {
    _zenUnlocked = false;
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_kZenUnlocked);
    } catch (_) {}
  }
}
