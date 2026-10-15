import 'dart:async';

import 'package:flutter/material.dart';

import '../widgets/dsh_panel.dart';


import '../../app_version.dart';
import '../../i18n/app_language.dart';
import '../../data/media_models.dart';
import '../../state/provider_keys.dart';
import '../../data/zen_channel.dart';
import '../../local/dsh_runtime.dart';
import '../../state/app_settings.dart';
import '../theme/dsh_tokens.dart';
import '../widgets/common.dart';
// 「运行日志」入口（导出到文件 / 系统分享）。日志里 API Key 会自动脱敏。
import '../widgets/send_log_button.dart';
// 「设置 → 模型」区的全部内容（我的模型 / 添加模型 / 轮换池）都在这个文件里。
// 本轮按用户 2026-10-05 的新方案**整段重写**，旧结构（当前模型卡 + 分组卡片 +
// 轮换组 + 长表单 + Agnes 单独一块）已经取消 —— 这里只负责把它挂到「模型」区。
import 'model_settings_panel.dart';
// 「关于」里的「更新说明」：整页展示各版本改了什么（数据在 data/changelog.dart）。
import 'release_notes_page.dart';
// 「检查更新」：拉远端版本清单、比版本、提示新版（L1）+ 应用内下载/校验/安装（L2）。
import '../../local/update_checker.dart';
// 更新包下载（断点续传 + sha256 校验 + 原子落盘）与「交给系统安装」那一步。
import '../../local/apk_downloader.dart';
import '../../local/apk_installer.dart';
// 更新源地址常量（默认那两条 + Release 页）。地址口径写在那个文件头部。
import '../../local/update_source.dart';
// 「上次检查：刚刚 / 12 分钟前」—— 与历史会话、会话列表共用同一个实现。
import '../../data/relative_time.dart';
// 打开下载页失败时，把异常翻成中文人话（与模型面板同一份实现）。
import '../../data/api_error_text.dart';

import '../../i18n/dsh_i18n.dart';

/// 「设置」Tab（底部导航第 5 项，原「项目空间」位置）。
///
/// 分区：外观 / 模型 / 插件 / 文件地址 / 关于。
///
/// ## 「模型」区（本轮重写，用户 2026-10-05 的原话是"取消现有的"）
///
/// 现在只有三块，顺序就是用户给的顺序：
///   1. **我的模型** —— 内置厂家的下拉卡片，顺序固定
///      `Agnes（免费）→ DeepSeek → Command（聚合）→ MiMo → LongCat`
///      （LongCat 是真实内置厂家，没被点名但保留在最后一张卡）。每张卡展开后是
///      「介绍 → 去注册 → 获取模型 → 只需要填 API Key → 填 Key → 测试并保存」；
///      内置厂家的地址不让用户填。
///   2. **添加模型** —— 用户自己加别的大模型（允许手填 Base URL），默认收起。
///   3. **轮换池**（旧「轮换组」改名）—— 说清它是干什么的，也是下拉菜单；
///      展开后能看到所有已注册的模型，点一下就把它放进池子。
///
/// 实现全在 [ModelSettingsPanel]（`ui/pages/model_settings_panel.dart`）里，
/// 本文件只负责其余四块 + 把面板挂上去。这样做的原因很实在：这四块与模型无关，
/// 每次改模型都要在同一个 3800 行的文件里外科手术，很容易碰坏它们。
///
/// 说实话的地方（**没验证过的部分**）：轮换池那一块只在界面上验证了
/// "展开、点模型进池、落盘、overlay 里出现 `rotate` 这个厂家"，
/// **没有**在真机上制造一次 429 去验证"真的会切换下一个成员"
/// （那需要能稳定返回 429 的上游，模拟器上做不到）。
class SettingsTab extends StatefulWidget {
  const SettingsTab({
    super.key,
    required this.runtime,
    required this.appSettings,
    required this.onModelChanged,
    this.onOpenExperts,
    this.onOpenMemory,
    this.refreshTick = 0,
  });

  final DshRuntime runtime;
  final AppSettings appSettings;

  /// 模型变更后：重写 overlay + 重建 runtime（由 AppShell 提供）
  final Future<void> Function() onModelChanged;

  /// 打开「专家」整页（用户 2026-10-09 要求：专家从底部 Tab 挪进设置）。
  final Future<void> Function()? onOpenExperts;

  /// 打开「记忆」整页（用户自己写、每个新会话自动注入）。
  final Future<void> Function()? onOpenMemory;

  /// 底部 Tab 切到本页时的刷新计数（见 app_shell 的 `_pageTicks`）。
  final int refreshTick;

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  /// 模型配置被改动后自增，用来让**两个**模型面板都重读磁盘。
  ///
  /// 为什么需要：轮换池被单独做成了一个板块（`ModelSettingsPanel` 被实例化了两次，
  /// 一个只画模型、一个只画池）。在「模型」板块里加的模型，如果不通知另一边，
  /// 「模型轮换池」板块会一直显示旧清单 —— 那就成了"两个真相"。
  final ValueNotifier<int> _modelTick = ValueNotifier<int>(0);

  @override
  void dispose() {
    _modelTick.dispose();
    super.dispose();
  }

  Future<void> _onModelChanged() async {
    await widget.onModelChanged();
    if (mounted) _modelTick.value++;
  }

  /// 两个面板共用的刷新计数：外部（切页）+ 内部（本页改了模型）。
  int get _tick => widget.refreshTick + _modelTick.value;

  @override
  Widget build(BuildContext context) {
    final runtime = widget.runtime;
    final settings = widget.appSettings;
    final onModelChanged = _onModelChanged;
    final refreshTick = _tick;
    return Column(
      children: [
        // 皮肤是运行时变量：这里不能 const（const 实例换肤时会被原样复用、颜色不刷新）
        // ignore: prefer_const_constructors
        DshPageHeader(title: context.tr('设置')),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              DshMetrics.pagePad,
              6,
              DshMetrics.pagePad,
              28,
            ),
            children: [
              // ── 六个分区**统一收成「下拉」**（用户要求：外观、插件也做成下拉）。
              //    设置页原本一长条，收起后一屏能看全；点标题才展开。
              //
              // 「检查更新」**放第一位、默认展开**（2026-10-13 加）：
              //   它是这一页里唯一跟"这台手机上的 App 本身"有关的板块，而且
              //   "有新版本"这件事必须一眼看得见 —— 收进下拉等于没做
              //   （用户 2026-10-13 的口径是"设置页顶部一张卡片"）。
              DshCollapsibleSection(
                title: context.tr('检查更新'),
                initiallyOpen: true,
                child: _card(
                    child: _UpdateSection(settings: settings, runtime: runtime)),
              ),
              const SizedBox(height: 10),
              DshCollapsibleSection(
                title: context.tr('外观'),
                child: _card(child: _appearanceSection(context, settings)),
              ),
              const SizedBox(height: 10),
              DshCollapsibleSection(
                // 用户要求：原来的「模型」改名为「云端大模型」——
                // 因为现在还有"本机跑的模型"，两者是并列的两类，名字必须能区分。
                title: context.tr('云端大模型'),
                child: _card(
                  child: ModelSettingsPanel(
                    filesDir: runtime.filesDir,
                    onModelChanged: onModelChanged,
                    refreshTick: refreshTick,
                    // 轮换池单独成了一个板块（见下方「模型轮换池」），这里不画它。
                    showPool: false,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              // 「本地大模型（测试）」这一整段**早已挪走**（用户 2026-10-09），
              // 而它挪去的那一页（底部导航第 2 项「本地大模型」）**又于 0.70 撤下**
              // （用户 2026-10-12：「本地大模型这一块不是太成熟，把这个功能删掉先」
              //  +「知识库也一并清理掉」；做法是**撤入口、留代码**，可逆）。
              // ⚠️ 所以现在的情况是：`local_model_home_page` / `ondevice_models_page`
              //    / `local_chat_page` / `kb_page` 这四页**都没有入口可达**了 ——
              //    （唯一还推得动它们的是一条"取图被中断后把本地对话推回来"的恢复路径，
              //     而它要求"上一次是从本地对话出发去取图"，没有入口就不可能满足）。
              //    代码与引擎都留在原位。**不要**再在设置页里加回入口 —— 那是用户的决定；
              //    要恢复的话是把 bottom_nav 那一项加回来（见该文件的下标说明）。
              const SizedBox(height: 10),
              // 「图像 / 视频模型」—— 用户 2026-10-11 的设计问题：
              // 「模型页是否增加一个图形和视频的设置页，用户设置好后可以在影视工具里选择
              // 图形和视频大模型」→ 加，且与会话模型**分开存**（见 data/media_models.dart）。
              DshCollapsibleSection(
                title: context.tr('图像 / 视频模型'),
                child: _card(child: _MediaModelsSection(runtime: runtime)),
              ),
              const SizedBox(height: 10),
              // 「免费模型（无需 Key）」—— 用户 2026-10-11 要求把它做成
              // **设置里显式开启的通道**（默认关）。
              DshCollapsibleSection(
                title: context.tr('免费模型（无需 Key）'),
                child: _card(
                  child: _ZenChannelBlock(
                    runtime: runtime,
                    settings: widget.appSettings,
                    onModelChanged: onModelChanged,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              // 用户要求：轮换池改名为「模型轮换池」，并**单独一个板块**。
              DshCollapsibleSection(
                title: context.tr('模型轮换池'),
                child: _card(
                  child: ModelSettingsPanel(
                    filesDir: runtime.filesDir,
                    onModelChanged: onModelChanged,
                    refreshTick: refreshTick,
                    // 只画轮换池：标题与折叠交给外层 _CollapsibleSection。
                    showModels: false,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              // 「专家」从底部 Tab 挪进来了（用户 2026-10-09）。
              // 这里只放入口：真正的整页由 AppShell 推入（它才有工作区与回调）。
              DshCollapsibleSection(
                title: context.tr('专家'),
                child: _card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      DshRichText(
                        context.tr('321 名专家 / 22 个分区（来自专家库）。'
                            '开启某位专家后，他的摘要会写进 AGENTS.md，'
                            'DSH 会在每个新会话的第一个请求前注入模型上下文 ——'
                            '**会占上下文**，所以别一次开太多。'),
                        style: TextStyle(
                            color: DshColors.textFaint,
                            fontSize: 11,
                            height: 1.45),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: widget.onOpenExperts == null
                              ? null
                              : () => widget.onOpenExperts!(),
                          icon: const Icon(Icons.auto_awesome, size: 16),
                          label: Text(context.tr('打开专家中心')),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              // 「记忆」：用户自己写的话，与专家开关共用 AGENTS.md 这条注入通道。
              // 单独一个板块（不塞进「专家」里）—— 两者是不同来源的内容：
              // 专家是"选一个现成角色"，记忆是"我自己写的偏好"。
              DshCollapsibleSection(
                title: context.tr('记忆'),
                child: _card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      DshRichText(
                        context.tr('在这里写下你希望模型**长期记住**的事（例如"回答用中文、'
                            '先给结论"）。它会写进 AGENTS.md，DSH 在**每个新会话的第一个请求前**'
                            '注入模型上下文；**对已经打开的会话不生效**，要新建会话。'),
                        style: TextStyle(
                            color: DshColors.textFaint, fontSize: 11, height: 1.45),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: widget.onOpenMemory == null
                              ? null
                              : () => widget.onOpenMemory!(),
                          icon: const Icon(Icons.psychology_outlined, size: 16),
                          label: Text(context.tr('打开记忆')),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              DshCollapsibleSection(
                title: context.tr('插件'),
                child: _card(child: _pluginsSection()),
              ),
              const SizedBox(height: 10),
              DshCollapsibleSection(
                title: context.tr('手机权限'),
                child: _card(child: _PermissionsSection(settings: widget.appSettings)),
              ),
              const SizedBox(height: 10),
              // 用户要求：原来的「关于」改名「文件地址」（它本来列的就是各种路径），
              // 「关于」另起一块，放求关注文案 + 公众号二维码 + 公众号 ID。
              DshCollapsibleSection(
                title: context.tr('文件地址'),
                child: _card(child: _locationsSection()),
              ),
              const SizedBox(height: 10),
              // 「关于」**常驻展开、不做下拉**（用户要求：关于不能收缩）。
              // 它放的是公众号二维码、联系方式这类"想让人一眼看到"的东西，
              // 收进下拉反而要多点一次。标题样式与可折叠的那些保持一致
              // （同样加粗加大），所以视觉上仍是一组。
              // 用户反馈：标题与这张卡贴得太紧。改用 DshStaticSection ——
              // 它与可折叠板块共用同一套标题内边距（10/10），节奏才对得上。
              DshStaticSection(
                title: context.tr('关于'),
                child: DshGlassCard(child: _aboutSection(context)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 一张「玻璃卡」：半透明面板 + 1px 细边 + 圆角 16 + 柔和光晕。
  ///
  /// 装饰统一走 [DshColors.panel]，这样浅色（半透明白玻璃）与深色
  /// （更亮的半透明层）是同一套写法，只有令牌不同。
  /// 玻璃卡：统一走共享组件 `DshGlassCard`（与「本地大模型」页同一份实现）。
  Widget _card({required Widget child}) => DshGlassCard(child: child);

  // ------------------------------------------------------------------ 外观

  /// 「外观」：主题三按钮（浅色 / 深色 / 自定义占位）+ 字号。
  ///
  /// 主题按钮的选中态用网站的 `--grad`（青 #0891b2 → 紫 #7c3aed）+ 光晕；
  /// 未选中态是半透明面板 + 1px 细边。**「自定义」不是一个状态**：它不参与
  /// 选中判断、不写盘，点了只如实说明"还没做"。
  Widget _appearanceSection(BuildContext context, AppSettings settings) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _rowLabel(context.tr('主题'), context.tr('点一下立即生效，重启后保持')),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final p in DshPalettes.all)
              _themeButton(
                label: p.label,
                selected: settings.skinId == p.id,
                onTap: () => settings.setSkin(p.id),
              ),
            _themeButton(
              label: AppSettings.customLabel,
              selected: false,
              placeholder: true,
              onTap: () => _showCustomPending(context),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          // 用户要求：这里的表述只说**本 App 自己**的两套皮肤长什么样，
          // 不出现"对齐某网站/参考某处"这种字眼（那是代码注释里的事，
          // 不该出现在用户读的文案里）。
          context.tr(
              '浅色：白底玻璃面板 + 青紫点缀，白天和强光下看得清。深色：同一套强调色的深色面，'
              '面板换成更亮的半透明层，夜里不刺眼。像素：近黑底 + 高饱和的薄荷/洋红/琥珀，'
              '并且**圆角全部变成直角**（不只是换色）。'),
          style:
              TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.6),
        ),
        const SizedBox(height: 4),
        // 把"到底落到哪个键上"如实写出来，等宽字体方便核对
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: context.tr('已落盘：'),
                style: TextStyle(color: DshColors.textFaint, fontSize: 10.5),
              ),
              TextSpan(
                text: 'dsh_theme_skin=${settings.skinId}',
                style: DshFonts.code(color: DshColors.textDim, fontSize: 10.5),
              ),
              TextSpan(
                text: context.tr('　「自定义」是占位：还没做，点了会如实说明，不会把主题切到一个不存在的状态。'),
                style: TextStyle(color: DshColors.textFaint, fontSize: 10.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Divider(height: 1, thickness: 1, color: DshColors.line),
        const SizedBox(height: 16),
        _rowLabel(context.tr('字号'), context.tr('全局生效，改完立即应用')),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final o in AppSettings.kTextScales)
              _chip(
                label: o.label,
                selected: (settings.textScale - o.scale).abs() < 0.001,
                onTap: () => settings.setTextScale(o.scale),
              ),
          ],
        ),
        const SizedBox(height: 18),
        Divider(height: 1, thickness: 1, color: DshColors.line),
        const SizedBox(height: 16),
        _rowLabel(context.tr('思考过程'),
            context.tr('模型"想"的那一段怎么显示（它的语言由模型决定）')),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final m in AppSettings.kThinkingModes)
              _chip(
                label: m.label,
                selected: settings.thinkingModeId == m.id,
                onTap: () => settings.setThinkingMode(m.id),
              ),
          ],
        ),
        const SizedBox(height: 8),
        for (final m in AppSettings.kThinkingModes)
          if (settings.thinkingModeId == m.id)
            Text(
              context.tr(m.note),
              style: TextStyle(
                  color: DshColors.textFaint, fontSize: 11, height: 1.5),
            ),
        const SizedBox(height: 6),
        Text(
          // 如实说明：思考的语言**我们管不了**，只有"不显示"能保证看不到英文。
          context.tr('思考用哪种语言是模型自己决定的（国内模型多数用英文思考），'
              '我们只能"请求它用中文"，不能保证 —— 所以想彻底不看到英文思考，'
              '选「不显示」是唯一的硬办法。'),
          style: TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.6),
        ),
        const SizedBox(height: 4),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: context.tr('已落盘：'),
                style: TextStyle(color: DshColors.textFaint, fontSize: 10.5),
              ),
              TextSpan(
                text: 'dsh_thinking_mode=${settings.thinkingModeId}',
                style: DshFonts.code(color: DshColors.textDim, fontSize: 10.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Divider(height: 1, thickness: 1, color: DshColors.line),
        const SizedBox(height: 16),
        _rowLabel(context.tr('语言'), context.tr('切界面文案，点一下立即生效、重启后保持')),
        const SizedBox(height: 10),
        // 按钮上写的是**各自的母语名**（中文 / English / 日本語 / 한국어）：
        // 界面已经切成日文时，韩国用户仍能一眼找到「한국어」——
        // 理由写在 i18n/app_language.dart 的文档里。
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final l in AppLanguage.values)
              _chip(
                label: l.nativeName,
                selected: settings.language == l,
                onTap: () => settings.setLanguage(l),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          // 这条边界必须写在用户看得见的地方：切了语言之后电脑端回传的内容
          // 仍是中文，不解释清楚会被当成"没做完"。
          context.tr(
              '切的是 App 自己画的界面：导航、设置、按钮、内置提示。电脑上那台 DSH 回传的内容 —— 会话消息、技能名、专家库、后端报错 —— 是它给的，保持原文，App 不替它决定用什么语言。'),
          style:
              TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.6),
        ),
        const SizedBox(height: 4),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: context.tr('已落盘：'),
                style: TextStyle(color: DshColors.textFaint, fontSize: 10.5),
              ),
              TextSpan(
                text: 'dsh_ui_language=${settings.language.id}',
                style: DshFonts.code(color: DshColors.textDim, fontSize: 10.5),
              ),
              TextSpan(
                text: context.tr('　当前语言：{0}（{1}）',
                    [settings.language.nativeName, settings.language.zhName]),
                style: TextStyle(color: DshColors.textFaint, fontSize: 10.5),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 主题按钮。选中 = 青紫渐变填充 + 光晕；未选中 = 半透明面板 + 细边。
  Widget _themeButton({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    bool placeholder = false,
  }) {
    final fg = selected
        ? DshColors.onAccent
        : (placeholder ? DshColors.textFaint : DshColors.text);
    return Semantics(
      button: true,
      selected: selected,
      label: placeholder ? context.tr('{0}（占位，还没做）', [label]) : label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.controlRadius)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? null : DshColors.surfaceHigh,
            gradient: selected ? DshColors.grad : null,
            borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.controlRadius)),
            border: Border.all(
              color: selected ? Colors.transparent : DshColors.line,
              width: 1,
            ),
            boxShadow: selected ? DshColors.accentShadow : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  /// 「自定义」是占位：**不做假开关**。点了只如实说明，不改皮肤、不落盘。
  void _showCustomPending(BuildContext context) {
    debugPrint('[dsh-settings-tab] 主题「自定义」是占位、未实现 —— 不切换皮肤');
    // 这条 SnackBar 是**每次点击现造**的（不是常驻组件），所以 const 不会导致
    // 换肤不刷新；文案本身也是常量。
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(AppSettings.customPendingNote)),
      );
  }

  // ------------------------------------------------------------------ 插件

  Widget _pluginsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.extension_outlined,
                size: 16, color: DshColors.textFaint),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                context.tr('安装插件'),
                style: TextStyle(color: DshColors.textDim, fontSize: 13.5),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: DshColors.surfaceHigh,
                borderRadius: BorderRadius.circular(DshMetrics.radius(6)),
                border: Border.all(color: DshColors.divider, width: 0.8),
              ),
              child: Text(
                context.tr('暂未开放'),
                style: TextStyle(color: DshColors.textFaint, fontSize: 11),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          context.tr('插件安装暂未开放：插件可以执行任意代码，要先做完安全校验与回滚机制，做完再放出可点入口。'),
          style:
              TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.5),
        ),
      ],
    );
  }

