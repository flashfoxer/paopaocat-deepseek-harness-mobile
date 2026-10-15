import 'package:flutter/material.dart';

import '../theme/dsh_tokens.dart';

import '../../i18n/dsh_i18n.dart';

/// 底部输入区（设计稿每个对话页底部都是这个形态）。
///
/// **设计稿的纵向次序（这一条是我上一轮做反的，OCR 坐标是硬证据）**：
///
/// | 元素 | 设计稿 y | 屏高比例 |
/// |---|---|---|
/// | 胶囊输入框（`按住说话` / `发消息或按住说话`） | 2301~2354 | 87.2%~89.2% |
/// | 当前模型按钮（如 `Hy4preview`） | 2292~2346 | 86.8%~88.9% |
/// | 底部导航 5 项标签 | 2567~2610 | 97.2%~98.9% |
///
/// 也就是**模型按钮在胶囊下方**（两者几乎同一带，模型按钮是右侧的一个小胶囊），
/// 而输入区整体贴在底部导航之上。上一轮把它放在了输入框上方，属于读图错误。
///
/// [readOnly] = true 时整个胶囊是一个按钮（任务首页用它"点一下进对话页"），
/// false 时是可输入的真实 TextField。
/// [voiceMode] = true 时右侧出现麦克风，**按住说话是真的**（见 [onVoiceState]：
/// 按下启动系统语音识别、松手停止，结果回填输入框）。
///
/// ⚠️ 这条注释原来写的是"占位交互"，而实现早就是真的了（chat_page 的
/// `_onVoiceState` → `_startSpeech`/`_stopSpeech`）—— 属于会误导下一个人的过时注释。
class InputBar extends StatelessWidget {
  const InputBar({
    super.key,
    this.controller,
    required this.hintText,
    required this.modelName,
    this.readOnly = false,
    this.enabled = true,
    this.onTap,
    this.onTapModel,
    this.onTapAttach,
    this.onSend,
    this.onCancel,
    this.running = false,
    this.voiceMode = false,
    this.canSend = false,
    this.voiceHeld = false,
    this.onVoiceState,
  });

  final TextEditingController? controller;
  final String hintText;
  final String modelName;
  final bool readOnly;
  final bool enabled;
  final VoidCallback? onTap;
  final VoidCallback? onTapModel;
  final VoidCallback? onTapAttach;
  final VoidCallback? onSend;

  /// 运行中时右下角变成「停止」
  final VoidCallback? onCancel;
  final bool running;

  /// 是否启用"按住说话"（设计稿只有对话页有这个入口）
  final bool voiceMode;

  /// 输入框里有没有内容 —— 有内容时右侧按钮变成「发送」。
  /// 由调用方在 controller 的监听里维护并 setState。
  final bool canSend;

  /// 当前是否处于按住状态（由外层持有，便于同时驱动上方提示条）
  final bool voiceHeld;

  /// 按住状态变化：`held=true` 按下，`false` 松开
  final void Function(bool held)? onVoiceState;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (onTapAttach != null) ...[
              _CircleButton(
                icon: Icons.add,
                onTap: enabled ? onTapAttach : null,
                tooltip: context.tr('添加附件'),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(child: _buildField(context)),
            // 右侧按钮在「麦克风」与「发送」之间切换。
            //
            // 为什么必须切换：设计稿 page-02 的胶囊只有 `按住说话`（当时没有文字），
            // page-11 是 `发消息或按住说话`。如果恒显麦克风，用户打了字就没有发送
            // 入口（实测只能靠软键盘回车）—— 这是上一版引入的真实可用性缺口。
            // 规则：输入框为空 → 麦克风（按住说话）；有文字 → 发送。
            if (voiceMode && !canSend) ...[
              const SizedBox(width: 8),
              _VoiceButton(
                enabled: enabled && !running,
                held: voiceHeld,
                onState: onVoiceState,
              ),
            ] else ...[
              const SizedBox(width: 8),
              _CircleButton(
                icon: running ? Icons.stop : Icons.arrow_upward,
                onTap: running ? onCancel : onSend,
                tooltip: running ? context.tr('停止') : context.tr('发送'),
                primary: true,
              ),
            ],
          ],
        ),
        // 模型按钮在输入框**下方**（设计稿 y=2292~2346），右对齐
        if (onTapModel != null)
          Padding(
            padding: const EdgeInsets.only(top: 7, right: 2),
            child: _ModelChip(name: modelName, onTap: onTapModel!),
          ),
      ],
    );
  }

  Widget _buildField(BuildContext context) {
    // 设计稿胶囊高 53 设计像素 ≈ 2.0% 屏高 ≈ 18dp 内文 + 上下 12dp = 42dp。
    // 这里锁成 46dp，和设计稿在屏高上的占比一致。
    const fieldHeight = 46.0;

    final field = Container(
      height: fieldHeight,
      alignment: Alignment.centerLeft,
      // 输入框的底必须**不透明**：原来用 `DshColors.surface`（深色下 7% 白），
      // 键入的正文会和页面渐变糊在一起 —— 用户 2026-10-15 的原话是
      // 「输入文字的时候和底版混在一起看不清」。见 [DshPalette.fieldFill]。
      decoration: BoxDecoration(
        color: DshColors.fieldFill,
        borderRadius: BorderRadius.circular(DshMetrics.inputRadius),
        border: Border.all(color: DshColors.line, width: 0.8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Text(
        (controller != null && controller!.text.isNotEmpty && readOnly)
            ? context.tr('发消息…')
            : hintText,
        style: TextStyle(color: DshColors.textFaint, fontSize: 13.5),
      ),
    );

    if (readOnly) {
      return Semantics(
        textField: true,
        label: hintText,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(DshMetrics.inputRadius),
          child: field,
        ),
      );
    }

    return Semantics(
      textField: true,
      label: hintText,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: fieldHeight),
        child: TextField(
          controller: controller,
          enabled: enabled,
          minLines: 1,
          maxLines: 5,
          textInputAction: TextInputAction.newline,
          keyboardType: TextInputType.multiline,
          style: TextStyle(color: DshColors.text, fontSize: 13.5, height: 1.4),
          cursorColor: DshColors.accent,
          decoration: InputDecoration(
            hintText: hintText,
            filled: true,
            // 同上：实色底，保证"正在键入的字"始终压在实底上。
            fillColor: DshColors.fieldFill,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(DshMetrics.inputRadius),
              borderSide: BorderSide(color: DshColors.line, width: 0.8),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(DshMetrics.inputRadius),
              borderSide: BorderSide(color: DshColors.line, width: 0.8),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(DshMetrics.inputRadius),
              borderSide: BorderSide(color: DshColors.accent, width: 1),
            ),
          ),
        ),
      ),
    );
  }
}

