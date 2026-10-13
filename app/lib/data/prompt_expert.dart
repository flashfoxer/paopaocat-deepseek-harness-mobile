import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../i18n/dsh_i18n.dart';
import '../state/provider_keys.dart';
import 'chat_model_rule.dart';
import 'configured_models.dart';

/// 「提示词助手」—— 手机上最省事的一项：**你打一句话，它扩写成专业提示词**。
///
/// ## 为什么这个功能在手机上价值最大
///
/// 桌面插件里那 6 个「提示词专家」是给键盘用户准备的；手机上打一段
/// "主体+动作+运镜+光线+风格" 的提示词非常累，**打字才是这条路上最贵的一步**。
/// 所以这里做成：一句话 → 专业提示词 → 一键填进输入框 → 直接生成。
///
/// ## 一条硬约定：模型**只许返回提示词本身**
///
/// 系统提示里明确要求"不要解释、不要前后缀、不要引号"。因为结果会被
/// **直接写进输入框** —— 模型要是回一句"好的，这是为你写的提示词：…"，
/// 用户就得自己删一遍，那还不如不打字。万一它还是带了套话，
/// [cleanPrompt] 会尽力剥掉常见外壳（但这是兜底，不是主要手段）。
class PromptExpert {
  const PromptExpert({
    required this.key,
    required this.icon,
    required this.name,
    required this.hint,
    required this.system,
  });

  final String key;
  final String icon;
  final String name;

  /// 输入框里的例子（手机上给例子比给说明有用）。
  final String hint;

  /// 系统提示词。
  final String system;
}

/// 6 类专家 —— 与桌面插件的「提示词专家」一一对应（名字一致，便于你两边找同一个）。
const List<PromptExpert> kPromptExperts = <PromptExpert>[
  PromptExpert(
    key: 't2i',
    icon: '🖼',
    name: '文生图专家',
    hint: '例如：一个穿汉服的女孩在樱花树下弹古筝',
    system: '你是 AI 绘图提示词专家。把用户的一句话扩写成可直接用于文生图的提示词：'
        '主体与外貌、动作、构图与镜头、环境与光线、风格与画质。'
        '只输出**提示词本身**，一行，不要解释、不要前后缀、不要引号、不要分点。'
        '中文，60-120 字。',
  ),
  PromptExpert(
    key: 'i2i',
    icon: '🎨',
    name: '图生图专家',
    hint: '例如：把这张产品图的背景换成海边黄昏',
    system: '你是 AI 改图提示词专家。用户会描述想怎么改一张已有图。'
        '把它写成精准的改图指令：**改什么**、**保留什么**、风格与光线。'
        '只输出**提示词本身**，一行，不要解释、不要引号。中文，50-100 字。',
  ),
  PromptExpert(
    key: 't2v',
    icon: '🎬',
    name: '文生视频专家',
    hint: '例如：一只猫在夕阳下的海滩散步',
    system: '你是 AI 视频提示词专家。把用户的一句话写成文生视频提示词：'
        '主体 + **一个连续动作** + 镜头运动（推拉摇移跟拍固定）+ 环境与光线 + 风格与节奏。'
        '⚠️ 只写一个连续动作（写"先…然后…再…"会导致动作变形）；'
        '不要要求画面里出现文字/字幕/logo。'
        '只输出**提示词本身**，一行，不要解释、不要引号。中文，60-120 字。',
  ),
  PromptExpert(
    key: 'sheet',
    icon: '🧍',
    name: '角色三视图专家',
    hint: '例如：28岁职场女性，干练短发',
    system: '你是角色设定提示词专家。根据用户描述生成**角色三视图**（正面/侧面/背面）'
        '绘图提示词：年龄气质、脸型发型、服装材质与颜色、体态、纯色背景、全身、'
        '同一角色一致的设定图。只输出**提示词本身**，一行，不要解释、不要引号。中文，60-120 字。',
  ),
  PromptExpert(
    key: 'drama',
    icon: '🎭',
    name: '短剧剧本专家',
    hint: '例如：外卖员逆袭成集团继承人',
    system: '你是竖屏短剧编剧。根据用户的一句话写一个 60 秒左右的竖屏短剧片段：'
        '开头 3 秒必须有钩子、中段一个反转、结尾留悬念。'
        '只输出**正文**（场景 + 动作 + 台词），不要解释、不要标题、不要分点。中文。',
  ),
  PromptExpert(
    key: 'anchor',
    icon: '🎙',
    name: '数字人口播专家',
    hint: '例如：介绍一款降噪耳机，突出性价比',
    system: '你是口播稿作者。根据用户的一句话写一段适合 TTS 朗读的口播稿：'
        '口语化、短句、有节奏、开头 5 秒抓住人。'
        '只输出**稿件正文**，不要解释、不要标注、不要分点、不要 emoji。中文。',
  ),
];