  // ------------------------------------------------------------- 文件地址

  /// 「文件地址」：把运行时各处**落盘位置**列全，方便用户自己去文件管理器里找。
  ///
  /// 用户要求把原来的「关于」改名成这个 —— 它原本列的就是路径，改名后语义准确了。
  Widget _locationsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 这些全是**真实路径**，一律走等宽字体族（网站对路径/命令都是等宽排版）
        _kv(context.tr('运行时目录'), widget.runtime.nodeHome, mono: true),
        _kv(context.tr('工作目录'), widget.runtime.filesDir, mono: true),
        _kv(context.tr('会话记录'), '${widget.runtime.nodeHome}/sessions',
            mono: true),
        _kv(context.tr('技能目录'), '${widget.runtime.nodeHome}/skills',
            mono: true),
        _kv(context.tr('附件目录'), '${widget.runtime.filesDir}/attachments',
            mono: true),
        _kv(context.tr('工具脚本'), '${widget.runtime.filesDir}/tools', mono: true),
        _kv(context.tr('模型配置'), widget.runtime.overlayPath, mono: true),
        _kv(context.tr('模型清单'), '${widget.runtime.filesDir}/models.json',
            mono: true),
        const SizedBox(height: 8),
        DshRichText(
          context.tr(
              '以上都在 App 私有目录里，其它应用读不到；长按可以复制。「模型清单」里存的是厂家/模型/轮换池的结构，**不含任何 API Key**（Key 只在系统安全区）。'),
          style:
              TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.5),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ 关于

