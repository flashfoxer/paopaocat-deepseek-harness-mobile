import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/easter_egg.dart';
import '../../data/mascot_lines.dart';
import '../../i18n/dsh_i18n.dart';
import '../../local/dsh_runtime.dart';
import '../theme/dsh_tokens.dart';
import 'brand_logo.dart';

/// 普通点击一下的**短震**（毫秒）。见 [DshHost.vibrate]。
const int kMascotShortVibrateMs = 30;

/// 连点到第 [EasterEggStore.tapsToUnlock] 下的**长震**（毫秒）。
///
/// 为什么 350ms：短于 200ms 用户分不清"长震"和"短震"；长于 500ms 会像手机出了故障。
const int kMascotLongVibrateMs = 350;

/// 首页那只猫 + **点它会有泡泡和震动**（用户 2026-10-15 第 4 条 + 同一晚的补充要求）。
///
/// ## 怎么实现的（以及为什么这么做）
///
/// 气泡用 **Overlay**，不是塞在首页那一列里：
///   * 首页品牌区是**按屏高比例**排的固定高度块（见 `task_home_view.dart` 的
///     `_ScrollBody`），往里塞气泡会把下面的内容顶掉、还可能溢出；
///   * Overlay 画在所有内容之上，气泡可以自由地"盖"在标语上，几秒后自己消失。
///
/// ## 行为（用户 2026-10-15 晚逐条定下来的）
///
///   * 点一下 → **短震** + 说下一句（台词**轮换**，不是随机：轮换保证每次都不一样，
///     又不会连着两次撞同一句）；
///   * 泡泡位置**左 → 上 → 右 轮换**（第 1 下在左边、第 2 下在上面、第 3 下在右边，
///     第 4 下回左边…）—— 用户要求"左边上边右边，每点一下都是个泡泡"；
///   * **连点到第 [EasterEggStore.tapsToUnlock] 下（7 下）** → **长震** +
///     **左/上/右三个泡泡同时弹**，文字固定为「有彩蛋，在设置里」，并且**同时解锁**：
///     设置页「模型」组里会多出「实验通道 · OpenCode Zen」（见 `data/easter_egg.dart`）；
///   * 第 8 下起**回到普通泡泡**（左/上/右轮换 + 短震）；
///   * 再说一句会**顶掉**上一句（不会叠成一堆）；5 秒后自己消失；气泡也可以点掉。
///
/// 文案本身在 `data/mascot_lines.dart`（本地写死、走 i18n、不发任何请求）。
class MascotSpeech extends StatefulWidget {
  const MascotSpeech({super.key, this.size = 70, this.clock = DateTime.now});

  final double size;

  /// 取"现在"的函数。**默认就是 `DateTime.now`，生产代码不用改。**
  ///
  /// ⚠️ 存在的唯一理由是**可测**：连点窗口是按真实时间算的，而 widget 测试里
  /// `tester.pump(Duration)` 只推进*测试时钟*，不会让 `DateTime.now()` 走动 ——
  /// 于是"慢慢点不该解锁"这条根本没被验证过（点得再慢，真实时间也只过了几毫秒）。
  /// 注入时钟之后，测试可以明确地把时间往前拨。
  final DateTime Function() clock;

  @override
  State<MascotSpeech> createState() => _MascotSpeechState();
}

/// 泡泡出现在猫的哪一侧（也决定尾巴朝哪边）。
enum _BubbleSide {
  /// 猫的左边 → 尾巴朝右
  left,

  /// 猫的上边 → 尾巴朝下
  top,

  /// 猫的右边 → 尾巴朝左
  right,
}

class _MascotSpeechState extends State<MascotSpeech> {
  final GlobalKey _anchor = GlobalKey();
  OverlayEntry? _entry;
  Timer? _timer;
  int _tick = 0;

  /// 连点计数与上一次点击的时刻（彩蛋用）。
  ///
  /// 超过 [EasterEggStore.tapWindow] 就从 1 重新数 —— 否则"今天点 3 下、明天点 4 下"
  /// 也会解锁，那就不像彩蛋了。
  int _taps = 0;
  DateTime? _lastTapAt;

