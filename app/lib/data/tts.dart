import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../i18n/dsh_i18n.dart';
import '../local/dsh_runtime.dart';
import '../local/local_tts.dart';
import '../state/provider_keys.dart';

/// 口播 / 短剧的**文稿分段** + **配音**（默认走手机自带的 TTS，MiMo 是可选项）。
///
/// ⚠️ 这东西是给**网友**用的 App：配音**不能**要求某个云厂商的 Key。
/// 所以 [synthesizeSpeech] 默认 [TtsSource.system]（人人可用），MiMo 只是可选升级。
///
/// 规则照抄桌面端影视工具插件里那份（`anchor-engine.ts` 的 `segmentText`）——
/// 它是在真实使用中调出来的：分段太碎会让 TTS 一句一停、听感很跳；
/// 分段太长则字幕一行放不下、而且单次 TTS 请求也会变大。
///
/// 顺序：先按**句末标点**（。！？；）与换行切 → 把太短的并起来 → 把太长的按逗号再切。
class NarrationSegmenter {
  NarrationSegmenter._();

  /// 中文口播的粗略语速（字/秒）—— 只用来估算"这段大概读多久"，
  /// 不参与真实时长计算（真实时长由 ffprobe 探出来，见 make-narration.mjs）。
  static const double charsPerSec = 4.2;

  /// 一段最多多少字（字幕一行放得下、TTS 请求不至于太大）。
  static const int maxChars = 60;

  /// 把 [text] 切成分段。`minSegSec` 是最短时长（默认 1.6 秒），
  /// 比它更短的碎片会跟相邻的合并。
  static List<String> split(String text, {double minSegSec = 1.6}) {
    final clean = text.replaceAll('\r\n', '\n').trim();
    if (clean.isEmpty) return <String>[];

    // ① 按句末标点 / 换行切开（保留标点在上一段末尾）
    final rough = <String>[];
    final buf = StringBuffer();
    for (final rune in clean.runes) {
      final ch = String.fromCharCode(rune);
      if (ch == '\n') {
        final t = buf.toString().trim();
        if (t.isNotEmpty) rough.add(t);
        buf.clear();
        continue;
      }
      buf.write(ch);
      if ('。！？!?；;'.contains(ch)) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) rough.add(t);
        buf.clear();
      }
    }
    final tail = buf.toString().trim();
    if (tail.isNotEmpty) rough.add(tail);

    // ② 太短的并进上一段（合并后仍不超过上限）
    final minChars = (minSegSec * charsPerSec).round().clamp(6, maxChars);
    final merged = <String>[];
    for (final piece in rough) {
      if (merged.isNotEmpty) {
        final last = merged.last;
        if (last.length < minChars && (last + piece).length <= maxChars) {
          merged[merged.length - 1] = last + piece;
          continue;
        }
      }
      merged.add(piece);
    }

    // ③ 还超长的按逗号再切（优先在停顿处断，不要硬切字）
    final out = <String>[];
    for (final seg in merged) {
      if (seg.length <= maxChars) {
        out.add(seg);
        continue;
      }
      final parts = <String>[];
      final b = StringBuffer();
      for (final rune in seg.runes) {
        final ch = String.fromCharCode(rune);
        b.write(ch);
        if ('，,、'.contains(ch)) {
          parts.add(b.toString());
          b.clear();
        }
      }
      if (b.isNotEmpty) parts.add(b.toString());

      var cur = '';
      for (final p in parts) {
        if (cur.isNotEmpty && (cur + p).length > maxChars) {
          out.add(cur);
          cur = p;
        } else {
          cur += p;
        }
      }
      if (cur.isNotEmpty) out.add(cur);
    }

    // ④ 最后兜底：**单个逗号块本身就超长**时（没有可用的停顿点），硬切。
    //    没有这一步的话，"一段 70 多字、中间只有逗号"的文稿会产出一段超长字幕
    //    （一行放不下、TTS 单次请求也偏大）。实测过：这一步是必需的。
    final wrapped = <String>[];
    for (final seg in out) {
      if (seg.length <= maxChars) {
        wrapped.add(seg);
        continue;
      }
      for (var i = 0; i < seg.length; i += maxChars) {
        final end = (i + maxChars) > seg.length ? seg.length : i + maxChars;
        wrapped.add(seg.substring(i, end));
      }
    }
    return wrapped.map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  }
}