  /// 「关于」：求关注文案 + 公众号二维码 + 公众号 ID。
  ///
  /// ⚠️ 下面那段话是用户**原话**，逐字照抄（含 `：）`）—— 不要改写、不要"优化"语气、
  /// 不要补标点。用户改过一次文案，以这里最新的为准。
  Widget _aboutSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr('做这个主要是下班晚上才有时间做，而且本人公众号一直没有人关注，要求不多：），麻烦大家点个关注就行'),
          style: TextStyle(color: DshColors.text, fontSize: 13.5, height: 1.9),
        ),
        const SizedBox(height: 16),
        // 皮肤是运行时变量：这一处不能 const（const 实例换肤时会被原样复用、颜色不刷新）
        // ignore: prefer_const_constructors
        Center(child: _QrBlock()),
        const SizedBox(height: 6),
        // 把"长按能干什么"写出来 —— 手势是隐式的，不写没人知道（用户第 8 条要的
        // 是"长按弹出扫描"，那就得先让人知道可以长按）。
        Text(
          context.tr('长按上面的二维码 → 直接唤起微信扫一扫'),
          style: TextStyle(color: DshColors.textFaint, fontSize: 11),
        ),
        const SizedBox(height: 8),
        Center(
          child: SelectableText(
            context.tr('公众号 ID：paopaocat888'),
            style: TextStyle(
              color: DshColors.accent,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 18),
        _kv(context.tr('应用名'), context.tr('泡泡猫的Deepseek harness')),
        _kv(context.tr('版本'), kAppVersion),
        const SizedBox(height: 2),
        // ⚠️ **CC BY-SA 4.0 的署名**（用户 2026-10-12 定：「加：在「关于」里写一行
        //    「内容来自第三方社区语料，许可 CC BY-SA 4.0」」）。
        //
        //    为什么必须有：知识库那份语料是 CC BY-SA 4.0，这个许可**要求署名**。
        //    以前界面上只写「许可：CC BY-SA 4.0」—— 那是"声明了许可"但**没署名**，
        //    合规上差一步。
        //
        //    为什么这么写（不点数据源名字）：同一天你的要求是
        //    「把知识库的中文维基百科字样消除，就写知识库三个字就行」——
        //    所以署名只说"第三方社区语料"，**不写具体是哪一份**。这两条不冲突：
        //    该保留的是"署名 + 许可"，该去掉的是"点名数据源"。
        Padding(
          padding: const EdgeInsets.only(bottom: 7),
          child: Text(
            context.tr('知识库内容来自第三方社区语料，依 CC BY-SA 4.0 许可使用。'),
            style: TextStyle(
                color: DshColors.textFaint, fontSize: 11, height: 1.5),
          ),
        ),
        const SizedBox(height: 6),
        // 「更新说明」入口（用户原话：关于那一块加个更新说明的按钮，点开能看到各个版本，
        // 点版本号就看到那版改了什么）。点开是**整页**而不是弹层：版本多了弹层会被憋住。
        // 记录本身是写死的文字（`data/changelog.dart`），不联网、不暗示"检查更新"。
        _aboutTile(
          icon: Icons.history,
          title: context.tr('更新说明'),
          note: context.tr('每个版本改了什么（当前 v{0}）', [kAppVersion]),
          onTap: () => _openReleaseNotes(context),
        ),
        const SizedBox(height: 10),
        // 「运行日志」入口（用户原话：设置页加个按钮生成日志，方便看运行中哪里出错）。
        // 自包含组件：内含「导出到文件」+「系统分享」两个出口、脱敏说明、以及没有
        // 文件选择器/分享界面时的退路（显示绝对路径 + 一键复制）。日志里 **API Key
        // 一律脱敏**（唯一入口式，见 lib/local/diagnostics_log.dart）。
        //
        // ⚠️ 这里**故意不用 `const`**：const 出来的组件实例在换肤（浅色/深色）时会被
        // Flutter 原样复用、跳过重建，颜色就不会刷新 —— 本项目多处踩过这个坑。
        // ignore: prefer_const_constructors
        SendLogButton(),
        const SizedBox(height: 12),
        Text(
          context.tr('基于 DeepSeek Harness 的本地运行时，除模型接口外不依赖任何服务器。'),
          style:
              TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.5),
        ),
        const SizedBox(height: 12),
        // 第三方组件与许可：**必须放在用户能读到的地方**。
        //
        // 为什么非写不可：App 里随包了一个 ffmpeg（口播/短剧要用），它是
        // **GPLv2+** 的（`--enable-gpl --enable-libx264`，libx264 本身是 GPL）。
        // GPL 要求随二进制给出许可与相应源码的获取方式 —— 藏在仓库的文档里不算，
        // 装机的人要能在 App 里看到。这一段就是那个"能看到的地方"。
        _aboutTile(
          icon: Icons.gavel_outlined,
          title: context.tr('第三方组件与许可'),
          note: context.tr('随包的 ffmpeg 是 GPLv2+（含 libx264）'),
          onTap: () => _showLicenses(context),
        ),
      ],
    );
  }

  /// 「第三方组件与许可」—— 内容与 `docs/第三方许可.md` 一致。
  ///
  /// ⚠️ 加组件就要同步加这里：GPL 类组件不写等于不合规（详情见那个文档）。
  void _showLicenses(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.tr('第三方组件与许可')),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SelectableText(
                context.tr('本 App 随包包含以下第三方组件：\n'
                    '\n'
                    '· ffmpeg 7.1（含 libx264）—— 用于口播/短剧的拼接、转码、混音、加字幕。'
                    '以 GPLv2 或更高版本（GPLv2+）授权，因为启用了 libx264（GPL）。\n'
                    '  许可全文：https://www.gnu.org/licenses/old-licenses/gpl-2.0.html\n'
                    '  相应源码：https://ffmpeg.org/download.html 与 '
                    'https://code.videolan.org/videolan/x264\n'
                    '  本 App 未修改其源码，只做了针对 Android arm64 的编译'
                    '（构建参数随仓库的 install/build-ffmpeg-android.sh 一并提供）。\n'
                    '\n'
                    '· frontend-design 与 discernment-nudge —— 两个随包「技能」'
                    '（写给模型看的流程说明），搬自 Anthropic 官方开源技能库'
                    '（github.com/anthropics/skills），以 Apache-2.0 授权。\n'
                    '  本 App 已修改其文字：翻译成中文，并针对手机端的执行环境改写'
                    '（本机没有 python；原版里"截图回看"这类做不到的步骤已删掉）。\n'
                    '  许可全文随包提供：assets/skills/frontend-design/LICENSE.txt 与 '
                    'assets/skills/discernment-nudge/LICENSE.txt\n'
                    '  许可全文链接：https://www.apache.org/licenses/LICENSE-2.0\n'                    '\n'
                    '· novel-to-game / novel-game-analyze / game-concept / game-world-design / '
                    'game-art-direction / game-build / game-qa（七个随包技能）—— 来自 NovelToGame v0.4.0'
                    '（zenstory.ai 的「有原著依据的小说改编游戏工作流」），以 MIT 授权。\n'
                    '  本 App 只改写了两处：技能简介改写成一行中文、正文开头加署名区块；'
                    '正文与参考文件一字未改。\n'
                    '  许可全文随包提供：assets/skills/novel-to-game/LICENSE.txt\n'                    '\n'
                    '· diagram-design —— 画图表技能（44 种图型，出自包含的 HTML + 内联 SVG），'
                    '来自 diagram-design v2.6（github.com/cathrynlavery/diagram-design），以 MIT 授权。\n'
                    '  本 App 只随包了必需部分（技能正文 + 方法文档 + 五套模板 + 图标）；'
                    '上游的 211 个示例图与 5 个 python 脚本没有随包（原因写在技能正文的署名区块里）。\n'
                    '  许可全文随包提供：assets/skills/diagram-design/LICENSE.txt\n'
                    '\n'
                    '· Android 运行时自带的系统组件（按 Android 系统许可）。\n'
                    '· DeepSeek Harness 及各 dsh-* 子包（按各自许可）。'),
                style: const TextStyle(fontSize: 12, height: 1.6),
              ),
              // ⚠️ 2026-10-13 起，新组件**单独成块**，不再往上面那一大段里追加：
              //    那一整段是**一个 i18n key**（已经翻成三语），往里加一句就得
              //    整段重译；拆开之后每个组件一个 key，改动小、也好核对。
              const SizedBox(height: 12),
              SelectableText(
                context.tr('本机离线配音（2026-10-13 新增，随包）\n'
                    '\n'
                    '· sherpa-onnx 1.13.8 —— 本机离线配音的推理引擎（语音合成）。'
                    '以 Apache-2.0 授权，https://www.apache.org/licenses/LICENSE-2.0\n'
                    '  源码与文档：https://github.com/k2-fsa/sherpa-onnx\n'
                    '  本 App 未修改其源码，直接用官方发布的 arm64 预编译库。\n'
                    '\n'
                    '· onnxruntime —— sherpa-onnx 的推理后端（随包的 libonnxruntime.so）。'
                    '以 MIT 授权，源码：https://github.com/microsoft/onnxruntime\n'
                    '\n'
                    '· seek-bzip 2.0.0 —— 纯 JS 的 bzip2 解压（用来在手机上解模型压缩包，'
                    '因为 Android 既没有 tar 也没有 bzip2）。以 MIT 授权，'
                    '源码**原样**随包提供：assets/toolbox/vendor/seek-bzip/（含 LICENSE）\n'
                    '\n'
                    '· 语音模型 vits-icefall-zh-aishell3 —— **不随包**，由你在 App 里'
                    '按需下载（约 32 MB）。它来自 icefall（Apache-2.0）'
                    '（https://github.com/k2-fsa/icefall），基于 aishell3 数据集训练。'
                    '下载前界面上会写明体积与来源。'),
                style: const TextStyle(fontSize: 12, height: 1.6),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(context.tr('知道了')),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- 小部件工厂

  /// 「关于」里的一个可点条目（图标 + 标题 + 说明 + 右箭头）。
  ///
  /// 玻璃面板 + 1px 细边，和别的控件同一套观感；整行可点，读屏也是一句完整的话。
  Widget _aboutTile({
    required IconData icon,
    required String title,
    required String note,
    required VoidCallback onTap,
  }) {
    return Semantics(
      button: true,
      label: '$title：$note',
      // ⚠️ 这里用 container（**不是 excludeSemantics**）：实测在「关于」这张卡里，
      // 加了 excludeSemantics 反而会让这个节点被并进父节点，uiautomator 里
      // 就找不到「更新说明」这一项了（点都点不到）。container 让它稳稳落成独立节点。
      container: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.controlRadius)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
          decoration: BoxDecoration(
            color: DshColors.surfaceHigh,
            borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.controlRadius)),
            border: Border.all(color: DshColors.line, width: 1),
          ),
          child: Row(
            children: [
              Icon(icon, size: 16, color: DshColors.accent),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: DshColors.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      note,
                      style: TextStyle(
                        color: DshColors.textFaint,
                        fontSize: 11,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: DshColors.textDim),
            ],
          ),
        ),
      ),
    );
  }

  /// 打开「更新说明」整页。
  ///
  /// ⚠️ [ReleaseNotesPage] 的 build 里读 `DshColors`，所以这里**不能**写成
  /// `const ReleaseNotesPage()`：const 实例在换肤重建时会被原样复用，皮肤色不刷新
  /// （项目里已有先例，见 `_QrBlock` 调用点）。
  // 打开「本地大模型」整页的方法**已移除**（用户 2026-10-09）：
  // 它现在是底部导航第 2 项那一页的「设置」按钮（见 local_model_home_page.dart）。

  void _openReleaseNotes(BuildContext context) {
    debugPrint('[dsh-settings-tab] 打开「更新说明」（当前版本 $kAppVersion）');
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        // ignore: prefer_const_constructors
        builder: (_) => ReleaseNotesPage(),
      ),
    );
  }

  Widget _rowLabel(String title, String note) => Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            title,
            style: TextStyle(
              color: DshColors.text,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              note,
              style: TextStyle(color: DshColors.textFaint, fontSize: 11),
            ),
          ),
        ],
      );

  /// 小胶囊（字号档位、服务商）。**选中态用网站的 `--grad` 青→紫渐变** ——
  /// 这是"当前项"的统一表达（与主题按钮、底部导航选中项同一套）。
  Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.controlRadius)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? null : DshColors.surfaceHigh,
            gradient: selected ? DshColors.grad : null,
            borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.controlRadius)),
            border: Border.all(
              color: selected ? Colors.transparent : DshColors.line,
              width: 1,
            ),
            boxShadow: selected ? DshColors.accentShadow : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? DshColors.onAccent : DshColors.textDim,
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }

  /// 一行「键 : 值」。**路径 / route / model id / 命令类文本传 [mono] = true**，
  /// 走等宽字体族 [DshFonts.code]（网站对代码、路径、命令都是等宽排版）。
  Widget _kv(String key, String value, {bool mono = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 78,
              child: Text(
                key,
                style: TextStyle(color: DshColors.textFaint, fontSize: 12),
              ),
            ),
            Expanded(
              child: SelectableText(
                value,
                style: mono
                    ? DshFonts.code(
                        color: DshColors.textDim,
                        fontSize: 11.5,
                        height: 1.45,
                      )
                    : TextStyle(
                        color: DshColors.textDim, fontSize: 12, height: 1.4),
              ),
            ),
          ],
        ),
      );
}

/// 公众号二维码。
///
/// ⚠️ **必须衬在白底上**：App 是深色的，而二维码在深底上对比度不够，
/// 很多扫码器读不出来（尤其中间还带公众号头像的那种）。
///
/// 图片放在 `assets/images/wechat_qr.png`（`pubspec.yaml` 已登记整个
/// `assets/images/` 目录，所以放进去重新构建即可，不用改配置）。
/// 没放图时**如实显示占位文字**，不画一个假二维码骗人。
/// 「手机权限」分区（用户意见⑦）。
///
/// 做成独立的 StatefulWidget：设置页本身是 StatelessWidget，而权限状态要异步读、
/// 申请完还要刷新 —— 把状态关在这一个小部件里，不用把整页改成有状态。
///
/// 三档如实表达，**不承诺做不到的事**：
///   ① 当前状态（逐项显示系统给了没有）；
///   ② 「申请常用权限」—— 麦克风 / 定位 / 相册 / 通知，弹真正的系统授权框；
///   ③ 特殊权限 —— 必须去系统页面**手动**打开，应用无法自行授予，
///      Android 也没有「一键全开」的 API。
///
/// ⚠️ 这一段只讲 **Android 系统权限**，与最下面那行「DSH 沙箱模式」是两件事：
/// 后者决定 Agent 能用哪些工具，跟手机给不给权限无关。
class _PermissionsSection extends StatefulWidget {
  const _PermissionsSection({required this.settings});

  /// 用来读写「允许打开的应用」白名单（只有用户能放行，模型无权）。
  final AppSettings settings;

  @override
  State<_PermissionsSection> createState() => _PermissionsSectionState();
}

class _PermissionsSectionState extends State<_PermissionsSection> {
  /// 权限键 → 中文名。**必须与 MainActivity.permissionGroups() 的键保持一致**。
  static Map<String, String> get _names => {
        'microphone': tr('麦克风'),
        'location': tr('定位'),
        'photos': tr('相册'),
        'notifications': tr('通知'),
      };

  static Map<String, String> get _stateText => {
        'granted': tr('已允许'),
        'denied': tr('未允许（还能再申请）'),
        'permanently-denied': tr('已拒绝 · 只能去系统设置里开'),
        'not-declared': tr('这个 Android 版本不需要'),
      };

