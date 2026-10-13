#!/usr/bin/env node
'use strict';
/**
 * make-video.mjs —— 用 Agnes Video 2.5 Flash 生成视频（文生视频 / 首尾帧 / 图片·音频参考）。
 *
 * 用法：
 *   node make-video.mjs "<提示词>" <输出文件> [--seconds 5] [--ratio 16:9]
 *        [--mode text|keyframe|reference]
 *        [--first-frame <URL>] [--last-frame <URL>] [--image <URL>]... [--audio <URL>]...
 *   node make-video.mjs --help
 *
 * 环境变量：
 *   AGNES_API_KEY          必需；没有就报中文错误（去哪免费注册、去哪配），**绝不假装成功**
 *   AGNES_BASE_URL         可选，默认 https://api.agnes-ai.cn/v1
 *   AGNES_REGISTER_URL     可选，默认 https://platform.agnes-ai.cn
 *   AGNES_VIDEO_TIMEOUT_MS 可选，默认 600000（10 分钟轮询上限）
 *   AGNES_POLL_INTERVAL_MS 可选，默认 1500（官方建议 1–2 秒查一次）
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 官方接口约定（照抄 https://agnes-ai.cn/zh-Hans/docs/agnes-video-25-flash 的 .md 原文）
 * ══════════════════════════════════════════════════════════════════════════
 *   创建：POST {base}/videos
 *     {
 *       "model": "agnes-video-2.5-flash",   // 必填
 *       "prompt": "...",                    // 必填
 *       "mode": "text" | "keyframe" | "reference",   // 必填
 *       "seconds": "5",        // 可选，**字符串** "4"–"12"，默认 "5"
 *       "size": "720P",        // Flash 固定 720P，别的值官方 400：size must be 720P
 *       "aspect_ratio": "16:9",// 可选，默认 16:9
 *       // keyframe 模式：first_frame / last_frame 至少给一个
 *       // reference 模式：images（≤5）或 audios（≤3）至少一类非空
 *       "seed": 123, "n": 1    // 可选；n 当前只支持 1
 *     }
 *   查询（官方推荐，适用全部模式）：
 *     GET {origin}/agnesapi?video_id=<VIDEO_ID>&model_name=agnes-video-2.5-flash
 *     （不带 model_name 的纯 video_id 查询只对 mode=text 有效）
 *   完成：status == "completed" → 取**顶层** url；status == "failed" → 读 error；
 *         中间态看 status / progress（internal_status/internal_progress 是内部字段，别当依据）。
 *
 * 模式互斥规则（官方"生成模式规则"表，本脚本会在发请求前先本地拦下来，省一次无效请求）：
 *   text      : 不允许 first_frame / last_frame / images / audios / videos
 *   keyframe  : first_frame 与 last_frame 至少一个；不允许 images / audios / videos
 *   reference : images 或 audios 至少一类非空；不允许 first_frame / last_frame / videos
 *
 * 兜底：如果 agnesapi 那条查询路径返回 404 或报错，会再试 `GET {base}/videos/<ID>`
 * （老写法）；两次都失败才如实报错，不会因为一条路径不对就整体失败。
 *
 * 价格口径（不要写成"永久免费"）：官方文档称原价 ¥0.15/秒、现价 ¥0/秒，
 * **当前限时免费**；免费政策如有调整，以 Agnes AI 平台最新公告为准。
 *
 * ⚠ 素材可访问性：官方要求"所有媒体 URL 都应可由 Agnes AI 服务公开访问"。
 *   Data URI 只在图片文档里被明确支持，视频接口不一定接受；本地文件仍会按
 *   data:image/...;base64,... 转换，但会往 stderr 打一行警告。
 *
 * 退出码：0 成功；1 生成/轮询/下载失败；2 参数或配置错误（含没有 Key）。
 * 依赖：只用 node 内置模块，**不使用 fetch**。
 */

import { createWriteStream, existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync } from 'node:fs';
import * as http from 'node:http';
import * as https from 'node:https';
import { dirname, extname, resolve } from 'node:path';

import {
  KeyRotator,
  RateLimitedError,
  backoffMs,
  callWithRateLimitRetry,
  humanDuration,
  parseApiKeys,
  retryAfterMs,
} from './agnes-retry.mjs';

// 多厂家：形状表是**唯一来源**（用户 2026-10-11 纠正「影视这个工具实际是可以
// 使用多个厂家」）。Agnes 那条路仍走下面的原生实现（它的查询端点在站点根、
// 还有 429 退避与多 Key 轮换，塞进通用函数反而最容易把它弄坏）。
import { VENDORS, missingBaseUrl, providerOf, vendorLabel, videoPlan } from './media-vendors.mjs';

// ─────────────────────────────────────────────────────────── 常量

const DEFAULT_BASE_URL = 'https://api.agnes-ai.cn/v1';
const DEFAULT_MODEL = 'agnes-video-2.5-flash';
const DEFAULT_REGISTER_URL = 'https://platform.agnes-ai.cn';
const DEFAULT_SECONDS = '5';
const DEFAULT_RATIO = '16:9';
const DEFAULT_TIMEOUT_MS = 600_000; // 轮询总上限 10 分钟
const DEFAULT_POLL_INTERVAL_MS = 1500; // 官方建议 1–2 秒
const CREATE_TIMEOUT_MS = 120_000;
const POLL_REQUEST_TIMEOUT_MS = 60_000;
const DEFAULT_BASE_MS = 2_000; // 没有 Retry-After 时的退避基准（与 agnes-retry.mjs 一致）
const DOWNLOAD_TIMEOUT_MS = 900_000;
const MAX_REDIRECTS = 3;
/** Flash 只能 720P（其它值官方 400：size must be 720P） */
const SIZE = '720P';
const MODES = ['text', 'keyframe', 'reference'];
const RATIOS = ['21:9', '16:9', '4:3', '1:1', '3:4', '9:16'];
const MAX_IMAGES = 5;
const MAX_AUDIOS = 3;