/// 配音从哪来。
///
/// ⚠️ **默认必须是 [system]**：这个 App 是给网友用的，不能假设他们注册过某家云 TTS。
/// 系统 TTS 人人都有、零配置、免费、可离线；MiMo 与 MiniMax 都是"想要更自然音色"
/// 时的**可选**升级，都要用户自己配 Key。
///
/// 三家**不是随便挑的**，各自有真实依据：
///   * [system] —— 手机自带的 `TextToSpeech`（`DshHost.ttsToFile`）；
///   * [mimo] —— 小米 MiMo `mimo-v2.5-tts`（官方文档的预置音色表，见 [kMimoVoices]）；
///   * [minimax] —— MiniMax `t2a_v2`（端点/入参/hex 回包照官方 CLI `mmx speech
///     synthesize` 的实现在 2026-10-12 逐行核对过，见 [synthesizeMinimax]）。
enum TtsSource {
  /// 手机自带的文字转语音（默认，无需任何配置）。
  ///
  /// ⚠️ **"无需配置"不等于"一定有"**：真机上遇到过整台手机**没有 TTS 引擎**
  /// （nubia NX809J / Android 16）——所以文案里不许写"任何设备都能用"。
  system,

  /// **本机离线配音**（sherpa-onnx + 中文 VITS 模型）——**零 Key、离线、免费**。
  ///
  /// 为什么加它（2026-10-13 用户要求）：「系统配音没有本机可用的吗，给一个方案」。
  /// 用户那台手机一个 TTS 引擎都没有，而云端两家都要 Key —— 只有自带引擎
  /// 才能保证"本机一定出得了声"。
  ///
  /// 代价（**如实**）：① 要**下一次模型**（31.5 MB，装好占约 32 MB）；
  /// ② APK 因为原生库大约长 10 MB（压缩后）；③ 音色比云端**机械**
  /// （VITS int8 多说话人模型）；④ 手机上的实际速度**尚未真机实测**。
  /// 选型、实测体积与实时率见 docs/本机离线配音-验证.md。
  local,

  /// MiMo（小米）的云端 TTS —— 音色更自然，但**需要用户自己配 Key**。
  mimo,

  /// MiniMax 的云端 TTS（`t2a_v2`）—— **第二家云配音**，同样需要 Key。
  ///
  /// 为什么要加第二家：用户 2026-10-12 的要求是"配音要做好"，而只绑一家云 TTS
  /// 等于"这家没号就用不了"。两家的 Key 各自独立存（`ProviderKeys`），
  /// 用户有哪家就用哪家。
  minimax,
}

/// 一个可选**音色**。
///
/// [id] 是**直接发给供应商的字段值**，绝不能翻译、不能"美化"——
/// 它是供应商的标识符（MiMo 甚至就是中文词本身，如 `冰糖`）。
/// [label] 才是界面显示名（中文原文，渲染处一律再过一层 `context.tr`）。
class TtsVoice {
  const TtsVoice(this.id, this.label, {this.hint = ''});

  final String id;
  final String label;

  /// 一句话说明（可空）。同样要在渲染处 `context.tr`。
  final String hint;
}

/// MiMo `mimo-v2.5-tts` 的**预置音色**。
///
/// 出处：小米官方文档《Speech Synthesis (MiMo-V2.5-TTS Series)》的
/// 「Built-in Voice List」表，以及官方仓库 `XiaomiMiMo/MiMo-Skills` 的
/// `skills/mimo-v2-5-tts/SKILL.md`（两份一致）—— 2026-10-12 核对。
/// **不要凭印象加音色**：文档之外的名字这个接口不认。
const List<TtsVoice> kMimoVoices = <TtsVoice>[
  TtsVoice('mimo_default', '默认（跟随集群）', hint: '国内集群是「冰糖」'),
  TtsVoice('冰糖', '冰糖', hint: '中文女声 · 活泼少女'),
  TtsVoice('茉莉', '茉莉', hint: '中文女声 · 知性'),
  TtsVoice('苏打', '苏打', hint: '中文男声 · 阳光少年'),
  TtsVoice('白桦', '白桦', hint: '中文男声 · 成熟'),
  TtsVoice('Mia', 'Mia', hint: '英文女声 · 活泼'),
  TtsVoice('Chloe', 'Chloe', hint: '英文女声 · 甜美'),
  TtsVoice('Milo', 'Milo', hint: '英文男声 · 阳光'),
  TtsVoice('Dean', 'Dean', hint: '英文男声 · 沉稳'),
];

/// MiniMax 的**兜底音色**（只有这一条是写死的）。
///
/// 为什么不全写死：MiniMax 的音色跟**账号**走，官方 CLI 是去
/// `POST {base}/v1/get_voice`（body `{"voice_type":"system"}`）**现拉**的，
/// 它自己的代码里没有任何音色清单（官方 CLI 仓库 `MiniMax-AI/cli`，
/// `src/commands/speech/voices.ts` + `src/client/endpoints.ts` 核对）。
/// 所以我们也不编：默认给官方 CLI 的默认音色，其余由用户在界面上**拉取**或手填。
const TtsVoice kMinimaxDefaultVoice =
    TtsVoice('English_expressive_narrator', 'MiniMax 默认（英文叙事）', hint: '官方 CLI 的默认音色');