  Map<String, String>? _status;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final r = await DshHost.permissionStatus();
      if (!mounted) return;
      setState(() {
        _status = r;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _request() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final after = await DshHost.requestPermissions(_names.keys.toList());
      if (!mounted) return;
      setState(() => _status = after);
      final missing = <String>[];
      for (final k in _names.keys) {
        if ((after[k] ?? '') != 'granted' &&
            (after[k] ?? '') != 'not-declared') {
          missing.add(_names[k] ?? k);
        }
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(missing.isEmpty
              ? context.tr('该给的都给了')
              : context.tr('还没允许：{0}', [missing.join('、')])),
        ),
      );
    } catch (e) {
      messenger
          .showSnackBar(SnackBar(content: Text(context.tr('申请失败：{0}', [e]))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openAppSettings() async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await DshHost.openAppSettings();
    if (!ok) {
      messenger.showSnackBar(SnackBar(content: Text(tr('没能打开系统设置页'))));
    }
  }

  /// 跳系统的「特殊权限」页。
  ///
  /// ⚠️ 失败时**必须给手动路径**（2026-10-11 用户第 7 条）：原来只弹一句
  /// "没这个页面 / 打开失败"，用户拿着这句话在手机里**无处可去** —— 而国产 ROM
  /// 恰恰最爱改名、藏入口、甚至整页删掉（`unsupported` 就是这么来的）。
  Future<void> _openSpecial(String which, String label, String path) async {
    final messenger = ScaffoldMessenger.of(context);
    final r = await DshHost.openSpecialSettings(which);
    if (r == 'opened') return;
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 10),
        content: Text(
          r == 'unsupported'
              ? tr('这台手机（或这个 Android 版本）里没有「{0}」的设置页 —— 国产 ROM 常把入口改名、藏起来或整个删掉。'
                  '手动找：{1}', <Object?>[label, path])
              : tr('没能打开「{0}」的设置页。手动找：{1}', <Object?>[label, path]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final st = _status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr(
              '只列本 App 真正会用到的那几项。点「申请」才会弹系统授权框 —— Android 不允许应用给自己开权限，也没有「一键全开」这种接口。'),
          style:
              TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.45),
        ),
        const SizedBox(height: 10),
        if (_error != null)
          Text(
            context.tr('读取权限失败：{0}', [_error]),
            style: TextStyle(color: DshColors.err, fontSize: 11.5),
          )
        else if (st == null)
          Text(
            context.tr('正在读取系统权限…'),
            style: TextStyle(color: DshColors.textFaint, fontSize: 11.5),
          )
        else
          for (final k in _names.keys)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _names[k]!,
                      style: TextStyle(color: DshColors.text, fontSize: 12.5),
                    ),
                  ),
                  Text(
                    _stateText[st[k]] ?? (st[k] ?? context.tr('未知')),
                    style: TextStyle(
                      color: st[k] == 'granted'
                          ? DshColors.accent
                          : DshColors.textFaint,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _btn(context.tr('申请常用权限'), _request),
            _btn(context.tr('去系统设置'), _openAppSettings),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          context.tr('特殊权限（必须去系统页面手动打开，应用无法自行授予）'),
          style: TextStyle(color: DshColors.text, fontSize: 12),
        ),
        const SizedBox(height: 6),
        // 2026-10-11 用户第 7 条：「特殊权限这里有几个选项打开以后是无法点选的，
        // 这些权限到底是干嘛的」——所以这里从"一排只有名字的按钮"改成
        // **每项都写清用途 + 手动路径**的列表（原来连"这是干什么的"都没有）。
        Text(
          context.tr('这 5 项不是普通权限：Android 不允许应用自己开，也没有「应用内开关」—— '
              '只能在系统的「特殊应用权限」页里拨。下面写清每一项是干嘛的。'),
          style: TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.45),
        ),
        const SizedBox(height: 8),
        for (final p in _specialPerms) _specialPermRow(p),
        Text(
          context.tr('⚠️ 本页不显示这 5 项的实时状态：Android 只在系统页面里读 / 改它们'
              '（要在这里显示，得再加一个原生查询接口，这一版没做）。是否已开启，'
              '以系统页面里的开关为准。'),
          style: TextStyle(color: DshColors.textFaint, fontSize: 10.5, height: 1.45),
        ),
        const SizedBox(height: 14),
        // ⚠️ 这里原来有「允许打开的应用」白名单 + 「选择允许的应用」按钮。
        // 2026-10-10 用户要求**取消「打开应用」功能**，整条链路已删除
        // （设备通道 device_bridge、工具箱脚本 open-app.mjs、随包技能
        //   open-phone-app、原生 listLaunchableApps/openApp、以及这里的白名单）。
        // 要恢复：从 git 历史里找 `feat: 打开本机应用` 那一批。
        const _SpeechCheck(),
        const SizedBox(height: 12),
        Text(
          context.tr(
              'DSH 沙箱模式：danger-full-access —— 这是「Agent 能用哪些工具」的开关，与上面这些手机权限是两码事（Android 内核没有 landlock，这一项在手机上下调不了）。'),
          style:
              TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.45),
        ),
      ],
    );
  }

  /// 5 项特殊权限：**中文原文就是 i18n 的 key**（要让扫描器看见，见 [_i18nAnchors]）。
  ///
  /// 字段：
  ///   * `which` —— 与 `MainActivity.openSpecialSettingsPage` 的键**逐字一致**；
  ///   * `name`  —— 界面上的名字（也是失败提示里的称呼）；
  ///   * `use`   —— **一句人话用途**（用户第 7 条问的正是"这些权限到底是干嘛的"）；
  ///   * `path`  —— 系统里的**手动路径**：系统页打不开时唯一的出路，国产 ROM 尤其需要。
  ///
  /// ⚠️ 这里的字符串渲染用的是普通 `Text`（不是 DshRichText），所以**不要**写
  /// `**加粗**` 或反引号 —— 那会原样显示出来。
  static const List<({String which, String name, String use, String path})>
      _specialPerms = <({String which, String name, String use, String path})>[
    (
      which: 'all-files',
      name: '全部文件访问',
      use: '让 App 能读写手机里任意目录的文件（不只是自己那一份）。'
          '不开也能用：会话与工具会在自己的私有目录、以及你手动选给它的范围内活动。',
      path: '设置 → 应用 → 特殊应用权限 → 所有文件访问权限'
          '（Android 11 及以上；部分手机在「应用管理 → 本应用 → 权限 → 文件和媒体」里）',
    ),
    (
      which: 'overlay',
      name: '悬浮窗',
      use: '允许 App 在别的应用上面显示小窗 —— 语音输入与「取图后回到本页」的提示会用到。'
          '不给也能用，只是这类提示可能被系统挡住。',
      path: '设置 → 应用 → 特殊应用权限 → 显示在其他应用上层',
    ),
    (
      which: 'write-settings',
      name: '修改系统设置',
      use: '改系统级设置（例如屏幕亮度、自动锁屏时间）时需要。'
          '日常聊天、生图、生视频、短剧都不用它。',
      path: '设置 → 应用 → 特殊应用权限 → 修改系统设置',
    ),
    (
      which: 'usage-access',
      name: '使用情况访问',
      use: '查看「哪个应用在用、用了多久」的能力。'
          '⚠️ 这一项没有「只看本应用」的页面：打开后是一份应用列表，'
          '要自己在里面找到本应用再允许。',
      path: '设置 → 应用 → 特殊应用权限 → 使用情况访问权限'
          '（部分手机叫「有权查看使用情况的应用」）',
    ),
    (
      which: 'install-packages',
      name: '安装未知应用',
      use: '让 App 能安装 APK（例如以后把新版本安装包交给它来升级）。'
          '每次安装系统还会再问你一次。',
      path: '设置 → 应用 → 特殊应用权限 → 安装未知应用 → 本应用 → 允许',
    ),
  ];

  /// ⚠️ **i18n 扫描器的锚点**（不要删）。
  ///
  /// [_specialPerms] 里的名字/用途/路径是以**数据**形式写在上面的，而扫描器只收集
  /// 源码里字面量形式的 `tr('…')` —— 数据里的字符串它看不见，于是切到英/日/韩时
  /// 这一段还是中文。界面上真正取用的是 `context.tr(p.name / p.use / p.path)`，
  /// 这个函数只负责"让扫描器看得到"。**新增一项时这里也要加三行。**
  // ignore: unused_element
  void _i18nAnchors() {
    tr('全部文件访问');
    tr('悬浮窗');
    tr('修改系统设置');
    tr('使用情况访问');
    tr('安装未知应用');
    tr('让 App 能读写手机里任意目录的文件（不只是自己那一份）。'
        '不开也能用：会话与工具会在自己的私有目录、以及你手动选给它的范围内活动。');
    tr('允许 App 在别的应用上面显示小窗 —— 语音输入与「取图后回到本页」的提示会用到。'
        '不给也能用，只是这类提示可能被系统挡住。');
    tr('改系统级设置（例如屏幕亮度、自动锁屏时间）时需要。'
        '日常聊天、生图、生视频、短剧都不用它。');
    tr('查看「哪个应用在用、用了多久」的能力。'
        '⚠️ 这一项没有「只看本应用」的页面：打开后是一份应用列表，'
        '要自己在里面找到本应用再允许。');
    tr('让 App 能安装 APK（例如以后把新版本安装包交给它来升级）。'
        '每次安装系统还会再问你一次。');
    tr('设置 → 应用 → 特殊应用权限 → 所有文件访问权限'
        '（Android 11 及以上；部分手机在「应用管理 → 本应用 → 权限 → 文件和媒体」里）');
    tr('设置 → 应用 → 特殊应用权限 → 显示在其他应用上层');
    tr('设置 → 应用 → 特殊应用权限 → 修改系统设置');
    tr('设置 → 应用 → 特殊应用权限 → 使用情况访问权限'
        '（部分手机叫「有权查看使用情况的应用」）');
    tr('设置 → 应用 → 特殊应用权限 → 安装未知应用 → 本应用 → 允许');
  }

  /// 一项特殊权限：名称 + 「去设置」 + 一句用途 + 手动路径。
  Widget _specialPermRow(
      ({String which, String name, String use, String path}) p) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(context.tr(p.name),
                    style: TextStyle(
                        color: DshColors.text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600)),
              ),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _openSpecial(
                        p.which, context.tr(p.name), context.tr(p.path)),
                child: Text(context.tr('去设置'),
                    style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
          Text(context.tr(p.use),
              style: TextStyle(
                  color: DshColors.textDim, fontSize: 11.5, height: 1.45)),
          const SizedBox(height: 3),
          Text(
            context.tr('找不到入口时手动找：{0}',
                <Object?>[context.tr(p.path)]),
            style: TextStyle(
                color: DshColors.textFaint, fontSize: 10.5, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _btn(String label, VoidCallback onTap) => Semantics(
        button: true,
        label: label,
        child: OutlinedButton(
          onPressed: _busy ? null : onTap,
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
      );
}

// 可折叠板块与板块标题已提到共享组件 `widgets/dsh_panel.dart`：
// 「本地大模型」页要用同一套观感，复制一份会慢慢跑偏。

class _SpeechCheck extends StatefulWidget {
  const _SpeechCheck();

  @override
  State<_SpeechCheck> createState() => _SpeechCheckState();
}

class _SpeechCheckState extends State<_SpeechCheck> {
  Map<String, Object?>? _info;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final r = await DshHost.speechSupport();
      if (mounted) setState(() => _info = r);
    } catch (e) {
      if (mounted) setState(() => _info = <String, Object?>{'error': '$e'});
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = _info;
    final onDevice = i?['onDeviceAvailable'] == true;
    final available = i?['recognitionAvailable'] == true;
    final handlers = i?['intentHandlers'];
    final handlerCount = handlers is int ? handlers : -1;

    final (verdict, color) = switch (i) {
      null => (context.tr('正在检测…'), DshColors.textFaint),
      {'error': final e} => (context.tr('检测失败：{0}', [e]), DshColors.err),
      _ when onDevice => (context.tr('可用 · 设备端离线识别'), DshColors.ok),
      _ when available || handlerCount > 0 => (
          context.tr('可用 · 系统识别服务'),
          DshColors.ok
        ),
      _ => (context.tr('这台设备上没有可用的语音识别服务'), DshColors.err),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              context.tr('语音输入'),
              style: TextStyle(color: DshColors.text, fontSize: 12.5),
            ),
            const Spacer(),
            Text(verdict, style: TextStyle(color: color, fontSize: 11)),
            const SizedBox(width: 6),
            // ⚠️ 原来是一个裸 InkWell + 15px 图标：**没有 tooltip、没有语义标签**，
            // 读屏用户听到的是"按钮"而不知道它是干什么的，触控目标也只有 15dp
            // （远低于 48dp 的建议值）—— 审计 P1-4。现在补 tooltip（自带语义）+
            // 撑到 44dp 的触控区（图标本身仍 15dp，视觉不变）。
            Tooltip(
              message: context.tr('重新检测'),
              child: InkWell(
                onTap: _run,
                borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Icon(Icons.refresh, size: 15, color: DshColors.textDim),
                ),
              ),
            ),
          ],
        ),
        if (i != null && i['error'] == null) ...[
          const SizedBox(height: 4),
          Text(
            context.tr('系统识别={0} · 设备端离线={1} · 可处理识别的应用数={2} · 语言={3}{4}', [
              available ? context.tr('有') : context.tr('无'),
              onDevice ? context.tr('有') : context.tr('无'),
              handlerCount,
              i['language'] ?? '-',
              i['sdkInt'] != null ? ' · Android ${i['sdkInt']}' : ''
            ]),
            style: TextStyle(
                color: DshColors.textFaint, fontSize: 10.5, height: 1.4),
          ),
          if (!onDevice && !available && handlerCount <= 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                context.tr(
                    '系统里没有任何语音识别服务，App 无论怎么写都用不了语音 —— 需要去应用商店装一个（例如各家的语音助手），或改用文字输入。'),
                style: TextStyle(
                    color: DshColors.err, fontSize: 10.5, height: 1.4),
              ),
            ),
        ],
      ],
    );
  }
}

/// 公众号二维码（含**长按唤起微信扫一扫**，用户 2026-10-15 第 8 条）。
///
/// ## 长按做什么
///
/// 调原生 `openWechatScan()`（`weixin://dl/scan`）把**微信的扫一扫**叫起来，
/// 用户对着屏幕上这张二维码扫即可 —— App 自己不做相机扫码（那要加相机权限 +
/// CameraX + 识别库，而微信本来就有扫一扫）。
///
/// ## 三种结果都如实说
///
///   * 成功拉起 → 提示"已打开微信扫一扫，对它扫一下就行"；
///   * 没装微信 → 提示"这台机器上没找到微信，可以自己打开微信扫一扫"；
///   * 被系统拦 → 提示失败原因。
///
/// **绝不说"已进入公众号"** —— App 只能把微信叫起来，进不进得去由微信决定。
class _QrBlock extends StatelessWidget {
  const _QrBlock();

  static const String assetPath = 'assets/images/wechat_qr.png';