  @override
  void dispose() {
    _timer?.cancel();
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  void _dismiss() {
    _timer?.cancel();
    _timer = null;
    _entry?.remove();
    _entry = null;
  }

  /// 一次点击：短震 + 一个泡泡（位置轮换）；连点到第 N 下时改成"长震 + 三个泡泡 + 解锁"。
  void _onTapCat() {
    final now = widget.clock();
    final last = _lastTapAt;
    if (last == null || now.difference(last) > EasterEggStore.tapWindow) {
      _taps = 1;
    } else {
      _taps++;
    }
    _lastTapAt = now;

    // ── 第 [tapsToUnlock] 下（现在 = 7）：长震 + 左/上/右三个泡泡 + 解锁 ──
    //
    // ⚠️ 这里**每次都表演**（不是"只第一次"）：用户明确要的是"点到第 7 下会这样"，
    //    把它做成一次性反而会让人第二次点以为自己点错了。解锁本身是幂等的。
    if (_taps >= EasterEggStore.tapsToUnlock) {
      _taps = 0;
      _lastTapAt = null;
      unawaited(EasterEggStore.instance.unlockZen());
      unawaited(DshHost.vibrate(kMascotLongVibrateMs));
      _showBubbles(
        const <_BubbleSide>[_BubbleSide.left, _BubbleSide.top, _BubbleSide.right],
        text: context.tr('有彩蛋，在设置里'),
      );
      return;
    }

    // ── 普通点击：短震 + 一个泡泡，位置按 左 → 上 → 右 轮换 ──
    unawaited(DshHost.vibrate(kMascotShortVibrateMs));
    final side = _BubbleSide.values[(_taps - 1) % _BubbleSide.values.length];
    _showBubbles(<_BubbleSide>[side], text: mascotLineAt(_tick++));
  }

  /// 在猫周围弹泡泡。[sides] 里的每个位置都会得到一个泡泡（第 7 下时传三个）。
  ///
  /// 位置是**按猫的真实位置算的**（不是写死的百分比）：猫在首页的位置由品牌区
  /// 的屏高比例决定，不同机型不一样。
  void _showBubbles(List<_BubbleSide> sides, {required String text}) {
    _dismiss();
    final box = _anchor.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !mounted) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;

    final screen = MediaQuery.sizeOf(context);
    final inset = MediaQuery.paddingOf(context);
    const pad = DshMetrics.pagePad;

    final origin = box.localToGlobal(Offset.zero);
    final catW = box.size.width;
    final catLeft = origin.dx;
    final catTop = origin.dy;
    final catRight = catLeft + catW;

    // 左/右两侧气泡能占多宽：一路顶到猫的边缘（再留 6dp 空隙），别盖住猫。
    // 太窄（< 88）就退到"上面"——窄气泡会把一句歌词挤成四五行的豆腐块。
    final sideRoom = math.max(catLeft - 6 - pad, screen.width - catRight - 6 - pad);
    final sideWidth = math.min(sideRoom, screen.width * 0.46);

    /// 左/右气泡的竖直位置：跟猫的**上沿**对齐（看起来像并排说话）。
    final sideTop = catTop;

    Widget bubble(_BubbleSide side) {
      switch (side) {
        case _BubbleSide.left:
          return Positioned(
            left: pad,
            top: sideTop,
            width: sideWidth,
            child: _Bubble(
              text: text,
              tail: _TailSide.toRight,
              onTap: _dismiss,
            ),
          );
        case _BubbleSide.right:
          return Positioned(
            right: pad,
            top: sideTop,
            width: sideWidth,
            child: _Bubble(
              text: text,
              tail: _TailSide.toLeft,
              onTap: _dismiss,
            ),
          );
        case _BubbleSide.top:
          return Positioned(
            left: screen.width * 0.16,
            right: screen.width * 0.16,
            // 用 `bottom` 贴猫的上沿：不必知道气泡有多高（它随文字行数变），
            // 也就不会因为多一行字而把猫盖住。
            bottom: math.max(screen.height - catTop + 6, inset.top + 4),
            child: _Bubble(
              text: text,
              tail: _TailSide.toBottom,
              onTap: _dismiss,
            ),
          );
      }
    }

    final children = <Widget>[];
    for (final s in sides) {
      // 上方空间不够时（猫顶到状态栏了）把"上面"降级成"右边"，免得画到屏幕外。
      if (s == _BubbleSide.top && catTop - inset.top < 64) {
        children.add(bubble(_BubbleSide.right));
      } else if ((s == _BubbleSide.left || s == _BubbleSide.right) &&
          sideWidth < 88) {
        children.add(bubble(_BubbleSide.top));
      } else {
        children.add(bubble(s));
      }
    }

    _entry = OverlayEntry(
      builder: (_) => Positioned.fill(
        // Stack 本身在空白处不命中点击 → 手指能穿过去点页面别处（只有气泡会吃掉点击）。
        child: Stack(children: children),
      ),
    );
    overlay.insert(_entry!);
    _timer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(_dismiss);
    });
    setState(() {}); // 让 Semantics/测试能看到"正在说话"
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: context.tr('泡泡猫（点一下它会说话）'),
      child: GestureDetector(
        key: _anchor,
        behavior: HitTestBehavior.opaque,
        onTap: _onTapCat,
        child: BrandLogo(size: widget.size),
      ),
    );
  }
}

