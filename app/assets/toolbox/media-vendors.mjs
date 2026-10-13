// 「影视」生图 / 生视频的**厂家形状表 —— 唯一来源**。
//
// ## 为什么必须有这一份（用户 2026-10-11 明确纠正）
//
// 手机版原先只会发 Agnes 那一套请求：端点写死 `/v1/images/generations`、
// `/v1/videos`，参数写死 `size: '1K'|'2K'` + `extra_body.response_format`、
// `mode/seconds`。于是"换厂家"只换了 base URL 和 Key —— **参数名、端点、
// 返回结构全不对**，第三方厂家必然失败。用户的原话是：
//
//   「本 App 的视频请求只认 Agnes 那套形状实际是那个内置的会话限制了你的使用…
//     影视这个工具实际是可以使用多个厂家」
//
// 他是对的：桌面版影视工具的做法就是**同一个面板按模型名路由到不同厂家的
// 端点 + 各自的 Key**（见 dsh-agnes-studio 的 `src/vendors.ts` 与
// `/agnes-studio/api/proxy`）。手机版要补的是**按厂家换请求形状**。
//
// ## 这一份的职责边界（重要）
//
// * 本模块**只做纯计算**：把 (厂家, 统一参数) → 翻译成这家的
//   「端点 + 请求体 + 怎么从响应里取结果 + 怎么轮询」。**不发请求、不读环境变量**。
//   好处：可以直接 `node -e` 干跑，形状对不对一眼可见（见文件末尾 `--selftest`）。
// * **"哪家支持哪些档位"不在这里** —— 那属于界面（Dart 侧
//   `data/media_models.dart` 的 `MediaVendors`），因为要拿它渲染选项。
//   这里只管"你给我的值，该用哪个字段名、什么格式发出去"。
//
// ## 形状的出处（每一条都可追）
//
// | 厂家 | 出处 |
// |---|---|
// | Agnes | 本仓库 `make-image.mjs` / `make-video.mjs` 原有实现（已验证可用） |
// | 豆包 Seedance / OpenAI 图像 / MiniMax H3 | 桌面版影视工具里已投产的
// |   | `vendor/oh-story/drama/skills/short-drama-produce/scripts/provider_adapters.py` |
// | 通义万相（图像 / 视频） | 阿里云百炼官方文档（异步 image-synthesis / video-synthesis） |
// | 硅基流动 | SiliconFlow 官方文档（POST /video/submit → POST /video/status） |
// | MiniMax 图像 | MiniMax 开放平台文档（POST /v1/image_generation） |
//
// ⚠️ **本机无法验证"能不能通"**：没有这些厂家的 Key，也没有安卓设备。
// 这里保证的是"形状按文档/按已投产实现写对"，失败时把上游原始错误原样带出来。
//
// 只用 node 内置能力，不引任何依赖（本机只能跑内置模块）。

/** 图像 / 视频两类。 */
export const IMAGE = 'image';
export const VIDEO = 'video';

/**
 * 拼 URL，**版本段不重复**。
 *
 * 各家的 base 有的带版本（`.../v1`、`.../api/v3`），而端点路径也常自带版本
 * （`/v1/image_generation`、`/v2/video_generation`、`/api/v1/tasks/x`）。
 * 直接拼会出现 `.../v1/v1/...` —— 桌面版影视工具就**真踩过**这个坑
 * （Agnes 回 404，面板里每一次生图/生视频都失败），修法就是下面这段逻辑。
 * 这里照抄，不再犯第二次。
 *
 *   base .../v1 + /v1/images/... → .../v1/images/...
 *   base .../v1 + /images/...    → .../v1/images/...
 *   base .../v1 + /v2/video_gen  → .../v2/video_gen     （端点的版本说了算）
 *   base 无版本 + /api/v1/tasks  → .../api/v1/tasks
 */
export function joinUrl(base, endpoint) {
  const b = String(base || '').trim().replace(/\/+$/, '');
  const ep = '/' + String(endpoint || '').trim().replace(/^\/+/, '');
  const baseVersion = b.match(/\/(v\d+[a-z0-9]*)$/i);
  const epVersion = ep.match(/^\/(v\d+[a-z0-9]*)(\/|$)/i);
  if (baseVersion && epVersion) {
    return b.slice(0, b.length - baseVersion[0].length) + ep;
  }
  return b + ep;
}

