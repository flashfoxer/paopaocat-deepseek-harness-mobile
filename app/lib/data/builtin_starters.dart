import 'dart:math';

import 'package:flutter/material.dart';

import '../i18n/dsh_i18n.dart' show tr;

/// 首页「内置会话」的条目池（用户 2026-10-04 第 8 条反馈）。
///
/// 用户原话：
/// 「首页我看到你预置的四个内置会话（做一份幻灯片、视频制作工作台、进行数据分析
///   及可视化、进行文档处理）点击以后只是在会话有了几个字，是不是点任意一个开始
///   会调用相应的技能，同时点换一换也只是四个位置的不同，放 12 的内置会话怎么样。」
///
/// 他说的两点都是真的：
///   * 旧实现 `_onTapTip` 只是 `onOpenChat(initialText: 标题)`，把标题当文本填进去；
///   * `_shuffle()` 是 `(i + 1) % 4`，只有 4 条在循环顺延，看着就是"换个顺序"。
///
/// 现在改成：
///   * 池子有 13 条（[BuiltinStarters.all]）；
///   * 每条**绑一个随包内置的技能**（[BuiltinStarter.skill]，正文在
///     `assets/skills/<name>/SKILL.md`，由 `data/builtin_skills.dart` 装到手机上）；
///   * 点一条 → 开新会话，首句就是 [BuiltinStarter.prompt]（**点名技能**，
///     这样模型会真的走那条技能的流程，而不是只看到四个字）；
///   * 「换一换」→ 一次换一整组、**一轮里不重复**（见 [StarterDealer]）。
///
/// ⚠️ **池子大小可以随便加**（2026-10-12 从 12 加到 13 时特意改成这样）：
///    取法不再依赖"12 正好是 4 的整数倍"这个巧合，任何条数都成立 ——
///    理由写在 [StarterDealer] 的注释里（固定步长绕环在 13 条时会重叠）。
class BuiltinStarter {
  const BuiltinStarter({
    required this.skill,
    required this.title,
    required this.subtitle,
    required this.prompt,
    required this.icon,
  });

  /// 绑定的内置技能名（= `assets/skills/<name>/SKILL.md` 的目录名）。
  final String skill;

  /// 首页那一行显示的文字。
  final String title;

  /// 一句话说明（首页空间够时显示；不够就省略）。
  final String subtitle;

  /// 点下去之后填进输入框 / 直接发出去的第一句话。
  /// **必须点名技能**，否则模型不一定知道该用哪个技能。
  final String prompt;

  final IconData icon;
}

class BuiltinStarters {
  BuiltinStarters._();

  /// 首页一次显示几条。
  ///
  /// 用户 2026-10-04 明确要求：**「首页的内置对话改为 4 个一组」** —— 所以是 4，
  /// 「换一换」就是**换一整组**。
  ///
  /// ⚠️ 与**池子大小解耦**：13 条池子的分组由 [StarterDealer] 负责，它保证
  ///    "一轮内不重复"（点 ⌈13/4⌉ = 4 次看完 13 条），不再依赖"池子正好能被 4 整除"。
  static const int visibleCount = 4;

