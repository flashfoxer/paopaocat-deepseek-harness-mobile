#!/usr/bin/env node
'use strict';
/**
 * make-image.mjs —— 生成图片（文生图 / 图生图 / 多图合成），**支持多个厂家**。
 *
 * 用法：
 *   node make-image.mjs "<提示词>" <输出文件> [--provider agnes] [--size 2K] [--ratio 16:9]
 *                       [--model agnes-image-2.5-flash] [--ref <图片URL或本地文件路径>]...
 *   node make-image.mjs "<提示词>" --print-request [--provider openai] ...   # 干跑：只打印请求形状
 *   node make-image.mjs --help
 *
 * 厂家（`--provider`，不传就从模型名 + 端点猜，猜不出按 OpenAI 兼容试）：
 *   agnes · openai · zhipu（智谱 GLM）· dashscope（通义万相）· doubao（火山方舟）·
 *   minimax · siliconflow（硅基流动）· unknown（用户自己填的端点）
 *
 *   **请求形状（端点 / 参数名 / 怎么取结果 / 怎么轮询）全部来自共享形状表
 *   `./media-vendors.mjs`** —— 本文件不再自己拼请求体。改这条的理由（用户
 *   2026-10-11 明确纠正）：「影视这个工具实际是可以使用多个厂家」，而原来这里
 *   只会发 Agnes 那一套（`size` 档位 + `extra_body.response_format`），
 *   换厂家只换 base URL / Key 的话参数名与端点全不对，必然失败。
 *
 * 环境变量（**变量名保持 AGNES_* 不变** —— App 侧是"借名"注入的：不同厂家
 * 用同一组变量名，值是那家的 Key 与端点；改名会让 App 侧跟着改）：
 *   AGNES_API_KEY       必需。没有它就直接报中文错误（说清是哪一家、去哪配），
 *                       **绝不假装生成成功**。
 *   AGNES_API_KEYS      可选：**多把** Key（逗号/空白/换行分隔），被限流时自动换。
 *   AGNES_BASE_URL      可选。**用户填的端点优先**；不填就用厂家表里的默认端点
 *                       （App 会把「设置 → 图像模型」里选中那条的端点注入这里）。
 *                       `unknown`（自定义厂家）在表里没有默认端点，必须填。
 *   AGNES_REGISTER_URL  可选，默认 https://platform.agnes-ai.cn（仅 Agnes 报错时打印）
 *   AGNES_IMAGE_TIMEOUT_MS 可选，默认 360000（官方建议客户端超时 60s–360s）
 *   AGNES_IMAGE_MODEL   可选，默认内置模型名（App 注入选中的模型；`--model` 优先）
 *
 * 干跑（`--print-request`）：把"将要发的请求"按固定格式打到 stdout（provider /
 * method / url / multipart / async / headers / body），**不发任何网络请求**，
 * 也不需要 Key，exit 0。测试与人工核对形状都靠它。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 其中 Agnes 那一家的官方接口约定（照抄
 * https://agnes-ai.cn/zh-Hans/docs/agnes-image-25-flash ，
 * 这一页的 .md 原文比渲染页面更全，以下字段名/取值都是原文核对过的）
 * ══════════════════════════════════════════════════════════════════════════
 *   POST https://api.agnes-ai.cn/v1/images/generations
 *   Headers: Authorization: Bearer <KEY> · Content-Type: application/json
 *   Body:
 *     {
 *       "model": "agnes-image-2.5-flash",     // 必填
 *       "prompt": "...",                      // 必填
 *       "size": "2K",                         // 必填；1K/2K/3K/4K，也兼容 "1024x768"
 *       "ratio": "16:9",                      // 可选；默认 1:1
 *       "extra_body": {
 *         "response_format": "url",           // ⚠ 必须放 extra_body，放顶层是官方点名的错误写法
 *         "image": ["https://... 或 data:image/png;base64,..."]   // 图生图/多图合成：放这里的数组！
 *       }
 *     }
 *   响应：{ "created": 1780000000,
 *           "data": [ { "url": "https://...", "b64_json": null, "revised_prompt": null } ] }
 *   （Base64 返回时 url 为 null、b64_json 有值；本脚本两种都能落盘。）
 *
 * Agnes 的易错点（官方故障排除里专门列了三条，形状表里已按这个写死）：
 *   1. `response_format` 放顶层 → 错，必须 `extra_body.response_format`。
 *   2. 参考图放顶层 → 错，必须 `extra_body.image`（数组）。
 *   3. 图生图**不需要** `tags: ["img2img"]`，别多传。
 *
 * 别家的形状（对照 `media-vendors.mjs`）：
 *   * openai 兼容（openai / 智谱 / 豆包 / 硅基流动 / unknown）：`size` 用像素、
 *     `response_format` 在顶层、参考图在顶层 `image` 数组；
 *   * **OpenAI 带参考图**：走 `/images/edits` 的 **multipart/form-data**（字段名
 *     `image`，多张就重复同名字段）—— 官方没有顶层 `image` 参数；
 *   * MiniMax：`/image_generation`，比例用 `aspect_ratio`，结果在 `data.image_urls[]`；
 *   * 通义万相（DashScope）：**异步** —— 先带 `X-DashScope-Async: enable` 创建任务，
 *     再轮询 `/api/v1/tasks/{id}` 到 `output.task_status === 'SUCCEEDED'`，
 *     结果在 `output.results[0].url|b64_image`；**没有** `ratio` 参数（比例靠 `size`）。
 *
 * 价格口径（不要写成"永久免费"）：Agnes 官方文档称「所有支持的输出分辨率档位和输入
 * 参考图片当前均免费」；免费政策如有调整，以 Agnes AI 平台最新公告为准。
 * 别家的计费口径各不相同，本脚本不猜、也不在文案里承诺。
 *
 * 退出码：0 成功；1 生成/下载失败；2 参数或配置错误（含没有 Key）。
 * 依赖：只用 node 内置模块，**不使用 fetch**（要自己控制超时、重定向与错误体读取），
 *       multipart 也自己用 Buffer 拼（不引第三方库）。
 */