  Future<void> _longPress(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    // ⚠️ 三句文案**必须在 await 之前取**：await 之后再用 `context.tr` 会踩
    // `use_build_context_synchronously`（页面可能已经不在树上）。
    final okMsg = context.tr('已打开微信扫一扫 —— 对着上面这张二维码扫一下就行。');
    final noWxMsg = context.tr('这台机器上没找到微信，可以自己打开微信扫一扫再扫这张图。');
    final failTemplate = context.tr('没能唤起微信（{0}），可以自己打开微信扫一扫。');
    String msg;
    try {
      final r = await DshHost.openWechatScan();
      msg = r == 'ok'
          ? okMsg
          : r == 'no_wechat'
              ? noWxMsg
              : _fill(failTemplate, r);
    } catch (e) {
      msg = _fill(failTemplate, '$e');
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // 让整块（含白底内边距）都能长按，不用精确戳到图
      behavior: HitTestBehavior.opaque,
      onLongPress: () => _longPress(context),
      child: _qrCard(context),
    );
  }

  Widget _qrCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(DshMetrics.radius(12)),
        border: Border.all(color: DshColors.divider, width: 0.8),
      ),
      child: Image.asset(
        assetPath,
        width: 156,
        height: 156,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        errorBuilder: (context, error, stackTrace) => SizedBox(
          width: 156,
          height: 156,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(12),
              // 开发者会看到这个（用户正常看不到）：说明图该放哪儿。
              child: Text(
                context.tr('二维码待放入\nassets/images/wechat_qr.png\n放入后重新构建'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.black38, fontSize: 11, height: 1.6),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 把译文模板里的 `{0}` 换成实际值（与其它页面同一套规则）。
String _fill(String template, String v) => template.replaceAll('{0}', v);

/// 「免费模型（无需 Key）」的设置块。
///
/// ## 这个界面的首要任务是**别让人误会**
///
/// 它提供的是一条**把请求伪装成官方 CLI** 去用 OpenCode 匿名免费额度的通道。
/// 所以界面上必须做到三件事（缺一件就是误导）：
///   1. **默认关闭**，且说清"打开后会发生什么"；
///   2. **如实标注风险**：随时可能失效、不承诺稳定性；同时**必须写明它不用写 Key**
///      —— 这条通道本来就是匿名的，催用户"去配一个自己的 Key"与它的事实不符
///      （2026-10-11 用户纠正："这个项目的特点就是不用写key"）；
///   3. **显示真实状态**（代理在不在跑、拿到几个模型、上次什么错），
///      而不是一个"已开启"的空壳。
class _ZenChannelBlock extends StatefulWidget {
  const _ZenChannelBlock({
    required this.runtime,
    required this.settings,
    required this.onModelChanged,
  });

  final DshRuntime runtime;
  final AppSettings settings;
  final Future<void> Function() onModelChanged;

  @override
  State<_ZenChannelBlock> createState() => _ZenChannelBlockState();
}

class _ZenChannelBlockState extends State<_ZenChannelBlock> {
  bool _busy = false;
  ({bool running, int? port, int models, String? lastError})? _status;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    final st = await ZenChannel.status();
    if (!mounted) return;
    setState(() => _status = st);
  }

  Future<void> _toast(String msg) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _toggle(bool on) async {
    // ⚠️ 下面要连续 await（起代理/取模型/写配置），所以文案先取出来 ——
    //    既避开"await 之后用 context"，也避免页面已经回收还去读 context。
    final tAdded = context.tr('已加入 {0} 个免费模型，去模型选择器里看看。');
    final tClosed = context.tr('已关闭，并把这批免费模型从模型列表里移除。');
    setState(() {
      _busy = true;
      _notice = null;
    });
    if (on) {
      final r = await ZenChannel.enable(runtime: widget.runtime);
      if (!mounted) return;
      if (r.ok) {
        ZenChannel.clearRefreshError();
        await widget.settings.setZenEnabled(true);
        // ⚠️ 必须走这个回调：它负责把新的模型配置写进 overlay 并重建 runtime。
        await widget.onModelChanged();
        _notice = _fill(tAdded, '${r.models}');
      } else {
        // 没成 → 不要把开关留在"开"的状态（否则用户以为开了、其实没有）。
        await widget.settings.setZenEnabled(false);
        _notice = r.error;
      }
    } else {
      await ZenChannel.disable(runtime: widget.runtime);
      await widget.settings.setZenEnabled(false);
      await widget.onModelChanged();
      if (mounted) _notice = tClosed;
    }
    await _refreshStatus();
    if (!mounted) return;
    setState(() => _busy = false);
    if (_notice != null) await _toast(_notice!);
  }

  Future<void> _refreshModels() async {
    final tRefreshed = context.tr('已刷新：{0} 个免费模型。');
    setState(() => _busy = true);
    final r = await ZenChannel.enable(runtime: widget.runtime);
    if (!mounted) return;
    if (r.ok) {
      await widget.onModelChanged();
      _notice = _fill(tRefreshed, '${r.models}');
    } else {
      _notice = r.error;
    }
    await _refreshStatus();
    if (!mounted) return;
    setState(() => _busy = false);
    if (_notice != null) await _toast(_notice!);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.settings.zenEnabled;
    final st = _status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        DshRichText(
          context.tr('打开后，App 会在本机起一个小小的**转发代理**，把请求按'
              '**官方 CLI 的样子**发到 OpenCode 的匿名免费额度，并把拿到的免费模型'
              '直接加进你的模型列表 —— **不用配置任何 Key**。'),
          style: TextStyle(color: DshColors.textDim, fontSize: 12, height: 1.5),
        ),
        const SizedBox(height: 8),
        // ⚠️ 风险说明：不能省。这是把"随时可能失效、且属于绕过上游限制"的能力
        //    交给用户，他有权在打开之前就知道。
        Text(
          context.tr('⚠️ 请先看清楚：\n'
              '· 上游的免费额度**只给它自家客户端用**，这条通道是把请求**伪装成官方 CLI** '
              '去通过它的限制 —— 属于灰色用法，**随时可能失效**'
              '（2026-10-13/14 就已经收紧过第三次：换了端点、加了会话头与工具校验）。\n'
              '· **它不需要任何 Key**：那条通道本来就是匿名的（上游凭据就是公开的 `public`），'
              '所以你不用在这里填任何东西；失效时它会如实报错，不会假装成功。\n'
              '· 它按出口 IP 限流，被限流时等一会儿再试。\n'
              '· 本 App **不做** IP 轮换、也不做反复重试（不拿它去刷额度）。\n'
              '· 用不到时请把它关掉。'),
          style: TextStyle(
              color: DshColors.err.withValues(alpha: 0.85),
              fontSize: 11,
              height: 1.5),
        ),
        const SizedBox(height: 6),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: enabled,
          onChanged: _busy ? null : (v) => _toggle(v),
          title: Text(context.tr('启用社区免费通道'),
              style: const TextStyle(fontSize: 13)),
          subtitle: Text(
            enabled
                ? context.tr('已开启（模型列表里会出现「免费模型（无需 Key）」这一组）')
                : context.tr('默认关闭。开启后不用 Key 就能用一批免费模型。'),
            style: TextStyle(color: DshColors.textFaint, fontSize: 11),
          ),
        ),
        const SizedBox(height: 2),
        // 真实状态：不给"已开启"的空壳
        Text(
          st == null
              ? context.tr('状态：读取中…')
              : (st.running
                  ? context.tr('状态：代理在跑（127.0.0.1:{0}）· 免费模型 {1} 个{2}',
                      <Object?>[
                        '${st.port}',
                        '${st.models}',
                        st.lastError == null ? '' : '· 上次错误：${st.lastError}',
                      ])
                  : context.tr('状态：代理没在跑')),
          style: TextStyle(color: DshColors.textFaint, fontSize: 11),
        ),
        if (enabled) ...<Widget>[
          const SizedBox(height: 6),
          Row(children: <Widget>[
            TextButton.icon(
              onPressed: _busy ? null : _refreshModels,
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(context.tr('重新获取模型列表')),
            ),
            TextButton.icon(
              onPressed: _busy ? null : _refreshStatus,
              icon: const Icon(Icons.monitor_heart_outlined, size: 16),
              label: Text(context.tr('刷新状态')),
            ),
          ]),
        ],
      ],
    );
  }
}

/// 「图像 / 视频模型」设置块 —— **影视页用的模型**（与会话模型无关）。
///
/// ## 用户 2026-10-11 提的设计问题
///
/// 原文：「模型页是否增加一个图形和视频的设置页，用户设置好后可以在影视工具里
/// 选择图形和视频大模型」。答案是**加**，理由不是"功能好看"，而是：
///   * 现在影视页把模型名写死在脚本默认值里（Agnes 那条），用户**换不了** ——
///     一旦官方换档/收费/下架，App 里没有任何办法应对；
///   * 而"哪家的图像模型"这件事，本来就该是用户能决定的事。
///
/// ## 两套模型故意不混
///
/// 这里存的是 `media-models.json`（`data/media_models.dart`），**不是** `models.json`。
/// 会话模型必须走 `/chat/completions`，而图像/视频模型走 `/images/generations` 与
/// `/videos` —— 混在一起就会重现"图像模型出现在会话模型面板里、选中必然聊不了天"。
///
/// ## 能力边界（界面里也这么写，别让人以为换厂商很容易）
///
/// 2026-10-11 用户纠正过：「影视这个工具实际是可以使用多个厂家」—— 所以形状
/// **按各家文档写**（`assets/toolbox/media-vendors.mjs` 是唯一来源）：
///   * **图像**：Agnes 一套（`size` 是 1K/2K 档位 + 参考图放 `extra_body`）、
///     OpenAI 兼容一套（像素 `size`，OpenAI 官方带参考图走 `/images/edits`）、
///     MiniMax 自有（吃 `aspect_ratio`）、万相异步（星号尺寸 + 轮询任务）。
///   * **视频**：Agnes / 豆包 Seedance（方舟异步任务）/ MiniMax /
///     通义万相（百炼异步）/ 硅基流动（`/video/submit` + `/video/status`）。
///   * ⚠️ 本机**没有这些厂家的 Key、也没有安卓真机** —— 形状按文档写对了，
///     "能不能通"只能试；失败会把上游原话带出来，不假装成功。
///   * Key 是从「云端大模型」里那家厂家读的（同一套系统安全区）：想用别家的模型，
///     就要先在那边把别家配好。
class _MediaModelsSection extends StatefulWidget {
  const _MediaModelsSection({required this.runtime});

  final DshRuntime runtime;

  @override
  State<_MediaModelsSection> createState() => _MediaModelsSectionState();
}

class _MediaModelsSectionState extends State<_MediaModelsSection> {
  MediaModelConfig _cfg = const MediaModelConfig();
  String? _notice;