/// 拉取音色列表时最多收多少条（防止把下拉框撑爆）。
const int kMinimaxVoiceLimit = 200;

/// **语速**三档 → 给界面用的中文标签（MiniMax 用它映射成 `speed` 倍率）。
///
/// ⚠️ MiMo **没有**数值语速参数：官方文档给的是"用自然语言指令描述语速"
/// （`user` 消息里的指令）。所以 [mimoSpeedHint] 把三档翻成指令词，
/// 而 MiniMax 走真正的 `voice_setting.speed`。
const List<({String label, double speed, String mimoHint})> kSpeedPresets =
    <({String label, double speed, String mimoHint})>[
  (label: '慢一点', speed: 0.85, mimoHint: '语速放慢一些，吐字清楚，停顿从容。'),
  (label: '正常', speed: 1.0, mimoHint: '语速中等，节奏稳定。'),
  (label: '快一点', speed: 1.2, mimoHint: '语速稍快一些，节奏紧凑但不含糊。'),
];

/// MiMo 支持的输出格式。
///
/// 官方文档的非流式示例给的就是 `wav`（流式才用 `pcm16`）——
/// **没有**看到 mp3 的写法，所以这一格不编 mp3：MiMo 出 wav。
const String kMimoAudioFormat = 'wav';

/// MiniMax 支持的输出格式（官方 CLI `T2A_FORMATS`：mp3 / pcm / flac / wav /
/// pcmu_raw / pcmu_wav / opus，默认 mp3）。我们只用最通用的 mp3。
const String kMinimaxAudioFormat = 'mp3';

/// 配音文件该用什么后缀（合成脚本按真实后缀交给 ffprobe，别写死 `.wav`）。
String ttsExtensionFor(TtsSource source) =>
    source == TtsSource.minimax ? '.$kMinimaxAudioFormat' : '.wav';

/// ⚠️ **i18n 扫描器的锚点**（不要删）。
///
/// 上面音色表里的 [TtsVoice.label] / [TtsVoice.hint] 与语速档的
/// `label` 都是**数据表里的字面量**，界面用 `context.tr(...)` 显示；
/// 而扫描器只认源码里 `tr('字面量')` 这种写法 —— 写在 `const` 记录里的
/// 字符串它**看不见**（同 `configured_models.dart` 的 `_presetNoteAnchors`）。
/// 这一段的唯一作用就是让扫描器看得到它们，从而能发现"没翻"并拦住漂移。
///
/// **改了上面任何一条文案，这里要逐字同步**（`test/tts_provider_test.dart`
/// 的「音色文案都在 i18n 锚点里」会核对）。
// ignore: unused_element
void ttsI18nAnchors() {
  tr('默认（跟随集群）');
  tr('国内集群是「冰糖」');
  tr('冰糖');
  tr('中文女声 · 活泼少女');
  tr('茉莉');
  tr('中文女声 · 知性');
  tr('苏打');
  tr('中文男声 · 阳光少年');
  tr('白桦');
  tr('中文男声 · 成熟');
  tr('Mia');
  tr('英文女声 · 活泼');
  tr('Chloe');
  tr('英文女声 · 甜美');
  tr('Milo');
  tr('英文男声 · 阳光');
  tr('Dean');
  tr('英文男声 · 沉稳');
  tr('MiniMax 默认（英文叙事）');
  tr('官方 CLI 的默认音色');
  tr('慢一点');
  tr('语速放慢一些，吐字清楚，停顿从容。');
  tr('正常');
  tr('语速中等，节奏稳定。');
  tr('快一点');
  tr('语速稍快一些，节奏紧凑但不含糊。');
}


/// 本机离线配音的错误 → 给用户看的中文（每条都要"说清怎么办"）。
String _localTtsMessage(LocalTtsException e) {
  switch (e.error) {
    case LocalTtsError.notInstalled:
      return tr('本机离线配音的模型还没装好（{0}）。到「配音 → 本机离线」点一下下载即可。',
          <Object?>[e.message]);
    case LocalTtsError.loadFailed:
      return tr('本机离线配音的引擎没能加载（{0}）。'
          '可能是安装包不完整，或这台机器的架构不受支持 —— 可以改用系统 / MiMo / MiniMax。',
          <Object?>[e.message]);
    case LocalTtsError.generateFailed:
    case LocalTtsError.emptyText:
    case LocalTtsError.badSpeaker:
      return tr('本机离线配音失败：{0}', <Object?>[e.message]);
  }
}

