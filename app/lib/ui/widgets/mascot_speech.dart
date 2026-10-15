import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/easter_egg.dart';
import '../../data/mascot_lines.dart';
import '../../i18n/dsh_i18n.dart';
import '../theme/dsh_tokens.dart';
import 'brand_logo.dart';

/// 首页那只猫 + **点一下它会说一句话**（用户 2026-10-15 第 4 条）。
///
/// ## 怎么实现的（以及为什么这么做）
///
/// 气泡用 **Overlay**，不是塞在首页那一列里：
///   * 首页品牌区是**按屏高比例**排的固定高度块（见 `task_home_view.dart` 的
///     `_ScrollBody`），往里塞一个气泡会把下面的内容顶掉、还可能溢出；
///   * Overlay 画在所有内容之上，气泡可以自由地"盖"在标语上，几秒后自己消失。
///
/// ## 行为
///
///   * 点一下 → 按顺序说下一句（**轮换**，不是随机：轮换保证每次点的都不一样，
///     又不会连着两次撞同一句）；
///   * **连点 6 下 → 解锁一个彩蛋**（用户 2026-10-15 指定：「菜单是连点 6 下猫咪
///     就会出现」）—— 设置页「模型」组里会多出「实验通道 · OpenCode Zen」
///     （见 `data/easter_egg.dart`）；
///   * 再说一句会**顶掉**上一句（不会叠成一堆）；
///   * 5 秒后自己消失；气泡也可以点掉。
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

class _MascotSpeechState extends State<MascotSpeech> {
  final GlobalKey _anchor = GlobalKey();
  OverlayEntry? _entry;
  Timer? _timer;
  int _tick = 0;

  /// 连点计数与上一次点击的时刻（彩蛋用）。
  ///
  /// 超过 [EasterEggStore.tapWindow] 就从 1 重新数 —— 否则"今天点 3 下、明天点 3 下"
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

  /// 一次点击：先说一句话；如果是第 [EasterEggStore.tapsToUnlock] 次连点，就解锁彩蛋。
  void _onTapCat() {
    final now = widget.clock();
    final last = _lastTapAt;
    if (last == null || now.difference(last) > EasterEggStore.tapWindow) {
      _taps = 1;
    } else {
      _taps++;
    }
    _lastTapAt = now;

    if (_taps >= EasterEggStore.tapsToUnlock) {
      _taps = 0;
      _lastTapAt = null;
      // 已经解锁过就只说普通的话（别每次连点都报一遍"找到我了"）。
      final first = !EasterEggStore.instance.zenUnlocked;
      unawaited(EasterEggStore.instance.unlockZen());
      if (first) {
        _speak(text: context.tr('找到我了！去「设置 → 模型」看看 —— 多了一条实验通道。'));
        return;
      }
    }
    _speak();
  }

  void _speak({String? text}) {
    _dismiss();
    final box = _anchor.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !mounted) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;

    final topLeft = box.localToGlobal(Offset.zero);
    final bottom = topLeft.dy + box.size.height;
    final line = text ?? mascotLineAt(_tick++);

    _entry = OverlayEntry(
      builder: (ctx) => Positioned(
        left: DshMetrics.pagePad,
        right: DshMetrics.pagePad,
        // 放在猫**下面**：上面是顶栏与状态行，气泡会被挤到屏幕外。
        top: bottom + 4,
        child: _Bubble(text: line, onTap: _dismiss),
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

/// 那个"对话的样子"的气泡：一只小尾巴 + 圆角块，淡入 + 轻微放大。
class _Bubble extends StatelessWidget {
  const _Bubble({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 小尾巴：一个旋转 45° 的方块，指向上面的猫
            Padding(
              padding: const EdgeInsets.only(left: DshMetrics.pagePad),
              child: Transform.rotate(
                angle: 0.7854,
                child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: DshColors.surfaceStrong,
                      border: Border(
                        top: BorderSide(
                            color: DshColors.accent,
                            width: DshMetrics.borderWidth),
                        left: BorderSide(
                            color: DshColors.accent,
                            width: DshMetrics.borderWidth),
                      ),
                    )),
              ),
            ),
            // ⚠️ **不要用负 margin**：Flutter 3.x 的 `Container` 直接断言
            //    `margin.isNonNegative` —— 也就是 debug 构建下、气泡一画出来就抛异常
            //    （真机 release 没断言，所以这个洞一直没被发现；是 0.75 给彩蛋写
            //     测试时第一次真正构建气泡才抓到的）。
            //    原来这里是 `margin: EdgeInsets.only(top: -4)`，目的是让圆角块
            //    和上面那个 45° 的小尾巴重叠 4px；改成 `Transform.translate` 上移
            //    同样的距离 —— **绘制位置一样，但不参与布局测量**（这正是负 margin
            //    与它的区别），视觉与原来一致。
            Transform.translate(
              offset: const Offset(0, -4),
              child: Container(
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
              ),
            ),
          ],
        ),
      ),
    );
  }
}