  /// 「这家厂家有没有配 Key」—— 用户 2026-10-12：「图像/视频模型貌似没有写 key 的位置」。
  ///
  /// 这里只记**有没有**（布尔），**绝不把 Key 本身读进内存再显示**。
  Map<String, bool> _keyState = <String, bool>{};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final cfg = MediaModels.read(widget.runtime.filesDir);
    if (!mounted) return;
    setState(() {
      _cfg = cfg;
      final err = MediaModels.lastReadError;
      if (err != null) _notice = err;
    });
    unawaited(_refreshKeyState());
  }

  /// 查一遍"这些厂家有没有 Key"（只取有无，不取内容）。
  Future<void> _refreshKeyState() async {
    final ids = <String>{
      for (final m in _cfg.custom) m.provider.trim(),
      MediaModels.builtinProvider,
    }..removeWhere((e) => e.isEmpty);
    final out = <String, bool>{};
    for (final id in ids) {
      try {
        final k = await ProviderKeys.read(id);
        out[id] = k != null && k.trim().isNotEmpty;
      } catch (_) {
        out[id] = false;
      }
    }
    if (!mounted) return;
    setState(() => _keyState = out);
  }

  /// 「去哪拿 Key」：把这个厂家的注册 / 控制台地址**显示出来**并允许复制。
  ///
  /// 为什么不是直接 `launchUrl` 打开浏览器：本 App 是"不联网也能用"的本地工具，
  /// 而这条路会在用户没预期的时候跳出去。而且用户要的多半是"复制到电脑上注册"，
  /// 所以给可复制的文本更实用（长按即复制）。
  Future<void> _openRegister(String providerId) async {
    final url = MediaVendors.registerUrl(providerId);
    if (url.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DshColors.surfaceStrong,
        title: Text(context.tr('「{0}」的 Key 去哪拿', <Object?>[providerId])),
        content: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          SelectableText(url,
              style: TextStyle(color: DshColors.text, fontSize: 12.5)),
          const SizedBox(height: 10),
          Text(
            context.tr('在浏览器里打开它注册 / 登录，把 Key 复制回来，'
                '再点这一行的「填 Key」贴进来。'),
            style: TextStyle(
                color: DshColors.textFaint, fontSize: 11, height: 1.45),
          ),
        ]),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(context.tr('知道了'))),
        ],
      ),
    );
  }

  /// 就地为某个厂家填 Key（写进「云端大模型」那同一个凭据库）。
  Future<void> _editKey(String providerId) async {
    final ctl = TextEditingController();
    final tSaved = context.tr('Key 已保存到「{0}」这家。', <Object?>[providerId]);
    final tEmpty = context.tr('没填内容，Key 未改动。');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.tr('给「{0}」填 Key', <Object?>[providerId])),
        content: TextField(
          controller: ctl,
          obscureText: true,
          autofocus: true,
          decoration: InputDecoration(
              labelText: context.tr('API Key'),
              hintText: context.tr('留空 = 不改动已存的 Key'),
              border: const OutlineInputBorder(),
              isDense: true),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(context.tr('取消'))),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(context.tr('保存'))),
        ],
      ),
    );
    if (ok != true) return;
    final k = ctl.text.trim();
    if (k.isEmpty) {
      await _toast(tEmpty);
      return;
    }
    await ProviderKeys.write(providerId, k);
    await _refreshKeyState();
    await _toast(tSaved);
  }

  Future<void> _toast(String msg) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 6)));
  }

  Future<void> _pick(String kind) async {
    // ⚠️ 文案要在**第一个 await 之前**取好（跨 async gap 用 context 会被 lint 拦下）。
    final tDone = context.tr('换好了 —— 影视页里生图/生视频就会用这个模型。');
    final isImage = kind == 'image';
    final list = MediaModels.choices(_cfg, kind);
    final cur = MediaModels.selected(_cfg, kind).route;
    final picked = await _choiceSheet(
      title: isImage ? context.tr('生图用哪个模型？') : context.tr('生视频用哪个模型？'),
      options: <({String value, String label, String sub})>[
        for (final m in list)
          (
            value: m.route,
            label: m.displayName,
            sub: m.route + (m.builtin ? context.tr(' · 内置') : ''),
          ),
      ],
      current: cur,
    );
    if (picked == null) return;
    await MediaModels.select(
        filesDir: widget.runtime.filesDir, kind: kind, route: picked);
    _reload();
    await _toast(tDone);
  }

  Future<String?> _choiceSheet({
    required String title,
    required List<({String value, String label, String sub})> options,
    required String current,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(title,
                  style: TextStyle(
                      color: DshColors.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
            ),
            for (final o in options)
              ListTile(
                leading: Icon(
                  o.value == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: o.value == current ? DshColors.accent : DshColors.textDim,
                ),
                title: Text(o.label,
                    style: TextStyle(color: DshColors.text, fontSize: 12.5)),
                subtitle: Text(o.sub,
                    style: TextStyle(color: DshColors.textFaint, fontSize: 11)),
                onTap: () => Navigator.of(ctx).pop(o.value),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _add() async {
    // ⚠️ 下面要连续 await（弹层/落盘），文案先取出来 —— 避开"await 之后用 context"。
    final tEmpty = context.tr('模型名不能为空。');
    final tAdded = context.tr('加好了。');
    final nameCtl = TextEditingController();
    final labelCtl = TextEditingController();
    final providerCtl = TextEditingController(text: MediaModels.builtinProvider);
    final baseCtl = TextEditingController(
        text: MediaModels.builtins().first.baseUrl);
    // ⚠️ 用户 2026-10-12：「图像/视频模型貌似没有写 key 的位置」—— 确实没有：
    //    这里以前只有一句"Key 是从「云端大模型」里那家读的"，让用户自己去别处找。
    //    现在**就地**给一个 Key 输入框，填了就写进同一个凭据库（ProviderKeys），
    //    与「云端大模型」那份是同一处 —— 不新增第二份 Key 存储。
    final keyCtl = TextEditingController();
    String kind = 'image';
    // 点了「内置外部厂商」预设之后：记住它叫什么 + 那条**注意事项**（如实显示给用户）。
    String presetVendor = '';
    String presetNote = '';
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => Padding(
          padding: EdgeInsets.only(
              left: 16, right: 16, bottom: MediaQuery.of(ctx).viewInsets.bottom + 16),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(context.tr('添加一个模型'),
                    style: TextStyle(
                        color: DshColors.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                Wrap(spacing: 8, children: <Widget>[
                  ChoiceChip(
                    label: Text(context.tr('图像模型')),
                    selected: kind == 'image',
                    onSelected: (_) => setLocal(() => kind = 'image'),
                  ),
                  ChoiceChip(
                    label: Text(context.tr('视频模型')),
                    selected: kind == 'video',
                    onSelected: (_) => setLocal(() => kind = 'video'),
                  ),
                ]),
                const SizedBox(height: 10),
                // 内置厂商那一排：**图像 6 家 / 视频 4 家**（2026-10-11 补上视频）。
                // 点一下把「端点 + 建议模型名 + 厂家 id」都填好（模型名可改）。
                Text(context.tr('内置外部厂商（点一下自动填好端点与模型名）'),
                    style: TextStyle(
                        color: DshColors.textDim,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final p in (kind == 'image'
                        ? MediaModels.externalPresets
                        : MediaModels.externalVideoPresets))
                      ActionChip(
                        label: Text(p.vendor,
                            style: const TextStyle(fontSize: 11.5)),
                        onPressed: () => setLocal(() {
                          nameCtl.text = p.model;
                          baseCtl.text = p.baseUrl;
                          providerCtl.text = p.provider;
                          presetVendor = p.vendor;
                          presetNote = p.note;
                        }),
                      ),
                  ],
                ),
                if (presetNote.trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: 6),
                  // ⚠️ 必须走 `context.tr()`：这些 note 是数据表里的中文，
                  //    直接 `Text(presetNote)` 在英/日/韩下**会露中文**
                  //   （0.61 起就是这样，2026-10-11 补锚点时一并修掉）。
                  Text(context.tr(presetNote),
                      style: TextStyle(
                          color: DshColors.accent,
                          fontSize: 11,
                          height: 1.4)),
                ],
                const SizedBox(height: 6),
                if (kind == 'image')
                  Text(
                    context.tr('图像请求的形状**按各家的文档写**（size 是像素值还是 1K/2K '
                        '档位、参考图放哪、要不要 response_format 都不同）—— 本机没有'
                        '这些厂家的 Key，**能不能通要试**；失败会把上游原话显示出来。'),
                    style: TextStyle(
                        color: DshColors.textFaint, fontSize: 11, height: 1.5),
                  )
                else
                  Text(
                    context.tr('视频请求的形状同样按各家文档写：豆包 Seedance（方舟异步任务）/ '
                        'MiniMax / 通义万相（百炼异步）/ 硅基流动 各一套 —— '
                        '**能不能通要试**；失败会把上游原话显示出来。'),
                    style: TextStyle(
                        color: DshColors.textFaint, fontSize: 11, height: 1.5),
                  ),
                if (presetVendor.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    context.tr('记得先在「云端大模型」里把「{0}」这家配好'
                        '（厂家 id 用 {1}）—— Key 是从那边读的。',
                        <Object?>[presetVendor, providerCtl.text]),
                    style: TextStyle(
                        color: DshColors.textFaint, fontSize: 11, height: 1.5),
                  ),
                ],
                const SizedBox(height: 8),
                TextField(
                  controller: nameCtl,
                  decoration: InputDecoration(
                      labelText: context.tr('模型名（发给上游的 id）'),
                      hintText: 'agnes-image-2.5-flash',
                      border: const OutlineInputBorder(),
                      isDense: true),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: labelCtl,
                  decoration: InputDecoration(
                      labelText: context.tr('显示名（可留空）'),
                      border: const OutlineInputBorder(),
                      isDense: true),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: baseCtl,
                  decoration: InputDecoration(
                      labelText: context.tr('端点'),
                      border: const OutlineInputBorder(),
                      isDense: true),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: providerCtl,
                  decoration: InputDecoration(
                      labelText: context.tr('厂家 id（用它读 Key）'),
                      hintText: 'agnes',
                      border: const OutlineInputBorder(),
                      isDense: true),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: keyCtl,
                  obscureText: true,
                  decoration: InputDecoration(
                      labelText: context.tr('API Key（可以直接在这里填）'),
                      hintText: context.tr('留空 = 不改动已存的 Key'),
                      border: const OutlineInputBorder(),
                      isDense: true),
                ),
                const SizedBox(height: 6),
                Text(
                  context.tr('Key 存在「{0}」这家厂家名下（与「云端大模型」里那份是**同一个地方**，'
                      '填一次两边都认）。留空就不动它 —— 所以这里**从不回显已存的 Key**。',
                      <Object?>[providerCtl.text.trim().isEmpty
                          ? MediaModels.builtinProvider
                          : providerCtl.text.trim()]),
                  style: TextStyle(
                      color: DshColors.textFaint, fontSize: 11, height: 1.5),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: Text(context.tr('保存')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok != true) return;
    final id = nameCtl.text.trim();
    if (id.isEmpty) {
      await _toast(tEmpty);
      return;
    }
    final typedKey = keyCtl.text.trim();
    if (typedKey.isNotEmpty) {
      // 写进同一个凭据库 —— 与「云端大模型」共用，不新增第二份存储。
      await ProviderKeys.write(providerCtl.text.trim().isEmpty
          ? MediaModels.builtinProvider
          : providerCtl.text.trim(), typedKey);
    }
    final provider = providerCtl.text.trim().isEmpty
        ? MediaModels.builtinProvider
        : providerCtl.text.trim();
    final base = baseCtl.text.trim().isEmpty
        ? MediaModels.builtins().first.baseUrl
        : baseCtl.text.trim();
    await MediaModels.add(
      filesDir: widget.runtime.filesDir,
      model: MediaModelSpec(
        provider: provider,
        id: id,
        baseUrl: base,
        label: labelCtl.text.trim(),
        apiKeyEnv: 'AGNES_API_KEY',
        kind: kind,
      ),
    );
    _reload();
    await _toast(tAdded);
  }

  Future<void> _remove(MediaModelSpec m) async {
    final tRemoved = context.tr('已删除。');
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.tr('删掉「{0}」？', <Object?>[m.displayName])),
        content: Text(context.tr('只是从影视页的候选里去掉，不影响你的 Key。')),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(context.tr('取消'))),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(context.tr('删除'))),
        ],
      ),
    );
    if (yes != true) return;
    await MediaModels.remove(filesDir: widget.runtime.filesDir, route: m.route);
    _reload();
    await _toast(tRemoved);
  }

  @override
  Widget build(BuildContext context) {
    final img = MediaModels.selected(_cfg, 'image');
    final vid = MediaModels.selected(_cfg, 'video');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      DshRichText(
        context.tr('影视页（生图 / 生视频 / 短剧每镜）**用哪个模型**在这里定：'
            '与会话模型**分开**，改动不会影响你在会话里选的模型。'),
        style: TextStyle(color: DshColors.textDim, fontSize: 12, height: 1.5),
      ),
      const SizedBox(height: 8),
      _row(context.tr('生图用'), img.displayName, () => _pick('image')),
      _row(context.tr('生视频用'), vid.displayName, () => _pick('video')),
      const Divider(height: 18),
      // ── 厂家的 Key（用户 2026-10-12：「图像/视频模型貌似没有写 key 的位置」）──
      //
      // 以前只在「添加模型」的说明里写了一句"Key 是从「云端大模型」里那家读的"，
      // 用户找不到地方填。现在**这一页就有**：每个用到的厂家一行，显示配没配，
      // 点一下就填。写的是**同一个凭据库**（ProviderKeys），不是第二份。
      Text(context.tr('各厂家的 Key（点一下就能填）'),
          style: TextStyle(
              color: DshColors.textDim,
              fontSize: 11.5,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 2),
      Text(
        context.tr('图像 / 视频走哪家，就用哪家的 Key；存的位置和「云端大模型」**同一个**，'
            '在哪边填都认。'),
        style: TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.4),
      ),
      const SizedBox(height: 4),
      for (final pid in _providersInUse())
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: Icon(
            _keyState[pid] == true ? Icons.key : Icons.key_off_outlined,
            size: 18,
            color: _keyState[pid] == true ? DshColors.ok : DshColors.err,
          ),
          title: Text(pid,
              style: TextStyle(color: DshColors.text, fontSize: 12.5)),
          subtitle: Text(
              _keyState[pid] == true
                  ? context.tr('已配 Key')
                  : context.tr('还没配 Key —— 没凭据这条模型必然失败'),
              style: TextStyle(
                  color: _keyState[pid] == true
                      ? DshColors.textFaint
                      : DshColors.err,
                  fontSize: 11)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
            // 「去注册 / 拿 Key」—— 用户 2026-10-12：「也可以给注册地址」。
            // 地址来自 media_models.dart 的 registerUrls（唯一来源是脚本里的表）；
            // 自定义厂家没有地址 → 不显示链接（**不猜**）。
            if (MediaVendors.registerUrl(pid).isNotEmpty)
              TextButton(
                onPressed: () => _openRegister(pid),
                child: Text(context.tr('去哪拿 Key')),
              ),
            TextButton(
              onPressed: () => _editKey(pid),
              child: Text(_keyState[pid] == true
                  ? context.tr('换一把')
                  : context.tr('填 Key')),
            ),
          ]),
        ),
      const Divider(height: 18),
      for (final kind in <String>['image', 'video']) ...<Widget>[
        Text(kind == 'image' ? context.tr('可选的图像模型') : context.tr('可选的视频模型'),
            style: TextStyle(
                color: DshColors.textDim,
                fontSize: 11.5,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        for (final m in MediaModels.choices(_cfg, kind))
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(
              MediaModels.selected(_cfg, kind).route == m.route
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: MediaModels.selected(_cfg, kind).route == m.route
                  ? DshColors.accent
                  : DshColors.textDim,
            ),
            title: Text(m.displayName,
                style: TextStyle(color: DshColors.text, fontSize: 12.5)),
            subtitle: Text(
                m.route + (m.builtin ? context.tr(' · 内置（免费档）') : ''),
                style: TextStyle(color: DshColors.textFaint, fontSize: 11)),
            onTap: () async {
              await MediaModels.select(
                  filesDir: widget.runtime.filesDir, kind: m.kind, route: m.route);
              _reload();
            },
            trailing: m.builtin
                ? null
                : IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () => _remove(m),
                  ),
          ),
      ],
      const SizedBox(height: 6),
      OutlinedButton.icon(
        onPressed: _add,
        icon: const Icon(Icons.add, size: 18),
        label: Text(context.tr('添加一个模型')),
      ),
      const SizedBox(height: 8),
      Text(
        context.tr('⚠️ 边界（别踩）：图像与视频都**按厂家的形状**发 —— 端点、参数名、'
            '轮询各不相同（唯一来源是 assets/toolbox/media-vendors.mjs）。'
            '本机没有这些厂家的 Key、也没法真机验证，所以**能不能通要试**；'
            '失败了会把上游原话显示出来，不假装成功。'),
        style: TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.5),
      ),
      if (_notice != null) ...<Widget>[
        const SizedBox(height: 6),
        Text(_notice!,
            style: TextStyle(color: DshColors.err, fontSize: 11, height: 1.5)),
      ],
    ]);
  }

  /// 这一页里**实际用到的**厂家 id（配置过的模型 + 内置那家），去重且稳定排序。
  List<String> _providersInUse() {
    final ids = <String>{
      MediaModels.builtinProvider,
      for (final m in _cfg.custom) m.provider.trim(),
    }..removeWhere((e) => e.isEmpty);
    final list = ids.toList()..sort();
    // 内置那家（agnes）排最前 —— 它是默认路径。
    if (list.remove(MediaModels.builtinProvider)) {
      list.insert(0, MediaModels.builtinProvider);
    }
    return list;
  }

  Widget _row(String label, String value, VoidCallback onTap) {
    return Row(children: <Widget>[
      SizedBox(
        width: 68,
        child: Text(label,
            style: TextStyle(
                color: DshColors.textDim,
                fontSize: 11.5,
                fontWeight: FontWeight.w600)),
      ),
      Expanded(
        child: Text(value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: DshColors.text, fontSize: 12.5)),
      ),
      TextButton(onPressed: onTap, child: Text(context.tr('换一个'))),
    ]);
  }
}