/**
 * 厂家表。
 *
 * `base` 是这家默认的 API 根（用户可在 App 里改成自己的代理/专属域名，
 * 那时以用户填的为准）。`image` / `video` 为 `null` 表示**这家在本 App 里
 * 不做这一项**（不是"做不到"，是没接 —— 界面要如实说，不要给个必失败的选项）。
 */
export const VENDORS = {
  agnes: {
    label: 'Agnes',
    base: 'https://api.agnes-ai.cn/v1',
    register: 'https://platform.agnes-ai.cn',
    image: { shape: 'agnes' },
    video: { shape: 'agnes' },
  },
  openai: {
    label: 'OpenAI',
    base: 'https://api.openai.com/v1',
    register: 'https://platform.openai.com/signup',
    // gpt-image-1 默认就返回 b64_json（不接受 response_format），
    // 所以这家**不传** response_format；带参考图时必须走 /images/edits 的 multipart。
    image: { shape: 'openai-compat', sizeSep: 'x', responseFormat: false, editsWhenRefs: true },
    video: null,
  },
  zhipu: {
    label: '智谱 GLM',
    base: 'https://open.bigmodel.cn/api/paas/v4',
    register: 'https://open.bigmodel.cn/',
    image: { shape: 'openai-compat', sizeSep: 'x' },
    video: null,
  },
  dashscope: {
    label: '通义万相（阿里云百炼）',
    base: 'https://dashscope.aliyuncs.com',
    register: 'https://bailian.console.aliyun.com/',
    // 万相**没有** OpenAI 兼容的生图入口：图像和视频都是
    // 「创建任务 → 轮询 /api/v1/tasks/{id}」的异步协议，且必须带
    // `X-DashScope-Async: enable`（缺了会报 "current user api does not support
    // synchronous calls"）。尺寸格式是 `1024*1024`（星号，不是 x）。
    image: { shape: 'dashscope-async', sizeSep: '*', submitPath: '/api/v1/services/aigc/text2image/image-synthesis' },
    video: { shape: 'dashscope-async', submitPath: '/api/v1/services/aigc/video-generation/video-synthesis' },
  },
  doubao: {
    label: '豆包（火山方舟）',
    base: 'https://ark.cn-beijing.volces.com/api/v3',
    register: 'https://console.volcengine.com/ark',
    // 图像是 OpenAI 兼容（`/images/generations`）；视频是方舟自己的
    // 「contents/generations/tasks」异步任务。
    image: { shape: 'openai-compat', sizeSep: 'x' },
    video: { shape: 'ark-task' },
  },
  minimax: {
    label: 'MiniMax',
    base: 'https://api.minimax.cn/v1',
    // Key 在「账户管理 > 接口密钥」（官方文档里给的地址）。
    register: 'https://platform.minimax.cn/user-center/basic-information/interface-key',
    // 视频在 v2 上（`/v2/video_generation`），查进度却在 v1
    // （`/v1/query/video_generation/{id}`）—— 两个根不一样，所以分开写。
    videoBase: 'https://api.minimax.cn/v2',
    image: { shape: 'minimax-image' },
    video: { shape: 'minimax-task' },
  },
  siliconflow: {
    label: '硅基流动 SiliconFlow',
    base: 'https://api.siliconflow.cn/v1',
    // 国内站 cloud.siliconflow.cn；国际站是 cloud.siliconflow.com
    //（对应的 API 域名是 api.siliconflow.com，两边的 Key 不通用）。
    register: 'https://cloud.siliconflow.cn/',
    image: { shape: 'openai-compat', sizeSep: 'x' },
    video: { shape: 'siliconflow-task' },
  },
  /**
   * 认不出来的厂家（用户自己填的代理 / 小众平台）。
   *
   * 按 **OpenAI 兼容**试 —— 这是目前最普遍的形状（`/images/generations` +
   * `{model, prompt, size}`）。日志里会写明"按 OpenAI 兼容形状发的"，
   * 不通就把上游原话带出来，不假装知道这家的协议。
   */
  unknown: {
    label: '自定义厂家',
    base: '',
    image: { shape: 'openai-compat', sizeSep: 'x' },
    video: null,
  },
};

/**
 * 厂家的**注册 / 拿 Key** 地址。
 *
 * 用户 2026-10-12：「也可以给注册地址」。以前只有 Agnes 有这一项，
 * 其余六家的 Key 去哪拿全靠用户自己搜 —— 现在表里都有，界面上直接给链接。
 *
 * 拿不到（自定义厂家）返回空串，调用方据此不显示链接（**不猜地址**）。
 */