import { createWriteStream, existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
import * as http from 'node:http';
import * as https from 'node:https';
import { tmpdir } from 'node:os';
import { basename, dirname, extname, join, resolve } from 'node:path';

import {
  KeyRotator,
  RateLimitedError,
  TransientError,
  callWithRateLimitRetry,
  parseApiKeys,
  retryAfterMs,
  sleep,
} from './agnes-retry.mjs';

// 厂家形状表（**唯一来源**，只做纯计算；本文件不自己拼请求体）。
// 见该文件顶部：为什么必须有这一份（用户 2026-10-11 的纠正）。
import {
  VENDOR_IDS,
  dashscopeImageResult,
  imagePlan,
  missingBaseUrl,
  providerOf,
  vendorLabel,
} from './media-vendors.mjs';

// ─────────────────────────────────────────────────────────── 常量

const DEFAULT_BASE_URL = 'https://api.agnes-ai.cn/v1';
const DEFAULT_MODEL = 'agnes-image-2.5-flash';
const DEFAULT_REGISTER_URL = 'https://platform.agnes-ai.cn';
const DEFAULT_SIZE = '2K';
const DEFAULT_TIMEOUT_MS = 360_000; // 官方建议 60s–360s
const DOWNLOAD_TIMEOUT_MS = 300_000;
const MAX_REDIRECTS = 3;

/** 官方支持的宽高比（默认 1:1） */
const RATIOS = ['1:1', '3:4', '4:3', '16:9', '9:16', '2:3', '3:2', '21:9'];
/** 官方推荐的档位式尺寸 */
const SIZES = ['1K', '2K', '3K', '4K'];
/** 本地参考图 → Data URI 时用的 MIME */
const MIME_BY_EXT = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.bmp': 'image/bmp',
};

