/// 本地模型服务的「对外规格」——overlay 生成与 UI 都要用它。
///
/// 为什么单独一个文件：`dsh_runtime.dart`（写 overlay）与
/// `local_model_server.dart`（起进程）互相都要用这个类型。放进任一方的文件里
/// 都会形成循环 import；抽成这种"零依赖的小值对象"是 Dart 里最省事的解。
class LocalModelSpec {
  const LocalModelSpec({
    required this.port,
    required this.modelId,
    required this.displayName,
    this.contextSize = 16384,
    this.vision = false,
  });

  /// **引擎实际分配的上下文窗口**（`-c` 的值，默认 16384）。
  ///
  /// 为什么必须带进 overlay（真机踩坑，2026-10-08）：
  /// DSH 用 `contextWindow` 去 clamp 生成上限：
  ///   `maxTokens = contextWindow - 已用 prompt - 4096(安全余量)`
  /// 如果这里写小了（以前硬编码 4096），而 DSH 一轮 prompt 就 6822 tokens，
  /// 那 `available` 是负值 → maxTokens 被强制成 **1** → 模型只吐一个 token 就停，
  /// 表现为"发什么都空回复"。必须跟引擎的 `-c` 一致（16384）。

  /// overlay 里注册的 provider id（固定 `local`）。
  static const String providerId = 'local';

  /// overlay 里 `local` 厂家引用的凭据环境变量名。
  ///
  /// ⚠️ **它必须与 `state/provider_keys.dart` 里注入的那个键完全一致**。
  /// 曾经这里写 `apiKeyEnv: LOCAL_MODEL_API_KEY` 而 provider_keys 忘了注入它，
  /// 后果是真机报错 `no credential for provider route "local"` ——
  /// 本地服务明明跑着却用不了，用户还被指引去"注册 Agnes"。
  /// 现在两边都引用这个常量，**不可能再写不一致**。
  static const String apiKeyEnvName = 'LOCAL_MODEL_API_KEY';

  /// 本机服务不校验 Key，但 DSH 要求这个变量存在 —— 就给个占位值。
  static const String apiKeyPlaceholder = 'local-model';

  final int port;

  /// 引擎实际分配的上下文窗口（`-c` 的值，默认 16384），写进 overlay 的
  /// `contextWindow`，好让 DSH 正确 clamp maxTokens（见构造参数注释）。
  final int contextSize;

  /// 注册给 DSH 的模型 id（overlay 里 `local` 这个 provider 下的 model）。
  final String modelId;

  final String displayName;

  /// **这个模型看不看得懂图片**（多模态）。
  ///
  /// 为什么要单独一个位：图片走的是引擎内建的视觉编码器，**只有多模态模型
  /// （如 Gemma 4 E2B）才有**。把图发给 Qwen3 0.6B / Gemma 3 1B 这种纯文本模型，
  /// 轻则被忽略、重则报错。所以「本地对话」里那两个拍照/选图按钮**按这个位显示**
  /// —— 拍了照模型却看不见，比不给入口更糟。
  final bool vision;

  /// DSH 里的全限定 route，例如 `local/qwen2.5-1.5b-instruct-q4_k_m`。
  String get route => '$providerId/$modelId';

  @override
  String toString() => 'LocalModelSpec($route @127.0.0.1:$port)';
}

/// 启动时**真正生效**的上下文长度 = min(用户档位, 模型文件物理能装的)。
///
/// [modelKvTokens] 为 0 = 清单没写这个模型的容量 → 按用户档位来（老行为）。
///
/// 为什么要有这个函数（真机 2026-10-09 抓到的事故）：
/// 用户选了 Gemma 3 1B（文件 `..._ekv4096.litertlm`，KV 只有 **4096** 格），
/// 而 App 一律按用户档位（默认 **16384**）启动，overlay 也声明 16384 →
/// 两轮就把缓存吃到 3920/4096，第三轮报
/// `Status Code: 9 · Prefill input length exceeds available state entries
///  (remaining capacity: 176)`，整轮失败。
///
/// ⚠️ 取 min 之后，这个数**必须同时**给引擎的 `maxNumTokens` 与 overlay 的
/// `contextWindow`（走 `LocalModelSpec.contextSize`）。只改一边就会掉进它的
/// 镜像坑：overlay 写小了 → DSH 把 maxTokens clamp 成 1 → 空回复。
int effectiveLocalContext({
  required int requested,
  required int modelKvTokens,
}) =>
    (modelKvTokens > 0 && modelKvTokens < requested) ? modelKvTokens : requested;