export function registerUrl(vendorId) {
  const v = VENDORS[vendorId];
  return v && v.register ? v.register : '';
}

/** 支持的厂家 id（界面/测试用；顺序即展示顺序）。 */
export const VENDOR_IDS = [
  'agnes',
  'openai',
  'zhipu',
  'dashscope',
  'doubao',
  'minimax',
  'siliconflow',
  'unknown',
];

/**
 * 定厂家：显式 id > 从模型名猜 > 从 base URL 猜 > `unknown`。
 *
 * 模型名猜法沿用桌面版 `getVendorFromModel` 的思路（前缀匹配），
 * 但**加上 base URL 兜底** —— 手机版允许用户自己填端点，
 * 那时候"填的域名"比"模型名"更能说明问题。
 */
export function providerOf({ provider, model, baseUrl } = {}) {
  const p = String(provider || '').trim().toLowerCase();
  if (p && VENDORS[p]) return p;

  const m = String(model || '').trim().toLowerCase();
  if (m.startsWith('ollama:')) return 'unknown';
  for (const id of VENDOR_IDS) {
    if (id === 'unknown') continue;
    if (m.startsWith(id + '-') || m.startsWith(id + '_') || m.startsWith(id + '.')) return id;
  }
  // 模型名里带厂家关键词（豆包/Seedream/Seedance/万相/通义/智谱/glm/kolors…）
  if (/seedream|seedance|doubao|ark-|volces/.test(m)) return 'doubao';
  if (/wanx|wan2|qwen-image|qwen-image|dashscope|tongyi/.test(m)) return 'dashscope';
  if (/cogview|glm-|zhipu|bigmodel/.test(m)) return 'zhipu';
  if (/minimax|hailuo|image-01/.test(m)) return 'minimax';
  if (/kolors|siliconflow|qwen\/|flux/.test(m)) return 'siliconflow';
  if (/gpt-image|dall-e|openai/.test(m)) return 'openai';
  if (m.startsWith('agnes')) return 'agnes';

  const u = String(baseUrl || '').toLowerCase();
  if (u) {
    if (u.includes('agnes-ai')) return 'agnes';
    if (u.includes('api.openai.com')) return 'openai';
    if (u.includes('bigmodel.cn')) return 'zhipu';
    if (u.includes('dashscope') || u.includes('aliyuncs.com')) return 'dashscope';
    if (u.includes('volces.com') || u.includes('ark.cn-')) return 'doubao';
    if (u.includes('minimax')) return 'minimax';
    if (u.includes('siliconflow')) return 'siliconflow';
  }
  return 'unknown';
}

/** 取厂家的图像/视频能力定义；这家没接就返回 null。 */
export function vendorSpec(vendorId, kind) {
  const id = VENDORS[vendorId] ? vendorId : 'unknown';
  const v = VENDORS[id];
  const spec = kind === VIDEO ? v.video : v.image;
  if (!spec) return null;
  return { id, label: v.label, base: v.base, videoBase: v.videoBase, ...spec };
}

/**
 * 这家**缺 base URL** 吗（用户没填、表里也没有默认值）？
 *
 * `unknown`（用户自己填的厂家）表里没有默认端点 —— 不填就会拼出
 * `/images/generations` 这种没有主机名的地址，`new URL()` 会直接抛错。
 * 调用方要拿这个提前给出**人话**（"这家要自己填端点"），而不是让 node 抛一个
 * `Invalid URL` 让用户猜。
 */
export function missingBaseUrl(vendorId, baseUrl) {
  if (String(baseUrl || '').trim()) return false;
  const v = VENDORS[vendorId];
  return !v || !v.base;
}

/** 厂家 id → 中文名（日志里说清"这份请求是发给哪家的"）。 */
export function vendorLabel(vendorId) {
  const v = VENDORS[vendorId];
  return v ? v.label : VENDORS.unknown.label;
}

/** 尺寸分隔符：`1024x1024`（多数）还是 `1024*1024`（万相）。
 *
 * ⚠️ 必须把**所有**常见写法都归一化（`x` / `X` / `*` / `×` / `✕`），不能只换
 * `*` 和 `×` —— 界面里写的是 `1024x1024`（人类习惯），而万相要的是
 * `1024*1024`。只换 `*` 的话，用户从界面选的尺寸会**原样带着 `x` 发出去**，
 * 上游报"参数格式错误"，看起来像"万相接不通"。
 *（这个是同事做生图脚本时发现的：他只改了 `*`/`×` 两种。）
 */
