/// 本地大模型的「简单对话」——**不经过 DSH**，直连引擎的 OpenAI 兼容端点。
///
/// ## 为什么必须有这条路（真机 2026-10-09 实测，日志逐字可查）
///
/// 1–2B 的端侧模型吃不下 DSH 的 Agent 协议：一轮系统提示约 3k~7k tokens
/// （工具指令 + 技能目录 + 运行时上下文），实测问一句「说一下山西晋城」得到的是
/// 中/英/日/印地/韩混着的乱码，还把工具调用当正文写出来（`**[Tool Call: web_search]**`）。
/// 这不是管道没调好（同一条管道测速 33 tok/s 正常），而是**模型本身干不了 Agent 的活**。
///
/// 所以按用户口径（2026-10-09）：**本地模型只做简单对话** ——
/// 只把用户自己的话按顺序发过去，不带系统提示、不带工具、不带历史快照。
///
/// ## 顺带它还是诊断通道
///
/// 报错**原样显示**（例如 `Failed to apply template: ... (in template:16)`），
/// 不再被 DSH 包一层"推理失败"——哪种构建不能用，一眼就看出来。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 一条对话。角色只有 `user` / `model` 两种 —— 简单对话不需要别的角色。
class LocalChatMessage {
  const LocalChatMessage({
    required this.role,
    required this.text,
    this.images = const <String>[],
    this.context = '',
    this.kbHits = 0,
    this.usedWeb = false,
    this.truncated = false,
  });

  /// `user` 或 `model`。
  final String role;
  final String text;

  /// 这一条附带的图片（**文件绝对路径**，在 App 私有目录里）。
  ///
  /// 为什么存路径而不是字节：聊天记录要落盘（`local_chat.json`），把几 MB 的
  /// base64 塞进 JSON 会把记录文件撑爆；发送时再按路径读出来编码。
  /// 路径失效（用户清了缓存/系统回收）时**跳过那张图**并照常把文字发出去，
  /// 不因为一张图报废整轮对话。
  final List<String> images;

  /// 这一轮附带的**参考资料**（联网搜索 / 以后的知识库检索）。
  ///
  /// 为什么不直接拼进 [text]：界面上要显示的是**用户问的那句话**，
  /// 而不是一坨参考资料。发送时再把两者拼起来（见 [contentOf]），
  /// 落盘时也分开存 —— 这样刷新页面看到的还是干净的问题。
  final String context;

  /// 这一轮从**知识库**检到了几段（0 = 没用知识库）。
  final int kbHits;

  /// 这一轮用没用**联网搜索**。
  final bool usedWeb;

  /// 这条回答是不是**顶到长度上限被截断**的（不是答完）。
  ///
  /// 为什么必须记下来（用户 2026-10-12 排查时发现）：真机报告里有一轮
  /// `生成完成：首字 2617ms · **768 段**`，768 正好等于 `groundedMaxTokens` ——
  /// 也就是模型不是答完了，是被 `max_tokens` 砍掉了。而界面上**一个字都不说**，
  /// 用户看到的只是"句子说到一半没了"，跟"答得乱七八糟"长得一模一样。
  final bool truncated;

  bool get isUser => role == 'user';

  /// 真正发给引擎的文字：参考资料在前、问题在后。
  String get contentOf {
    final c = context.trim();
    if (c.isEmpty) return text;
    return text.trim().isEmpty ? c : '$c\n\n$text';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'role': role,
        'text': text,
        if (images.isNotEmpty) 'images': images,
        if (context.trim().isNotEmpty) 'context': context,
        if (kbHits > 0) 'kbHits': kbHits,
        if (usedWeb) 'usedWeb': true,
        if (truncated) 'truncated': true,
      };

  /// 认不出来就返回 null（磁盘上写坏了不该让整段历史读不出来）。
  static LocalChatMessage? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final role = raw['role'];
    final text = raw['text'];
    if (role is! String || text is! String) return null;
    if (role != 'user' && role != 'model') return null;
    return LocalChatMessage(
      role: role,
      text: text,
      context: (raw['context'] as String?) ?? '',
      kbHits: (raw['kbHits'] as num?)?.toInt() ?? 0,
      usedWeb: raw['usedWeb'] == true,
      truncated: raw['truncated'] == true,
      images: <String>[
        for (final p in (raw['images'] as List? ?? const <Object?>[]))
          if (p is String && p.isNotEmpty) p,
      ],
    );
  }
}

