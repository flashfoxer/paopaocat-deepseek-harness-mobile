/// 「本地大模型」——底部导航第 2 项。
///
/// ## 这一页为什么存在
///
/// 用户 2026-10-09 要求：本地大模型**不再藏在设置页里**，而是给它一个正经入口
/// （首页右边的 Tab）。这一页只做两件事：
///   1. 讲清**本地大模型是什么、能做什么、代价是什么**（如实，不吹）；
///   2. 给两个按钮 —— 「本地对话」（直接开聊）与「设置」（下载/导入/启动/后端…）。
///
/// 也就是说：**设置页里那份「本地大模型」已经搬到这一页的「设置」按钮后面**，
/// 不再两处各放一份（以前用户要点进设置才找得到）。
library;

import 'package:flutter/material.dart';

import '../../i18n/dsh_i18n.dart';
import '../../local/dsh_runtime.dart';
import '../../local/local_model_server.dart';
import '../../state/app_settings.dart';
import '../theme/dsh_tokens.dart';
import '../widgets/common.dart';
import '../widgets/dsh_panel.dart';
import 'local_chat_page.dart';
import 'ondevice_models_page.dart';

class LocalModelHomePage extends StatefulWidget {
  const LocalModelHomePage({
    super.key,
    required this.runtime,
    required this.settings,
    required this.onModelChanged,
    this.refreshTick = 0,
  });

  final DshRuntime runtime;
  final AppSettings settings;
  final Future<void> Function() onModelChanged;

  /// 底部 Tab 切到本页时的刷新计数（见 app_shell 的 `_pageTicks`）——
  /// 换了模型/装了新模型回来，状态行要跟着变。
  final int refreshTick;

  @override
  State<LocalModelHomePage> createState() => _LocalModelHomePageState();
}

class _LocalModelHomePageState extends State<LocalModelHomePage> {
  @override
  void didUpdateWidget(covariant LocalModelHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshTick != widget.refreshTick && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final server = LocalModelServer.instance;
    final running = server.running;
    final spec = server.spec;
    return Scaffold(
      backgroundColor: DshColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            DshPageHeader(
              title: context.tr('本地大模型'),
              subtitle: context.tr('在手机上跑，不联网、不花额度'),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
                children: <Widget>[
                  _statusCard(context, running, spec?.displayName, spec?.port),
                  const SizedBox(height: 12),
                  _intro(context),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => _openChat(context),
                      icon: const Icon(Icons.chat_bubble_outline, size: 18),
                      label: Text(context.tr('本地对话')),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => _openSettings(context),
                      icon: const Icon(Icons.tune, size: 18),
                      label: Text(context.tr('设置：下载模型 / 启动服务 / 后端 / 知识库 / 联网')),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 服务现状（一行能看清"现在在跑什么"）。
  Widget _statusCard(
      BuildContext context, bool running, String? name, int? port) {
    return DshGlassCard(
      child: Row(
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: running ? DshColors.accent2 : DshColors.textFaint,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              running
                  ? (name == null
                      ? context.tr('本地模型服务：运行中')
                      : context.tr('运行中 · {0} · 127.0.0.1:{1}', [
                          name,
                          '${port ?? 0}',
                        ]))
                  : context.tr('本地模型服务没在运行 —— 点「设置」启动它'),
              style: TextStyle(
                  color: running ? DshColors.text : DshColors.textDim,
                  fontSize: 12.5,
                  height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  /// 如实介绍：能做什么、代价是什么。**不写"跟云端一样聪明"这种话**。
  Widget _intro(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _para(context, '这是什么',
              '把一个小模型（1–2B）下到手机里，本机推理。装完之后断网也能对话，'
                  '不消耗任何云端额度 —— 因为它压根不联网。'),
          _para(context, '它擅长 / 不擅长',
              '适合：翻译、润色、归类、闲聊、读你给它的资料（知识库）后回答问题。\n'
                  '不擅长：当"会自己动手的 Agent"。真机实测过：让它在**会话里**'
                  '按 DSH 的 Agent 协议干活（约 7k tokens 系统提示 + 工具），'
                  '1–2B 的模型会吐多语种乱码、还会把工具调用当正文写出来。'
                  '所以本地模型这条路**只做简单对话**，会话里不再列它。'),
          _para(context, '怎么让它更能干',
              '① 装**知识库**（本地百科/你自己的资料）——提问时先查、把命中的段落'
                  '附在问题里，事实题会明显变好；\n'
                  '② 打开 **🔍 联网**（内置免费源，不用配 Key）——补"最新"那部分；\n'
                  '③ 会看图的模型（Gemma 4 E2B）可以**发图**直接问。'),
          _para(context, '代价（如实说）',
              '慢：CPU 上约 11 tok/s、GPU 约 22–33 tok/s（真机实测），'
                  '比云端慢很多；上下文只有 16k，聊长了会满；'
                  '而且它**真的只能在手机上跑**，关掉服务就没了。'),
        ],
      );

  Widget _para(BuildContext context, String title, String body) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(context.tr(title),
                style: TextStyle(
                    color: DshColors.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(context.tr(body),
                style: TextStyle(
                    color: DshColors.textDim, fontSize: 11.5, height: 1.55)),
          ],
        ),
      );

  Future<void> _openChat(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LocalChatPage(
          dshHome: widget.runtime.nodeHome,
          settings: widget.settings,
          runtime: widget.runtime,
          onModelChanged: widget.onModelChanged,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openSettings(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OnDeviceModelsPage(
          runtime: widget.runtime,
          onModelChanged: widget.onModelChanged,
          settings: widget.settings,
        ),
      ),
    );
    if (mounted) setState(() {});
  }
}