// ═══════════════════════════════════════════════════════════ 检查更新（L1）

/// 「检查更新」板块（设置页里，排在「关于」之前）。
///
/// ## 这一版做到哪、没做到哪（**界面上的话必须跟这里一致**）
///
/// 做到：① 去更新源读一份**版本清单**、比版本，有新版本就在这里提示；
///      ② 记住"上次什么时候查过"；③ 可以自填镜像源；④ 可以关掉自动检查。
/// 没做到：**应用内下载与安装**（下一阶段）。所以"下载"这一步现在交给
///      系统浏览器，按钮就写「去浏览器下载」—— 不装作 App 自己能装。
///
/// ## 为什么不弹窗、不亮红点
///
/// 见 `local/update_checker.dart` 文件头的静默约定：国内访问 GitHub 时好时坏，
/// 检查失败是常态，不该打扰用户；查到新版也只在这里露出一张卡，不弹窗催。
/// [State] 里那几行状态（`_checking` / `_result` / `_showTried`）就是全部界面状态 ——
/// **不把"检查过没有"写进磁盘**，每次进设置页都是从 `AppSettings` 读上次时间戳。
class _UpdateSection extends StatefulWidget {
  const _UpdateSection({required this.settings, required this.runtime});

  final AppSettings settings;

  /// 要它的 `filesDir` —— 安装包落在 `<filesDir>/updates/`，
  /// 那个目录已加进 FileProvider 白名单（否则拉起安装器会抛异常，见 `res/xml/file_paths.xml`）。
  final DshRuntime runtime;

  @override
  State<_UpdateSection> createState() => _UpdateSectionState();
}

/// 「应用内下载 / 安装」走到哪一步了。
///
/// ⚠️ 只有四步，**没有"已安装"这一步** —— Android 不允许普通应用静默安装，
/// 我们拉起系统安装界面之后就再也拿不到结果了（见 `local/apk_installer.dart`）。
/// 界面不能自己编一个"安装成功"出来。
enum _UpdPhase { idle, downloading, downloaded, installing }

class _UpdateSectionState extends State<_UpdateSection> {
  bool _checking = false;
  UpdateCheckResult? _result;
  bool _showTried = false;

  // ── 应用内下载 / 安装的状态。**只活在本次进程内，不落盘。**
  //
  //    为什么不落盘：下载器是**幂等**的（目标文件在、哈希对得上就直接返回），
  //    所以用户切走再回来点一次「下载」是瞬间完成 —— 没必要为此再加一套持久化，
  //    少一份状态就少一类"磁盘上写着下好了、其实文件被清了"的错。
  _UpdPhase _phase = _UpdPhase.idle;
  ApkDownloadProgress? _progress;
  ApkDownloadCancelToken? _cancel;
  String? _apkPath;
  SignatureCheck? _sig;
  InstallEnv? _env;
  String? _ioNotice;

  /// 这一次下的是哪个包（精简 / 完整）—— 界面拿它显示大小与"含不含运行环境"。
  /// 下载结束后仍留着，好让"已下载"那一段也能说清下的是哪一个。
  UpdateVariant? _variant;

  /// 正在编辑的源地址。**只有点「保存」才落盘** —— 边打字边存的话，
  /// 用户打到一半（地址还不完整）就会把设置里的值覆盖成半截。
  late final TextEditingController _sourceCtrl =
      TextEditingController(text: widget.settings.updateSource);

  @override
  void initState() {
    super.initState();
    // 启动时那次自动检查的结果已经在这儿了（见 `main.dart` 的 `_autoCheckUpdate`），
    // 所以用户一进设置页就看到"有没有新版"，不必自己再点一次。
    _result = widget.settings.lastUpdateResult;
  }