/// ⚠️ **i18n 扫描器的锚点**（不要删）。
///
/// 上面那些专家的**名字与例子是以数据形式**写在 `kPromptExperts` 里的，
/// 而 i18n 扫描器只收集源码里**字面量形式**的 `tr('…')` ——
/// 数据里的字符串它看不见，于是这些文案**永远不会被翻译**，
/// 切到日语/英语时专家列表还是中文。
///
/// 所以这里显式把每条字面量以 `tr('…')` 出现一次：界面上真正取用的是
/// `context.tr(expert.name)`（`ui/pages/media_page.dart`），
/// 这一段只负责"让扫描器看得到"。新增专家时**这里也要加一行**。
///
/// 为什么 `system` 提示词不在此列：那是给**模型**看的指令（不是界面文案），
/// 与 App 其它模型侧文本（AGENTS.md / toolNotes）一样保持中文。
// ignore: unused_element
void _i18nAnchors() {
  tr('文生图专家');
  tr('图生图专家');
  tr('文生视频专家');
  tr('角色三视图专家');
  tr('短剧剧本专家');
  tr('数字人口播专家');
  tr('例如：一个穿汉服的女孩在樱花树下弹古筝');
  tr('例如：把这张产品图的背景换成海边黄昏');
  tr('例如：一只猫在夕阳下的海滩散步');
  tr('例如：28岁职场女性，干练短发');
  tr('例如：外卖员逆袭成集团继承人');
  tr('例如：介绍一款降噪耳机，突出性价比');
}

/// 一次扩写的结果。
class PromptExpandResult {
  const PromptExpandResult({
    required this.ok,
    this.text,
    this.error,
    this.tryNextCandidate = false,
  });

  final bool ok;
  final String? text;

  /// 这个失败"换个模型再试一次"有没有意义。
  ///
  /// 只有"模型名 / 路由不对"（400 / 404 / 422）才为 true；
  /// 限流、超时、网络不通都是 false —— 换一个候选也只是换个地方失败。
  final bool tryNextCandidate;

  /// 已经翻好的中文原因（界面直接显示）。
  final String? error;
}

/// 把 [input] 按 [expert] 扩写。
///
/// ## 用哪个模型（用户 2026-10-12 报的那条 400）
///
/// ① **优先用你当前选中的那个模型**（`models.json` 的 `selected`）——
///    它就是你在会话里用的那个；点「扩写」却偷偷换成别的，本来就说不通。
///    ⚠️ 选中项是**轮换组**（`rotate/xxx`）时跳过：组名不是模型名，
///    发给上游必然失败，这时退到 ②。
/// ② 再按 `models.json` 的顺序往下兜底，**但只挑能聊天的**：
///    图像 / 视频模型（Agnes 的内置媒体端口）不走 `/chat/completions`，
///    发过去只会得到 400 —— 这就是「提示词专家返回 400」的根因。
///    规则与设置页**共用一份**，见 `data/chat_model_rule.dart`。
///
/// 候选会**依次真的试**：某个模型 400 / 404 / 422 时自动换下一个。
/// 限流（429）、超时、网络不通**不换** —— 那类问题换个模型也只是换个地方失败，
/// 还会让用户白等。
Future<PromptExpandResult> expandPrompt({
  required PromptExpert expert,
  required String input,
  required ConfiguredConfig cfg,
  Duration timeout = const Duration(seconds: 90),
}) async {
  final candidates = await _pickCandidates(cfg);
  if (candidates.isEmpty) {
    return PromptExpandResult(
      ok: false,
      error: tr('还没有可用的云端模型：请先在「设置 → 模型」里配好一个（填 Key 并保存）。'),
    );
  }

  var tried = 0;
  PromptExpandResult? last;
  for (final picked in candidates.take(_kMaxCandidates)) {
    tried++;
    final r = await _expandWith(picked, expert, input, timeout);
    if (r.ok) return r;
    last = r;
    if (!r.tryNextCandidate) break;
  }

  // 试了不止一个还是全挂 → 把"试了几个"也说出来。
  // 这条信息正是这次修 bug 时最缺的：界面上只显示一句 HTTP 400，只能靠猜。
  var err = last?.error ?? tr('扩写失败。');
  if (tried > 1) {
    err = tr('已经依次试过 {0} 个模型，都不行。最后这个的报错是：{1}',
        <Object?>['$tried', err]);
  }
  return PromptExpandResult(ok: false, error: err);
}