function sizeWith(value, sep) {
  if (!value) return undefined;
  return String(value).replace(/\s/g, '').replace(/[*×✕xX]/g, sep || 'x');
}

// ───────────────────────────────────────────────────────── 图像

/**
 * 把一个**统一的图像请求**翻译成某家的请求。
 *
 * 统一入参（由 make-image.mjs 从命令行/环境变量整理好，都是**已经选定**的值，
 * 本模块不做"哪家支持什么"的判断）：
 *   `{ model, prompt, size, ratio, negativePrompt, refs: [{path, mime, dataUri}] }`
 *
 * 返回：
 *   `{ endpoint, method, headers, body, multipart, log }`
 *   其中 `multipart` 非空时（OpenAI 带参考图）要发 multipart，body 变成表单字段。
 *
 * @returns {object|null} null = 这家没接图像
 */
export function imagePlan(vendorId, req) {
  const spec = vendorSpec(vendorId, IMAGE);
  if (!spec) return null;
  const { model, prompt, size, ratio, negativePrompt } = req || {};
  const refs = Array.isArray(req && req.refs) ? req.refs : [];
  const base = (req && req.baseUrl) || spec.base;

  switch (spec.shape) {
    // ── Agnes：size 用档位（1K/2K/3K/4K），response_format 与参考图必须在 extra_body ──
    // 依据：官方点名的错误写法就是"放顶层"，放错会被拒或静默忽略。
    case 'agnes': {
      const extraBody = { response_format: 'url' };
      if (refs.length > 0) extraBody.image = refs.map((r) => r.dataUri || r.path);
      const body = { model, prompt, size };
      if (ratio) body.ratio = ratio;
      if (negativePrompt) body.negative_prompt = negativePrompt;
      body.extra_body = extraBody;
      return {
        endpoint: joinUrl(base, '/images/generations'),
        method: 'POST',
        headers: {},
        body,
        multipart: null,
        log: `Agnes 形状：size=${size}（档位）· response_format 与参考图放 extra_body`,
      };
    }

    // ── OpenAI 兼容：size 用像素，response_format 在顶层，参考图在顶层 image 数组 ──
    // 覆盖 OpenAI / 智谱 / 豆包 Seedream / 硅基流动（以及认不出的厂家按这个试）。
    case 'openai-compat': {
      const px = sizeWith(size, spec.sizeSep || 'x');
      const body = { model, prompt, n: 1 };
      if (px) body.size = px;
      if (negativePrompt) body.negative_prompt = negativePrompt;
      if (spec.responseFormat !== false) body.response_format = 'url';

      // OpenAI 官方**没有**顶层 `image` 参数：图生图/多图合成走 `/images/edits`
      // 的 multipart（字段名 image，多张就重复同名字段）。
      if (refs.length > 0 && spec.editsWhenRefs) {
        return {
          endpoint: joinUrl(base, '/images/edits'),
          method: 'POST',
          headers: {},
          body,
          multipart: { fields: body, files: refs.map((r) => ({ field: 'image', ref: r })) },
          log: `OpenAI 形状：size=${px || '(默认)'}（像素）· 带 ${refs.length} 张参考图 → /images/edits multipart`,
        };
      }
      if (refs.length > 0) {
        // 其它兼容实现（智谱/方舟/硅基流动等）普遍接受顶层 image 数组。
        body.image = refs.map((r) => r.dataUri || r.path);
      }
      return {
        endpoint: joinUrl(base, '/images/generations'),
        method: 'POST',
        headers: {},
        body,
        multipart: null,
        log: `OpenAI 兼容形状：size=${px || '(默认)'}（像素）· response_format 在顶层` +
          (refs.length ? ` · 参考图放顶层 image（${refs.length} 张）` : ''),
      };
    }

    // ── MiniMax：自有接口，比例用 aspect_ratio，结果在 data.image_urls[] ──
    case 'minimax-image': {
      const body = { model, prompt, n: 1, response_format: 'url', prompt_optimizer: true };
      if (ratio) body.aspect_ratio = ratio;
      if (negativePrompt) body.negative_prompt = negativePrompt;
      return {
        endpoint: joinUrl(base, '/image_generation'),
        method: 'POST',
        headers: {},
        body,
        multipart: null,
        log: `MiniMax 形状：aspect_ratio=${ratio || '(默认 1:1)'} · 结果在 data.image_urls[]`,
      };
    }

    // ── 万相（DashScope）：异步。创建任务 → 轮询 /api/v1/tasks/{id} ──
    case 'dashscope-async': {
      const body = { model, input: { prompt } };
      if (negativePrompt) body.input.negative_prompt = negativePrompt;
      const params = {};
      const px = sizeWith(size, spec.sizeSep || '*');
      if (px) params.size = px;
      // ⚠️ 万相**没有** `ratio` 参数（比例是通过 size 表达的：`1024*1024` /
      //    `1280*720` / `720*1280` / `768*1152`）。这里**故意不发** ratio ——
      //    多发一个上游不认的字段，轻则报参数错误，重则被静默忽略让人以为生效了。
      //    比例由 Dart 侧换算成对应的 size 传进来。
      if (Object.keys(params).length > 0) body.parameters = params;
      return {
        endpoint: joinUrl(base, spec.submitPath),
        method: 'POST',
        headers: { 'x-dashscope-async': 'enable' },
        body,
        multipart: null,
        poll: dashscopePoll(base),
        log: `万相（DashScope）异步形状：size=${px || '(默认)'}（用 ${spec.sizeSep || '*'} 分隔）· ` +
          '创建任务后轮询 /api/v1/tasks/{id}',
      };
    }

    default:
      return null;
  }
}

