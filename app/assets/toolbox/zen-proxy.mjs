/**
 * zen-proxy.mjs —— 本地 OpenAI 兼容代理，转发到 **OpenCode Zen 的匿名免费通道**。
 *
 * ## ⚠️ 先说清楚这是什么（不要含糊）
 *
 * OpenCode Zen 的免费层**只允许它自家的 CLI 用**：自 2026-09-16 起，上游对
 * 非官方会话形状直接返回 `403 FreeTierError: free tier can only be used from within OpenCode`。
 * 这个代理做的事情，是**把请求伪装成官方 CLI 的样子**去通过那道门禁 ——
 * 也就是说：它绕过的是上游**有意设置**的访问限制，不是"用了一个公开的免费接口"。
 *
 * 因此在本 App 里的定位是**实验性、默认关闭、用户显式开启**的能力，界面上必须如实标注。
 * 也**刻意不做**下面这些（那是真正的滥用放大器，本项目不实现）：
 *   * 不做 IP 池 / 出口轮换来分摊按出口 IP 的配额（手机端也没有这个基础设施）；
 *   * 不做重试轰炸：429 时**如实报出来**让用户决定。
 *     （对比 `FishBottle7/opencode2dsh`：它用的是**有界退避** —— 8 次、~1s→20s、
 *      单步最坏约 90s —— 并静默熬过去。那是它的取舍，**不是滥用**；
 *      我们选了更透明的做法。要不要补一层小退避，见 docs/免费模型-方案.md。）
 *   * 不抓取、不分发任何账号或凭据（这条通道本来就是匿名的，全程没有 Key）。
 *
 * ## 门禁的实际形状（照 `FishBottle7/opencode2dsh` 的实测记录实现）
 *
 * 目前上游**只看两件事**（原文：descriptions、parameters 和每个 header 都不检查）：
 *   1. `x-opencode-session` 必须是 `ses_` + 12 位小写 hex + 14 位 Base62 的形状；
 *   2. 请求体必须 `stream: true`，且 `tools` 里有函数工具名为 **`bash`** 与 **`read`**。
 * 头部（User-Agent / x-opencode-client / 关联 id）现在不检查了，但仍然照发 ——
 * 保持"官方 CLI 形状"，也让上游将来收紧时行为更接近有意为之。
 *
 * ⚠️ 上游随时可能再收紧（历史上已经收紧过两次）。所以：
 *   * 失败时**必须如实报出来**（让 App 能说"这个通道现在不可用"），绝不假装成功。
 *
 * ## 用法
 *
 *   node zen-proxy.mjs --port 0 [--state <dir>] [--upstream https://opencode.ai/zen]
 *                      [--ttl-hours 12] [--log-requests]
 *
 * 就绪时在 **stdout** 打一行（Dart 侧按这一行回填端口，别改格式）：
 *   `listening on http://127.0.0.1:<port>`
 *
 * 路由：
 *   GET  /healthz              → {"ok":true,"models":<n>,"lastError":<string|null>}
 *   GET  /v1/models            → OpenAI 形状，**只列免费模型**
 *   POST /v1/chat/completions  → 注入门禁形状 → 转发 → 把 SSE 原样流回来
 *
 * 只用 node 内置模块（本机运行时没有 npm 依赖）。
 */

import { createHash } from 'node:crypto';
import http from 'node:http';
import https from 'node:https';
import { createServer } from 'node:http';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const DEFAULT_UPSTREAM = 'https://opencode.ai/zen';
const DEFAULT_TTL_HOURS = 12;

/**
 * 已在社区实测"匿名可用"的免费模型（离线兜底名单）。
 * 来源：opencode2dsh 的 `staticFreeModels`（带各自验证日期）。
 * ⚠️ 上游会上下架模型，所以这份名单只是"断网/接口失败时还能给出点东西"，
 *    真正的新鲜列表走 `GET /v1/models`。
 */
const STATIC_FREE_MODELS = [
  'big-pickle', // 2026-08-28 实测匿名可用
  'mimo-v2.6-flash-free', // 2026-10-03 实测（mimo-v2.5-free 的后继）
  'mimo-v2.5-free', // 2026-08-28 实测（models.dev 已标弃用，但仍能应答）
  'ling-3.0-flash-fin-free', // 2026-09-01 实测
  'nemotron-3.5-lightning-free', // 2026-09-01 实测
  'nemotron-3-ultra-free', // 2026-09-01 实测
];

/** 免费判定：名字里带 `free`，或者在我们已实测的静态名单里。 */
function isFree(model) {
  const m = String(model || '').toLowerCase();
  return m.includes('free') || STATIC_FREE_MODELS.includes(m);
}

// ─────────────────────────────────────────────────────────── 参数