/// 一段文字**大概要读多久**（秒）—— 只在"没有配音"时用。
///
/// ## 为什么需要它（2026-10-13 用户要求「A 方案」）
///
/// 口播/短剧的每一镜时长本来取自**配音的真实长度**（合成脚本用 ffprobe 探）。
/// 可一旦这台手机没有可用的 TTS 引擎（真机上真发生了），以前是**整个流程中断、
/// 什么都拿不到**。现在改成"没有配音也把片子做出来"（画面 + 字幕 + 静音），
/// 而静音镜必须有个时长 —— 就用这个估算值，而不是写死一个 3 秒
/// （一句话和一段话都 3 秒，节奏会明显不对）。
///
/// ## 依据（可核对，不是拍脑袋）
///
/// 中文播报语速一般 **240–280 字/分钟**，即 **4–4.7 字/秒**，这里取 **4.5 字/秒**；
/// 标点算 0.6 个字（停顿比念字短）、空白算 0.3 个；末尾多给 0.4 秒收尾。
/// 上下限 1.5–12 秒，避免极短/极长的镜头把节奏带跑。
double estimateSpeechSeconds(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return 3;
  const punct = '，。！？；：、,.!?;:…—';
  var units = 0.0;
  for (final rune in trimmed.runes) {
    final ch = String.fromCharCode(rune);
    if (ch.trim().isEmpty) {
      units += 0.3;
    } else if (punct.contains(ch)) {
      units += 0.6;
    } else {
      units += 1;
    }
  }
  return (units / 4.5 + 0.4).clamp(1.5, 12.0);
}

/// 系统 TTS 的原生返回码 → 给用户看的中文。
///
/// 单独抽出来是因为这里每一条都要"说清怎么办"：
/// 不能说"配音失败"，得说"去系统设置装中文语音包，或改用 MiMo"。
String systemTtsMessage(String status) {
  if (status == 'ok') return '';
  if (status == 'no_engine') {
    // ⚠️ 这条是**真机上真遇到过的**（2026-10-12 反馈第 2/3 条）。所以它必须给出
    //    "两条都能走通的路"，而不是只说一句失败：
    //      ① 系统里装引擎（免费，但要用户去系统设置里折腾）；
    //      ② 改用云端两家（一步到位，但要一个 Key）。
    //    改这条文案前先想：用户看完知道下一步点哪儿吗？
    return tr('这台手机没有可用的「文字转语音」引擎（系统里一个都没装）。'
        '两条路：① 到「系统设置 → 语言与输入 → 文字转语音」装一个引擎并下载中文语音包；'
        '② 改用 MiMo 或 MiniMax 配音 —— 在「设置 → 云端大模型 → MiMo / MiniMax」里填一个 API Key 即可。');
  }
  if (status == 'no_lang') {
    return tr('这台手机没装中文语音数据。请到「系统设置 → 语言与输入 → 文字转语音」里'
        '下载中文语音包；或者改用 MiMo 配音（需要 Key）。');
  }
  if (status == 'no_text') return tr('没有可配音的文本。');
  if (status == 'bad_path') return tr('配音文件的路径不可写。');
  if (status == 'error:timeout') return tr('系统配音超时了（这台设备的语音引擎没有回应）。再试一次，或改用 MiMo。');
  return tr('系统配音失败：{0}', <Object?>[status]);
}

/// MiMo 配音（TTS）。契约来自桌面端插件的**实测**：
/// `POST {base}/chat/completions`，带一个 `audio` 块，WAV 以 base64 回在
/// `choices[0].message.audio.data`。
///
/// 为什么用 MiMo（而不是安卓系统自带的 TTS）：桌面端的口播用的就是它，
/// 两边一致；而且 App 本来就把 MiMo 作为一个厂家（模型设置里有它），
/// 用户填过的 Key 直接复用，不用再配一套。
class TtsResult {
  const TtsResult({required this.ok, this.file, this.bytes, this.error});

  final bool ok;
  final String? file;
  final int? bytes;

  /// 给用户看的中文原因（已翻译）。
  final String? error;
}

/// MiMo 两档端点：套餐 Key（`tp-` 开头）走另一个集群。
const String kMimoUrl = 'https://api.xiaomimimo.com/v1';
const String kMimoTokenPlanUrl = 'https://token-plan-cn.xiaomimimo.com/v1';

String mimoBaseUrlFor(String apiKey) =>
    apiKey.trim().startsWith('tp-') ? kMimoTokenPlanUrl : kMimoUrl;

/// 让声音听起来像"人在讲"，不像机器念（照抄桌面端那份风格提示）。
///
/// ⚠️ 这里**故意不含语速那句**：语速由用户选的档位拼在后面（见 [mimoSpeedHint]），
/// 否则文案里会同时出现两个互相打架的语速要求。
const String _ttsStyle =
    '自然、清晰、适合中文口播解说。语气有感染力、有起伏，像在给观众讲故事，不要平淡机械。';

