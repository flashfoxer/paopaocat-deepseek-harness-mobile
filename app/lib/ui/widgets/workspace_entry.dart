import 'package:flutter/material.dart';

import '../theme/dsh_tokens.dart';

import '../../i18n/dsh_i18n.dart';

/// 「工作区」入口（图标 + 文字）。
///
/// **为什么要做成共用组件**：首页顶栏和对话页顶栏都放它，而且必须是
/// **同一个功能、同一个样子**（用户要求：对话页右上角那个「模型设置」按钮
/// 改成工作区入口，"和首页右上角工作区一个功能"）。两处各抄一份的话，
/// 改一次样式要改两处，很快就会长得不一样。
///
/// **为什么图标后面还要文字**：只用图标用户不知道是干嘛的 —— 上一版首页
/// 就是个列表图标 + 角标数字，用户原话"不知道是干嘛的"。
///
/// **它到底干什么**：打开工作区管理器（`WorkspacePage`）—— 看有哪些工作区、
/// 每个工作区下有哪些会话、切工作区、恢复历史会话。不管从首页点还是从
/// 对话页点，进的都是**同一个页面**（回调由 `AppShell` 提供，见 `_openWorkspace`）。
class WorkspaceEntryButton extends StatelessWidget {
  const WorkspaceEntryButton({
    super.key,
    required this.onTap,
    this.compact = false,
  });

  final VoidCallback onTap;

  /// 紧凑版：对话页顶栏要塞下「停止 / 产物 N / 工作区」，横向留白收一点。
  /// 图标与字号**刻意不变** —— 不然两个入口看起来不像同一个东西。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: context.tr('工作区'),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 7 : 9,
            vertical: 5,
          ),
          decoration: BoxDecoration(
            color: DshColors.surface,
            borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
            border: Border.all(color: DshColors.divider, width: 0.8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_open, size: 15, color: DshColors.accent),
              const SizedBox(width: 5),
              Text(
                context.tr('工作区'),
                style: TextStyle(
                  color: DshColors.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