/// 尾巴指向哪边（按"指向猫"命名）：气泡在猫上面 → [toBottom]。
enum _TailSide { toBottom, toRight, toLeft }

/// 那个"对话的样子"的气泡：一只小尾巴 + 圆角块，淡入 + 轻微放大。
class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.text,
    required this.onTap,
    required this.tail,
  });

  final String text;
  final VoidCallback onTap;
  final _TailSide tail;

  BorderSide get _accent => BorderSide(
        color: DshColors.accent,
        width: DshMetrics.borderWidth,
      );

  /// 小尾巴：一个旋转 45° 的方块。**哪两条边有颜色**决定旋转后的尖端朝向 ——
  /// 左上角朝上、右上角朝右、右下角朝下、左下角朝左（这是旋转 45° 的几何结果）：
  ///   * 尖端朝下（气泡在猫上方）→ `bottom + right`
  ///   * 尖端朝右（气泡在猫左侧）→ `top + right`
  ///   * 尖端朝左（气泡在猫右侧）→ `bottom + left`
  Widget _tail() => Transform.rotate(
        angle: 0.7854,
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: DshColors.surfaceStrong,
            border: Border(
              top: tail == _TailSide.toRight ? _accent : BorderSide.none,
              bottom: tail == _TailSide.toRight ? BorderSide.none : _accent,
              left: tail == _TailSide.toLeft ? _accent : BorderSide.none,
              right: tail == _TailSide.toLeft ? BorderSide.none : _accent,
            ),
          ),
        ),
      );

  Widget _box() => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: DshColors.surfaceStrong,
          borderRadius: BorderRadius.circular(DshMetrics.radius(12)),
          border: Border.all(
              color: DshColors.accent, width: DshMetrics.borderWidth),
          boxShadow: DshColors.panelShadow,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('🐱', style: TextStyle(fontSize: 14)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: DshColors.text,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    // ⚠️ **不要用负 margin**：Flutter 3.x 的 `Container` 直接断言
    //    `margin.isNonNegative` —— debug 下气泡一画出来就抛异常（release 没断言，
    //    所以这个洞长期潜伏；是 0.75 给彩蛋写测试时第一次真正构建气泡才抓到的）。
    //    尾巴与气泡块的 4px 重叠改用 `Transform.translate` —— 绘制位置一样，
    //    但它**不参与布局测量**，这正是与负 margin 的区别。
    final Widget content = switch (tail) {
      _TailSide.toBottom => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _box(),
            const SizedBox(height: 0),
            // 尾巴居中：正对着下方的猫
            Transform.translate(
              offset: const Offset(0, -4),
              child: Center(child: _tail()),
            ),
          ],
        ),
      _TailSide.toRight => Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: _box()),
            Transform.translate(
              offset: const Offset(-4, 0),
              child: _tail(),
            ),
          ],
        ),
      _TailSide.toLeft => Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Transform.translate(
              offset: const Offset(4, 0),
              child: _tail(),
            ),
            Expanded(child: _box()),
          ],
        ),
    };

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutBack,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0, 1),
        child: Transform.scale(scale: 0.92 + 0.08 * t, child: child),
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: content,
      ),
    );
  }
}