/** DashScope 图像结果的取法（`output.results[0].url`）。 */
function dashscopeImageResult(json) {
  const out = json && json.output;
  if (!out) return {};
  const results = Array.isArray(out.results) ? out.results : [];
  const first = results.find((r) => r && (r.url || r.b64_image)) || null;
  if (first) return { url: first.url, b64: first.b64_image };
  return {};
}

// ───────────────────────────────────────────────────────── 视频

/**
 * 把一个**统一的视频请求**翻译成某家的「提交 + 轮询」。
 *
 * 统一入参：
 *   `{ model, prompt, seconds, resolution, ratio, firstFrame, mode }`
 *   * `seconds` 是字符串（`'5'`），`resolution` 是档位（`'720P'` / `'720p'`），
 *   * `firstFrame` 是**已读好的**参考帧 `{dataUri}`（图生视频）。
 *
 * 返回 `null` 表示这家在本 App 里没接视频（界面要如实说，不要给必失败的选项）。
 *
 * 返回结构：
 * ```
 * {
 *   shape, label,
 *   submit: { url, method, headers, body },
 *   taskIdOf(json) -> string,
 *   poll: { url(taskId), method, headers, body? },
 *   pick(json) -> { state: 'running'|'done'|'failed', url?, message? },
 *   pollIntervalMs, timeoutMs,
 *   log,
 * }
 * ```
 */