  @override
  void dispose() {
    _sourceCtrl.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _showTried = false;
    });
    // 手动检查**绕缓存**（`?t=` 时间戳）：用户刚在电脑上传了新清单，
    // 不该让他拿到 CDN 里那份旧的。
    final r = await checkForUpdate(
      customSource: widget.settings.updateSource,
      bypassCache: true,
    );
    // 成败都记时间戳：那行字说的是"什么时候**试过**"，不是"什么时候成功过"。
    await widget.settings.noteUpdateChecked();
    // 存进内存槽：这样切走再回设置页，"有没有新版"还在（不必重查）。
    widget.settings.setLastUpdateResult(r);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _result = r;
    });
  }

  Future<void> _openUrl(String url) async {
    final messenger = ScaffoldMessenger.of(context);
    debugPrint('[dsh-update] 打开 → $url');
    try {
      final r = await DshHost.openUrl(url);
      if (!mounted || r != 'no_app') return;
      messenger.showSnackBar(SnackBar(
          content:
              Text(context.tr('这台设备没有能打开网页的应用，请手动访问：{0}', [url]))));
    } catch (e) {
      final t = translateException(e);
      debugPrint('[dsh-update] 打开失败：${t.zh}');
      if (!mounted) return;
      messenger.showSnackBar(
          SnackBar(content: Text(context.tr('打不开网页：{0}', [t.zh]))));
    }
  }

  Future<void> _saveSource() async {
    final v = _sourceCtrl.text.trim();
    if (v.isNotEmpty && !looksLikeUpdateSource(v)) {
      // 与 `AppSettings.setUpdateSource` 的二次校验同一个口径（那里是兜底，
      // 这里是给用户看得见的提示）。
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(context
              .tr('这不像一个完整网址：要以 http:// 或 https:// 开头。'))));
      return;
    }
    await widget.settings.setUpdateSource(v);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(v.isEmpty
            ? context.tr('已恢复内置更新源。')
            : context.tr('已保存更新源。'))));
  }

  // ───────────────────────────────── 应用内下载 → 校验 → 交给系统安装（L2）

  /// 从清单给的地址推出保存用的文件名。
  ///
  /// 用 URL 的最后一段（Release 附件本来就叫 `paopaocat-preview-0.75-arm64-v8a.apk`）；
  /// 拿不到就按版本号造一个 —— 文件名只影响"用户自己去看文件时认不认得出来"，
  /// 安全性靠 sha256 与签名，不靠名字。
  String _fileNameFor(String url) {
    final seg = Uri.tryParse(url)?.pathSegments;
    final last = (seg == null || seg.isEmpty) ? '' : seg.last;
    if (last.toLowerCase().endsWith('.apk') && last.length > 4) return last;
    return 'paopaocat-update-arm64-v8a.apk';
  }

  Future<void> _download(UpdateInfo info) async {
    if (_phase == _UpdPhase.downloading) return;
    // 挑包：手机里**已经有运行时**（老用户更新，绝大多数情况）→ 下精简包，省 32 MB；
    // **还没有**（全新安装 / 清了数据）→ 下完整包，装完即用、无网也能打开。
    // 这一句是 0.75 那次"没网就打不开"硬伤的修法。
    final variant = info.pickVariant(runtimeReady: widget.runtime.isUnpacked);
    final dir = '${widget.runtime.filesDir}/updates';
    final token = ApkDownloadCancelToken();
    setState(() {
      _phase = _UpdPhase.downloading;
      _cancel = token;
      _progress = null;
      _ioNotice = null;
      _sig = null;
      _apkPath = null;
      _variant = variant;
    });
    final downloader = ApkDownloader(dir: dir);
    try {
      final res = await downloader.download(
        url: variant.url,
        fileName: _fileNameFor(variant.url),
        expectSha256: variant.sha256,
        expectBytes: variant.size,
        cancel: token,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _phase = _UpdPhase.downloaded;
        _apkPath = res.path;
        _progress = null;
        _cancel = null;
      });
      // 下完**立刻**验签名：把"这个包是不是同一家签的"摆在安装按钮**之前**，
      // 而不是等用户点了安装才告诉他不行。
      await _checkSignature(res.path);
    } on ApkDownloadCancelled {
      if (!mounted) return;
      setState(() {
        _phase = _UpdPhase.idle;
        _progress = null;
        _cancel = null;
        _ioNotice = context.tr('已取消下载。已经下好的那一部分留着，下次点「下载」会接着下。');
      });
    } on ApkDownloadException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _UpdPhase.idle;
        _progress = null;
        _cancel = null;
        _ioNotice = e.zh;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _UpdPhase.idle;
        _progress = null;
        _cancel = null;
        _ioNotice = context.tr('下载出错了：{0}', ['$e']);
      });
    } finally {
      downloader.close();
    }
  }

  /// 校验签名 + 读一次安装环境（一起做，界面一次刷到位）。
  Future<void> _checkSignature(String path) async {
    final sig = await verifyDownloadedApk(path);
    final env = await readInstallEnv();
    if (!mounted) return;
    setState(() {
      _sig = sig;
      _env = env;
    });
    debugPrint('[dsh-update] 签名校验 matched=${sig.matched} '
        'reason=${sig.reason} canInstall=${env.canInstall}');
  }

  Future<void> _install() async {
    final path = _apkPath;
    if (path == null) return;
    if (_sig != null && !_sig!.matched) {
      // 双保险：签名不通过时安装按钮本来就不该出现，这里再挡一次。
      setState(() => _ioNotice = _sig!.message);
      return;
    }
    setState(() {
      _phase = _UpdPhase.installing;
      _ioNotice = null;
    });
    final r = await installDownloadedApk(path);
    if (!mounted) return;
    setState(() {
      // 回到 downloaded：安装按钮留着（用户可能装完又回来，或第一次没在系统界面点确认）。
      _phase = _UpdPhase.downloaded;
      _ioNotice = r.message;
    });
    // 差权限时顺手把"允许安装未知应用"那一页打开（省掉用户自己找路）。
    if (r.outcome == InstallOutcome.needPermission) {
      await _openInstallPermission();
    }
  }

  /// 跳到系统的「安装未知应用」授权页。
  Future<void> _openInstallPermission() async {
    try {
      final r = await DshHost.openSpecialSettings('install-packages');
      // 原生约定：打开成功回 `'opened'`（与 Dart 侧那句判断**逐字对齐**）。
      debugPrint('[dsh-update] 打开"安装未知应用"设置页 → $r');
    } catch (e) {
      debugPrint('[dsh-update] 打不开设置页：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final r = _result;
    final last = s.updateLastCheckAt;
    // 用户跳过的那一版**正在生效**吗（只有远端版本正好是他跳过的那一版才算）。
    final skipActive = r != null &&
        r.ok &&
        r.hasUpdate &&
        r.info!.version == s.updateSkippedVersion;
    // 要不要弹那张"有新版本"的卡：有新版、且不是他跳过的那一版。
    final showUpdate = r != null && r.ok && r.hasUpdate && !skipActive;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        DshRichText(
          context.tr('App 会去更新源读一份**版本清单**，有新版本就在这里提示你。'
              '它只读清单、**不会自己装东西** —— 装包那一步必须你亲手点'
              '（Android 规定普通应用不能静默安装，任何正规 App 都一样）。'),
          style: TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.55),
        ),
        const SizedBox(height: 12),
        _kvRow(context.tr('当前版本'), 'v$kAppVersion'),
        if (last != null)
          _kvRow(context.tr('上次检查'), relativeTimeLabel(last)),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _checking ? null : _check,
            icon: _checking
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh, size: 18),
            label: Text(_checking ? context.tr('正在检查…') : context.tr('检查更新')),
          ),
        ),
        if (r != null) ...<Widget>[
          const SizedBox(height: 12),
          if (showUpdate)
            _updateCard(r.info!)
          else if (r.ok && skipActive)
            _note(context.tr('v{0} 你选了跳过。出下一版时会再提示你。',
                [r.info!.version]))
          else if (r.ok)
            _note(context.tr('已是最新版本（v{0}）。', [kAppVersion]))
          else
            _failureBlock(r),
        ],
        const SizedBox(height: 14),
        // ⚠️ 这里**刻意不用 `SwitchListTile`**：它把自己的底色与水波纹画在**最近的
        //    Material 祖先**上，而这一块外面是玻璃卡（`DshGlassCard` 的 DecoratedBox
        //    带底色）—— Flutter 会当场报「ListTile background color or ink splashes
        //    may be invisible」，点击遍历测试（`clickthrough_test`）会把它当成
        //    "点完留下了异常"直接判失败。自定义一行 Row + Switch 没有这个约束。
        Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(context.tr('启动后自动检查'),
                      style: TextStyle(
                          color: DshColors.text,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    s.updateAutoCheck
                        ? context.tr('开。启动时在后台查一次；连不上就静默跳过，不打扰你。')
                        : context.tr('关。只有你点「检查更新」时才会联网查这一次。'),
                    style: TextStyle(
                        color: DshColors.textFaint, fontSize: 11, height: 1.4),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Switch(value: s.updateAutoCheck, onChanged: (v) => s.setUpdateAutoCheck(v)),
          ],
        ),
        Divider(height: 20, color: DshColors.line),
        _sourceEditor(s),
      ],
    );
  }

  /// 左标签右值的一行。
  Widget _kvRow(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 72,
              child: Text(label,
                  style: TextStyle(
                      color: DshColors.textDim,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600)),
            ),
            Expanded(
              child: Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: DshColors.text, fontSize: 12.5)),
            ),
          ],
        ),
      );

  Widget _note(String text) => Text(
        text,
        style: TextStyle(color: DshColors.textDim, fontSize: 11.5, height: 1.5),
      );

  /// 「有新版本」那张卡 —— 这一块是整页的重点，所以给足信息：
  /// 版本号、日期、包大小、说明条数、改动列表（最多 6 条）、下载按钮、跳过。
  Widget _updateCard(UpdateInfo info) {
    final s = widget.settings;
    final bits = <String>[
      if ((info.publishedAt ?? '').isNotEmpty) info.publishedAt!,
      if (info.size != null && info.size! > 0) formatBytes(info.size),
      if (info.notes.isNotEmpty) context.tr('{0} 条说明', ['${info.notes.length}']),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: BoxDecoration(
        color: DshColors.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(DshMetrics.radius(12)),
        border: Border.all(color: DshColors.accent.withValues(alpha: 0.38)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.system_update_alt, size: 16, color: DshColors.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(context.tr('发现新版本 v{0}', [info.version]),
                    style: TextStyle(
                        color: DshColors.accent,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          if (bits.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(bits.join(' · '),
                style: TextStyle(color: DshColors.textDim, fontSize: 11.5)),
          ],
          if (info.notes.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            for (final n in info.notes.take(6))
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text('· $n',
                    style: TextStyle(
                        color: DshColors.text, fontSize: 11.5, height: 1.45)),
              ),
            if (info.notes.length > 6)
              Text(
                  context.tr('…还有 {0} 条，去发布页能看到全部。',
                      ['${info.notes.length - 6}']),
                  style:
                      TextStyle(color: DshColors.textFaint, fontSize: 11)),
          ],
          const SizedBox(height: 10),
          _downloadArea(info),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => s.setUpdateSkippedVersion(info.version),
              style: TextButton.styleFrom(
                  padding: EdgeInsets.zero, minimumSize: const Size(0, 30)),
              child: Text(context.tr('跳过这个版本'),
                  style: const TextStyle(fontSize: 11.5)),
            ),
          ),
        ],
      ),
    );
  }

  /// 「下载 → 校验 → 安装」这一块的界面，按当前走到哪一步画。
  ///
  /// 三段话必须说清（用户最容易误解的三处）：
  ///   * 下载是**应用内**做的，可以取消、**断了能接着下**；
  ///   * 装之前**两样都验**了 —— 哈希（文件没坏）+ 签名（是同一家签的）；
  ///   * 最后**一定要点系统那个「安装」** —— 我们只能把安装界面交到你手上。
  Widget _downloadArea(UpdateInfo info) {
    switch (_phase) {
      // ── 正在下载
      case _UpdPhase.downloading:
        final p = _progress;
        final frac = p?.fraction;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // ⚠️ 刻意**总是给 value**（拿不到进度就给 0），不用"不确定进度条"：
            //    那种是**无限动画**，而点击遍历测试（clickthrough）会一直等不到静止。
            LinearProgressIndicator(value: frac ?? 0, minHeight: 6),
            const SizedBox(height: 6),
            Text(
              p == null
                  ? context.tr('正在连接…')
                  : (frac == null
                      ? context.tr('已下载 {0}', [formatBytes(p.received)])
                      : context.tr('{0} / {1} · {2}/秒', [
                          formatBytes(p.received),
                          formatBytes(p.total),
                          formatBytes(p.bytesPerSecond.round()),
                        ])),
              style: TextStyle(color: DshColors.textDim, fontSize: 11.5),
            ),
            const SizedBox(height: 6),
            OutlinedButton(
              onPressed: () => _cancel?.cancel(),
              child: Text(context.tr('取消下载')),
            ),
          ],
        );

      // ── 下载好了（安装按钮就在这儿）
      case _UpdPhase.downloaded:
      case _UpdPhase.installing:
        final sig = _sig;
        final matched = sig?.matched ?? false;
        final canInstall = _env?.canInstall ?? false;
        final busy = _phase == _UpdPhase.installing;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(matched ? Icons.verified : Icons.gpp_bad,
                    size: 15,
                    color: matched ? DshColors.accent : DshColors.err),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                      matched
                          ? context.tr('已下载，校验通过')
                          : context.tr('已下载，但签名对不上'),
                      style: TextStyle(
                          color: matched ? DshColors.accent : DshColors.err,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            DshRichText(
              matched
                  ? context.tr('文件哈希对得上、签名与当前应用**同一把**，可以装。')
                  : sig?.message ?? context.tr('校验没通过。'),
              style: TextStyle(
                  color: DshColors.textDim, fontSize: 11, height: 1.45),
            ),
            const SizedBox(height: 8),
            if (matched) ...<Widget>[
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: busy ? null : _install,
                  icon: const Icon(Icons.system_update_alt, size: 18),
                  label: Text(busy
                      ? context.tr('正在交给系统…')
                      : (canInstall
                          ? context.tr('安装（会弹出系统安装界面）')
                          : context.tr('先允许「安装未知应用」'))),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                context.tr('最后那一下**一定要你亲手点** —— Android 不允许普通应用自己装东西。'
                    '装完回到这里就是新版，数据不会丢。'),
                style: TextStyle(
                    color: DshColors.textFaint, fontSize: 11, height: 1.45),
              ),
            ] else ...<Widget>[
              Text(
                context.tr('出于安全，这个包不会给你装。'),
                style: TextStyle(
                    color: DshColors.err, fontSize: 11.5, height: 1.45),
              ),
            ],
            if (_ioNotice != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(_ioNotice!,
                  style: TextStyle(
                      color: DshColors.textDim, fontSize: 11.5, height: 1.45)),
            ],
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                if (busy)
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                else
                  TextButton(
                    onPressed: () => _download(info),
                    style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 30)),
                    child: Text(context.tr('重新下载'),
                        style: const TextStyle(fontSize: 11.5)),
                  ),
                TextButton(
                  onPressed: () => _openUrl(_variant?.url ?? info.url),
                  style: TextButton.styleFrom(
                      padding: EdgeInsets.zero, minimumSize: const Size(0, 30)),
                  child: Text(context.tr('改用浏览器下载'),
                      style: const TextStyle(fontSize: 11.5)),
                ),
                TextButton(
                  onPressed: _openInstallPermission,
                  style: TextButton.styleFrom(
                      padding: EdgeInsets.zero, minimumSize: const Size(0, 30)),
                  child: Text(context.tr('打开「安装未知应用」设置'),
                      style: const TextStyle(fontSize: 11.5)),
                ),
              ],
            ),
          ],
        );

      // ── 还没下（默认）
      case _UpdPhase.idle:
        // 这一次会下哪个包，界面要**提前**说清（大小、含不含运行环境）——
        // 别让用户点了下载才发现"怎么有 97 MB"。
        final v = _variant ??
            info.pickVariant(runtimeReady: widget.runtime.isUnpacked);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _download(info),
                icon: const Icon(Icons.download, size: 18),
                label: Text(v.size != null && v.size! > 0
                    ? context.tr('下载到本机（{0}）', [formatBytes(v.size!)])
                    : context.tr('下载到本机')),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              widget.runtime.isUnpacked
                  ? context.tr('这次下的是**精简包**（不含运行环境）—— 这台手机上已经有了，'
                      '所以能省下那份流量。')
                  : context.tr('这次下的是**完整包**（含运行环境）—— 因为这台手机上还没有，'
                      '这样装完就能直接打开、不需要联网再补。'),
              style: TextStyle(
                  color: DshColors.textFaint, fontSize: 11, height: 1.45),
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () => _openUrl(v.url),
              style: TextButton.styleFrom(
                  padding: EdgeInsets.zero, minimumSize: const Size(0, 30)),
              child: Text(context.tr('或者用浏览器下载'),
                  style: const TextStyle(fontSize: 11.5)),
            ),
            const SizedBox(height: 2),
            DshRichText(
              context.tr('下载在**本机**做，断了能接着下；装之前会**验两样** —— '
                  '文件哈希（没下坏）+ 签名（跟现在这个 App 是同一把钥匙签的）。'
                  '签名对不上就不给你装，这是防止包被替换的那道闸。'),
              style: TextStyle(
                  color: DshColors.textFaint, fontSize: 11, height: 1.45),
            ),
            if (_ioNotice != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(_ioNotice!,
                  style: TextStyle(
                      color: DshColors.textDim,
                      fontSize: 11.5,
                      height: 1.45)),
            ],
          ],
        );
    }
  }

  /// 检查失败：如实说原因，并给一个"看看卡在哪一步"的展开区。
  ///
  /// 为什么要把每个源的失败原因都留着：三条源全不通时，用户最需要知道的是
  /// **是不是被网络挡了**、以及**该不该换个镜像** —— 只说"检查失败"等于没说。
  Widget _failureBlock(UpdateCheckResult r) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(r.errorZh ?? context.tr('检查失败，原因不明。'),
            style: TextStyle(
                color: DshColors.err, fontSize: 11.5, height: 1.5)),
        if (r.tried.isNotEmpty) ...<Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => _showTried = !_showTried),
              style: TextButton.styleFrom(
                  padding: EdgeInsets.zero, minimumSize: const Size(0, 30)),
              child: Text(
                  _showTried
                      ? context.tr('收起细节')
                      : context.tr('看看卡在哪一步'),
                  style: const TextStyle(fontSize: 11.5)),
            ),
          ),
          if (_showTried)
            for (final t in r.tried)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: SelectableText('· $t',
                    style: TextStyle(
                        color: DshColors.textFaint,
                        fontSize: 10.5,
                        height: 1.4)),
              ),
        ],
      ],
    );
  }

  /// 更新源：显示现在用的是内置源还是自填的，并允许改。
  ///
  /// 为什么把这条通道**摆在界面上**而不是藏起来：国内访问 GitHub 时好时坏，
  /// 用户在别处有能通的镜像时，自己填一条比我们猜哪个站可用靠谱得多。
  Widget _sourceEditor(AppSettings s) {
    final custom = s.updateSource;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(context.tr('更新源'),
            style: TextStyle(
                color: DshColors.text,
                fontSize: 13,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        DshRichText(
          custom.isEmpty
              ? context.tr('现在用内置的两条源（GitHub 原站为主、jsDelivr 兜底），'
                  '**一般不用动**。如果这两条在你那边连不上，把你自己的镜像地址填进来。')
              : context.tr('现在用你填的这一条。清空后保存就回到内置的两条源。'),
          style: TextStyle(
              color: DshColors.textFaint, fontSize: 11, height: 1.5),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _sourceCtrl,
          maxLines: 1,
          style: const TextStyle(fontSize: 12),
          decoration: InputDecoration(
            isDense: true,
            hintText: defaultUpdateSources().first,
            hintStyle: TextStyle(color: DshColors.textFaint, fontSize: 11),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            OutlinedButton(
                onPressed: _saveSource, child: Text(context.tr('保存'))),
            if (custom.isNotEmpty)
              TextButton(
                onPressed: () {
                  _sourceCtrl.clear();
                  _saveSource();
                },
                child: Text(context.tr('恢复内置源')),
              ),
            TextButton(
              onPressed: () => _openUrl(kReleasesPage),
              child: Text(context.tr('打开发布页')),
            ),
          ],
        ),
      ],
    );
  }
}