  static const List<BuiltinStarter> all = <BuiltinStarter>[
    BuiltinStarter(
      skill: 'make-slides',
      title: '做一份幻灯片',
      subtitle: '生成真正的 .pptx（不是 HTML 糊弄）',
      prompt: '用 make-slides 技能帮我做一份幻灯片。主题/材料：\n'
          '（把主题或要讲的内容写在这里，我先按你说的整理大纲，再生成 .pptx 文件并告诉你路径）',
      icon: Icons.slideshow_outlined,
    ),
    BuiltinStarter(
      skill: 'make-image',
      title: '生成一张图片',
      subtitle: 'Agnes 文生图（当前免费）',
      prompt: '用 make-image 技能帮我生成一张图片。画面描述：\n'
          '（写清主体、场景、风格、光线；我会直接生成图片文件并告诉你路径）',
      icon: Icons.image_outlined,
    ),
    BuiltinStarter(
      skill: 'make-video',
      title: '生成一段视频',
      subtitle: 'Agnes 文生视频（异步，等几分钟）',
      prompt: '用 make-video 技能帮我生成一段视频。画面描述：\n'
          '（写清主体、动作、镜头、时长；我会提交任务并等它生成好，然后给你文件路径）',
      icon: Icons.movie_creation_outlined,
    ),
    BuiltinStarter(
      skill: 'data-analysis',
      title: '数据分析与可视化',
      subtitle: 'CSV/JSON → 结论 + 图表',
      prompt: '用 data-analysis 技能帮我分析数据。数据文件在：\n'
          '（把文件路径或工作区文件名写在这里；我要看结论、关键数字和图表）',
      icon: Icons.insights_outlined,
    ),
    BuiltinStarter(
      skill: 'doc-processing',
      title: '文档处理',
      subtitle: '摘要 / 改写 / 纠错 / 转格式',
      prompt: '用 doc-processing 技能帮我处理这份文档：\n'
          '（写清文件路径与你要的结果：摘要、改写、纠错，还是转成 Markdown/HTML）',
      icon: Icons.description_outlined,
    ),
    BuiltinStarter(
      skill: 'doc-digest',
      title: '长文速读提炼',
      subtitle: '要点 + 时间线，别再让我读完',
      prompt: '用 doc-digest 技能帮我速读这份长文：\n'
          '（给出文件路径或粘贴内容；我要要点清单和一条时间线）',
      icon: Icons.menu_book_outlined,
    ),
    BuiltinStarter(
      skill: 'sheet-cleanup',
      title: '表格整理',
      subtitle: '去重 / 规范 / 分组汇总',
      prompt: '用 sheet-cleanup 技能帮我整理这张表：\n'
          '（给出 CSV 路径；说明要去重、统一格式，还是要按某列分组汇总）',
      icon: Icons.table_chart_outlined,
    ),
    BuiltinStarter(
      skill: 'code-tool',
      title: '代码小工具',
      subtitle: '写个 node 脚本并真的跑通',
      prompt: '用 code-tool 技能帮我写一个小工具并跑通。需求：\n'
          '（说清输入是什么、要输出什么；我会写成 node 脚本、真的执行一次、把结果给你）',
      icon: Icons.terminal_outlined,
    ),
    BuiltinStarter(
      skill: 'file-organize',
      title: '文件整理归档',
      subtitle: '批量重命名 / 分类移动',
      prompt: '用 file-organize 技能帮我整理工作区文件。目标：\n'
          '（说明按什么规则重命名或归档；动手前我会先把计划列给你确认）',
      icon: Icons.folder_open_outlined,
    ),
    BuiltinStarter(
      skill: 'translate-polish',
      title: '中英互译润色',
      subtitle: '双语对照，不是机翻腔',
      prompt: '用 translate-polish 技能帮我翻译并润色：\n'
          '（给出原文或文件路径，说明目标语言与语气；我要双语对照版）',
      icon: Icons.translate_outlined,
    ),
    BuiltinStarter(
      skill: 'study-cards',
      title: '生成学习卡片',
      subtitle: '把材料变成问答卡片',
      prompt: '用 study-cards 技能把这些材料变成学习卡片：\n'
          '（给出文件路径或主题；我要「问题 / 答案」成对的卡片，能直接背）',
      icon: Icons.school_outlined,
    ),
    BuiltinStarter(
      skill: 'weekly-report',
      title: '汇总一份周报',
      subtitle: '把这段时间的产物理成周报',
      prompt: '用 weekly-report 技能帮我写一份周报。时间范围与关注点：\n'
          '（比如"这周做的三件事"；我会先看工作区里的文件再汇总，不确定的地方会问你）',
      icon: Icons.event_note_outlined,
    ),
    // 第 13 条（2026-10-12）：**小说改游戏**这条创作线的首页入口。
    // 它对应的是本轮刚搬进来的 NovelToGame 那条流水线（7 个技能，见
    // `data/builtin_skills.dart` 的注释）。为什么要放进首页：它需要用户
    // **先把小说文件给我**，是个"从零开始"的场景 —— 工作台里那张说明卡
    // 用户得先想到去点，而首页这 4 条是他一进来就看见的。
    // ⚠️ 首句必须**如实说清"这是多轮"**：这条线要走 拆原著 → 选方向 → 设计 →
    //    构建 → 验；说成"一句话就能出游戏"就是骗人（模型也会被带成赶工）。
    BuiltinStarter(
      skill: 'novel-to-game',
      title: '把小说做成游戏',
      subtitle: '改编成能玩的网页游戏（要多轮对话）',
      prompt: '用 novel-to-game 技能把我这本小说做成一个能玩的游戏：\n'
          '（给出小说文件路径或书名。我会先拆原著、再比选方向，然后一步步做出'
          '能真跑的网页游戏 —— 这是一条多轮流水线，不是一轮就能交付的）',
      icon: Icons.sports_esports_outlined,
    ),
  ];