export function videoPlan(vendorId, req) {
  const spec = vendorSpec(vendorId, VIDEO);
  if (!spec) return null;
  const { model, prompt, firstFrame, mode } = req || {};
  const base = (req && req.baseUrl) || spec.base;
  const seconds = Number(req && req.seconds) || 5;
  const resolution = String((req && req.resolution) || '720P');
  const ratio = (req && req.ratio) || '16:9';
  const frameUri = firstFrame && (firstFrame.dataUri || firstFrame.url);

  switch (spec.shape) {
    // ── Agnes：POST /videos（mode/seconds/size）→ GET /videos/{id} → metadata.url ──
    case 'agnes': {
      const body = { model, prompt, mode: mode || (frameUri ? 'keyframe' : 'text'), seconds: String(seconds), size: resolution };
      if (ratio) body.aspect_ratio = ratio;
      if (frameUri) body.first_frame = frameUri;
      return {
        shape: 'agnes',
        label: spec.label,
        submit: { url: joinUrl(base, '/videos'), method: 'POST', headers: {}, body },
        taskIdOf: (j) => String((j && (j.video_id || j.id || j.task_id)) || ''),
        poll: { url: (id) => joinUrl(base, `/videos/${encodeURIComponent(id)}`), method: 'GET', headers: {} },
        pick: (j) => {
          const st = String((j && j.status) || '');
          if (st === 'completed' || st === 'succeeded') {
            const url = (j && j.metadata && j.metadata.url) || (j && j.url) || '';
            return url ? { state: 'done', url } : { state: 'failed', message: '任务完成但没给视频地址' };
          }
          if (st === 'failed' || st === 'cancelled' || st === 'canceled') {
            return { state: 'failed', message: String((j && j.error && j.error.message) || (j && j.error) || '生成失败') };
          }
          return { state: 'running' };
        },
        pollIntervalMs: 1500,
        timeoutMs: 600_000,
        log: `Agnes 形状：mode=${body.mode} seconds=${body.seconds} size=${resolution} → 轮询 /videos/{id}`,
      };
    }

    // ── 豆包 Seedance（火山方舟）：contents/generations/tasks ──
    // 依据：桌面版影视工具已投产的 provider_adapters.py（compile_seedance_payload /
    // _run_seedance / _poll_seedance）。提示词放在 content[] 里，不是顶层 prompt。
    case 'ark-task': {
      const content = [{ type: 'text', text: prompt }];
      if (frameUri) {
        content.push({
          type: 'image_url',
          image_url: { url: frameUri },
          role: mode === 'keyframe' ? 'first_frame' : 'reference_image',
        });
      }
      const body = { model, content };
      if (ratio) body.ratio = ratio;
      if (seconds) body.duration = seconds;
      return {
        shape: 'ark-task',
        label: spec.label,
        submit: { url: joinUrl(base, '/contents/generations/tasks'), method: 'POST', headers: {}, body },
        taskIdOf: (j) => String((j && (j.id || j.task_id)) || ''),
        poll: {
          url: (id) => joinUrl(base, `/contents/generations/tasks/${encodeURIComponent(id)}`),
          method: 'GET',
          headers: {},
        },
        pick: (j) => {
          const st = String((j && j.status) || '').toLowerCase();
          if (st === 'succeeded' || st === 'success') {
            const url = j && j.content && j.content.video_url;
            return url ? { state: 'done', url } : { state: 'failed', message: '任务成功但没给 video_url' };
          }
          if (['failed', 'cancelled', 'canceled', 'expired', 'timeout'].includes(st)) {
            return { state: 'failed', message: String((j && j.error && (j.error.message || j.error.code)) || st) };
          }
          return { state: 'running' };
        },
        pollIntervalMs: 5000,
        timeoutMs: 1_800_000,
        log: `豆包 Seedance 形状：content[] + ratio=${ratio} duration=${seconds}s → 轮询 tasks/{id}`,
      };
    }

    // ── MiniMax H3：POST /v2/video_generation → GET /v1/query/video_generation/{id} ──
    // 依据：桌面版 provider_adapters.py 的 _run_minimax_video / _poll_minimax_video。
    // ── MiniMax：视频生成 **V2**（H3 / H3-Max）────────────────────────────
    //
    // 依据（2026-10-12 逐条对过官方文档）：
    //   * 创建：`POST https://api.minimax.cn/v2/video_generation`
    //     body = `{model, content[], duration, resolution, ratio}`；
    //     `content` 是**多模态数组**：文本项 `{type:'text',text}`、
    //     首帧 `{type:'image_url', image_url:{url}, role:'first_frame'}`
    //     （文档里 `required: [model, content, resolution, duration]`）。
    //   * 查询：`GET https://api.minimax.cn/v2/query/video_generation/{task_id}`
    //     —— task_id 是**路径段**。
    //   * 成功响应：`{task:{status:'succeeded', content:{url}, ...}}`。
    //
    // ⚠️ **改之前这里是坏的，而且是"看着像对"的那种坏**（三处各错一点，
    //    单看每一处都像在照文档写）：
    //      ① body 发的是 **v1** 形状（`{model, prompt, duration, resolution}`），
    //         路径却是 **v2**。v2 没有 `prompt` 字段 → 上游回
    //         `invalid params, content must include a non-empty text item (2013)`；
    //      ② 首帧写 `body.first_frame`（v1 字段）→ v2 要放进 `content[]`；
    //      ③ 轮询打的是 `/v1/query/video_generation/{id}`，而任务是 **v2** 建的
    //         → 查不到（而且 v1 那个接口的 task_id 是**查询参数** `?task_id=`，
    //         不是路径段 —— 就算走 v1，这条 URL 也是错的）。
    //
    //    也就是说：**视频生成这条路在真机上必然失败**，而且失败信息会指向
    //    "参数不对"，很容易被当成"模型不支持"。
    case 'minimax-task': {
      const vbase = (req && req.videoBaseUrl) || spec.videoBase || base;
      // ⚠️ MiniMax v2 的 `resolution` 枚举只有 **480P / 768P / 2K** —— 通用的
      //    兜底值 `'720P'` 在这家是**非法**的（Agnes 与万相才用 720P）。
      //    Dart 侧本来就按厂家给选项、会传合法值；这里再兜一次，万一漏传就给
      //    768P —— H3 与 H3-Max **唯一都支持**的那一档。
      //    官方依据（2026-10-12 核对）：H3 只支持 768P / 2K；H3-Max 只支持 480P / 768P。
      const mmRes = ['480P', '768P', '2K'].includes(resolution) ? resolution : '768P';
      // v2 的 content 数组：文本项 + （可选）首帧图。
      const content = [{ type: 'text', text: prompt }];
      if (frameUri) {
        content.push({ type: 'image_url', image_url: { url: frameUri }, role: 'first_frame' });
      }
      const body = {
        model,
        content,
        duration: seconds,
        resolution: mmRes,
        // 图生视频时文档要求 `adaptive`（由首帧决定）；文生视频才给具体比例
        // （文档：t2va 时 `ratio` **必填且不能是 adaptive**）。
        ratio: frameUri ? 'adaptive' : ratio,
      };
      return {
        shape: 'minimax-task',
        label: spec.label,
        submit: { url: joinUrl(vbase, '/video_generation'), method: 'POST', headers: {}, body },
        taskIdOf: (j) => String((j && (j.task_id || (j.task && j.task.id) || j.id)) || ''),
        poll: {
          // v2 查询：task_id 走**路径**（与 v1 的 ?task_id= 不同）。
          url: (id) => joinUrl(vbase, `/query/video_generation/${encodeURIComponent(id)}`),
          method: 'GET',
          headers: {},
        },
        pick: (j) => {
          const task = j && j.task;
          const st = String((task && task.status) || '').toLowerCase();
          if (st === 'succeeded' || st === 'success') {
            const url = task && task.content && task.content.url;
            return url ? { state: 'done', url } : { state: 'failed', message: '任务成功但没给 content.url' };
          }
          if (['failed', 'cancelled', 'canceled', 'expired', 'timeout'].includes(st)) {
            // v2 的错误是 `task.error = {code, message}` —— 直接 String(对象)
            // 会得到 "[object Object]"，把上游原话丢掉。
            const e = task && task.error;
            const msg = (e && (e.message || e.code)) || (task && task.message) || st;
            return { state: 'failed', message: String(msg) };
          }
          return { state: 'running' };
        },
        pollIntervalMs: 5000,
        timeoutMs: 1_800_000,
        log: `MiniMax 形状（V2/H3）：POST /v2/video_generation（content[${content.length}]`
          + ` duration=${seconds} resolution=${mmRes} ratio=${body.ratio}）`
          + ' → 轮询 GET /v2/query/video_generation/{task_id}',
      };
    }

    // ── 通义万相（DashScope）：video-synthesis（必须 X-DashScope-Async: enable）→ /api/v1/tasks/{id} ──
    // 依据：阿里云百炼「万相-文生视频」API 参考。
    case 'dashscope-async': {
      const parameters = { resolution, ratio, duration: seconds };
      const body = { model, input: { prompt }, parameters };
      return {
        shape: 'dashscope-async',
        label: spec.label,
        submit: {
          url: joinUrl(base, spec.submitPath),
          method: 'POST',
          headers: { 'x-dashscope-async': 'enable' },
          body,
        },
        taskIdOf: (j) => String((j && j.output && j.output.task_id) || ''),
        poll: {
          url: (id) => joinUrl(base, `/api/v1/tasks/${encodeURIComponent(id)}`),
          method: 'GET',
          headers: {},
        },
        pick: (j) => {
          const out = j && j.output;
          const st = String((out && out.task_status) || '').toUpperCase();
          if (st === 'SUCCEEDED') {
            const url = out && out.video_url;
            return url ? { state: 'done', url } : { state: 'failed', message: '任务成功但没给 video_url' };
          }
          if (['FAILED', 'CANCELED', 'CANCELLED', 'UNKNOWN'].includes(st)) {
            return {
              state: 'failed',
              message: String((out && out.message) || (j && j.message) || st),
            };
          }
          return { state: 'running' };
        },
        pollIntervalMs: 15_000,
        timeoutMs: 1_800_000,
        log: `万相（DashScope）异步形状：parameters{resolution=${resolution} ratio=${ratio} duration=${seconds}}` +
          ' → 轮询 /api/v1/tasks/{id}',
      };
    }

    // ── 硅基流动：POST /video/submit → POST /video/status ──
    // 依据：SiliconFlow 官方文档（/video/submit 要 image_size；/video/status 用 requestId）。
    case 'siliconflow-task': {
      const px = ratioToPixels(ratio);
      const body = { model, prompt, image_size: px };
      if (frameUri) body.image = frameUri;
      return {
        shape: 'siliconflow-task',
        label: spec.label,
        submit: { url: joinUrl(base, '/video/submit'), method: 'POST', headers: {}, body },
        taskIdOf: (j) => String((j && (j.requestId || j.request_id || j.id)) || ''),
        poll: {
          url: () => joinUrl(base, '/video/status'),
          method: 'POST',
          headers: {},
          bodyOf: (id) => ({ requestId: id }),
        },
        pick: (j) => {
          const st = String((j && j.status) || '');
          if (st === 'Succeed' || st === 'succeeded') {
            const vids = (j && j.results && j.results.videos) || [];
            const url = vids.length > 0 && vids[0] && vids[0].url;
            return url ? { state: 'done', url } : { state: 'failed', message: '任务成功但没给视频地址' };
          }
          if (st === 'Failed' || st === 'failed') {
            return { state: 'failed', message: String((j && j.reason) || st) };
          }
          return { state: 'running' };
        },
        pollIntervalMs: 5000,
        timeoutMs: 1_800_000,
        log: `硅基流动形状：image_size=${px}（按比例算）· POST /video/submit → POST /video/status`,
      };
    }

    default:
      return null;
  }
}