/// 简单对话出错 —— [message] 就是**引擎的原话**（不加工、不翻译）。
class LocalChatException implements Exception {
  LocalChatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 引擎报错里**认得出来**的那几类。
///
/// 为什么只做"识别"、措辞留给界面：这个文件不碰 BuildContext，翻不成四语；
/// 界面侧按这个枚举给可操作的人话（`context.tr`）。和原生层 `reuseBlockReason`
/// 返回英文原因码、界面再翻人话，是同一个套路。
enum LocalChatErrorKind {
  /// 会话缓存装不下了 —— 模型文件自带的 KV 格数被这段对话占满。
  ///
  /// 真机原话（2026-10-09 诊断报告 16:32:35，Gemma 3 1B）：
  /// `Prefill input length exceeds available state entries (remaining capacity: 176)`
  /// 用户当时看到的只是 `HTTP 500 {…}` —— 既没说清发生了什么、也没说下一步干什么，
  /// 而它其实是个**能自救**的状态（新开会话 / 换上下文更大的模型）。
  contextFull,

  /// 认不出来 → 原样显示，不猜。
  unknown,
}

/// 把引擎原话归类。**纯函数**，便于单测。
LocalChatErrorKind classifyLocalChatError(String raw) {
  final s = raw.toLowerCase();
  if (s.contains('prefill input length exceeds') ||
      s.contains('available state entries') ||
      s.contains('remaining capacity')) {
    return LocalChatErrorKind.contextFull;
  }
  return LocalChatErrorKind.unknown;
}

/// 简单对话的落盘（`<dshHome>/local_chat.json`）。
///
/// 为什么落盘：这一页是从「本地大模型」页推进来的（返回即销毁），而用户刚反馈过
/// "从别的页面转回来就重置了" —— 聊天记录比那两项设置更不该丢。
class LocalChatStore {
  LocalChatStore({required this.dshHome});

  /// DSH_HOME（`.../files/dshhome`）。
  final String dshHome;

  String get path =>
      dshHome.isEmpty ? 'local_chat.json' : '$dshHome/local_chat.json';

  /// 读回历史。任何异常都当"没有历史"，绝不让它把页面卡住。
  Future<List<LocalChatMessage>> load() async {
    try {
      final f = File(path);
      if (!f.existsSync()) return <LocalChatMessage>[];
      final raw = jsonDecode(await f.readAsString());
      if (raw is! List) return <LocalChatMessage>[];
      final out = <LocalChatMessage>[];
      for (final e in raw) {
        final m = LocalChatMessage.fromJson(e);
        if (m != null) out.add(m);
      }
      return out;
    } catch (_) {
      return <LocalChatMessage>[];
    }
  }

  Future<void> save(List<LocalChatMessage> messages) async {
    try {
      final f = File(path);
      if (!f.parent.existsSync()) await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(<Object>[
        for (final m in messages) m.toJson(),
      ]));
    } catch (_) {
      // 落盘失败只影响"下次还记不记得"，本次对话照常。
    }
  }