  /// 按名字取一条（找不到返回 null —— 调用方要如实处理，不要编一条假的）。
  static BuiltinStarter? bySkill(String skill) {
    for (final s in all) {
      if (s.skill == skill) return s;
    }
    return null;
  }


  /// i18n 锚点：**唯一作用是让扫描器看见这些字面量**（运行时用不到它）。
  ///
  /// 为什么"数据表串"必须靠它：`install/i18n/check-tables.mjs` 只把
  /// **被 `tr(…)` 包住**的串当"源码 key"（见该脚本的 extractSourceKeys），
  /// 而这三串写在 `const` 记录里（界面用 `context.tr(starter.title)` 查表）——
  /// 没有锚点它们**永远不会进 i18n 表**：切英/日/韩首页那 13 张卡还是中文，
  /// 而 `check-tables` 会报 0 漂移（它看不见，就以为没有）。
  ///
  /// ⚠️ 2026-10-12 这一处**同时有两个毛病**，只修一个都不够：
  ///   ① 没有任何锚点（数据串扫描器本来就看不见）；
  ///   ② 更要命的：`scan.mjs` 的 SKIP_FILES 里排着整个 `builtin_starters.dart`，
  ///      而那张名单是**按文件**跳的 —— 于是**连锚点也会被一起丢掉**
  ///      （我先补了锚点却仍然报"陈旧 39"，根因就是这个；已把该文件移出名单）。
  ///
  /// 核对手段：`test/builtin_starters_test.dart` 逐条断言"这三个串都在三张表里" ——
  /// 那一条**比扫源码更硬**（锚点里打错一个字也会被当场抓住）。
  ///
  /// 改文案的纪律：上面的数据表与这里**必须一起改**；只改数据表的话，
  /// 表里还是旧文案、界面查不到新文案，又变回露中文。
  // ignore: unused_element
  static void _starterI18nAnchors() {
    tr('做一份幻灯片');
    tr('生成真正的 .pptx（不是 HTML 糊弄）');
    tr('用 make-slides 技能帮我做一份幻灯片。主题/材料：\n（把主题或要讲的内容写在这里，我先按你说的整理大纲，再生成 .pptx 文件并告诉你路径）');
    tr('生成一张图片');
    tr('Agnes 文生图（当前免费）');
    tr('用 make-image 技能帮我生成一张图片。画面描述：\n（写清主体、场景、风格、光线；我会直接生成图片文件并告诉你路径）');
    tr('生成一段视频');
    tr('Agnes 文生视频（异步，等几分钟）');
    tr('用 make-video 技能帮我生成一段视频。画面描述：\n（写清主体、动作、镜头、时长；我会提交任务并等它生成好，然后给你文件路径）');
    tr('数据分析与可视化');
    tr('CSV/JSON → 结论 + 图表');
    tr('用 data-analysis 技能帮我分析数据。数据文件在：\n（把文件路径或工作区文件名写在这里；我要看结论、关键数字和图表）');
    tr('文档处理');
    tr('摘要 / 改写 / 纠错 / 转格式');
    tr('用 doc-processing 技能帮我处理这份文档：\n（写清文件路径与你要的结果：摘要、改写、纠错，还是转成 Markdown/HTML）');
    tr('长文速读提炼');
    tr('要点 + 时间线，别再让我读完');
    tr('用 doc-digest 技能帮我速读这份长文：\n（给出文件路径或粘贴内容；我要要点清单和一条时间线）');
    tr('表格整理');
    tr('去重 / 规范 / 分组汇总');
    tr('用 sheet-cleanup 技能帮我整理这张表：\n（给出 CSV 路径；说明要去重、统一格式，还是要按某列分组汇总）');
    tr('代码小工具');
    tr('写个 node 脚本并真的跑通');
    tr('用 code-tool 技能帮我写一个小工具并跑通。需求：\n（说清输入是什么、要输出什么；我会写成 node 脚本、真的执行一次、把结果给你）');
    tr('文件整理归档');
    tr('批量重命名 / 分类移动');
    tr('用 file-organize 技能帮我整理工作区文件。目标：\n（说明按什么规则重命名或归档；动手前我会先把计划列给你确认）');
    tr('中英互译润色');
    tr('双语对照，不是机翻腔');
    tr('用 translate-polish 技能帮我翻译并润色：\n（给出原文或文件路径，说明目标语言与语气；我要双语对照版）');
    tr('生成学习卡片');
    tr('把材料变成问答卡片');
    tr('用 study-cards 技能把这些材料变成学习卡片：\n（给出文件路径或主题；我要「问题 / 答案」成对的卡片，能直接背）');
    tr('汇总一份周报');
    tr('把这段时间的产物理成周报');
    tr('用 weekly-report 技能帮我写一份周报。时间范围与关注点：\n（比如"这周做的三件事"；我会先看工作区里的文件再汇总，不确定的地方会问你）');
    tr('把小说做成游戏');
    tr('改编成能玩的网页游戏（要多轮对话）');
    tr('用 novel-to-game 技能把我这本小说做成一个能玩的游戏：\n（给出小说文件路径或书名。我会先拆原著、再比选方向，然后一步步做出能真跑的网页游戏 —— 这是一条多轮流水线，不是一轮就能交付的）');
  }

}