function parseArgs(argv) {
  const out = {
    port: 0,
    state: '',
    upstream: DEFAULT_UPSTREAM,
    ttlHours: DEFAULT_TTL_HOURS,
    logRequests: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    const need = () => {
      const v = argv[++i];
      if (v === undefined) {
        process.stderr.write('zen-proxy: 选项 ' + a + ' 后面缺参数\n');
        process.exit(2);
      }
      return v;
    };
    if (a === '--port') out.port = Number(need());
    else if (a === '--state') out.state = need();
    else if (a === '--upstream') out.upstream = need();
    else if (a === '--ttl-hours') out.ttlHours = Number(need());
    else if (a === '--log-requests') out.logRequests = true;
    else if (a === '--help') {
      process.stdout.write('用法: node zen-proxy.mjs --port 0 [--state <dir>] [--upstream <url>]\n');
      process.exit(0);
    } else {
      process.stderr.write('zen-proxy: 不认识的选项 ' + a + '\n');
      process.exit(2);
    }
  }
  if (!Number.isInteger(out.port) || out.port < 0 || out.port > 65535) {
    process.stderr.write('zen-proxy: --port 需要 0-65535\n');
    process.exit(2);
  }
  return out;
}

// ─────────────────────────────────────────────────────────── 伪装成官方 CLI

const BASE62 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
const CANONICAL_SESSION = /^ses_[0-9a-f]{12}[0-9A-Za-z]{14}$/;

function base62Fixed(value, width) {
  let n = value;
  const out = new Array(width);
  const base = 62n;
  for (let i = width - 1; i >= 0; i -= 1) {
    out[i] = BASE62.charAt(Number(n % base));
    n /= base;
  }
  return out.join('');
}

/**
 * 把任意种子**确定性地**换算成官方会话 id 的形状。
 * 同一个会话拿到同一个 id（保持上游的 prompt cache 亲和性）。
 */
function canonicalSessionId(seed) {
  const s = String(seed || '');
  if (CANONICAL_SESSION.test(s)) return s;
  const sum = createHash('sha256').update('ses\u0000' + s).digest();
  const timePart = sum.subarray(0, 6).toString('hex');
  const randomPart = base62Fixed(BigInt('0x' + sum.subarray(6, 16).toString('hex')), 14);
  return `ses_${timePart}${randomPart}`;
}

function requestId(seed) {
  return 'req_' + createHash('sha256').update('req\u0000' + seed).digest('hex').slice(0, 20);
}

function projectId(seed) {
  return 'prj_' + createHash('sha256').update('prj\u0000' + seed).digest('hex').slice(0, 20);
}

/** 官方 CLI 形状的 UA（版本号与平台串按实测值；上游现在不检查，但保持同形）。 */
function cliUserAgent() {
  return `opencode/1.18.31 (${process.platform} ${process.arch}; node${process.versions.node})`;
}

function disguiseHeaders(session) {
  return {
    // ⚠️ **匿名通道的凭据就是字面量 `public`**（`FishBottle7/opencode2dsh` 的
    //    README 原文："the anonymous lane's key is the literal string `public`"）。
    //    这里**不是**在替用户保管什么 Key，所以「不用写 Key」是事实而不是宣传：
    //    2026-10-11 实测 `GET /v1/models` 带与不带这个头都返回 200，但官方实现
    //    一律带上它 —— 形状与官方一致，上游将来收紧时也更接近"有意为之"。
    //    ⚠️ 上游转发时**不要**把 DSH 传来的 `Authorization: Bearer local-zen` 透传，
    //    那个占位值不是这条通道认的凭据（所以这里是覆盖，不是透传）。
    authorization: 'Bearer public',
    'user-agent': cliUserAgent(),
    'x-opencode-client': 'cli',
    'x-opencode-session': session,
    'x-session-affinity': session,
    'X-Session-Id': session,
    'x-opencode-request': requestId(session),
    'x-opencode-project': projectId(session),
    accept: 'application/json',
  };
}

/** 门禁要求的两个"占位"工具：只要**存在**就行（描述与参数都不检查）。 */
const GATE_TOOL_NAMES = ['bash', 'read'];

function gateTool(name) {
  return {
    type: 'function',
    function: {
      name,
      description: 'Reserved for the host runtime; do not call it.',
      parameters: { type: 'object', properties: {} },
    },
  };
}

/**
 * 把请求体改造成能过门禁的形状：
 *   * 补上缺的 `bash` / `read`（**只在缺的时候补** —— DSH 自己的会话本来就带
 *     bash/read 工具，那种情况下这里什么都不做，请求保持原样）；
 *   * 强制 `stream: true`（门禁要求）。
 * 返回 { body, injected }，`injected` 是这次补进去的名字（用于回程过滤）。
 */
