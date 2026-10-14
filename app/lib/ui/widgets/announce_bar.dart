import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/relative_time.dart';
import '../../i18n/dsh_i18n.dart';
import '../../local/broadcast_feed.dart';
import '../../local/dsh_runtime.dart' show DshHost;
import '../../state/app_settings.dart';
import '../theme/dsh_tokens.dart';

/// 首页那条**滚动公告栏**（用户 2026-10-15 第 3 条要求）。
///
/// ## 位置
///
/// 首页「v0.75」版本号**下面**那一行 —— 用户指定。
///
/// ## 它显示什么
///
/// 仓库根目录 `notice.json` 里的 `items`（见 `local/broadcast_feed.dart`）。
/// **拉不到就什么都不显示**（不占位、不写假话）：这条栏空着，首页跟以前一样。
///
/// ## 两种形态
///
///   * 文字比这条栏窄 → **居中静止显示**（不滚动：短句滚来滚去纯属晃眼）；
///   * 文字比栏宽 → 真的**横向滚动**（速度按文字长度定，长得越久滚得越慢，
///     读得完），到底之后无缝接上第二条。
///
/// 点一下 → 弹出全部条目（这是"信息栏"该有的第二层：一行只看得到一条，
/// 想看全得有个去处）。带 `url` 的条目给「查看详情」，交给系统浏览器。
class AnnounceBar extends StatefulWidget {
  const AnnounceBar({super.key, required this.settings});

  final AppSettings settings;

  /// 这条栏占的高度（dp）。**首页的布局计算要减掉它**，见 task_home_view.dart。
  static const double height = 26;

  @override
  State<AnnounceBar> createState() => _AnnounceBarState();
}

class _AnnounceBarState extends State<AnnounceBar>
    with SingleTickerProviderStateMixin {
  /// 当前滚动的是哪一条（多条时循环）
  int _index = 0;

  @override
  void initState() {
    super.initState();
    widget.settings.addListener(_onFeedChanged);
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onFeedChanged);
    super.dispose();
  }

  void _onFeedChanged() {
    if (!mounted) return;
    // 换了清单 → 从头显示（别停在上一份的第 3 条上，那看着像内容错乱）
    setState(() => _index = 0);
  }

  List<BroadcastItem> get _items => widget.settings.broadcastFeed?.items ?? const [];

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items.isEmpty) return const SizedBox(height: AnnounceBar.height);

    final item = items[_index % items.length];
    final text = item.text;
    final style = TextStyle(
      color: DshColors.text,
      fontSize: 11.5,
      height: 1.3,
    );

    return SizedBox(
      height: AnnounceBar.height,
      child: Semantics(
        button: true,
        label: context.tr('公告：{0}', [text]),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _openSheet(context),
          child: Container(
            decoration: BoxDecoration(
              // 三套皮肤都能看清：用强调色的低透明度底 + 一条细边
              color: DshColors.accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(DshMetrics.radius(6)),
              border: Border.all(
                color: DshColors.accent.withValues(alpha: 0.35),
                width: DshMetrics.pixelStyle ? 2 : 0.8,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                if (item.tag != null) ...[
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: DshColors.accent,
                      borderRadius: BorderRadius.circular(DshMetrics.radius(3)),
                    ),
                    child: Text(
                      item.tag!,
                      style: TextStyle(
                        color: DshColors.onAccent,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, box) => _Runnable(
                      // 宽度变了（转屏/字号）要重建那份动画，所以 key 里带上宽度
                      key: ValueKey<String>('${item.text}|${box.maxWidth}'),
                      text: text,
                      style: style,
                      available: box.maxWidth,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right,
                    size: 13, color: DshColors.textFaint),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openSheet(BuildContext context) {
    final feed = widget.settings.broadcastFeed;
    if (feed == null || feed.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: DshColors.surfaceStrong,
      builder: (_) => _AnnounceSheet(feed: feed),
    );
  }
}

/// 一行文字：装得下就居中静止，装不下就横向滚动。
class _Runnable extends StatefulWidget {
  const _Runnable({
    super.key,
    required this.text,
    required this.style,
    required this.available,
  });

  final String text;
  final TextStyle style;
  final double available;

  @override
  State<_Runnable> createState() => _RunnableState();
}

class _RunnableState extends State<_Runnable>
    with SingleTickerProviderStateMixin {
  AnimationController? _c;

  double _textWidth() {
    final tp = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return tp.width;
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = _textWidth();
    if (w <= widget.available) {
      // 装得下：居中静止（滚动是给长句用的，短句滚起来只有干扰）
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          widget.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: widget.style,
        ),
      );
    }

    // 装不下：真滚动。速度 ~28 dp/s，长句滚得久一点（读得完）。
    // 两份文字之间的空隙（首尾相接时它就是"一句话说完了停一下"的那点余地）。
    const gap = 40.0;
    final span = w + gap;
    final seconds = (span / 28).clamp(6, 60).toDouble();
    _c ??= AnimationController(
        vsync: this, duration: Duration(milliseconds: (seconds * 1000).round()))
      ..repeat();

    return ClipRect(
      // OverflowBox 是必须的：滚动那一行**比可用宽度宽**是它的正常状态，
      // 直接用 Row 会被 Flutter 判成 RenderFlex overflow（黄黑条）。
      child: OverflowBox(
        alignment: Alignment.centerLeft,
        maxWidth: double.infinity,
        child: AnimatedBuilder(
          animation: _c!,
          builder: (context, child) => Transform.translate(
            offset: Offset(-_c!.value * span, 0),
            child: child,
          ),
          // 画两份首尾相接 → 到底立刻接上，看起来是无缝循环
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.text,
                  maxLines: 1, softWrap: false, style: widget.style),
              const SizedBox(width: gap),
              Text(widget.text,
                  maxLines: 1, softWrap: false, style: widget.style),
            ],
          ),
        ),
      ),
    );
  }
}