/// 首页「换一换」的**发牌器**：手里是一副牌，每次发 [BuiltinStarters.visibleCount] 张，
/// 发到不够发了就**重新洗一副接在后面**。
///
/// ## 为什么不用"起点 +4 绕环"（原来的写法）
///
/// 原来靠的是 `(start + 4) % 12` —— 它成立**只因为 12 正好是 4 的整数倍**：
/// 起点序列是 0 → 4 → 8 → 0，三组 [0-3] [4-7] [8-11] 互不重叠，点 3 次正好看完 12 条。
/// 池子一旦变成 13 条，起点序列就变成 0 → 4 → 8 → 12 → 3 → 7 …（gcd(4,13)=1），
/// 相邻两组开始**互相叠**（第 4 组 = [12,0,1,2] 与第 1 组重 3 条），
/// 用户点几次就会看到"还是那几条"—— 他 2026-10-04 正是为这个观感提的意见。
///
/// 发牌器的性质（**对任意池子大小都成立**，n = 池子条数，k = 每次显示几条）：
///   * 前 `⌊n/k⌋` 批**互不重复**，正好覆盖 `k·⌊n/k⌋` 条；
///   * 剩下的 `n mod k` 条出现在**下一批的开头**（不会被吞掉），
///     这一批其余的几张从**新洗的一副**里补满 —— 所以**只有这一批会出现重复**。
///     这是 n 不是 k 的整数倍时**不可避免**的代价（凑满 k 张只能用已有的牌）；
///     替代方案是那一批只给 `n mod k` 张（13 条时就是"只显示 1 张卡"，更像坏掉）。
///   * 再往后就是新一轮（顺序也重新洗过）。
///
/// ⚠️ 首屏**故意保持声明顺序**（不是随机）：用户一进来看到的还是同样那 4 条，
///    行为与改动前一致；只有「换一换」换到第二轮之后才是新洗的顺序。
class StarterDealer {
  /// [pool] / [random] 可注入：测试里给固定种子就能得到可复现的结果。
  StarterDealer({List<BuiltinStarter>? pool, Random? random})
      : _pool = pool ?? BuiltinStarters.all,
        _random = random ?? Random() {
    _queue.addAll(_pool); // 第一轮：声明顺序
    _topUp();
  }

  final List<BuiltinStarter> _pool;
  final Random _random;
  final List<BuiltinStarter> _queue = <BuiltinStarter>[];

  int get _take =>
      BuiltinStarters.visibleCount.clamp(1, _pool.isEmpty ? 1 : _pool.length);

  /// 当前这一批（最多 [BuiltinStarters.visibleCount] 条；池子更小就全给）。
  List<BuiltinStarter> get current => List<BuiltinStarter>.unmodifiable(
        _queue.take(_take),
      );

  /// 换一整组：把**刚刚展示过的那一批**从队首移除，再补齐到一整批。
  ///
  /// 不变量（由 [_topUp] 维持）：调用本方法时队列长度**必然 ≥ [_take]**，
  /// 所以移除的正是 `current` 刚给出的那几张；队列短于一批的情况不会出现。
  void next() {
    final step = _take < _queue.length ? _take : _queue.length;
    _queue.removeRange(0, step);
    _topUp();
  }

  /// 保证队列里至少还有一批可发；不够就把**新洗的一副**接到队尾。
  void _topUp() {
    if (_pool.isEmpty) return;
    while (_queue.length < _take) {
      _queue.addAll(<BuiltinStarter>[..._pool]..shuffle(_random));
    }
  }
}