/// **统一的配音入口**：[source] 决定用系统 TTS、MiMo 还是 MiniMax。
///
/// 口播/短剧都走这里 —— 界面默认给 [TtsSource.system]（人人可用），
/// 用户想要更自然的音色再自己切到 MiMo / MiniMax。
///
/// [voice] 是**供应商的音色 ID**（不翻译）；空 = 用该家的默认音色。
/// [speed] 是语速倍率（1.0 = 原速）：MiniMax 走它的 `voice_setting.speed`，
/// MiMo 没有这个参数、只能翻成自然语言指令（见 [kSpeedPresets]），
/// 系统 TTS 走原生 `rate`。
Future<TtsResult> synthesizeSpeech({
  required String text,
  required String outPath,
  TtsSource source = TtsSource.system,
  String? voice,
  double speed = 1.0,
  double? rate,
  double? pitch,
  Duration timeout = const Duration(seconds: 180),
}) async {
  if (source == TtsSource.local) {
    // 本机离线配音：引擎与模型都在设备上，不联网、不需要 Key。
    try {
      final paths = await DshHost.getPaths();
      final filesDir = (paths['filesDir'] as String?) ?? '';
      final tts = LocalTts(filesDir);
      if (!tts.installed) {
        // 缺文件时**说清缺什么、去哪儿装**，而不是抛一个底层异常
        return TtsResult(
          ok: false,
          error: tr('本机离线配音的模型还没装（缺 {0}）。'
              '在「配音 → 本机离线」那里点下载即可（31.5 MB，装好后离线可用、不用 Key）。',
              <Object?>[tts.missingFiles.join('、')]),
        );
      }
      // 音色（语音参数）用说话人编号：设置里那一格存的是字符串，这里解析成 int。
      final sid = int.tryParse((voice ?? '').trim()) ?? 0;
      final file = tts.synthesizeToWav(
        text: text,
        outPath: outPath,
        sid: sid,
        speed: speed,
      );
      final bytes = File(file).existsSync() ? File(file).lengthSync() : 0;
      if (bytes <= 0) {
        return TtsResult(ok: false, error: tr('本机离线配音写出了空文件，请再试一次。'));
      }
      return TtsResult(ok: true, file: file, bytes: bytes);
    } on LocalTtsException catch (e) {
      debugPrint('[dsh-tts] 本机离线配音失败：${e.error.name} ${e.message}');
      return TtsResult(ok: false, error: _localTtsMessage(e));
    } catch (e) {
      debugPrint('[dsh-tts] 本机离线配音异常：$e');
      return TtsResult(ok: false, error: tr('本机离线配音失败：{0}', <Object?>['$e']));
    }
  }
  if (source == TtsSource.system) {
    try {
      final status = await DshHost.ttsToFile(
        text: text,
        path: outPath,
        rate: rate,
        pitch: pitch,
      );
      if (status == 'ok') {
        final bytes = File(outPath).existsSync() ? File(outPath).lengthSync() : 0;
        if (bytes <= 0) {
          return TtsResult(ok: false, error: tr('系统配音写了空文件，请再试一次。'));
        }
        return TtsResult(ok: true, file: outPath, bytes: bytes);
      }
      return TtsResult(ok: false, error: systemTtsMessage(status));
    } catch (e) {
      debugPrint('[dsh-tts] 系统配音调用失败：$e');
      return TtsResult(ok: false, error: tr('系统配音失败：{0}', <Object?>['$e']));
    }
  }
  if (source == TtsSource.minimax) {
    return synthesizeMinimax(
      text: text,
      outPath: outPath,
      voice: voice,
      speed: speed,
      timeout: timeout,
    );
  }
  return synthesizeMimo(
    text: text,
    outPath: outPath,
    voice: voice,
    speed: speed,
    timeout: timeout,
  );
}