/// 用 [picked] 发一次请求。
Future<PromptExpandResult> _expandWith(
  _Picked picked,
  PromptExpert expert,
  String input,
  Duration timeout,
) async {
  final url =
      '${picked.baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions';
  // 报错时要能一眼看出"用的哪个模型、发去了哪台机器"。
  final host = Uri.tryParse(url)?.host ?? picked.baseUrl;
  final who = '${picked.modelId} @ $host';
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await client.postUrl(Uri.parse(url));
    req.headers.contentType = ContentType.json;
    req.headers.set('authorization', 'Bearer ${picked.apiKey}');
    req.headers.set('accept', 'application/json');
    req.add(utf8.encode(jsonEncode(<String, Object>{
      'model': picked.modelId,
      'messages': <Map<String, String>>[
        <String, String>{'role': 'system', 'content': expert.system},
        <String, String>{'role': 'user', 'content': input},
      ],
      // 温度略高一点：提示词要有点想象力；max_tokens 给够但不夸张。
      'temperature': 0.8,
      'max_tokens': 800,
    })));
    final resp = await req.close().timeout(timeout);
    final body = await resp.transform(utf8.decoder).join();
    if (resp.statusCode == 429) {
      return PromptExpandResult(
          ok: false, error: tr('模型这边被限流了（429）。等一会儿再点，或换一个模型。'));
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final code = resp.statusCode;
      return PromptExpandResult(
        ok: false,
        // 400 / 404 / 422 = "这个模型名、或这条路不对" → 值得换下一个候选再试。
        tryNextCandidate: code == 400 || code == 404 || code == 422,
        error: tr('模型返回 HTTP {0}（用的是 {1}）：{2}', <Object?>[
          '$code',
          who,
          _head(body, 200),
        ]),
      );
    }
    final text = _extractContent(body);
    if (text == null || text.trim().isEmpty) {
      return PromptExpandResult(
          ok: false, error: tr('模型没有返回可用文本：{0}', <Object?>[_head(body, 200)]));
    }
    return PromptExpandResult(ok: true, text: cleanPrompt(text));
  } on TimeoutException {
    return PromptExpandResult(ok: false, error: tr('等模型回复超时了，再点一次试试。'));
  } catch (e) {
    debugPrint('[dsh-prompt-expert] 扩写失败：$e');
    return PromptExpandResult(ok: false, error: tr('请求失败：{0}', <Object?>['$e']));
  } finally {
    client.close(force: true);
  }
}

/// 一个候选：端点 + 凭据 + 要发给上游的模型名。
typedef _Picked = ({
  String baseUrl,
  String apiKey,
  String modelId,
  String providerId,
});

/// 最多依次试几个候选。
///
/// 为什么要有上限：清单里可能有二十几个模型，全试一遍就是二十几次网络往返 ——
/// 用户点一下「✨ 写专业点」要等好几分钟，那比报错还糟。
const int _kMaxCandidates = 3;

