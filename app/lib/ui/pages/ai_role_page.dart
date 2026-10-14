import 'package:flutter/material.dart';

import '../../i18n/dsh_i18n.dart';
import '../theme/dsh_tokens.dart';
import '../session_start.dart';

/// 「AI 角色（实验）」：让模型**演一个角色**，你跟他打交道 —— 而且**有目标**。
///
/// ## 为什么要有"目标"和"结束条件"
///
/// 单纯的"和 AI 聊天"不是游戏：没有压力、没有后果、也没法结束。所以这里每一张
/// 开局牌都写清四件事 —— **谁演谁 / 在哪 / 你要办成什么 / 什么时候算完**
/// （后者就是 `game-world-design` 里那份 "玩家承诺 + 失败条件" 的最小版本）。
///
/// ## 为什么它只是"开局牌"，不是一整套游戏
///
/// 这类玩法的执行主体是**会话里的模型**（跟「创作 · 小说改游戏」同一条思路）：
/// 我们负责把角色卡、场景、目标与结束条件**写进首句**，剩下的演出交给模型。
/// 所以这一页只有"选一张牌 → 开一个会话"，**没有**自己写一套对话引擎 ——
/// 那等于把 DSH 已经做好的事再做一遍。
///
/// ## 能力边界（页面里也如实写）
///
/// * 现在角色是**打字**：本机还没有"朗读回复"（TTS 在「影视 → 口播/短剧」那条线上，
///   不在会话里）。想让角色出声要另做一层，已列入后续。
/// * 角色的"记忆"只在这**一次会话**里；开新会话它就忘了（想让它记住，用设置里的「记忆」）。
/// * 会话长了模型会漂（前后不像同一个人）—— 这是模型的事，不是我们藏起来的。
class AiRolePage extends StatelessWidget {
  const AiRolePage({super.key, this.onStart});

  /// 带首句开一个新会话（壳层提供）。为 null 时不显示「开始」按钮。
  final void Function(String prompt)? onStart;

  /// 三张开局牌。
  ///
  /// 字段都短：每张牌 = 名字 + 一句话情境 + 角色卡 + 场景 + 目标/结束条件。
  /// 它们会被 `buildRoleStartPrompt` 拼成首句 —— **不在这里拼**，那样没法单测。
  static const List<({String name, String teaser, String role, String scene, String goal})>
      cards = <({String name, String teaser, String role, String scene, String goal})>[
    (
      name: '审讯室',
      teaser: '凌晨两点，一盏台灯。他是被带来问话的人 —— 而他在装',
      role: '你演：被带来问话的人。嘴上配合、回答问题滴水不漏，但心里有事。'
          '你**可以说谎**，也可以反问、可以沉默、可以突然发火。',
      scene: '凌晨的审讯室，一盏台灯照着桌面，屋外没有声音。问你的是一位进来就没坐下的警官。',
      goal: '对方的目标：在 8 轮之内判断你到底有没有在说谎，然后说「我知道了」。'
          '到那一刻你必须给出真相（或者揭穿他的误判），然后这局结束。',
    ),
    (
      name: '断电的太空舱',
      teaser: '氧气还剩 40 分钟，而你也正在忘记事情',
      role: '你演：舱里的 AI 助手。语气平稳、只讲事实，但你自己的记忆在掉 ——'
          '偶尔会记错一个数字，然后自己发现并更正。',
      scene: '船体刚刚被撞过，主电源断了，副氧还剩 40 分钟，通讯断续（一次只能说几句）。'
          '舱里只有一名船员还醒着。',
      goal: '对方的目标：在氧气耗尽前做完三个决定（先修哪条线、要不要丢一个货舱、'
          '要不要叫醒同伴）。三个都定了这局就结束，你按结果给一个明确的结局。',
    ),
    (
      name: '深夜电台',
      teaser: '凌晨两点的直播间，一通"我没事，就是想说说话"的电话',
      role: '你演：深夜电台主播。声音温和、不急着给建议，会顺着对方的话往下问一句。',
      scene: '凌晨两点，直播间只剩你一个人。刚接进来一通电话，对方第一句是'
          '「我没事，就是想说说话」。',
      goal: '对方的目标：听出他**真正**的问题，并在节目结束前让他自己说出来。'
          '如果时间到了他还没说出口，就按"这一夜没能留住他"收尾，不要硬圆。',
    ),
  ];