function applyGate(body) {
  const out = { ...body, stream: true };
  const tools = Array.isArray(body.tools) ? body.tools.slice() : [];
  const names = new Set(
    tools
      .map((t) => (t && typeof t === 'object' && t.type === 'function' ? t.function?.name : undefined))
      .filter(Boolean),
  );
  const injected = GATE_TOOL_NAMES.filter((n) => !names.has(n));
  if (injected.length > 0) {
    for (const n of injected) tools.push(gateTool(n));
    out.tools = tools;
  }
  return { body: out, injected };
}

// ─────────────────────────────────────────────────────────── 上游请求

function upstreamUrl(base, path) {
  return String(base).replace(/\/+$/, '') + path;
}

/** 发一个上游请求，返回 { status, headers, body(Buffer) }。 */
function upstreamRequest({ method, url, headers, body, timeoutMs = 300000 }) {
  return new Promise((resolvePromise, rejectPromise) => {
    let settled = false;
    const done = (fn) => (v) => {
      if (settled) return;
      settled = true;
      fn(v);
    };
    const ok = done(resolvePromise);
    const bad = done(rejectPromise);

    const u = new URL(url);
    const transport = u.protocol === 'https:' ? https : http;

    const req = transport.request(
      u,
      { method, headers, timeout: timeoutMs },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () =>
          ok({ status: res.statusCode || 0, headers: res.headers, body: Buffer.concat(chunks) }),
        );
        res.on('error', bad);
      },
    );
    req.on('timeout', () => {
      req.destroy(new Error('上游超时'));
    });
    req.on('error', bad);
    if (body) req.write(body);
    req.end();
  });
}

// ─────────────────────────────────────────────────────────── 模型列表（带缓存）

function cachePath(state) {
  return state ? join(state, 'zen-models.json') : '';
}

function readCache(state, ttlHours) {
  try {
    const p = cachePath(state);
    if (!p || !existsSync(p)) return null;
    const raw = JSON.parse(readFileSync(p, 'utf8'));
    const ageMs = Date.now() - Number(raw.at || 0);
    if (!Array.isArray(raw.models) || raw.models.length === 0) return null;
    if (ageMs > ttlHours * 3600 * 1000) return null;
    return raw.models;
  } catch {
    return null;
  }
}

function writeCache(state, models) {
  try {
    const p = cachePath(state);
    if (!p) return;
    mkdirSync(state, { recursive: true });
    writeFileSync(p, JSON.stringify({ at: Date.now(), models }), 'utf8');
  } catch {
    /* 缓存写不进去不影响使用 */
  }
}

// ─────────────────────────────────────────────────────────── 主流程