/// 当前模型按钮（设计稿 `Hy4preview`，输入框右下方的小胶囊）。
class _ModelChip extends StatelessWidget {
  const _ModelChip({required this.name, required this.onTap});

  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: context.tr('当前模型 {0}', [name]),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DshMetrics.radius(14)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            // 与输入框同一层实底：它俩是同一排控件，一个透一个不透会看着像两个 App。
            color: DshColors.fieldFill,
            borderRadius: BorderRadius.circular(DshMetrics.radius(14)),
            border: Border.all(color: DshColors.line, width: 0.8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bolt, size: 12, color: DshColors.accent),
              const SizedBox(width: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: DshColors.textDim, fontSize: 11),
                ),
              ),
              Icon(Icons.expand_more, size: 14, color: DshColors.textFaint),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「按住说话」按钮。
///
/// ⚠️ **这是明确的占位交互，不伪造识别结果**：
/// 本机 App 里没有语音识别链路（`speech_to_text` 之类会显著增加包体积与权限面），
/// 所以按住时只给视觉反馈（放大 + 变青 + 上方提示条），松手时如实告知"暂未接入"。
/// 不做"假装识别出一段文字"的事 —— 那会让用户以为功能坏了。
class _VoiceButton extends StatefulWidget {
  const _VoiceButton({
    required this.enabled,
    required this.held,
    required this.onState,
  });

  final bool enabled;
  final bool held;
  final void Function(bool held)? onState;

  @override
  State<_VoiceButton> createState() => _VoiceButtonState();
}

class _VoiceButtonState extends State<_VoiceButton> {
  @override
  Widget build(BuildContext context) {
    final on = widget.enabled;
    return Semantics(
      button: true,
      label: context.tr('按住说话'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPressStart: on ? (_) => widget.onState?.call(true) : null,
        onLongPressEnd: on ? (_) => widget.onState?.call(false) : null,
        onLongPressCancel: on ? () => widget.onState?.call(false) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: widget.held ? 54 : 46,
          height: widget.held ? 54 : 46,
          decoration: BoxDecoration(
            color: widget.held
                ? DshColors.accent
                : (on ? DshColors.surface : DshColors.surfaceHigh),
            shape: BoxShape.circle,
            border: Border.all(
              color: widget.held ? DshColors.accent : DshColors.divider,
              width: 0.8,
            ),
            boxShadow: widget.held
                ? [
                    BoxShadow(
                      color: DshColors.accent.withValues(alpha: 0.35),
                      blurRadius: 14,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: Icon(
            Icons.mic_none,
            size: 20,
            color: widget.held
                ? const Color(0xFF06211D)
                : (on ? DshColors.textDim : DshColors.textFaint),
          ),
        ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.primary = false,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: Material(
          color: primary
              ? (enabled ? DshColors.accent : DshColors.surfaceHigh)
              : DshColors.surface,
          shape: const CircleBorder(),
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: 46,
              height: 46,
              child: Icon(
                icon,
                size: 19,
                color: primary
                    ? (enabled ? const Color(0xFF06211D) : DshColors.textFaint)
                    : (enabled ? DshColors.textDim : DshColors.textFaint),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