/// 点开后的全部公告。
class _AnnounceSheet extends StatelessWidget {
  const _AnnounceSheet({required this.feed});

  final BroadcastFeed feed;

  @override
  Widget build(BuildContext context) {
    final fetched = feed.fetchedAt == null
        ? ''
        : relativeTimeLabel(feed.fetchedAt);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.tr('公告'),
              style: TextStyle(
                  color: DshColors.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            Text(
              // 如实写"什么时候同步的"：公告是**拉来的**，不是推送，
              // 用户有权知道手里这份有多新。
              fetched.isEmpty
                  ? context.tr('这份是本地缓存的公告，还没有和远端对上时间')
                  : context.tr('上次同步：{0}', [fetched]),
              style: TextStyle(color: DshColors.textFaint, fontSize: 10.5),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: feed.items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, i) {
                  final item = feed.items[i];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (item.tag != null) ...[
                            Container(
                              margin: const EdgeInsets.only(top: 1),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: DshColors.accent
                                    .withValues(alpha: 0.18),
                                borderRadius:
                                    BorderRadius.circular(DshMetrics.radius(4)),
                              ),
                              child: Text(item.tag!,
                                  style: TextStyle(
                                      color: DshColors.accent, fontSize: 9.5)),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Expanded(
                            child: Text(
                              item.text,
                              style: TextStyle(
                                  color: DshColors.text,
                                  fontSize: 13,
                                  height: 1.55),
                            ),
                          ),
                        ],
                      ),
                      if (item.url != null) ...[
                        const SizedBox(height: 6),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () async {
                              final url = item.url!;
                              await Clipboard.setData(
                                  ClipboardData(text: url));
                              // 交给系统浏览器/微信打开（原生 Intent，见 DshHost.openUrl）。
                              // 链接**同时**已复制到剪贴板 —— 有些 ROM 会拦外链，
                              // 那时用户手里至少还有一份能粘出去的地址。
                              await DshHost.openUrl(url);
                            },
                            icon: const Icon(Icons.open_in_new, size: 15),
                            label: Text(context.tr('查看详情（链接已复制）')),
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