const MIME_BY_EXT = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.bmp': 'image/bmp',
};
const AUDIO_MIME_BY_EXT = {
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
  '.m4a': 'audio/mp4',
  '.aac': 'audio/aac',
  '.ogg': 'audio/ogg',
  '.flac': 'audio/flac',
};

const HELP = `make-video.mjs —— 生成视频（纯 node 内置模块，支持多个厂家）

用法:
  node make-video.mjs "<提示词>" <输出文件> [选项]
  node make-video.mjs "<提示词>" <输出文件> --provider doubao [选项]   # 用豆包 Seedance
  node make-video.mjs --print-request --provider dashscope "<提示词>" out.mp4  # 只看将要发的请求
  node make-video.mjs --help

选项:
  --provider <id>        厂家：agnes（默认）/ doubao / minimax / dashscope / siliconflow
                         不传就按模型名与端点猜；认不出按 agnes 的形状发
  --seconds <N>          时长。agnes 只认 4–12；别的厂家按各家的档位（1–60 之间由上游判断）
  --ratio <W:H>          画幅，默认 ${DEFAULT_RATIO}
                         agnes 支持 ${RATIOS.join(' / ')}；别家按各自文档
  --resolution <档位>    分辨率，默认 ${SIZE}（仅对支持这一档的厂家有效；Agnes Flash 固定 ${SIZE}）
  --mode <mode>          text（默认）/ keyframe（首帧图生视频）/ reference（仅 agnes）
  --first-frame <URL>    keyframe 模式首帧（图生视频）
  --last-frame <URL>     keyframe 模式尾帧（仅 agnes）
  --image <URL>          reference 模式参考图（仅 agnes），可重复，最多 ${MAX_IMAGES} 张
  --audio <URL>          reference 模式参考音频（仅 agnes），可重复，最多 ${MAX_AUDIOS} 段
  --model <name>         模型名，默认 ${DEFAULT_MODEL}（也可用环境变量 AGNES_VIDEO_MODEL 改默认值）
  --print-request        只打印将要发的请求（端点 + 请求体），**不发网络请求、不需要 Key**

各厂家的形状由 toolbox/media-vendors.mjs 一张表决定（唯一来源）：
  agnes      POST {base}/videos → 轮询 {origin}/agnesapi?video_id=…
  doubao     POST {base}/contents/generations/tasks → 轮询 …/tasks/{id}（Seedance，方舟）
  minimax    POST {v2base}/video_generation → 轮询 {base}/query/video_generation/{id}
  dashscope  POST {base}/api/v1/services/aigc/video-generation/video-synthesis
             （必须带 X-DashScope-Async: enable）→ 轮询 {base}/api/v1/tasks/{id}
  siliconflow POST {base}/video/submit → POST {base}/video/status
⚠️ 形状是按各家文档/已投产实现写的，但**本机没有这些厂家的 Key、也没法真机验证** ——
   能不能通要试；失败会把上游原话显示出来（不会吞掉）。

固定项: n 只支持 1。

环境变量:
  AGNES_API_KEY          必需（**借名**：换厂家时这里放的是那家的 Key）
  AGNES_API_KEYS         可选，多把（不同账号）用逗号/空白分隔
  AGNES_BASE_URL         可选，端点覆盖；默认按厂家取表里的地址
  AGNES_REGISTER_URL     可选，默认 ${DEFAULT_REGISTER_URL}
  AGNES_VIDEO_TIMEOUT_MS 可选，轮询总上限（毫秒）
  AGNES_POLL_INTERVAL_MS 可选，轮询间隔（毫秒；仅 agnes 生效，别家按各家的建议值）
  AGNES_VIDEO_TIMEOUT_MS 可选，轮询总上限，默认 ${DEFAULT_TIMEOUT_MS}（10 分钟）
  AGNES_POLL_INTERVAL_MS 可选，轮询间隔，默认 ${DEFAULT_POLL_INTERVAL_MS}

价格说明: 官方文档称原价 ¥0.15/秒、现价 ¥0/秒，当前限时免费；
          免费政策如有调整，以 Agnes AI 平台最新公告为准。

退出码: 0 成功；1 生成/轮询/下载失败；2 参数或配置错误（含没有 Key）。
`;

// ─────────────────────────────────────────────────────────── 输出与错误

function fail(message, code) {
  process.stderr.write('错误：' + message + '\n');
  process.exit(code === undefined ? 1 : code);
}

function usageFail(message) {
  process.stderr.write('错误：' + message + '\n\n' + HELP);
  process.exit(2);
}

function info(message) {
  process.stderr.write('[agnes-video] ' + message + '\n');
}

function head(text, n) {
  const s = String(text == null ? '' : text).replace(/\s+/g, ' ').trim();
  return s.length > (n || 200) ? s.slice(0, n || 200) + '…' : s;
}

// ─────────────────────────────────────────────────────────── HTTP（不用 fetch）

function rawRequest(method, urlStr, { headers, body, timeoutMs, redirectsLeft }) {
  return new Promise((resolvePromise, reject) => {
    let u;
    try {
      u = new URL(urlStr);
    } catch {
      reject(new Error('URL 不合法：' + urlStr));
      return;
    }
    if (u.protocol !== 'http:' && u.protocol !== 'https:') {
      reject(new Error('不支持的协议：' + u.protocol));
      return;
    }
    const mod = u.protocol === 'https:' ? https : http;
    const req = mod.request(u, { method, headers: headers || {} }, (res) => {
      const status = res.statusCode || 0;
      const location = res.headers.location;
      if (status >= 300 && status < 400 && location && (redirectsLeft || 0) > 0) {
        res.resume();
        resolvePromise(rawRequest(method, new URL(location, u).toString(), {
          headers,
          body,
          timeoutMs,
          redirectsLeft: redirectsLeft - 1,
        }));
        return;
      }
      resolvePromise({ res, url: u });
    });
    req.on('error', (err) => reject(new Error(`${err.code || 'ERR'}：${err.message}`)));
    if (timeoutMs) {
      req.setTimeout(timeoutMs, () => {
        req.destroy(Object.assign(new Error(`空闲超时（${timeoutMs} ms 没有数据往来）`), { code: 'ETIMEDOUT' }));
      });
    }
    req.end(body === undefined || body === null ? undefined : body);
  });
}