/// 挑出可以拿来扩写的模型，**按优先级排好**。
///
/// 顺序：① 你选中的那个（轮换组除外）→ ② 其余按 `models.json` 顺序。
/// 只收「有 baseUrl + 有凭据 + 能聊天」的，见 `data/chat_model_rule.dart`。
Future<List<_Picked>> _pickCandidates(ConfiguredConfig cfg) async {
  final out = <_Picked>[];
  final seen = <String>{};

  Future<void> consider(String providerId, String modelId) async {
    if (!seen.add('$providerId/$modelId')) return;
    final p = cfg.providerOf(providerId);
    if (p == null) return;
    final base = p.baseUrl.trim();
    if (base.isEmpty) return;
    // ⚠️ 这两行就是那个 400 的解药：媒体模型、非 OpenAI 协议的厂家，直接不要。
    if (!isChatModelFor(providerId, modelId)) return;
    if (!isOpenAiCompatible(p)) return;

    final key = await ProviderKeys.read(p.id);
    if (key == null || key.trim().isEmpty) {
      // 「凭据由 App 自己提供」的厂家（免费模型 / 本机模型）：安全区里**永远没有**
      // 它们的 Key，但两边的接收端（本地 zen 代理 / 本机模型服务）都不校验它。
      // 不这样判的后果：只开了免费通道的用户点「扩写」会被告知"没有可用模型"，
      // 而模型明明就在他手边 —— 与 ModelStore 同一口径（见 appProvidedCredentialIds）。
      if (!ConfiguredModels.appProvidedCredentialIds.contains(p.id)) return;
      out.add((
        baseUrl: base,
        apiKey: 'app-provided',
        modelId: modelId,
        providerId: p.id,
      ));
      return;
    }
    out.add((
      baseUrl: base,
      apiKey: key.trim(),
      modelId: modelId,
      providerId: p.id,
    ));
  }

  // ① 选中的那个排最前。轮换组（`rotate/xxx`）不是模型名，跳过。
  final sel = cfg.selected?.trim() ?? '';
  if (sel.isNotEmpty &&
      !sel.startsWith('${ConfiguredModels.rotateProviderId}/')) {
    final m = cfg.modelOfRoute(sel);
    if (m != null) await consider(m.provider, m.id);
  }

  // ② 其余按清单顺序兜底。
  for (final m in cfg.models) {
    await consider(m.provider, m.id);
  }
  return out;
}

/// 从 OpenAI 风格的响应里取正文（`choices[0].message.content`）。
String? _extractContent(String body) {
  try {
    final json = jsonDecode(body);
    if (json is! Map) return null;
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final first = choices.first;
    if (first is! Map) return null;
    final msg = first['message'];
    if (msg is Map && msg['content'] is String) return msg['content'] as String;
    // 少数实现把正文放在 text 里
    if (first['text'] is String) return first['text'] as String;
    return null;
  } catch (_) {
    return null;
  }
}

/// 剥掉模型偶尔多写的"外壳"（兜底，主要靠系统提示）。
///
/// 处理：首尾引号、`提示词：` 这类前缀、``` 代码围栏、以及末尾的解释段。
String cleanPrompt(String raw) {
  var s = raw.trim();
  // ```…``` 围栏
  final fence = RegExp(r'^```[a-zA-Z]*\s*([\s\S]*?)\s*```$').firstMatch(s);
  if (fence != null) s = fence.group(1)!.trim();
  // 常见前缀
  s = s.replaceFirst(
      RegExp(r'^(好的[，,]?|当然[，,]?)?\s*(这是|以下是)?\s*(为你?(写的|生成的))?\s*'
          r'(专业的)?\s*(绘图|改图|视频|口播|剧本)?\s*(提示词|稿件|正文|剧本)?\s*[:：]\s*'),
      '');
  // 首尾引号（成对才剥）
  for (final q in <List<String>>[
    <String>['"', '"'],
    <String>["'", "'"],
    <String>['“', '”'],
    <String>['「', '」'],
  ]) {
    if (s.length > 1 && s.startsWith(q[0]) && s.endsWith(q[1])) {
      s = s.substring(1, s.length - 1).trim();
    }
  }
  // 末尾单独一段解释（"这段提示词…"/"希望…"）——只处理"最后一段很短且不像提示词"的情况
  final parts = s.split(RegExp(r'\n\s*\n'));
  if (parts.length > 1) {
    final last = parts.last.trim();
    final looksLikeMeta = RegExp(r'^(以上|这段|希望|可以|如需|需要我)').hasMatch(last) &&
        last.length < 60;
    if (looksLikeMeta) s = parts.sublist(0, parts.length - 1).join('\n\n').trim();
  }
  return s.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
}

String _head(String s, int n) =>
    s.length <= n ? s : '${s.substring(0, n)}…';