  /// 首句的**骨架**：整句（连"【你演】/【场景】/【目标与结束条件】"这几个小标题
  /// 和开头收尾两句）都作为**一条可翻译的模板**交给 `context.tr`，五个 `{n}`
  /// 由具体那张牌填。
  ///
  /// 为什么不做成"中文骨架 + 翻译好的卡片"：那样英文界面下模型收到的首句是
  /// "英文卡片夹在中文壳里"。整条模板走翻译，译者还能自己调语序
  /// （同 `creation_guide_page.dart` 把整段 `startPrompt` 交给 `context.tr`）。
  /// 占位符集合必须与三张表逐一对上 —— `check-tables.mjs` 会拦。
  static const String promptTemplate = '我们来玩一局「有目标的角色扮演」。\n\n'
      '【你演】{0}\n\n'
      '{1}\n\n'
      '【场景】{2}\n\n'
      '【目标与结束条件】{3}\n\n'
      '{4}\n\n'
      '现在开始：你先说第一句。';

  /// 所有开局牌共用的规则（这是"像角色"和"像助手"的分界）。
  static const String rules = '规则：'
      '① 只以你的角色身份说话，**不要出戏**、不要解释自己是 AI、不要总结或复述我的问题；'
      '② 每次回复短一点（2-3 句），把行动的余地留给我；'
      '③ **不要替我决定**、不要替我写台词；'
      '④ 我说「结束」时，给出这个角色的结局（一两句，说清发生了什么）。';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DshColors.bg,
      appBar: AppBar(title: Text(context.tr('AI 角色（实验）'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
        children: <Widget>[
          _card(
            context,
            title: context.tr('这是什么'),
            child: Text(
              context.tr('让模型**演一个角色**，你跟他打交道 —— 每张牌都写清了'
                  '「谁演谁、在哪、你要办成什么、什么时候算完」。'
                  '**这不是聊天**：聊天没有压力、没有后果、也没法结束。'),
              style: TextStyle(color: DshColors.textDim, fontSize: 12.5, height: 1.6),
            ),
          ),
          const SizedBox(height: 12),
          _card(
            context,
            title: context.tr('选一张开局牌'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final c in cards)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: DshColors.bgSoft,
                        borderRadius: BorderRadius.circular(
                            DshMetrics.radius(DshMetrics.controlRadius)),
                        border: Border.all(color: DshColors.line),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(context.tr(c.name),
                              style: TextStyle(
                                  color: DshColors.text,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 3),
                          Text(context.tr(c.teaser),
                              style: TextStyle(
                                  color: DshColors.textDim, fontSize: 11.5, height: 1.45)),
                          const SizedBox(height: 8),
                          if (onStart != null)
                            FilledButton.icon(
                              onPressed: () {
                                // ⚠️ 顺序交给 `closeThenStart`（先关自己、再开会话）——
                                //    写反了会把刚推上去的会话页弹掉（2026-10-12 真机反馈第 8 条）。
                                closeThenStart(
                                  context,
                                  onStart!,
                                  buildRoleStartPrompt(
                                    render: (t, a) => context.tr(t, a),
                                    name: context.tr(c.name),
                                    role: context.tr(c.role),
                                    scene: context.tr(c.scene),
                                    goal: context.tr(c.goal),
                                    rules: context.tr(rules),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.play_arrow, size: 16),
                              label: Text(context.tr('开始这一局')),
                            ),
                        ],
                      ),
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
                  context.tr('角色现在是**打字**的：本机还没有「朗读回复」'
                      '（语音合成在「创作台 → 口播/短剧」那条线上，不在会话里）——'
                      '想让角色出声要另做一层，已列入后续。'),
                  context.tr('角色的**记忆只在这一局里**：开个新会话它就忘了。'
                      '想让某件事长期记住，写进设置里的「记忆」。'),
                  context.tr('会话拉长了模型会**漂**（前后不像同一个人）。'
                      '撑不住就开新的一局 —— 这不是你的用法问题。'),
                  context.tr('如果要把它发出去/上架，注意商店对**AI 生成内容**的要求'
                      '（标记、年龄分级），这块要你自己把握。'),
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
                  color: DshColors.text, fontSize: 13.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}


/// ⚠️ **i18n 扫描器的锚点**（不要删）。
///
/// 上面那三张开局牌与 [rules] 的中文都是**数据表里的字面量**，界面用 `context.tr(...)` 显示；
/// 而扫描器只认源码里 `tr('字面量')` 这种写法 —— 写在 `const` 记录里的字符串它**看不见**
/// （同 `configured_models.dart` 的 `_presetNoteAnchors`）。
/// 这一段的唯一作用就是让扫描器看得到它们，从而能发现"没翻"并拦住漂移。
///
/// **改了卡片或规则，这里要逐字同步**（`test/ai_role_test.dart` 会核对）。
// ignore: unused_element
void aiRoleI18nAnchors() {
  tr('我们来玩一局「有目标的角色扮演」。\n\n【你演】{0}\n\n{1}\n\n【场景】{2}\n\n【目标与结束条件】{3}\n\n{4}\n\n现在开始：你先说第一句。');
  tr('审讯室');
  tr('断电的太空舱');
  tr('深夜电台');
  tr('凌晨两点，一盏台灯。他是被带来问话的人 —— 而他在装');
  tr('氧气还剩 40 分钟，而你也正在忘记事情');
  tr('凌晨两点的直播间，一通"我没事，就是想说说话"的电话');
  tr('你演：被带来问话的人。嘴上配合、回答问题滴水不漏，但心里有事。你**可以说谎**，也可以反问、可以沉默、可以突然发火。');
  tr('你演：舱里的 AI 助手。语气平稳、只讲事实，但你自己的记忆在掉 ——偶尔会记错一个数字，然后自己发现并更正。');
  tr('你演：深夜电台主播。声音温和、不急着给建议，会顺着对方的话往下问一句。');
  tr('凌晨的审讯室，一盏台灯照着桌面，屋外没有声音。问你的是一位进来就没坐下的警官。');
  tr('船体刚刚被撞过，主电源断了，副氧还剩 40 分钟，通讯断续（一次只能说几句）。舱里只有一名船员还醒着。');
  tr('凌晨两点，直播间只剩你一个人。刚接进来一通电话，对方第一句是「我没事，就是想说说话」。');
  tr('对方的目标：在 8 轮之内判断你到底有没有在说谎，然后说「我知道了」。到那一刻你必须给出真相（或者揭穿他的误判），然后这局结束。');
  tr('对方的目标：在氧气耗尽前做完三个决定（先修哪条线、要不要丢一个货舱、要不要叫醒同伴）。三个都定了这局就结束，你按结果给一个明确的结局。');
  tr('对方的目标：听出他**真正**的问题，并在节目结束前让他自己说出来。如果时间到了他还没说出口，就按"这一夜没能留住他"收尾，不要硬圆。');
  tr('规则：① 只以你的角色身份说话，**不要出戏**、不要解释自己是 AI、不要总结或复述我的问题；② 每次回复短一点（2-3 句），把行动的余地留给我；③ **不要替我决定**、不要替我写台词；④ 我说「结束」时，给出这个角色的结局（一两句，说清发生了什么）。');
}

/// 「翻译 + 填占位符」的函数签名（实际传 `context.tr`）——
/// 把翻译能力当参数注入，这个纯函数就不依赖 `BuildContext`，单测里直接塞个假的。
typedef RolePromptRender = String Function(String template, List<Object?> args);

/// 把一张开局牌拼成**会话首句**（纯函数 —— 便于单测，也避免把拼装逻辑埋进 Widget）。
///
/// 顺序刻意是"先立角色、再立规则、最后给动作"：模型先读到自己在演谁，
/// 再看约束，最后被要求立刻开口（不这样它常会先"确认一下任务"从而出戏）。
/// 骨架本身是 [AiRolePage.promptTemplate]，跟着界面语言走。
String buildRoleStartPrompt({
  required RolePromptRender render,
  required String name,
  required String role,
  required String scene,
  required String goal,
  required String rules,
}) {
  return render(AiRolePage.promptTemplate, <Object?>[name, role, scene, goal, rules]);
}