/// 把一段文本合成为音频，写到 [outPath]。成功时 [TtsResult.file] == outPath。
///
/// 契约（2026-10-12 照官方文档与官方 skill 逐条核对）：
/// `POST {base}/chat/completions`，带 `audio: {format, voice}`，
/// 音频以 base64 回在 `choices[0].message.audio.data`。
/// **要读的文本放 `assistant` 消息、风格指令放 `user` 消息** —— 官方文档明确写了
/// 「目标文本必须填在 `assistant`，不能放在 `user`」，我们原来就是这么发的。
Future<TtsResult> synthesizeMimo({
  required String text,
  required String outPath,
  String? voice,
  double speed = 1.0,
  Duration timeout = const Duration(seconds: 180),
}) async {
  final key = await ProviderKeys.read('mimo');
  if (key == null || key.trim().isEmpty) {
    return TtsResult(
      ok: false,
      error: tr('没有配置 MiMo（小米）的 API Key，无法配音。'
          '请在「设置 → 云端大模型 → MiMo」里填一个 Key，或改用系统配音。'),
    );
  }
  final url = '${mimoBaseUrlFor(key).replaceAll(RegExp(r'/+$'), '')}/chat/completions';
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await client.postUrl(Uri.parse(url));
    req.headers.contentType = ContentType.json;
    req.headers.set('authorization', 'Bearer ${key.trim()}');
    req.headers.set('accept', 'application/json');
    req.add(utf8.encode(jsonEncode(<String, Object>{
      'model': 'mimo-v2.5-tts',
      'messages': <Map<String, String>>[
        <String, String>{'role': 'user', 'content': _mimoStyle(speed)},
        // ⚠️ 要读的文本放在 **assistant** 消息里，风格提示放 user —— 官方文档的硬要求。
        <String, String>{'role': 'assistant', 'content': text},
      ],
      'audio': <String, String>{
        'format': kMimoAudioFormat,
        'voice': (voice == null || voice.trim().isEmpty)
            ? 'mimo_default'
            : voice.trim(),
      },
    })));
    final resp = await req.close().timeout(timeout);
    final body = await resp.transform(utf8.decoder).join();
    if (resp.statusCode == 401) {
      return TtsResult(ok: false, error: tr('配音认证失败（401）：MiMo 的 API Key 不对或没开通。'));
    }
    if (resp.statusCode == 429) {
      return TtsResult(ok: false, error: tr('配音被限流了（429）。等一会儿再试，或换一段更短的文本。'));
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      return TtsResult(
        ok: false,
        error: tr('配音失败 HTTP {0}：{1}', <Object?>['${resp.statusCode}', _head(body, 160)]),
      );
    }
    String? b64;
    try {
      final json = jsonDecode(body);
      final choices = json is Map ? json['choices'] : null;
      if (choices is List && choices.isNotEmpty) {
        final msg = (choices.first is Map) ? (choices.first as Map)['message'] : null;
        final audio = (msg is Map) ? msg['audio'] : null;
        if (audio is Map && audio['data'] is String) b64 = audio['data'] as String;
      }
    } catch (e) {
      debugPrint('[dsh-tts] 解析 MiMo 响应失败：$e');
    }
    if (b64 == null || b64.isEmpty) {
      return TtsResult(
        ok: false,
        error: tr('配音返回里没有音频数据（choices[0].message.audio.data）：{0}',
            <Object?>[_head(body, 160)]),
      );
    }
    final bytes = base64Decode(b64);
    return await _writeAudio(bytes, outPath);
  } on TimeoutException {
    return TtsResult(ok: false, error: tr('等配音超时了（{0} 秒）。再试一次，或把文稿拆短些。',
        <Object?>['${timeout.inSeconds}']));
  } catch (e) {
    debugPrint('[dsh-tts] 配音失败：$e');
    return TtsResult(ok: false, error: tr('配音请求失败：{0}', <Object?>['$e']));
  } finally {
    client.close(force: true);
  }
}

/// 找语速档对应的 MiMo 指令词（认不出就用"正常"那档）。
///
/// 为什么 MiMo 要这么绕：官方文档没有数值语速参数，只有**自然语言控制**
/// （`user` 消息里写"语速稍快"）。所以这里的"语速"是**拼进风格指令**的，
/// 不是发一个 `speed` 字段 —— 这点必须在代码里写清楚，否则下一个人会以为漏了参数。
String mimoSpeedHint(double speed) {
  var best = kSpeedPresets[1];
  var bestGap = (speed - best.speed).abs();
  for (final p in kSpeedPresets) {
    final gap = (speed - p.speed).abs();
    if (gap < bestGap) {
      best = p;
      bestGap = gap;
    }
  }
  return best.mimoHint;
}

String _mimoStyle(double speed) => '$_ttsStyle${mimoSpeedHint(speed)}';