async function main() {
  const args = parseArgs(process.argv.slice(2));
  let lastError = null;
  let modelCache = null;

  /**
   * 取"免费模型"列表：优先上游实时列表（过滤出免费的），失败则用缓存，
   * 再失败用静态名单。**任何一步失败都不会让代理起不来** —— 起不来比"列表旧一点"糟得多。
   */
  async function listFreeModels() {
    if (modelCache) return modelCache;
    const cached = readCache(args.state, args.ttlHours);
    if (cached) {
      modelCache = cached;
      return cached;
    }
    try {
      const session = canonicalSessionId('models');
      const r = await upstreamRequest({
        method: 'GET',
        url: upstreamUrl(args.upstream, '/v1/models'),
        headers: disguiseHeaders(session),
        timeoutMs: 20000,
      });
      if (r.status >= 200 && r.status < 300) {
        const json = JSON.parse(r.body.toString('utf8'));
        const ids = (Array.isArray(json?.data) ? json.data : [])
          .map((m) => (m && typeof m.id === 'string' ? m.id : null))
          .filter(Boolean)
          .filter(isFree);
        // 静态名单里已被上游下架的不要硬塞进列表（避免给用户一个选了就报错的模型）
        const live = new Set(ids);
        const merged = [...ids];
        for (const m of STATIC_FREE_MODELS) {
          if (!live.has(m) && ids.length === 0) merged.push(m); // 只在实时列表为空时才兜底
        }
        if (merged.length > 0) {
          modelCache = merged;
          writeCache(args.state, merged);
          return merged;
        }
      }
      lastError = `取模型列表失败：HTTP ${r.status}`;
    } catch (e) {
      lastError = `取模型列表失败：${e.message}`;
    }
    modelCache = STATIC_FREE_MODELS.slice();
    return modelCache;
  }

  /** 把上游的错误转成 OpenAI 形状，并附上**能看懂**的中文说明。 */
  function errorBody(status, text) {
    let hint = '';
    if (status === 403) {
      hint = '（上游拒绝了：这个通道只对官方 CLI 开放，可能又收紧了 —— 这不是"你没配 Key"，这条通道本来就不用 Key。'
          + '可以等它恢复，或者先把它关掉、用别的模型。）';
    } else if (status === 429) {
      hint = '（被限流了：免费通道按出口 IP 限流，等一会儿再试。）';
    } else if (status === 401) {
      hint = '（上游要求鉴权：匿名通道可能已经关闭。）';
    }
    let detail = '';
    try {
      const j = JSON.parse(text);
      detail = String(j?.error?.message || j?.error || j?.message || '').slice(0, 300);
    } catch {
      detail = String(text || '').slice(0, 300);
    }
    return JSON.stringify({
      error: {
        message: `社区免费通道返回 HTTP ${status}${hint}${detail ? ` 上游原话：${detail}` : ''}`,
        type: 'upstream_error',
        code: status,
      },
    });
  }

  const server = createServer(async (req, res) => {
    const started = Date.now();
    const url = new URL(req.url || '/', 'http://127.0.0.1');
    const path = url.pathname;

    // ── 健康检查：给 App 显示状态用（是否在跑、模型数、上次错误）
    if (path === '/healthz') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({
        ok: true,
        models: (modelCache || []).length,
        upstream: args.upstream,
        lastError,
      }));
      return;
    }

    // ── 模型列表
    if (path === '/v1/models' && req.method === 'GET') {
      const models = await listFreeModels();
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({
        object: 'list',
        data: models.map((id) => ({ id, object: 'model', owned_by: 'opencode-zen' })),
      }));
      if (args.logRequests) process.stderr.write(`[zen-proxy] GET /v1/models → ${models.length} 个\n`);
      return;
    }

    // ── 对话（流式转发）
    if (path === '/v1/chat/completions' && req.method === 'POST') {
      const chunks = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', async () => {
        let payload;
        try {
          payload = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        } catch (e) {
          res.writeHead(400, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: { message: `请求体不是合法 JSON：${e.message}` } }));
          return;
        }

        // 会话种子：优先用调用方给的（这样同一会话 id 稳定），否则按第一条用户消息派生
        const clientSeed =
          String(req.headers['x-zen-seed'] || '').trim() ||
          (() => {
            const msgs = Array.isArray(payload.messages) ? payload.messages : [];
            const first = msgs.find((m) => m && m.role === 'user');
            const text = typeof first?.content === 'string'
              ? first.content
              : JSON.stringify(first?.content ?? '');
            return text || 'anonymous';
          })();
        const session = canonicalSessionId(clientSeed);

        const { body } = applyGate(payload);
        const headers = {
          ...disguiseHeaders(session),
          'content-type': 'application/json',
          // 上游可能按 Accept 分流，明确要 SSE
          accept: body.stream ? 'text/event-stream' : 'application/json',
        };

        try {
          const r = await upstreamRequest({
            method: 'POST',
            url: upstreamUrl(args.upstream, '/v1/chat/completions'),
            headers,
            body: Buffer.from(JSON.stringify(body), 'utf8'),
          });
          if (r.status < 200 || r.status >= 300) {
            const text = r.body.toString('utf8');
            lastError = `HTTP ${r.status}`;
            process.stderr.write(`[zen-proxy] 上游 HTTP ${r.status}：${text.slice(0, 200)}\n`);
            res.writeHead(r.status, { 'content-type': 'application/json' });
            res.end(errorBody(r.status, text));
            return;
          }
          lastError = null;
          // 原样把上游的流回传（含 SSE 头）
          res.writeHead(200, {
            'content-type': r.headers['content-type'] || 'text/event-stream',
            'cache-control': 'no-cache',
            connection: 'keep-alive',
            'transfer-encoding': 'chunked',
          });
          res.end(r.body);
          if (args.logRequests) {
            process.stderr.write(
              `[zen-proxy] POST chat model=${payload.model} → 200 (${r.body.length}B, ${Date.now() - started}ms)\n`,
            );
          }
        } catch (e) {
          lastError = e.message;
          process.stderr.write(`[zen-proxy] 转发失败：${e.message}\n`);
          res.writeHead(502, { 'content-type': 'application/json' });
          res.end(JSON.stringify({
            error: { message: `连接社区免费通道失败：${e.message}` },
          }));
        }
      });
      return;
    }

    res.writeHead(404, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: { message: `没有这个路径：${path}` } }));
  });

  server.listen(args.port, '127.0.0.1', () => {
    const port = server.address().port;
    // ⚠️ Dart 侧按这一行回填端口（系统挑的 0 端口只能这样告诉它）。格式不要改。
    process.stdout.write(`listening on http://127.0.0.1:${port}\n`);
    process.stderr.write(`[zen-proxy] 已就绪：上游 ${args.upstream}，仅实验性使用（见文件顶部说明）\n`);
  });

  // 预热模型列表（不阻塞就绪；失败也不影响）
  listFreeModels().catch(() => {});
}

main().catch((e) => {
  process.stderr.write(`zen-proxy: 未预期错误：${(e && e.stack) || e}\n`);
  process.exit(1);
});