/** 发 JSON 请求读回响应体（带总时长上限） */
async function httpJson(method, urlStr, { headers, jsonBody, timeoutMs }) {
  const payload = jsonBody === undefined ? null : Buffer.from(JSON.stringify(jsonBody), 'utf8');
  const h = { ...(headers || {}) };
  if (payload) {
    h['content-type'] = h['content-type'] || 'application/json';
    h['content-length'] = String(payload.length);
  }
  let timer = null;
  try {
    const { res } = await Promise.race([
      rawRequest(method, urlStr, { headers: h, body: payload, timeoutMs, redirectsLeft: 0 }),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(`请求超时（超过 ${timeoutMs} ms）`)), timeoutMs);
      }),
    ]);
    const chunks = [];
    await new Promise((resolveEnd, rejectEnd) => {
      res.on('data', (c) => chunks.push(c));
      res.on('end', resolveEnd);
      res.on('error', rejectEnd);
    });
    return { status: res.statusCode || 0, headers: res.headers, text: Buffer.concat(chunks).toString('utf8') };
  } finally {
    if (timer) clearTimeout(timer);
  }
}

async function downloadToFile(url, destPath, { timeoutMs, headers }) {
  const { res, url: finalUrl } = await rawRequest('GET', url, {
    headers: headers || {},
    timeoutMs,
    redirectsLeft: MAX_REDIRECTS,
  });
  const status = res.statusCode || 0;
  if (status < 200 || status >= 300) {
    const chunks = [];
    await new Promise((r) => {
      res.on('data', (c) => chunks.push(c));
      res.on('end', r);
      res.on('error', r);
    });
    throw new Error(`下载失败：HTTP ${status}（${finalUrl.host}） 响应体前 200 字符：${head(Buffer.concat(chunks).toString('utf8'))}`);
  }
  const tmp = destPath + '.part';
  mkdirSync(dirname(destPath), { recursive: true });
  const out = createWriteStream(tmp);
  try {
    await new Promise((resolvePipe, rejectPipe) => {
      res.on('error', rejectPipe);
      out.on('error', rejectPipe);
      out.on('finish', resolvePipe);
      res.pipe(out);
    });
  } catch (e) {
    try {
      out.destroy();
    } catch {
      /* ignore */
    }
    try {
      rmSync(tmp, { force: true });
    } catch {
      /* ignore */
    }
    throw e;
  }
  renameSync(tmp, destPath);
  return statSync(destPath).size;
}

// ─────────────────────────────────────────────────────────── 参数解析

function parseArgs(argv) {
  const out = {
    prompt: null,
    output: null,
    seconds: DEFAULT_SECONDS,
    ratio: DEFAULT_RATIO,
    mode: 'text',
    firstFrame: null,
    lastFrame: null,
    images: [],
    audios: [],
    // 分辨率档位。Agnes Flash 固定 720P（下面会忽略这个值），其它厂家按各家的档位。
    resolution: SIZE,
    // 厂家 id：App 会显式传 `--provider <id>`；没传就按模型名 / 端点猜（默认 agnes）。
    provider: null,
    printRequest: false,
    // 「设置 → 图像 / 视频模型」选好之后由 App 注入 AGNES_VIDEO_MODEL；未注入就是内置那条。
    model: (process.env.AGNES_VIDEO_MODEL || '').trim() || DEFAULT_MODEL,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    const need = (name) => {
      const v = argv[++i];
      if (v === undefined || v.startsWith('--')) usageFail(`${name} 后面需要跟一个值`);
      return v;
    };
    if (a === '--help' || a === '-h') {
      process.stdout.write(HELP);
      process.exit(0);
    } else if (a === '--seconds') out.seconds = need('--seconds');
    else if (a === '--ratio') out.ratio = need('--ratio');
    else if (a === '--resolution') out.resolution = need('--resolution');
    else if (a === '--provider') out.provider = need('--provider');
    else if (a === '--print-request') out.printRequest = true;
    else if (a === '--mode') out.mode = need('--mode');
    else if (a === '--first-frame' || a === '--first_frame') out.firstFrame = need(a);
    else if (a === '--last-frame' || a === '--last_frame') out.lastFrame = need(a);
    else if (a === '--image') out.images.push(need('--image'));
    else if (a === '--audio') out.audios.push(need('--audio'));
    else if (a === '--model') out.model = need('--model');
    else if (a.startsWith('--')) usageFail(`不认识的选项：${a}`);
    else if (out.prompt === null) out.prompt = a;
    else if (out.output === null) out.output = a;
    else usageFail(`多余的参数：${a}`);
  }
  return out;
}