const HELP = `make-image.mjs —— 文生图 / 图生图 / 多图合成，支持多个厂家（纯 node 内置模块）

用法:
  node make-image.mjs "<提示词>" <输出文件> [选项]
  node make-image.mjs "<提示词>" --print-request [选项]   # 干跑：只打印将要发的请求，不发网络请求
  node make-image.mjs --help

选项:
  --provider <id>        厂家，可选；不传就从 --model 与 AGNES_BASE_URL 猜。
                         内置：${VENDOR_IDS.join(' / ')}
                         （请求形状全部来自共享形状表 ./media-vendors.mjs）
  --size <1K|2K|3K|4K>   输出档位，默认 ${DEFAULT_SIZE}（也兼容 1024x768 这类历史精确尺寸）
                         别家的尺寸写法由「设置 → 图像模型」那条决定（例如 1024*1024）
  --ratio <W:H>          宽高比，可选；支持 ${RATIOS.join(' / ')}（不传则由服务端用默认值 1:1）
  --model <name>         模型名，默认 ${DEFAULT_MODEL}（也可用环境变量 AGNES_IMAGE_MODEL 改默认值）
  --negative-prompt <s>  负面提示词，可选；只有支持的厂家才会带上（不支持的会忽略）
  --ref <URL|本地文件>   参考图，可重复；本地文件会转成 data:image/...;base64,...
                         传了 --ref 就是图生图/多图合成（Agnes 放 extra_body.image；
                         OpenAI 会改走 /images/edits 的 multipart）
  --print-request        干跑：打印 method/url/multipart/async/headers/body 后正常退出（exit 0），
                         **不发任何网络请求、不需要 Key**（测试与人工核对形状用）

环境变量:
  AGNES_API_KEY          必需；没有会按**实际厂家**报错（Agnes 会提示去 ${DEFAULT_REGISTER_URL} 注册）
  AGNES_API_KEYS         可选：**多把** Key（逗号/空白/换行分隔）。限流按账号算，
                         只有不同账号的 Key 才能加容量；被限流时自动换下一把。
  AGNES_BASE_URL         可选。用户填的端点优先；不填就用厂家表默认（Agnes 默认 ${DEFAULT_BASE_URL}）。
                         ⚠ 变量名对**所有厂家**都是这一组（App 侧"借名"注入，值是那家的 Key 与端点）。
  AGNES_REGISTER_URL     可选，默认 ${DEFAULT_REGISTER_URL}
  AGNES_IMAGE_TIMEOUT_MS 可选，默认 ${DEFAULT_TIMEOUT_MS}

价格说明: Agnes 官方文档称所有支持的输出分辨率档位和输入参考图片当前均免费；
          免费政策如有调整，以 Agnes AI 平台最新公告为准。别家的计费口径各不相同。

退出码: 0 成功（含 --print-request）；1 生成/下载失败；2 参数或配置错误（含没有 Key）。
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

/** 只取错误体最前面一小段，避免把整页 HTML/密钥回显进日志 */
function head(text, n) {
  const s = String(text == null ? '' : text).replace(/\s+/g, ' ').trim();
  return s.length > (n || 200) ? s.slice(0, n || 200) + '…' : s;
}

// ─────────────────────────────────────────────────────────── HTTP（不用 fetch）

/** 起一个 http(s) 请求，返回 Promise<{res, url}>；超时/连接失败都 reject 带中文原因 */
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
      // 跟随重定向（图片/视频地址常常 302 到 CDN）
      const status = res.statusCode || 0;
      const location = res.headers.location;
      if (status >= 300 && status < 400 && location && (redirectsLeft || 0) > 0) {
        res.resume(); // 丢掉这个响应体，不然连接不释放
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

/**
 * 发一个请求并读回响应体；带"总时长"上限（生成类接口只回一次，总时长能兜住）。
 *
 * `jsonBody` 走 JSON；`rawBody`（Buffer）+ `contentType` 走**已拼好的原始字节**
 * （multipart/form-data 用这条，见 [buildMultipartBody]）。
 */
async function httpJson(method, urlStr, { headers, jsonBody, rawBody, contentType, timeoutMs }) {
  const payload = rawBody !== undefined
    ? rawBody
    : (jsonBody === undefined ? null : Buffer.from(JSON.stringify(jsonBody), 'utf8'));
  const h = { ...(headers || {}) };
  if (payload) {
    h['content-type'] = h['content-type'] || contentType || 'application/json';
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

/** 把 URL 下载到本地文件（先写 .part 再改名，避免留下半个文件） */
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

function defaultModel() {
  // 「设置 → 图像 / 视频模型」选好之后由 App 注入这个变量；没注入就是官方内置那条。
  // 用户也可以在 --model 里显式覆盖（显式参数优先）。
  const fromEnv = (process.env.AGNES_IMAGE_MODEL || '').trim();
  return fromEnv || DEFAULT_MODEL;
}

function parseArgs(argv) {
  const out = {
    prompt: null,
    output: null,
    size: DEFAULT_SIZE,
    ratio: null,
    model: defaultModel(),
    refs: [],
    provider: null,
    negativePrompt: null,
    printRequest: false,
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
    } else if (a === '--size') {
      out.size = need('--size');
    } else if (a === '--ratio') {
      out.ratio = need('--ratio');
    } else if (a === '--model') {
      out.model = need('--model');
    } else if (a === '--provider') {
      out.provider = need('--provider');
    } else if (a === '--negative-prompt' || a === '--negative') {
      out.negativePrompt = need(a);
    } else if (a === '--print-request') {
      out.printRequest = true;
    } else if (a === '--ref' || a === '--image') {
      out.refs.push(need(a));
    } else if (a.startsWith('--')) {
      usageFail(`不认识的选项：${a}`);
    } else if (out.prompt === null) {
      out.prompt = a;
    } else if (out.output === null) {
      out.output = a;
    } else {
      usageFail(`多余的参数：${a}`);
    }
  }
  return out;
}

/**
 * 参考图 → 形状表要的 `{path, mime, dataUri}`。
 *
 * 两种来源要分清（形状表里写的 `refs.map(r => r.dataUri || r.path)` 正是为这两种写的）：
 *   * **本地文件**：`path` 是真实路径（multipart 要读盘）、`dataUri` 是 `data:...`；
 *   * **远程 URL / data URI**：`path` 为 null，`dataUri` 直接放这个地址本身。
 */
function toImageRef(ref) {
  if (/^data:/i.test(ref)) return { path: null, mime: null, dataUri: ref };
  if (/^https?:\/\//i.test(ref)) return { path: null, mime: null, dataUri: ref };
  const p = resolve(ref);
  if (!existsSync(p)) fail(`参考图不存在：${p}`, 2);
  const ext = extname(p).toLowerCase();
  const mime = MIME_BY_EXT[ext];
  if (!mime) fail(`参考图格式不认识（${ext}）：${p}；支持 ${Object.keys(MIME_BY_EXT).join(' / ')}`, 2);
  const b64 = readFileSync(p).toString('base64');
  process.stderr.write(`[agnes-image] 本地参考图已转成 Data URI：${p}（${b64.length} 个 base64 字符）\n`);
  return { path: p, mime, dataUri: `data:${mime};base64,${b64}` };
}

/** 从 MIME 猜扩展名（远程参考图下到临时文件时要给个像样的文件名）。 */
function extFromMime(mime) {
  switch (String(mime || '').toLowerCase()) {
    case 'image/png':
      return '.png';
    case 'image/jpeg':
      return '.jpg';
    case 'image/webp':
      return '.webp';
    case 'image/gif':
      return '.gif';
    case 'image/bmp':
      return '.bmp';
    default:
      return '';
  }
}

/**
 * multipart 要的是**原始字节**：data URI 直接解码、本地文件读盘、远程 URL 先下到临时文件。
 *
 * @returns {Promise<{bytes: Buffer, mime: string}>}
 */
async function refBytes(ref) {
  const uri = String((ref && ref.dataUri) || '');
  if (uri.startsWith('data:')) {
    const comma = uri.indexOf(',');
    if (comma < 0) fail('参考图的 data URI 不合法（没有逗号分隔）。', 2);
    const meta = uri.slice(5, comma);
    const payload = uri.slice(comma + 1);
    const isB64 = /;base64/i.test(meta);
    const mime = (meta.split(';')[0] || '').trim() || ref.mime || 'application/octet-stream';
    return { bytes: Buffer.from(payload, isB64 ? 'base64' : 'utf8'), mime: ref.mime || mime };
  }
  if (ref && ref.path && existsSync(ref.path)) {
    return { bytes: readFileSync(ref.path), mime: ref.mime || 'application/octet-stream' };
  }
  if (/^https?:\/\//i.test(uri)) {
    const tmp = join(
      tmpdir(),
      `dsh-ref-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2)}` +
        (extFromMime(ref && ref.mime) || '.png'),
    );
    await downloadToFile(uri, tmp, { timeoutMs: DOWNLOAD_TIMEOUT_MS });
    try {
      return { bytes: readFileSync(tmp), mime: (ref && ref.mime) || extFromMime(extname(tmp)) || 'image/png' };
    } finally {
      rmSync(tmp, { force: true });
    }
  }
  fail('参考图既不是本地文件、也不是可下载的 URL，没法作为 multipart 的文件发出去。', 2);
}

/** multipart 里的文件名（只是给上游看的标签，不含路径）。 */
function refFilename(ref) {
  if (ref && ref.path) return basename(ref.path);
  const ext = extFromMime(ref && ref.mime) || '.png';
  return `image${ext}`;
}

/**
 * 自己用 Buffer 拼 multipart/form-data（**不引第三方库** —— 本机只能跑 node 内置模块）。
 *
 * 字段名取 `plan.multipart.files[].field`（OpenAI 的 `/images/edits` 是 `image`，
 * 多张就重复同名字段）；`plan.multipart.fields` 里的每个键值作为普通字段带上
 * （值为 undefined 的跳过 —— 形状表里可选字段就是 undefined）。
 */
function buildMultipartBody(fields, boundary, files) {
  const chunks = [];
  for (const [k, v] of Object.entries(fields || {})) {
    if (v === undefined || v === null) continue;
    const val = typeof v === 'object' ? JSON.stringify(v) : String(v);
    chunks.push(Buffer.from(`--${boundary}\r\ncontent-disposition: form-data; name="${k}"\r\n\r\n${val}\r\n`, 'utf8'));
  }
  for (const f of files) {
    chunks.push(
      Buffer.from(
        `--${boundary}\r\ncontent-disposition: form-data; name="${f.field}"; filename="${f.filename}"\r\n` +
          `content-type: ${f.mime}\r\n\r\n`,
        'utf8',
      ),
    );
    chunks.push(f.bytes);
    chunks.push(Buffer.from('\r\n', 'utf8'));
  }
  chunks.push(Buffer.from(`--${boundary}--\r\n`, 'utf8'));
  return Buffer.concat(chunks);
}

/** multipart 的 boundary（只要每次不同、且不出现在内容里就够；这里用随机串）。 */
function newBoundary() {
  return `----dshImage${Date.now().toString(36)}${Math.random().toString(36).slice(2, 10)}`;
}

// ─────────────────────────────────────────────────────────── 干跑（--print-request）

/**
 * 打印"将要发的请求"。**格式是稳定的**（测试会 grep 它），并且与
 * `make-video.mjs` 的干跑用**同一套词**（`submit` / `poll` / `body`），
 * 读两个脚本时不用换脑子：
 *
 * ```
 * [print-request] provider openai (OpenAI)
 * [print-request] submit POST https://api.openai.com/v1/images/edits
 * [print-request] multipart true
 * [print-request] multipart-fields image
 * [print-request] async false
 * [print-request] headers {}
 * [print-request] body {"model":"gpt-image-1",...}
 * [print-request] note OpenAI 形状：...
 * ```
 *
 * `body` 在 multipart 时是**表单字段**（文件本身不打印 —— 二进制没法看）。
 * `poll` 行只在异步（万相）时出现；`这家没接图像` 时打印 `image=unsupported`。
 * **不发任何网络请求**。
 */
function printRequest(provider, label, plan) {
  const out = process.stdout;
  out.write(`[print-request] provider ${provider} (${label})\n`);
  out.write(`[print-request] submit ${plan.method} ${plan.endpoint}\n`);
  out.write(`[print-request] multipart ${plan.multipart ? 'true' : 'false'}\n`);
  if (plan.multipart) {
    out.write(`[print-request] multipart-fields ${(plan.multipart.files || []).map((f) => f.field).join(',')}\n`);
  }
  out.write(`[print-request] async ${plan.poll ? 'true' : 'false'}\n`);
  if (plan.poll) out.write(`[print-request] poll ${plan.poll.method || 'GET'} ${plan.poll.url('TASKID')}\n`);
  out.write(`[print-request] headers ${JSON.stringify(plan.headers || {})}\n`);
  out.write(`[print-request] body ${JSON.stringify(plan.body)}\n`);
  out.write(`[print-request] note ${plan.log || ''}\n`);
}

// ─────────────────────────────────────────────────────────── 结果解析 / 异步轮询

/**
 * 从响应里取图片结果 —— **按厂家宽容**（形状表给什么取什么，多几种写法都认）。
 *
 * 顺序（与改造前一致的那几条放前面，别家的往后加）：
 *   1. 万相（`plan.poll` 非空）：`dashscopeImageResult` → `output.results[0].url|b64_image`；
 *   2. `data[0].url|b64_json`（Agnes / OpenAI 兼容 / OpenAI 的 /images/edits）；
 *   3. `images[0]`；
 *   4. MiniMax：`data.image_urls[0]`（字符串数组；也认 `[{url}]` 与顶层 `image_urls`）；
 *   5. 顶层直接给 base64（少数实现的写法）。
 *
 * @returns {object|null} `{url}` / `{b64_json}` / null（找不到）
 */
function pickImageItem(json, plan) {
  if (!json || typeof json !== 'object') return null;

  if (plan && plan.poll) {
    const dash = dashscopeImageResult(json);
    if (dash && (dash.url || dash.b64)) return { url: dash.url, b64_json: dash.b64 };
  }

  let item = Array.isArray(json.data) ? json.data[0] : null;
  if (typeof item === 'string') item = { url: item }; // 少数实现直接给 URL 字符串
  if (!item && Array.isArray(json.images)) item = json.images[0];

  const urls = (json.data && Array.isArray(json.data.image_urls) && json.data.image_urls) ||
    (Array.isArray(json.image_urls) ? json.image_urls : null);
  if (!item && urls && urls.length > 0) {
    const first = urls[0];
    if (typeof first === 'string') item = { url: first };
    else if (first && (first.url || first.image_url)) item = { url: first.url || first.image_url };
  }

  if (!item) {
    for (const k of ['b64_json', 'image', 'base64', 'data']) {
      if (typeof json[k] === 'string' && json[k].length > 100) {
        item = { b64_json: json[k] };
        break;
      }
    }
  }
  return item || null;
}

/**
 * 异步任务轮询（万相 DashScope）：创建任务之后，拿 `output.task_status` 等到 `SUCCEEDED`。
 *
 * 间隔 2 秒、总超时 5 分钟；**每次轮询都往 stderr 打一行进度**（用户在界面上要能看到
 * 它在等，而不是以为卡死了）。`FAILED` / `CANCELED` / `UNKNOWN` 直接报错并带上
 * `output.message`。查询用**创建任务的那把 Key**（任务归属那把 Key，换了查不到）。
 *
 * @returns {Promise<object>} 最终那次轮询的响应 JSON（结果从它里面取）
 */
async function pollTask({ plan, taskId, key, label, timeoutMs }) {
  const intervalMs = 2000;
  const totalMs = 5 * 60 * 1000;
  const startedAt = Date.now();
  const url = plan.poll.url(taskId);
  const method = plan.poll.method || 'GET';
  const headers = { ...(plan.poll.headers || {}), accept: 'application/json' };
  if (key) headers.authorization = `Bearer ${key}`;
  let round = 0;

  for (;;) {
    if (Date.now() - startedAt >= totalMs) {
      fail(
        `「${label}」任务 ${taskId} 超过 5 分钟还没完成（已查 ${round} 次），先放弃。` +
          '可以稍后用同一个任务 id 再查一次。',
        1,
      );
    }
    await sleep(intervalMs);
    round += 1;
    const elapsed = Math.round((Date.now() - startedAt) / 1000);

    let res;
    try {
      res = await httpJson(method, url, {
        headers,
        jsonBody: plan.poll.bodyOf ? plan.poll.bodyOf(taskId) : undefined,
        timeoutMs,
      });
    } catch (e) {
      process.stderr.write(`[agnes-image] 第 ${round} 次查询失败（${e.message}；已等 ${elapsed}s），继续等…\n`);
      continue;
    }
    if (res.status < 200 || res.status >= 300) {
      process.stderr.write(`[agnes-image] 第 ${round} 次查询 HTTP ${res.status}（已等 ${elapsed}s），继续等…\n`);
      continue;
    }
    let j = null;
    try {
      j = JSON.parse(res.text);
    } catch {
      process.stderr.write(`[agnes-image] 第 ${round} 次查询返回的不是 JSON（已等 ${elapsed}s），继续等…\n`);
      continue;
    }
    const out = j && j.output;
    const st = String((out && out.task_status) || (j && j.task_status) || '').toUpperCase();
    process.stderr.write(`[agnes-image] 第 ${round} 次查询：task_status=${st || '(空)'}（已等 ${elapsed}s）\n`);
    if (st === 'SUCCEEDED') return j;
    if (['FAILED', 'CANCELED', 'CANCELLED', 'UNKNOWN'].includes(st)) {
      fail(
        `「${label}」任务 ${taskId} ${st}：${head((out && out.message) || (j && j.message) || res.text, 300)}`,
        1,
      );
    }
    // PENDING / RUNNING / 空 → 继续等
  }
}

// ─────────────────────────────────────────────────────────── 主流程

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.prompt) usageFail('缺少提示词（第一个参数）');
  if (args.prompt.trim() === '') usageFail('提示词不能是空白');
  if (!args.output && !args.printRequest) usageFail('缺少输出文件路径（第二个参数）');

  // ── 厂家：显式 `--provider` 优先，否则从模型名 + 端点猜（**默认值不硬编码 agnes**）。
  //    baseUrl 是"用户填的那个"（App 注入 AGNES_BASE_URL）；没填就交给形状表用厂家默认端点。
  const baseUrl = (process.env.AGNES_BASE_URL || '').trim();
  if (args.provider && !VENDOR_IDS.includes(args.provider)) {
    // 认不出的 id（例如用户自己加的自定义厂家）→ 不当成错误，交给 providerOf 按
    // 模型名 / 端点猜；猜不出就是 unknown（按 OpenAI 兼容试）。
    process.stderr.write(
      `[agnes-image] 提示：--provider ${args.provider} 不在内置厂家表（${VENDOR_IDS.join(' / ')}）里，` +
        '按模型名与端点猜，猜不出就按 OpenAI 兼容形状发。\n',
    );
  }
  const provider = args.provider || providerOf({ model: args.model, baseUrl });
  const label = vendorLabel(provider);

  // 尺寸：档位式（1k→1K）原样或规范化；也允许 1024x768 这类精确尺寸。
  // ⚠ 只有 Agnes 用"档位"，别家的尺寸写法由「设置 → 图像模型」那条决定
  //   （万相是 `1024*1024`、OpenAI 是像素…），所以对别家**不拦**，原样交给形状表。
  if (SIZES.includes(args.size.toUpperCase())) {
    args.size = args.size.toUpperCase();
  } else if (/^\d+x\d+$/i.test(args.size)) {
    process.stderr.write(`[agnes-image] 提示：${args.size} 是历史精确尺寸写法，官方可能把不支持的尺寸标准化成最接近的档位\n`);
  } else if (provider === 'agnes') {
    usageFail(`--size 只推荐 ${SIZES.join(' / ')}（也可用 1024x768 这类精确尺寸），收到 ${JSON.stringify(args.size)}`);
  } else {
    process.stderr.write(`[agnes-image] 提示：--size ${JSON.stringify(args.size)} 不是 Agnes 的档位写法，按「${label}」的形状原样发。\n`);
  }

  if (args.ratio !== null && !RATIOS.includes(args.ratio)) {
    if (provider === 'agnes') {
      usageFail(`--ratio 不支持 ${JSON.stringify(args.ratio)}；官方支持：${RATIOS.join(' / ')}`);
    }
    process.stderr.write(
      `[agnes-image] 提示：--ratio ${JSON.stringify(args.ratio)} 不在 Agnes 的档位表里，按「${label}」的形状原样发（是否支持由上游决定）。\n`,
    );
  }

  const refs = args.refs.map(toImageRef);

  // ── 形状：端点 / 请求体 / 结果取法 / 轮询，全部问共享形状表要。
  if (missingBaseUrl(provider, baseUrl)) {
    fail(
      `「${label}」这家要自己填端点（base URL），现在没填，不知道该往哪儿发。` +
        '请在「设置 → 图像模型」里补上端点。',
      2,
    );
  }
  const plan = imagePlan(provider, {
    model: args.model,
    prompt: args.prompt,
    size: args.size,
    ratio: args.ratio,
    negativePrompt: args.negativePrompt,
    refs,
    baseUrl,
  });
  if (!plan) {
    if (args.printRequest) process.stdout.write('[print-request] image=unsupported\n');
    fail(`「${label}」这家在本 App 里没有接图像生成。`, 2);
  }

  // 干跑：只打印形状，不发网络请求、不需要 Key，正常退出。
  if (args.printRequest) {
    printRequest(provider, label, plan);
    process.exit(0);
  }

  // Key：没有就如实报错，绝不假装成功。**按实际厂家说清去哪配**。
  // 支持**多把**（`AGNES_API_KEYS`，逗号/空白/换行分隔；`AGNES_API_KEY` 仍然认）：
  // 限流按**账号**算，所以只有**不同账号**的多把 Key 才能真正加容量。
  // ⚠ 变量名对所有厂家都是 AGNES_*（App 侧"借名"注入，值是那家的 Key）——不要改名。
  const apiKeys = parseApiKeys();
  const registerUrl = (process.env.AGNES_REGISTER_URL || DEFAULT_REGISTER_URL).trim();
  const rotator = apiKeys.length > 0 ? new KeyRotator(apiKeys) : null;

  if (!rotator) {
    fail(
      `没有配置「${label}」的 API Key，无法生成图片。\n` +
        `       请在 App 的「设置 → 云端大模型」里按厂家 id「${provider}」配好这一家的 Key` +
        '（App 会以 AGNES_API_KEY / AGNES_API_KEYS 环境变量注入；变量名是历史遗留，值是这一家的 Key）。\n' +
        (provider === 'agnes'
          ? `       还没有 Key 的话，可以到 ${registerUrl} 免费注册（官方口径：所有输出档位与输入参考图当前均免费）。\n`
          : ''),
      2,
    );
  }

  const timeoutMs = Number(process.env.AGNES_IMAGE_TIMEOUT_MS || DEFAULT_TIMEOUT_MS);
  const planHeaders = { ...(plan.headers || {}), accept: 'application/json' };

  process.stderr.write(
    `[agnes-image] ${plan.method} ${plan.endpoint} provider=${provider}(${label}) model=${args.model} ` +
      `size=${args.size} ratio=${args.ratio || '(服务端默认)'} refs=${refs.length} ` +
      `方式=${plan.multipart ? 'multipart' : 'json'}${plan.poll ? '+轮询' : ''} 超时=${Math.round(timeoutMs / 1000)}s\n`,
  );
  if (plan.log) process.stderr.write(`[agnes-image] ${plan.log}\n`);

  // multipart（OpenAI 带参考图 → /images/edits）：自己拼 Buffer，字段名取形状表给的。
  let rawBody;
  let contentType;
  if (plan.multipart) {
    const files = [];
    for (const f of plan.multipart.files || []) {
      const got = await refBytes(f.ref);
      files.push({ field: f.field, filename: refFilename(f.ref), mime: got.mime, bytes: got.bytes });
    }
    const boundary = newBoundary();
    rawBody = buildMultipartBody(plan.multipart.fields, boundary, files);
    contentType = `multipart/form-data; boundary=${boundary}`;
  }

  // 云端出图：429 就退避重试；同一把 Key 连续被限流就换下一把（生图没有"任务归属"
  // 问题 —— 一次请求一次结果，所以这里可以放心换 Key）。
  let resp;
  let usedKey = null; // 轮询必须用**创建任务的那把 Key**，所以要把实际用的记下来
  {
    try {
      resp = await callWithRateLimitRetry(
        async (key) => {
          const res = await httpJson(plan.method, plan.endpoint, {
            headers: { ...planHeaders, authorization: `Bearer ${key}` },
            jsonBody: plan.multipart ? undefined : plan.body,
            rawBody,
            contentType,
            timeoutMs,
          });
          if (res.status === 429) {
            throw new RateLimitedError(
              `HTTP 429；响应体前 200 字符：${head(res.text)}`,
              retryAfterMs(res.headers),
            );
          }
          // 出图**重复是安全的**（最多多花一次额度）→ 5xx 也算可重试。
          // 依据：桌面端影视工具插件的代理里写着「Agnes 会间歇性返回 5xx
          // （请求上游失败，请稍后重试）」，那边对生图给了 3 次重试。
          // ⚠️ 这一条**不能**照搬到视频提交上（见 make-video.mjs 的注释）。
          if (res.status >= 500) {
            throw new TransientError(
              `HTTP ${res.status}（服务端临时故障）；响应体前 200 字符：${head(res.text)}`,
            );
          }
          usedKey = key;
          return res;
        },
        { rotator, log: (m) => process.stderr.write(`[agnes-image] ${m}\n`) },
      );
    } catch (e) {
      fail(`请求「${label}」失败：${e.message}`, 1);
    }
  }

  if (resp.status < 200 || resp.status >= 300) {
    fail(
      `「${label}」返回 HTTP ${resp.status}` +
        `${resp.status === 401 || resp.status === 403 ? '（大概率是 API Key 无效或没开通）' : ''}；` +
        `响应体前 200 字符：${head(resp.text)}`,
      1,
    );
  }

  let json;
  try {
    json = JSON.parse(resp.text);
  } catch (e) {
    fail(`「${label}」返回的不是合法 JSON：${e.message}；响应体前 200 字符：${head(resp.text)}`, 1);
  }

  // 异步（万相）：先创建任务，再轮询到 SUCCEEDED，最后从**轮询响应**里取结果。
  if (plan.poll) {
    const taskId = String((json && json.output && json.output.task_id) || '').trim();
    if (!taskId) {
      fail(
        `「${label}」没有返回任务 id（output.task_id），拿不到结果；响应体前 300 字符：${head(resp.text, 300)}`,
        1,
      );
    }
    process.stderr.write(
      `[agnes-image] 「${label}」任务已创建：task_id=${taskId}，开始轮询（每 2 秒一次，最多等 5 分钟）…\n`,
    );
    json = await pollTask({ plan, taskId, key: usedKey, label, timeoutMs });
  }

  const item = pickImageItem(json, plan);
  if (!item) {
    fail(
      `「${label}」响应里找不到图片字段（data[0] / images[0] / data.image_urls[0] / b64_json）：` +
        `${head(JSON.stringify(json), 300)}`,
      1,
    );
  }

  const dest = resolve(args.output);
  mkdirSync(dirname(dest), { recursive: true });

  let bytes;
  // 有些实现把图片**内联**给出来（`b64_json`，或 url 字段里就是一个 data URI）——
  // 这两种都不该走下载（`data:` 不是能请求的协议），直接解码落盘。
  const inline = item.b64_json
    ? String(item.b64_json)
    : (/^data:/i.test(String(item.url || '')) ? String(item.url) : null);
  if (item.url && inline === null) {
    try {
      bytes = await downloadToFile(item.url, dest, { timeoutMs: DOWNLOAD_TIMEOUT_MS });
    } catch (e) {
      fail(e.message, 1);
    }
  } else if (inline !== null) {
    // 少数情况下服务端就是给 base64（例如 OpenAI gpt-image-1 默认就回 b64_json）
    try {
      const payload = inline.includes('base64,') ? inline.slice(inline.indexOf('base64,') + 7) : inline;
      writeFileSync(dest, Buffer.from(payload, 'base64'));
      bytes = statSync(dest).size;
    } catch (e) {
      fail(`写文件失败（${dest}）：${e.message}`, 1);
    }
  } else {
    fail(`「${label}」响应里既没有 url 也没有 b64_json：${head(JSON.stringify(json), 300)}`, 1);
  }

  // ⚠ 这一行是 Dart 侧识别的成功标记，格式不要改
  process.stdout.write(`[agnes-image] ok file=${dest} bytes=${bytes} model=${args.model}\n`);
}

main().catch((e) => fail(`未预期的错误：${(e && e.stack) || e}`, 1));