/// MiniMax **语音合成（T2A v2）**。
///
/// 契约出处（2026-10-12 逐行核对官方 CLI 仓库 `MiniMax-AI/cli`，不是凭记忆）：
///   * 端点 `src/client/endpoints.ts` → `POST {base}/v1/t2a_v2`；
///     国内站 base = `https://api.minimax.cn`（与本 App「图像/视频模型」里
///     MiniMax 的 base 同一个，见 `media_models.dart`）；
///   * 鉴权 `src/client/http.ts` → `Authorization: Bearer <key>`；
///     密钥以 `sk-api-` 开头时官方改用 `x-api-key` 头 —— 两个都带上兼容写法没意义，
///     所以这里照官方**分流**；
///   * 请求体 `src/commands/speech/synthesize.ts` → `{model, text,
///     voice_setting:{voice_id, speed, vol, pitch}, audio_setting:{format,
///     sample_rate, bitrate, channel}, output_format:'hex', stream:false}`；
///   * 回包 `src/types/api.ts` 的 `SpeechResponse` → 音频在 `data.audio`，
///     是 **hex 字符串**（不是 base64！），要 hex 解码后写文件；
///     `base_resp.status_code != 0` 时 `status_msg` 是给用户看的原因。
Future<TtsResult> synthesizeMinimax({
  required String text,
  required String outPath,
  String? voice,
  double speed = 1.0,
  Duration timeout = const Duration(seconds: 180),
}) async {
  final key = await ProviderKeys.read('minimax');
  if (key == null || key.trim().isEmpty) {
    return TtsResult(
      ok: false,
      error: tr('没有配置 MiniMax 的 API Key，无法配音。'
          '请在「设置 → 云端大模型 → MiniMax」里填一个 Key，或改用系统配音。'),
    );
  }
  final trimmed = key.trim();
  final url = '${kMinimaxBaseUrl.replaceAll(RegExp(r'/+$'), '')}/v1/t2a_v2';
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await client.postUrl(Uri.parse(url));
    req.headers.contentType = ContentType.json;
    // 官方对 `sk-api-` 开头的密钥用 x-api-key，其余用 Bearer。
    if (trimmed.startsWith('sk-api-')) {
      req.headers.set('x-api-key', trimmed);
    } else {
      req.headers.set('authorization', 'Bearer $trimmed');
    }
    req.headers.set('accept', 'application/json');
    req.add(utf8.encode(jsonEncode(<String, Object>{
      'model': kMinimaxTtsModel,
      'text': text,
      'voice_setting': <String, Object>{
        'voice_id': (voice == null || voice.trim().isEmpty)
            ? kMinimaxDefaultVoice.id
            : voice.trim(),
        'speed': speed,
        'vol': 1.0,
        'pitch': 0,
      },
      'audio_setting': <String, Object>{
        'format': kMinimaxAudioFormat,
        'sample_rate': 32000,
        'bitrate': 128000,
        'channel': 1,
      },
      // 只要 hex：另一种 `url` 会回一个下载地址，还得再发一次请求。
      'output_format': 'hex',
      'stream': false,
    })));
    final resp = await req.close().timeout(timeout);
    final body = await resp.transform(utf8.decoder).join();
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      return TtsResult(
          ok: false, error: tr('配音认证失败（{0}）：MiniMax 的 API Key 不对或没开通。',
              <Object?>['${resp.statusCode}']));
    }
    if (resp.statusCode == 429) {
      return TtsResult(ok: false, error: tr('配音被限流了（429）。等一会儿再试，或换一段更短的文本。'));
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      return TtsResult(
        ok: false,
        error: tr('配音失败 HTTP {0}：{1}', <Object?>['${resp.statusCode}', _head(body, 160)]),
      );
    }
    String? hex;
    String? apiMsg;
    try {
      final json = jsonDecode(body);
      if (json is Map) {
        final base = json['base_resp'];
        if (base is Map) {
          final code = base['status_code'];
          if (code is int && code != 0) {
            apiMsg = '${base['status_msg'] ?? ''} ($code)';
          }
        }
        final data = json['data'];
        if (data is Map && data['audio'] is String) hex = data['audio'] as String;
      }
    } catch (e) {
      debugPrint('[dsh-tts] 解析 MiniMax 响应失败：$e');
    }
    if (apiMsg != null && apiMsg.trim().isNotEmpty) {
      return TtsResult(ok: false, error: tr('MiniMax 拒绝了这次配音：{0}', <Object?>[apiMsg]));
    }
    if (hex == null || hex.isEmpty) {
      return TtsResult(
        ok: false,
        error: tr('配音返回里没有音频数据（data.audio）：{0}', <Object?>[_head(body, 160)]),
      );
    }
    final bytes = minimaxHexToBytes(hex);
    if (bytes == null) {
      return TtsResult(ok: false, error: tr('配音返回的音频不是合法的 hex 数据。'));
    }
    return await _writeAudio(bytes, outPath);
  } on TimeoutException {
    return TtsResult(ok: false, error: tr('等配音超时了（{0} 秒）。再试一次，或把文稿拆短些。',
        <Object?>['${timeout.inSeconds}']));
  } catch (e) {
    debugPrint('[dsh-tts] MiniMax 配音失败：$e');
    return TtsResult(ok: false, error: tr('配音请求失败：{0}', <Object?>['$e']));
  } finally {
    client.close(force: true);
  }
}