function toMediaInput(ref, kind) {
  if (/^https?:\/\//i.test(ref) || /^data:/i.test(ref)) return ref;
  const p = resolve(ref);
  if (!existsSync(p)) fail(`${kind}不存在：${p}`, 2);
  const ext = extname(p).toLowerCase();
  const table = kind === '参考音频' ? AUDIO_MIME_BY_EXT : MIME_BY_EXT;
  const mime = table[ext];
  if (!mime) fail(`${kind}格式不认识（${ext}）：${p}；支持 ${Object.keys(table).join(' / ')}`, 2);
  const b64 = readFileSync(p).toString('base64');
  process.stderr.write(
    `[agnes-video] 本地${kind}已转成 Data URI：${p}\n` +
      '               ⚠ 官方要求"所有媒体 URL 都应可由 Agnes AI 服务公开访问"，Data URI 只在图片接口文档里被明确支持，\n' +
      '                 视频接口可能直接拒绝；如果被拒，请先把素材传到可公开访问的地址再传 URL。\n',
  );
  return `data:${mime};base64,${b64}`;
}

/** 创建任务的 endpoint：base 可能带 /v1 也可能不带 */
function videosEndpoint(baseUrl) {
  const base = String(baseUrl).trim().replace(/\/+$/, '');
  if (/\/videos$/i.test(base)) return base;
  if (/\/v\d+$/i.test(base)) return `${base}/videos`;
  return `${base}/v1/videos`;
}

/** 官方推荐的查询：注意在**站点根**上，不在 /v1 下 */
function pollEndpoint(baseUrl, videoId, model) {
  const origin = new URL(baseUrl).origin;
  return `${origin}/agnesapi?video_id=${encodeURIComponent(videoId)}&model_name=${encodeURIComponent(model)}`;
}

/** 兜底查询（老写法） */
function legacyEndpoint(baseUrl, videoId) {
  const base = String(baseUrl).trim().replace(/\/+$/, '');
  const v1 = /\/v\d+$/i.test(base) ? base : `${base}/v1`;
  return `${v1}/videos/${encodeURIComponent(videoId)}`;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 认证头。**每次请求现算**：Key 在提交阶段可能被轮换（查进度时不会，见 jobKey）。 */
const authFor = (key) => ({ authorization: `Bearer ${key}`, accept: 'application/json' });

// ─────────────────────────────────────────────────────────── 多厂家（形状表驱动）

/**
 * 干跑：打印**将要发的请求**（不发网络请求、不需要 Key）。
 *
 * 为什么要有：形状对不对，是这次多厂家改造里**最容易错又最难发现**的东西 ——
 * 真机上要等到"提交了才发现 400"。有了它，`node make-video.mjs … --print-request`
 * 就能把端点与请求体打出来人工核对，测试也能 grep 它。
 */
function printVideoRequest({ args, provider, baseUrl, videoBaseUrl, secNum }) {
  const firstFrame = args.firstFrame
    ? { dataUri: `data:<已省略>;base64,<本地文件 ${args.firstFrame} 会在这里被读进来>` }
    : null;
  if (provider === 'agnes') {
    const body = {
      model: args.model,
      prompt: args.prompt,
      mode: args.mode,
      seconds: String(secNum),
      size: SIZE,
      aspect_ratio: args.ratio,
      n: 1,
    };
    if (args.firstFrame) body.first_frame = firstFrame.dataUri;
    if (args.lastFrame) body.last_frame = `<本地文件 ${args.lastFrame}>`;
    if (args.images.length) body.images = args.images.map((x) => `<本地文件 ${x}>`);
    if (args.audios.length) body.audios = args.audios.map((x) => `<本地文件 ${x}>`);
    process.stdout.write(
      `[print-request] provider=agnes shape=agnes\n` +
        `[print-request] submit POST ${videosEndpoint(baseUrl)}\n` +
        `[print-request] poll   GET ${new URL(baseUrl).origin}/agnesapi?video_id=<ID>&model_name=<MODEL>\n` +
        `[print-request] body   ${JSON.stringify(body)}\n`,
    );
    return;
  }
  const plan = videoPlan(provider, {
    model: args.model,
    prompt: args.prompt,
    seconds: args.seconds,
    resolution: args.resolution,
    ratio: args.ratio,
    firstFrame,
    mode: args.mode,
    baseUrl,
    videoBaseUrl,
  });
  if (!plan) {
    process.stdout.write(
      `[print-request] provider=${provider} video=unsupported（这家在本 App 里没接视频）\n`,
    );
    return;
  }
  process.stdout.write(
    `[print-request] provider=${provider} shape=${plan.shape} label=${plan.label}\n` +
      `[print-request] submit ${plan.submit.method} ${plan.submit.url}\n` +
      `[print-request] body   ${JSON.stringify(plan.submit.body)}\n` +
      `[print-request] poll   ${plan.poll.method} ${plan.poll.url('TASKID')}` +
      `${plan.poll.bodyOf ? ` body=${JSON.stringify(plan.poll.bodyOf('TASKID'))}` : ''}\n`,
  );
}

/**
 * 非 Agnes 厂家：完全按形状表走「提交 → 轮询 → 下载」。
 *
 * ## 为什么不复用 Agnes 那条路
 *
 * Agnes 的查询端点在**站点根**（`/agnesapi?video_id=…&model_name=…`）、要带
 * model_name、还有 429 退避 + 多 Key 轮换 —— 那些都是 Agnes 特有的。把几家塞进
 * 同一个函数，最先坏掉的一定是**本来能用的 Agnes**。所以这里单开一条，
 * Agnes 那条一个字节都不动。
 *
 * ## 复用到的部分
 *
 * `httpJson`（带总时长上限）、`callWithRateLimitRetry`（429 退避 + 提交阶段换 Key）、
 * `downloadToFile`（先写 `.part` 再改名），以及最后那行 **Dart 侧认的成功标记**。
 */
async function runVendorVideo({ args, provider, baseUrl, videoBaseUrl, rotator, secNum }) {
  const firstFrame = args.firstFrame
    ? { dataUri: toMediaInput(args.firstFrame, '首帧图') }
    : null;
  const plan = videoPlan(provider, {
    model: args.model,
    prompt: args.prompt,
    seconds: args.seconds,
    resolution: args.resolution,
    ratio: args.ratio,
    firstFrame,
    mode: args.mode,
    baseUrl,
    videoBaseUrl,
  });
  if (!plan) {
    fail(
      `「${vendorLabel(provider)}」这家在本 App 里没有接视频生成。\n` +
        '       目前接了视频的：Agnes / 豆包 Seedance（火山方舟）/ MiniMax / 通义万相 / 硅基流动。',
      2,
    );
  }

  info(`厂家=${plan.label}（形状 ${plan.shape}）· ${plan.log}`);
  info(`POST ${plan.submit.url}`);

  // ── 提交 ──
  // ⚠️ 与 Agnes 同一条纪律：**只有 429 才重试**。5xx / 超时绝不重试 ——
  //    上一次提交可能已经在平台侧建了任务（只是响应丢了），再提交就是第二个
  //    任务 + 再扣一次额度。（依据：桌面版影视工具插件的代理对视频提交
  //    retries=0，注释写明 a duplicate would create a second task/quota hit。）
  let created;
  let jobKey = rotator.current;
  try {
    const attempt = await callWithRateLimitRetry(
      async (key) => {
        const res = await httpJson('POST', plan.submit.url, {
          headers: { ...authFor(key), ...(plan.submit.headers || {}) },
          jsonBody: plan.submit.body,
          timeoutMs: CREATE_TIMEOUT_MS,
        });
        if (res.status === 429) {
          throw new RateLimitedError(
            `HTTP 429；响应体前 200 字符：${head(res.text)}`,
            retryAfterMs(res.headers),
          );
        }
        return { res, key };
      },
      { rotator, log: info },
    );
    created = attempt.res;
    jobKey = attempt.key;
  } catch (e) {
    fail(`创建视频任务失败：${e.message}`, 1);
  }
  if (created.status < 200 || created.status >= 300) {
    fail(
      `创建视频任务返回 HTTP ${created.status}` +
        `${created.status === 401 || created.status === 403 ? `（大概率是「${plan.label}」的 API Key 无效或没开通）` : ''}；` +
        `响应体前 200 字符：${head(created.text)}`,
      1,
    );
  }
  let createdJson;
  try {
    createdJson = JSON.parse(created.text);
  } catch (e) {
    fail(`创建任务的响应不是合法 JSON：${e.message}；响应体前 200 字符：${head(created.text)}`, 1);
  }
  const taskId = plan.taskIdOf(createdJson);
  if (!taskId) {
    fail(
      `创建任务的响应里找不到任务 ID（${plan.label} 的形状是 ${plan.shape}）：${head(created.text, 300)}`,
      1,
    );
  }
  info(`任务已创建：task_id=${taskId}`);

  // 查进度沿用**创建任务的那把 Key**（换 Key 会查到别的账号，查不到这个任务）。
  const auth = authFor(jobKey);
  const envTimeout = Number(process.env.AGNES_VIDEO_TIMEOUT_MS || 0);
  const timeoutMs = envTimeout > 0 ? envTimeout : plan.timeoutMs;
  const startedAt = Date.now();
  let lastNote = '';
  let videoUrl = '';

  for (;;) {
    if (Date.now() - startedAt > timeoutMs) {
      fail(
        `轮询超时（等满 ${humanDuration(timeoutMs)} 仍没等到完成）。最后状态=${lastNote || '(未知)'}\n` +
          `       任务可能仍在平台侧继续，可稍后到 ${plan.label} 的控制台用 task_id=${taskId} 查看结果。`,
        1,
      );
    }
    let poll;
    try {
      poll = await httpJson(plan.poll.method || 'GET', plan.poll.url(taskId), {
        headers: { ...auth, ...(plan.poll.headers || {}) },
        jsonBody: plan.poll.bodyOf ? plan.poll.bodyOf(taskId) : undefined,
        timeoutMs: POLL_REQUEST_TIMEOUT_MS,
      });
    } catch (e) {
      fail(`查询任务失败：${e.message}`, 1);
    }
    // 查进度遇到 429：退避重试**不换 Key**（任务归创建它的那把 Key 所有）。
    if (poll.status === 429) {
      const wait = retryAfterMs(poll.headers) || backoffMs(1);
      info(`查询被限流（429），等 ${humanDuration(wait)} 再查…`);
      await sleep(wait);
      continue;
    }
    if (poll.status < 200 || poll.status >= 300) {
      fail(`查询任务返回 HTTP ${poll.status}；响应体前 200 字符：${head(poll.text)}`, 1);
    }
    let json;
    try {
      json = JSON.parse(poll.text);
    } catch (e) {
      fail(`查询任务的响应不是合法 JSON：${e.message}；响应体前 200 字符：${head(poll.text)}`, 1);
    }
    const picked = plan.pick(json);
    if (picked.state === 'done') {
      videoUrl = picked.url;
      break;
    }
    if (picked.state === 'failed') {
      fail(`任务失败（${plan.label}，task_id=${taskId}）：${head(String(picked.message || ''), 300)}`, 1);
    }
    lastNote = picked.note || plan.shape;
    // 说人话：视频任务排队几分钟是正常的，"没反应"不等于卡住。
    info(
      `任务在平台侧进行中（${lastNote}），已等 ${humanDuration(Date.now() - startedAt)}…` +
        '（视频是异步任务，几十秒到几分钟都正常）',
    );
    await sleep(plan.pollIntervalMs || 5000);
  }

  const dest = resolve(args.output);
  info(`任务完成，开始下载：${videoUrl}`);
  let bytes;
  try {
    bytes = await downloadToFile(videoUrl, dest, { timeoutMs: DOWNLOAD_TIMEOUT_MS, headers: {} });
  } catch (e) {
    fail(e.message, 1);
  }

  // ⚠ 这一行是 Dart 侧识别的成功标记，格式不要改（与 Agnes 那条完全一致）
  process.stdout.write(`[agnes-video] ok file=${dest} bytes=${bytes} seconds=${String(secNum)}\n`);
}

// ─────────────────────────────────────────────────────────── 主流程

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.prompt) usageFail('缺少提示词（第一个参数）');
  if (args.prompt.trim() === '') usageFail('提示词不能是空白');
  if (!args.output) usageFail('缺少输出文件路径（第二个参数）');

  // 厂家：App 会显式传 `--provider`（模型配置里的厂家 id）；没传就按模型名/端点猜。
  const envBaseUrl = (process.env.AGNES_BASE_URL || '').trim();
  const provider = String(args.provider || providerOf({ model: args.model, baseUrl: envBaseUrl }) || 'agnes')
    .trim()
    .toLowerCase();
  // ── 端点怎么定（这一步错一次，所有外部厂家都会发到 Agnes 的域名去）──
  //
  // 规则：**环境变量显式给了就用它**（App 会把所选模型的 baseUrl 注入
  // `AGNES_BASE_URL`，用户也可以自己改端点）；没给就取**这家自己的默认地址**。
  //
  // ⚠️ 不能写成 `process.env.AGNES_BASE_URL || DEFAULT_BASE_URL` —— 那样
  //    用户选了"豆包"、又没填端点时，请求会被发到 `api.agnes-ai.cn`（Agnes 的域名），
  //    必然 404/401，而且报错信息看起来像"豆包的 Key 不对"，极难查。
  //    （这个 bug 是在干跑 `--provider doubao` 时看出来的：端点竟然是 agnes 的。）
  const providerDefaultBase = (VENDORS[provider] && VENDORS[provider].base) || '';
  const baseUrl = envBaseUrl || providerDefaultBase;
  // MiniMax 是**两个根**：视频提交在 v2、查进度在 v1。用户自己改了端点时，
  // 视频那个根也要跟着走（否则自定义代理下只有提交会跑到官方域名去）。
  const videoBaseUrl = envBaseUrl ? envBaseUrl.replace(/\/v\d+$/i, '/v2') : undefined;

  // ── 参数校验**按厂家分** ────────────────────────────────────────────────
  //
  // 为什么必须分：Agnes 有它自己的档位（4–12 秒、固定的比例集合、mode 三选一），
  // 而别的厂家档位不一样 —— 豆包 Seedance 4–30、MiniMax 6–10、万相 2–15、
  // 硅基流动**根本没有时长参数**。拿 Agnes 的尺子去量别家，就是把本来能跑的参数
  // 判成非法（用户会看到"参数错误"，而其实参数是对的）。
  const secNum = Number(args.seconds);
  if (provider === 'agnes') {
    // 时长：官方是字符串 "4"–"12"
    if (!Number.isInteger(secNum) || secNum < 4 || secNum > 12) {
      usageFail(`--seconds 需要 4–12 的整数（官方是字符串 "4"–"12"），收到 ${JSON.stringify(args.seconds)}`);
    }
    if (!MODES.includes(args.mode)) usageFail(`--mode 只能是 ${MODES.join(' / ')}，收到 ${JSON.stringify(args.mode)}`);
    if (!RATIOS.includes(args.ratio)) usageFail(`--ratio 不支持 ${JSON.stringify(args.ratio)}；官方支持：${RATIOS.join(' / ')}`);

    // 模式互斥规则：本地先拦，省一次必然失败的请求
    if (args.mode === 'text') {
      if (args.firstFrame || args.lastFrame || args.images.length || args.audios.length) {
        usageFail('mode=text 不允许带 --first-frame / --last-frame / --image / --audio（官方模式规则）');
      }
    } else if (args.mode === 'keyframe') {
      if (!args.firstFrame && !args.lastFrame) usageFail('mode=keyframe 必须给 --first-frame 或 --last-frame（至少一个）');
      if (args.images.length || args.audios.length) usageFail('mode=keyframe 不允许带 --image / --audio（官方模式规则）');
    } else if (args.mode === 'reference') {
      if (args.images.length === 0 && args.audios.length === 0) {
        usageFail('mode=reference 必须给 --image 或 --audio（至少一类非空）');
      }
      if (args.firstFrame || args.lastFrame) usageFail('mode=reference 不允许带 --first-frame / --last-frame（官方模式规则）');
      if (args.images.length > MAX_IMAGES) usageFail(`mode=reference 的 --image 最多 ${MAX_IMAGES} 张（官方限制）`);
      if (args.audios.length > MAX_AUDIOS) usageFail(`mode=reference 的 --audio 最多 ${MAX_AUDIOS} 段（官方限制）`);
    }
  } else {
    if (!Number.isInteger(secNum) || secNum < 1 || secNum > 60) {
      usageFail(`--seconds 需要 1–60 的整数，收到 ${JSON.stringify(args.seconds)}（各家的真实档位由这家自己判断，超出会由上游报错）`);
    }
    // 这一层形状表只实现了「文生视频」和「首帧图生视频」。
    // 别家也许多模态参考（Seedance 支持参考视频/音频），但**没实测过就不假装支持**。
    if (args.mode === 'reference' || args.images.length || args.audios.length) {
      usageFail(
        `「${vendorLabel(provider)}」这条路目前只支持文生视频与首帧图生视频，没有"参考图/参考音频"这一路。\n` +
          '       请改用 --first-frame（图生视频），或换回 Agnes。',
      );
    }
    if (args.lastFrame) {
      usageFail(`「${vendorLabel(provider)}」这条路只支持首帧，不支持尾帧。请改用 --first-frame，或换回 Agnes。`);
    }
  }

  // 认不出的厂家（用户自己填的）表里没有默认端点 —— 不填就会拼出没有主机名的地址。
  if (missingBaseUrl(provider, baseUrl)) {
    fail(
      `「${vendorLabel(provider)}」这家要自己填端点（base URL），现在没填，不知道该往哪儿发。\n` +
        '       请到「设置 → 视频模型」把端点补上（也可以在「云端大模型」里按厂家 id 配好）。',
      2,
    );
  }

  // ── 干跑：只打印将要发的请求，**不发任何网络请求、不需要 Key** ──
  if (args.printRequest) {
    printVideoRequest({ args, provider, baseUrl, videoBaseUrl, secNum });
    return;
  }

  // 支持**多把** Key（`AGNES_API_KEYS`，逗号/空白/换行分隔；`AGNES_API_KEY` 仍然认）。
  // 多把的意义：限流/额度按**账号**算 —— 同一账号多建 Key 共享同一份配额，等于没用；
  // 只有**不同账号**的多把 Key 才能真正加容量。单把时行为与以前完全一致。
  const apiKeys = parseApiKeys();
  const registerUrl = (process.env.AGNES_REGISTER_URL || DEFAULT_REGISTER_URL).trim();
  if (apiKeys.length === 0) {
    // ⚠️ 文案按厂家分：对一家外部厂家说"没有配置 Agnes 的 Key"是误导
    //    （用户会以为要去注册 Agnes，其实该去配那家的 Key）。
    if (provider === 'agnes') {
      fail(
        '没有配置 Agnes 的 API Key，无法生成视频。\n' +
          `       请先到 ${registerUrl} 免费注册，拿到 API Key 后填到「设置 → 模型 → Agnes（免费）」这一项（App 会以 AGNES_API_KEY 环境变量注入）。\n` +
          '       视频模型当前限时免费（原价 ¥0.15/秒，现价 ¥0/秒）；免费政策如有调整，以 Agnes AI 平台最新公告为准。',
        2,
      );
    } else {
      fail(
        `没有配置「${vendorLabel(provider)}」的 API Key，无法生成视频。\n` +
          '       请到「设置 → 云端大模型」按**厂家 id** 配好这一家的 Key（厂家 id 就是模型配置里那个，' +
          `例如 ${provider}），App 会把它的 Key 注入给本脚本。`,
        2,
      );
    }
  }
  const rotator = new KeyRotator(apiKeys);
  if (rotator.count > 1) {
    info(
      `检测到 ${rotator.count} 把 Key：**提交**阶段遇到限流会自动换下一把；` +
        '查进度不会换（任务归创建它的那把 Key 所有）。',
    );
  }

  // ── 非 Agnes：完全按形状表走「提交 → 轮询 → 下载」 ─────────────────────
  if (provider !== 'agnes') {
    await runVendorVideo({ args, provider, baseUrl, videoBaseUrl, rotator, secNum });
    return;
  }

  const totalTimeoutMs = Number(process.env.AGNES_VIDEO_TIMEOUT_MS || DEFAULT_TIMEOUT_MS);
  const pollIntervalMs = Number(process.env.AGNES_POLL_INTERVAL_MS || DEFAULT_POLL_INTERVAL_MS);
  const createUrl = videosEndpoint(baseUrl);

  const body = {
    model: args.model,
    prompt: args.prompt,
    mode: args.mode,
    seconds: String(secNum), // 官方要字符串
    size: SIZE, // Flash 固定 720P
    aspect_ratio: args.ratio,
    n: 1,
  };
  if (args.mode === 'keyframe') {
    if (args.firstFrame) body.first_frame = toMediaInput(args.firstFrame, '首帧图');
    if (args.lastFrame) body.last_frame = toMediaInput(args.lastFrame, '尾帧图');
  }
  if (args.mode === 'reference') {
    if (args.images.length) body.images = args.images.map((x) => toMediaInput(x, '参考图'));
    if (args.audios.length) body.audios = args.audios.map((x) => toMediaInput(x, '参考音频'));
  }

  info(`POST ${createUrl} model=${args.model} mode=${args.mode} seconds=${body.seconds} size=${SIZE} ratio=${args.ratio}`);
  // ⚠️ 只有**提交**这一步能换 Key（换 Key 会建到另一个账号下）。
  // 429 走退避重试；401/403 是 Key 本身的问题，退避重试没意义 → 原样抛出。
  let created;
  let jobKey = rotator.current;
  try {
    const attempt = await callWithRateLimitRetry(
      async (key) => {
        const res = await httpJson('POST', createUrl, {
          headers: authFor(key),
          jsonBody: body,
          timeoutMs: CREATE_TIMEOUT_MS,
        });
        // ⚠️ **只有 429 才重试**。5xx / 网络超时**绝不能重试**：
        //    上一次提交可能已经在平台侧建了任务（只是响应丢了），再提交就是
        //    **第二个任务 + 再扣一次配额**。429 不同 —— 那是服务端明确拒收，
        //    说明没建任务，重试是安全的。
        //    依据：桌面端影视工具插件的代理也是这么分的（生图 retries=3、
        //    视频提交 retries=0，注释写明 a duplicate would create a second
        //    task/quota hit）。
        if (res.status === 429) {
          throw new RateLimitedError(
            `HTTP 429；响应体前 200 字符：${head(res.text)}`,
            retryAfterMs(res.headers),
          );
        }
        return { res, key };
      },
      { rotator, log: info },
    );
    created = attempt.res;
    // 记下"这个任务是用哪把 Key 建的" —— 后面查进度必须一直用它。
    jobKey = attempt.key;
  } catch (e) {
    fail(`创建视频任务失败：${e.message}`, 1);
  }
  if (created.status < 200 || created.status >= 300) {
    fail(
      `创建视频任务返回 HTTP ${created.status}${created.status === 401 || created.status === 403 ? '（大概率是 API Key 无效或没开通）' : ''}；` +
        `响应体前 200 字符：${head(created.text)}`,
      1,
    );
  }
  // 查进度 / 取结果都沿用**创建任务的那把 Key**（换 Key 会查到别的账号、查不到这个任务）。
  const auth = authFor(jobKey);
  let createdJson;
  try {
    createdJson = JSON.parse(created.text);
  } catch (e) {
    fail(`创建任务的响应不是合法 JSON：${e.message}；响应体前 200 字符：${head(created.text)}`, 1);
  }
  // 官方：video_id 用来查询；id / task_id 是任务 ID，作为兜底
  const videoId = createdJson.video_id || createdJson.id || createdJson.task_id;
  if (!videoId) {
    fail(`创建任务的响应里找不到 video_id / id / task_id：${head(created.text, 300)}`, 1);
  }
  info(`任务已创建：video_id=${videoId} status=${createdJson.status || '(未给出)'}`);

  // 轮询
  const startedAt = Date.now();
  const primaryUrl = pollEndpoint(baseUrl, videoId, args.model);
  const fallbackUrl = legacyEndpoint(baseUrl, videoId);
  let heardAboutFallback = false;
  let pollRateLimitWaits = 0;
  let lastStatus = '(未知)';
  let lastProgress = null;
  let result = null;

  for (;;) {
    if (Date.now() - startedAt > totalTimeoutMs) {
      fail(
        `轮询超时（等满 ${humanDuration(totalTimeoutMs)} 仍没等到 completed）。最后状态=${lastStatus}` +
          (lastProgress === null ? '' : ` 进度=${lastProgress}`) +
          `\n       任务可能仍在平台侧继续，可稍后到 ${registerUrl} 或平台控制台用 video_id=${videoId} 查看结果。`,
        1,
      );
    }

    let poll = null;
    let pollErr = null;
    try {
      poll = await httpJson('GET', primaryUrl, { headers: auth, timeoutMs: POLL_REQUEST_TIMEOUT_MS });
    } catch (e) {
      pollErr = e.message;
    }

    // 推荐路径 404 或报错 → 兜底试老写法（只提示一次）
    if (!poll || poll.status === 404 || poll.status >= 500) {
      if (!heardAboutFallback) {
        heardAboutFallback = true;
        info(
          `查询路径 ${poll ? `HTTP ${poll.status}` : `报错(${pollErr})`}，按兜底再试一次老写法：${fallbackUrl}`,
        );
      }
      try {
        const alt = await httpJson('GET', fallbackUrl, { headers: auth, timeoutMs: POLL_REQUEST_TIMEOUT_MS });
        if (alt.status >= 200 && alt.status < 300) poll = alt;
      } catch (e) {
        if (!poll) pollErr = e.message;
      }
    }

    if (!poll) {
      // 两条路径都连不上：可能是临时网络问题，限时重试而不立刻失败
      info(`查询失败（${pollErr}），${Math.round(pollIntervalMs / 1000)} 秒后重试…`);
      await sleep(pollIntervalMs);
      continue;
    }
    if (poll.status === 429) {
      // ⚠️ 这里**不换 Key、更不重新提交**：
      //   · 换 Key → 任务属于另一把 Key，查不到；
      //   · 重新提交 → 会**重复排队**，越等越久（这正是"越急越出不来"的原因）。
      // 所以只做退避，然后继续查同一个 video_id。
      const waitMs = retryAfterMs(poll.headers) ?? backoffMs(1, DEFAULT_BASE_MS, 30_000);
      pollRateLimitWaits += 1;
      info(
        `查进度被限流（HTTP 429），等 ${humanDuration(waitMs)} 再查` +
          `（任务仍在平台侧跑，不会重新提交；本次第 ${pollRateLimitWaits} 次限流）…`,
      );
      await sleep(waitMs);
      continue;
    }
    if (poll.status < 200 || poll.status >= 300) {
      fail(`查询任务返回 HTTP ${poll.status}；响应体前 200 字符：${head(poll.text)}`, 1);
    }

    let json;
    try {
      json = JSON.parse(poll.text);
    } catch (e) {
      fail(`查询任务的响应不是合法 JSON：${e.message}；响应体前 200 字符：${head(poll.text)}`, 1);
    }

    lastStatus = json.status || '(未知)';
    lastProgress = json.progress === undefined ? null : json.progress;

    if (lastStatus === 'completed') {
      result = json;
      break;
    }
    if (lastStatus === 'failed') {
      const err = json.error ? (typeof json.error === 'string' ? json.error : JSON.stringify(json.error)) : '(平台没有给出 error 字段)';
      fail(`任务失败（video_id=${videoId}）：${head(err, 300)}`, 1);
    }
    // 说人话：很多人以为"没反应"就是卡住了，其实视频任务排队几分钟是正常的。
    info(
      `任务在平台侧进行中（status=${lastStatus}${lastProgress === null ? '' : ` 进度=${lastProgress}`}），` +
        `已等 ${humanDuration(Date.now() - startedAt)}…（视频是异步任务，几十秒到几分钟都正常）`,
    );
    await sleep(pollIntervalMs);
  }

  const videoUrl = result.url;
  if (!videoUrl) {
    fail(`任务已完成，但响应里没有顶层 url 字段：${head(JSON.stringify(result), 300)}`, 1);
  }

  const dest = resolve(args.output);
  info(`任务完成，开始下载：${videoUrl}`);
  let bytes;
  try {
    bytes = await downloadToFile(videoUrl, dest, { timeoutMs: DOWNLOAD_TIMEOUT_MS, headers: {} });
  } catch (e) {
    fail(e.message, 1);
  }

  // ⚠ 这一行是 Dart 侧识别的成功标记，格式不要改
  process.stdout.write(`[agnes-video] ok file=${dest} bytes=${bytes} seconds=${body.seconds}\n`);
}

main().catch((e) => fail(`未预期的错误：${(e && e.stack) || e}`, 1));