/** DashScope 的轮询端点（图像、视频共用同一套 /api/v1/tasks/{id}）。 */
function dashscopePoll(base) {
  return {
    url: (id) => joinUrl(base, `/api/v1/tasks/${encodeURIComponent(id)}`),
    method: 'GET',
    headers: {},
  };
}

/** 比例 → 像素（硅基流动要 image_size 这种具体值，不是 16:9）。 */
export function ratioToPixels(ratio) {
  switch (String(ratio || '16:9')) {
    case '9:16':
      return '720x1280';
    case '1:1':
      return '960x960';
    case '4:3':
      return '1280x960';
    case '3:4':
      return '960x1280';
    default:
      return '1280x720';
  }
}

/** 从 DashScope 任务响应里取图像结果（导出给脚本用）。 */
export { dashscopeImageResult };

// ───────────────────────────────────────────────────────── 自检（干跑）

/**
 * 干跑：打印每家每类的「端点 + 请求体」。
 *
 * 这是本模块**唯一**的自检方式 —— 它证明"形状长什么样"，不证明"上游收不收"。
 *   node media-vendors.mjs --selftest
 */
function selftest() {
  const imgReq = {
    model: 'demo-model',
    prompt: '一只猫',
    size: '1024x1024',
    ratio: '16:9',
    refs: [{ path: '/tmp/a.png', mime: 'image/png', dataUri: 'data:image/png;base64,AAA' }],
  };
  const vidReq = {
    model: 'demo-model',
    prompt: '一只猫在跑',
    seconds: '5',
    resolution: '720P',
    ratio: '16:9',
    firstFrame: { dataUri: 'data:image/png;base64,AAA' },
    mode: 'keyframe',
  };
  let n = 0;
  for (const id of VENDOR_IDS) {
    for (const kind of [IMAGE, VIDEO]) {
      const plan = kind === IMAGE ? imagePlan(id, imgReq) : videoPlan(id, vidReq);
      if (!plan) continue;
      n++;
      process.stdout.write(`\n── ${id} · ${kind} ──\n`);
      if (kind === IMAGE) {
        process.stdout.write(`  ${plan.method} ${plan.endpoint}\n`);
        process.stdout.write(`  body: ${JSON.stringify(plan.body)}\n`);
        if (plan.multipart) process.stdout.write(`  multipart 字段: ${plan.multipart.files.map((f) => f.field).join(',')}\n`);
        if (plan.poll) process.stdout.write(`  poll: GET ${plan.poll.url('TASKID')}\n`);
      } else {
        process.stdout.write(`  submit: ${plan.submit.method} ${plan.submit.url}\n`);
        process.stdout.write(`  body:   ${JSON.stringify(plan.submit.body)}\n`);
        process.stdout.write(`  poll:   ${plan.poll.method} ${plan.poll.url('TASKID')}\n`);
      }
    }
  }
  process.stdout.write(`\n共 ${n} 个形状。\n`);
}

const invokedDirectly =
  process.argv[1] && /media-vendors\.mjs$/.test(process.argv[1]);
if (invokedDirectly && process.argv.includes('--selftest')) {
  selftest();
}