/// 拉取 MiniMax 账号下的**音色列表**（官方 CLI 的 `mmx speech voices` 就是这个）。
///
/// `POST {base}/v1/get_voice`，body `{"voice_type":"system"}`，
/// 回包 `system_voice[]`（每项有 `voice_id` / `voice_name` / `description[]`）。
/// 失败**不编造**：返回空表并给出原因，界面如实显示。
Future<({List<TtsVoice> voices, String? error})> fetchMinimaxVoices({
  Duration timeout = const Duration(seconds: 30),
}) async {
  final key = await ProviderKeys.read('minimax');
  if (key == null || key.trim().isEmpty) {
    return (
      voices: const <TtsVoice>[],
      error: tr('没有配置 MiniMax 的 API Key，拉不到音色列表。'
          '请在「设置 → 云端大模型 → MiniMax」里填一个 Key。'),
    );
  }
  final trimmed = key.trim();
  final url = '${kMinimaxBaseUrl.replaceAll(RegExp(r'/+$'), '')}/v1/get_voice';
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await client.postUrl(Uri.parse(url));
    req.headers.contentType = ContentType.json;
    if (trimmed.startsWith('sk-api-')) {
      req.headers.set('x-api-key', trimmed);
    } else {
      req.headers.set('authorization', 'Bearer $trimmed');
    }
    req.add(utf8.encode(jsonEncode(<String, Object>{'voice_type': 'system'})));
    final resp = await req.close().timeout(timeout);
    final body = await resp.transform(utf8.decoder).join();
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      return (
        voices: const <TtsVoice>[],
        error: tr('拉取音色失败 HTTP {0}：{1}',
            <Object?>['${resp.statusCode}', _head(body, 160)]),
      );
    }
    final out = <TtsVoice>[];
    try {
      final json = jsonDecode(body);
      final list = json is Map ? json['system_voice'] : null;
      if (list is List) {
        for (final item in list) {
          if (item is! Map) continue;
          final id = item['voice_id'];
          if (id is! String || id.trim().isEmpty) continue;
          final name = item['voice_name'];
          final desc = item['description'];
          final hint = (desc is List)
              ? desc.whereType<String>().join(' · ')
              : (name is String ? name : '');
          out.add(TtsVoice(id.trim(), id.trim(), hint: hint));
          if (out.length >= kMinimaxVoiceLimit) break;
        }
      }
    } catch (e) {
      debugPrint('[dsh-tts] 解析 MiniMax 音色表失败：$e');
      return (voices: const <TtsVoice>[], error: tr('音色列表看不懂（返回不是预期的 JSON）。'));
    }
    if (out.isEmpty) {
      return (voices: const <TtsVoice>[], error: tr('这个账号下没有可用的系统音色。'));
    }
    return (voices: out, error: null);
  } on TimeoutException {
    return (voices: const <TtsVoice>[], error: tr('拉取音色超时了（{0} 秒）。', <Object?>['${timeout.inSeconds}']));
  } catch (e) {
    debugPrint('[dsh-tts] 拉取 MiniMax 音色失败：$e');
    return (voices: const <TtsVoice>[], error: tr('拉取音色失败：{0}', <Object?>['$e']));
  } finally {
    client.close(force: true);
  }
}

/// hex 字符串 → 字节。长度是奇数或含非 hex 字符时返回 null（不抛）。
///
/// ⚠️ MiniMax 的 `data.audio` 是 **hex**，MiMo 的 `message.audio.data` 是 **base64** ——
/// 两家不一样，别把 `base64Decode` 用到这里（会解码出垃圾或直接抛）。
///
/// 公开是为了能被单测直接钉住：解码错了不会报错，只会产出**能写进文件、但播不出来**
/// 的音频 —— 那种坏法只有到手机上放的时候才发现。
List<int>? minimaxHexToBytes(String hex) {
  final s = hex.trim();
  if (s.isEmpty || s.length.isOdd) return null;
  final out = <int>[];
  for (var i = 0; i < s.length; i += 2) {
    final b = int.tryParse(s.substring(i, i + 2), radix: 16);
    if (b == null) return null;
    out.add(b);
  }
  return out;
}

/// 落盘 + 空文件检查（两家云配音共用，避免各写一遍还各漏一处）。
Future<TtsResult> _writeAudio(List<int> bytes, String outPath) async {
  if (bytes.isEmpty) {
    return TtsResult(ok: false, error: tr('配音返回的音频是空的。'));
  }
  final f = File(outPath);
  await f.parent.create(recursive: true);
  await f.writeAsBytes(bytes);
  return TtsResult(ok: true, file: outPath, bytes: bytes.length);
}

/// MiniMax 国内站根地址（与 `media_models.dart` 里 MiniMax 的 base 同源）。
const String kMinimaxBaseUrl = 'https://api.minimax.cn';

/// MiniMax 语音合成的模型（官方 CLI 的默认值 `speech-2.8-hd`）。
const String kMinimaxTtsModel = 'speech-2.8-hd';

String _head(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';
