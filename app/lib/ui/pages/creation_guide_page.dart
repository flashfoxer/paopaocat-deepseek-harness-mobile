import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../theme/dsh_tokens.dart';
import '../session_start.dart';
import '../../i18n/dsh_i18n.dart';

/// 「创作 · 小说改游戏」的说明页（创作台里的一个入口）。
///
/// ## 为什么是"说明页"而不是一个按钮流
///
/// 用户 2026-10-12 的口径是「创作台里的创作入口先做**小说改游戏**这一条线，
/// 以'一条主线能走通'为准」。而这条线的**执行主体是七个技能**（随包，见
/// `data/builtin_skills.dart` 里那 7 个 `novel-to-game` 系列）——
/// 技能是给**会话里的模型**读的，不是给我们自己写一套 UI 去驱动它。
///
/// 所以这一步只做三件事，**每件都是真的**：
///   1. 说清这条线是什么、分几个阶段（让用户知道会发生什么）；
///   2. 给一句**可直接复制的起始指令**（复制走 → 到会话里发出去 → 模型就会走这条流程）；
///   3. 如实写清边界（手机上只能做网页游戏、示例库没随包、题材要自己把握）。
///
/// ⚠️ 刻意**没有**放"开始创作"的按钮：这一页拿不到"开会话"的能力（那在壳层），
///    放一个点了没反应的按钮比不放更坏。做成"一键入口"要把壳层的开会话能力引进来，
///    列入后续（见台账）。
class CreationGuidePage extends StatelessWidget {
  const CreationGuidePage({super.key, this.onStart});

  /// 带首句开一个新会话（由壳层提供）。
  ///
  /// ⚠️ 可以为 null（比如测试里单独 pump 这一页）：那时**不显示**「开始」按钮 ——
  /// 宁可少一个按钮，也不放一个点了没反应的。
  final void Function(String prompt)? onStart;

  /// 起始指令（用户复制这句话到任意会话里发出去，模型就会走这条流程）。
  ///
  /// **必须点名 `novel-to-game`**：技能是靠"名字 + 简介"被模型发现的，
  /// 不点名它可能只是自由发挥写一段设定，而不是走这七个阶段。
  static const String startPrompt = '用 novel-to-game 技能，把我这本小说改编成一个能在浏览器里玩的游戏。\n'
      '\n'
      '小说在这里：（把小说文件放进工作区告诉我文件名；或者直接把正文粘贴过来）\n'
      '想要什么感觉：（一句话，比如"以对话和选择推进、多结局"）\n'
      '给谁玩：（一句话，比如"我自己玩，能玩 20 分钟就行"）';

  /// 七个阶段（与随包的那 7 个技能一一对应）。
  static const List<({String skill, String what})> stages = <({String skill, String what})>[
    (skill: 'novel-to-game', what: '总入口：编排整条流程，先问清你的要求'),
    (skill: 'novel-game-analyze', what: '拆原著：世界规则、玩家能做什么、空间、角色、系统（都要引原文）'),
    (skill: 'game-concept', what: '比选几个游戏方向，用硬否决和取舍挑一个'),
    (skill: 'game-world-design', what: '收成设计稿：核心循环、系统、关卡节奏、成败条件'),
    (skill: 'game-art-direction', what: '定美术方向：视觉身份、视听反馈、关键瞬间'),
    (skill: 'game-build', what: '真的做出来：按目标运行环境构建可运行的游戏'),
    (skill: 'game-qa', what: '在运行环境里实跑并留证据：渲染、输入、核心循环、至少一个结局'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DshColors.bg,
      appBar: AppBar(title: Text(context.tr('创作 · 小说改游戏'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
        children: <Widget>[
          _card(
            context,
            title: context.tr('这是什么'),
            child: Text(
              context.tr('把**一本小说**改编成**一个能在浏览器里玩的游戏**。'
                  '它不是"AI 自己玩"，也不是"AI 对战" —— 是一套有原著依据的改编流程：'
                  '每一步都要引原文，最后要拿运行证据说话。'),
              style: TextStyle(color: DshColors.textDim, fontSize: 12.5, height: 1.6),
            ),
          ),
          const SizedBox(height: 12),
          _card(
            context,
            title: context.tr('会经过七个阶段'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (var i = 0; i < stages.length; i += 1)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 7),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SizedBox(
                          width: 18,
                          child: Text('${i + 1}',
                              style: TextStyle(
                                  color: DshColors.accent,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700)),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(context.tr(stages[i].what),
                                  style: TextStyle(
                                      color: DshColors.text, fontSize: 12.5, height: 1.45)),
                              Text(stages[i].skill,
                                  style: DshFonts.code(
                                      color: DshColors.textFaint, fontSize: 10.5)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _card(
            context,
            title: context.tr('怎么开始'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  onStart != null
                      ? context.tr('点下面的按钮**直接开一个新会话**（首句就是这段起始指令）；'
                          '也可以自己复制走，发到任意会话里。')
                      : context.tr('复制下面这段，到「首页」的任意会话里发出去'
                          '（把括号里的内容换成你的）。模型看到就会走这条流程。'),
                  style: TextStyle(color: DshColors.textDim, fontSize: 12.5, height: 1.6),
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: DshColors.bgSoft,
                    borderRadius:
                        BorderRadius.circular(DshMetrics.radius(DshMetrics.controlRadius)),
                    border: Border.all(color: DshColors.line),
                  ),
                  child: SelectableText(
                    context.tr(startPrompt),
                    style: TextStyle(
                        color: DshColors.text, fontSize: 12, height: 1.6),
                  ),
                ),
                const SizedBox(height: 10),
                if (onStart != null)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () {
                        // 直接开一个新会话，首句就是这段起始指令（用户可以在会话里再改）。
                        // ⚠️ 顺序交给 `closeThenStart`（先关自己、再开会话）——
                        //    写反了会把刚推上去的会话页弹掉（2026-10-12 真机反馈第 7 条）。
                        closeThenStart(context, onStart!, context.tr(startPrompt));
                      },
                      icon: const Icon(Icons.auto_stories_outlined, size: 16),
                      label: Text(context.tr('开始一个改编会话')),
                    ),
                  ),
                if (onStart != null) const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(
                          ClipboardData(text: context.tr(startPrompt)));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(context.tr('已复制，去首页的会话里粘贴发送'))),
                      );
                    },
                    icon: const Icon(Icons.copy_all_outlined, size: 15),
                    label: Text(context.tr('复制起始指令'), style: const TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _card(
            context,
            title: context.tr('边界（如实说）'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final t in <String>[
                  context.tr('手机上只能做**网页游戏**（HTML/JS）—— 它能在本 App 的资料库里直接打开玩。'
                      'Unity / Godot 那类做不到，要如实说。'),
                  context.tr('做游戏很花时间：一部小说从拆解到能玩，通常是**多轮对话**的事，'
                      '不是一句话就出成品。'),
                  context.tr('上游那套自带的示例游戏（含成人向题材）**没有随包**；'
                      '题材与分级请自己把握。'),
                  context.tr('这七个技能来自 NovelToGame v0.4.0（MIT 许可），'
                      '只改写了简介并加了署名，正文与参考文件保持原样。'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('· $t',
                        style: TextStyle(
                            color: DshColors.textFaint, fontSize: 11.5, height: 1.5)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, {required String title, required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DshColors.surfaceStrong,
        borderRadius:
            BorderRadius.circular(DshMetrics.radius(DshMetrics.controlRadius)),
        border: Border.all(color: DshColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title,
              style: TextStyle(
                  color: DshColors.text,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}