  Future<void> clear() async {
    try {
      final f = File(path);
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }
}

/// 图片按后缀猜 MIME（引擎不看这个也能解码，但 OpenAI 形状里带上更标准）。
String _mimeOf(String path) {
  final p = path.toLowerCase();
  if (p.endsWith('.png')) return 'image/png';
  if (p.endsWith('.webp')) return 'image/webp';
  if (p.endsWith('.gif')) return 'image/gif';
  if (p.endsWith('.bmp')) return 'image/bmp';
  return 'image/jpeg';
}

/// 把本机图片读成 `data:image/...;base64,...`。
///
/// 只支持内联 data URL：**本机引擎读不到 http 图片**（它没有联网取图能力），
/// 让它去下载既慢又不可靠。文件不存在/读失败返回 null（调用方跳过这张）。
Future<String?> imageToDataUrl(String path) async {
  try {
    final f = File(path);
    if (!f.existsSync()) return null;
    final bytes = await f.readAsBytes();
    if (bytes.isEmpty) return null;
    return 'data:${_mimeOf(path)};base64,${base64Encode(bytes)}';
  } catch (_) {
    return null;
  }
}

/// 流式简单对话：把 [history]（**最后一条是本轮的 user**）发过去，逐段吐增量。
///
/// 刻意只带三样东西：`stream: true`、`max_tokens`、`temperature`。
/// **一条系统消息都不带** —— 这正是"简单对话"与"会话里当 Agent"的分界线。
///
/// 流式读取的**空闲**超时：连续这么久没有任何字节就算卡住（审计 P0-10 那条链）。
///
/// 为什么是"空闲"而不是总时长：本地模型做 prefill 时可以几秒到一分多钟**一个
/// token 都不吐**，总时长一刀切会把正常请求砍掉（同 P1-1 的取舍）。
/// 180 秒是保守取值 —— **需要真机实测后调**。
const Duration kLocalChatIdleTimeout = Duration(seconds: 180);

/// 带图的消息发 OpenAI 的 content 数组形状
/// （`[{"type":"text"},{"type":"image_url","image_url":{"url":"data:..."}}]`）——
/// 桥那边把它翻成引擎的 `Contents.of(Text, ImageBytes…)`。
Stream<String> localChatStream({
  required int port,
  required List<LocalChatMessage> history,
  int maxTokens = 512,
  double temperature = 0.7,
  /// 本轮带了检索材料时用的采样温度（见下）。
  double groundedTemperature = 0.3,
  /// 本轮带了检索材料时用的回复上限（材料要先"读"，512 容易被吃掉）。
  int groundedMaxTokens = 768,
  /// **出参**：本轮被截断时往里塞 `'length'`（顶到 `max_tokens` 上限）。
  ///
  /// 为什么用出参而不是抛异常：`finish_reason == 'length'` 是**成功**的一轮 ——
  /// 只是答案没写完。抛异常会把已经吐出来的正文丢掉；而**静默**当成完整回答，
  /// 用户看到的就是"话说一半没了"（真机证据：2026-10-12 01:23:18 那次 768 段，
  /// 正好等于 [groundedMaxTokens]）。所以既不能丢、也不能不说。
  List<String>? notices,
}) async* {
  // ── ⚠️ 用户 2026-10-12：「本地大模型调用知识库……感觉回答得乱七八糟」──
  //
  // 检索质量那半边在 `kb_index.dart` 的 `chunkText`（切片不按文档边界，
  // 一块里塞 9 篇无关文档 → top-1 命中 1/11；修完 15/16）。
  // **这里修的是另一半：把检索到的材料怎么交给模型。**
  //
  // 改之前有三个坑，都专门坑小模型：
  //   ① **没有 `system` 消息**：`formatKbContext` 里那句"请优先依据它们回答；
  //      资料里没提到的不要编造"被**粘在用户消息里**，和问题混在一起。
  //      小模型对"系统位"的指令遵守度明显高于用户消息里的夹带。
  //   ② **历史里每一轮的旧材料都会重发**：`contentOf` 会把 `context` 拼回去，
  //      而 `history` 是整段会话 —— 问第 5 句时，前 4 句各自的"以下是知识库
  //      查到的资料，请优先依据它们回答"还全在上下文里，而且讲的是**别的**问题。
  //      1B 级模型被这几坨互相矛盾的"优先依据"一冲，就是"乱七八糟"。
  //      现在**只有最后一条（本轮）带材料**，历史里的旧材料一律丢掉。
  //   ③ 温度：0.7 对"照资料答"偏高（小模型会顺着材料编）。
  //      有材料时降到 [groundedTemperature]（默认 0.3），上限提到
  //      [groundedMaxTokens]（默认 768，否则读完材料就没额度写答案了）。
  final lastIdx = history.length - 1;
  final grounded = lastIdx >= 0 && history[lastIdx].context.trim().isNotEmpty;

  // 先把消息拼好（图片要读盘 + base64，是异步的）。
  final msgs = <Map<String, dynamic>>[];
  for (var idx = 0; idx < history.length; idx++) {
    final m = history[idx];
    final role = m.isUser ? 'user' : 'assistant';
    // ⚠️ 只有本轮带材料；历史里那些旧材料丢掉（坑 ②）。
    final sent = idx == lastIdx ? m.contentOf : m.text;
    if (m.images.isEmpty) {
      msgs.add(<String, dynamic>{'role': role, 'content': sent});
      continue;
    }
    final parts = <Map<String, dynamic>>[];
    if (sent.trim().isNotEmpty) {
      parts.add(<String, dynamic>{'type': 'text', 'text': sent});
    }
    for (final p in m.images) {
      final url = await imageToDataUrl(p);
      if (url == null) continue; // 这张读不到 → 跳过，别拖垮整轮
      parts.add(<String, dynamic>{
        'type': 'image_url',
        'image_url': <String, dynamic>{'url': url},
      });
    }
    // 图全读失败 → 退回纯文本那条路（引擎对它的行为是验证过的）。
    if (parts.length <= 1) {
      if (sent.trim().isNotEmpty) {
        msgs.add(<String, dynamic>{'role': role, 'content': sent});
      }
      continue;
    }
    msgs.add(<String, dynamic>{'role': role, 'content': parts});
  }

  // 坑 ①：把"依据资料回答"的要求放到**系统位**（小模型的遵守度明显更高）。
  // 位置在 msgs 最前面 —— 引擎按数组顺序喂给模型。
  if (grounded) {
    msgs.insert(0, <String, dynamic>{
      'role': 'system',
      // ⚠️ 条件式，**不是**无条件命令 —— 理由与 `formatKbContext` 那段完全一样。
      //    大语料里"没查到相关的"是常态；无条件命令只会逼模型拿无关材料硬凑。
      'content': '你是助手。本轮的用户消息里**可能**附有「本地知识库」检索到的资料。'
          '如果它和问题相关：优先依据它回答，它没提到的内容不要编造，直接说不确定。'
          '如果它和问题无关：直接忽略，按你自己知道的回答，不要被它带偏。',
    });
  }

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:$port/v1/chat/completions'));
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode(<String, dynamic>{
      'model': 'local',
      'stream': true,
      'messages': msgs,
      // 坑 ③：有材料时降温度、提上限（读完材料还得有额度写答案）。
      'max_tokens': grounded ? groundedMaxTokens : maxTokens,
      'temperature': grounded ? groundedTemperature : temperature,
    })));
    final res = await req.close();
    if (res.statusCode != 200) {
      // ⚠️ 把引擎的报错**原样**告诉用户/日志：这就是我们判断"哪种构建不能用"的依据。
      final body = await res.transform(utf8.decoder).join();
      throw LocalChatException('HTTP ${res.statusCode} ${body.trim()}');
    }
    final lines = res
        // 空闲超时（P0-10）：连接超时只管"连得上"，管不了"连着但不吐字"。
        // `Stream.timeout` 每收到一个事件就重置，所以这是"连续 N 秒没有任何字节"。
        .timeout(kLocalChatIdleTimeout)
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    // ⚠️ 「流必须以 finish_reason 收尾」—— 这是 **DSH 客户端自己就在做的硬检查**，
    // 我们这条直连路径**原来没做**（审计 P0-10）。
    //
    // 不做的后果：native 抛 Error 把 socket 关掉时，`await for` 会看到"流正常
    // 结束"，于是**半截回复被当成完整回答**存进会话、落盘，用户以为答完了。
    //
    // 契约来自桥自己写下的注释（LiteRtLmBridge.kt:1000-1019）：成功时它会发一个
    // `choices[0].finish_reason = "stop"` 的分片，再发 `data: [DONE]`。
    // 而 DSH 那边的判法是 `if (!hasFinishReason) throw new Error("Stream ended
    // without finish_reason")` —— 我们照同一条判。
    var sawFinish = false;
    await for (final line in lines) {
      final t = line.trim();
      if (!t.startsWith('data:')) continue;
      final payload = t.substring(5).trim();
      if (payload.isEmpty) continue;
      if (payload == '[DONE]') {
        sawFinish = true;
        break;
      }
      try {
        final j = jsonDecode(payload);
        final choices = (j is Map ? j['choices'] : null) as List?;
        if (choices == null || choices.isEmpty) continue;
        final first = choices.first;
        // 收尾分片：delta 是空对象、finish_reason 有值 → 这一轮是完整的。
        if (first is Map && first['finish_reason'] != null) {
          sawFinish = true;
          // ⚠️ 「有 finish_reason」**不等于**「答完了」：`length` 表示顶到
          //    `max_tokens` 上限被砍。以前只判前者，于是被截断的回答被当成
          //    完整回答存下来 —— 用户看到句子说到一半没了，跟"答得乱七八糟"
          //    长得一样。这里如实记下来，由界面告诉用户。
          if (first['finish_reason'] == 'length') notices?.add('length');
        }
        final delta = (first is Map ? first['delta'] : null) as Map?;
        final content = delta?['content'];
        if (content is String && content.isNotEmpty) yield content;
      } catch (_) {
        // 单个分片解析失败不该打断整段对话（引擎偶尔会插一行非 JSON，
        // 例如收尾的 timings 分片）。
      }
    }
    if (!sawFinish) {
      // 已经吐出去的正文**不撤回**（用户至少能看到部分内容），
      // 但必须让调用方知道这是**半截**，不能当完整回答存下来。
      throw LocalChatException(
          '本地模型在 finish_reason 之前就断了 —— 这轮回答是半截的，请重试');
    }
  } on TimeoutException {
    throw LocalChatException(
        '本地模型 ${kLocalChatIdleTimeout.inSeconds} 秒没有任何输出（卡住了或已崩溃）');
  } on LocalChatException {
    rethrow;
  } catch (e) {
    throw LocalChatException('$e');
  } finally {
    client.close(force: true);
  }
}
