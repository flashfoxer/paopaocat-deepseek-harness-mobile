/**
 * dsh-web-search-anysearch —— 把 **AnySearch** 接成 DSH 的 `ctx.web` 搜索后端。
 *
 * ## 为什么要有它（而不是只用 MCP）
 *
 * 手机上原本就挂了 `dsh-tool-web`（模型看到的 `web_search` / `web_fetch`）+ 一个
 * 后端 `dsh-web-search-deepseek` —— **那个后端要 `DEEPSEEK_API_KEY`**，
 * 没配 Key 的会话一搜就报"没有可用的搜索后端"。
 *
 * 我们先用 MCP（`data/anysearch.dart`）给会话补了一条**免 Key** 的搜索通道；
 * 这个包是**更原生的那条路**：换掉/补上 `ctx.web` 的后端，于是模型用的是**同一个
 * `web_search`**（同样的提示词引导、同样的 `maxResults` 截断、同样的结构化错误），
 * 而不是多出一个 MCP 工具。
 *
 * ## 契约（照 `dsh-web-search-deepseek` 抄的形状，不是猜的）
 *
 * `ctx.web.registerSearchProvider(provider)`，provider 必须有：
 *   * `id`：稳定字符串（同类里唯一）—— 这里用 `anysearch`；
 *   * `available()`：**便宜的本地判断**（不许联网）—— 匿名层永远可用，所以恒 `true`；
 *   * `search(request, signal)` → `{ sources: [{url, title?, snippet?, publishedAt?}], truncated }`。
 *
 * AnySearch 的 REST：`POST {baseURL}/v1/search`，body `{query, max_results}`，
 * 可选 `Authorization: Bearer as_sk_…`（**不带就是匿名**，官方支持）。
 * 响应：`{code:0, data:{results:[{title,url,snippet,content}], metadata:{total_results,…}}}`
 * —— 本机实测（2026-10-15）：匿名 200 / 1.8 s，中文查询也通。
 */
import z from '@deepseek-ai/schemastery';
import { credentialRef } from '@deepseek-ai/dsh-credentials';
import { launchEnvironmentOf } from '@deepseek-ai/dsh-launch-environment';
import { WebError } from '@deepseek-ai/dsh-web';

/** 注册到 `ctx.web` 的稳定 id（与 `searchProvider:` 里写的一致）。 */
const ANYSEARCH_PROVIDER_ID = 'anysearch';

/** 官方 REST 基址（`/v1/search` 挂在它下面）。 */
const ANYSEARCH_DEFAULT_BASE_URL = 'https://api.anysearch.com';

/** 官方要求的客户端标识头。 */
const ANYSEARCH_CLIENT_HEADER = 'X-Anysearch-Client';
const USER_AGENT = 'dsh-web-search-anysearch/0.1.0';

/** 单次搜索的超时（不给上游无限期挂着的机会）。 */
const ANYSEARCH_DEFAULT_TIMEOUT_MS = 30000;

/** 一次搜索的结果条数上限（seam 还会按 `maxResults` 再截一次）。 */
const ANYSEARCH_DEFAULT_MAX_RESULTS = 8;

/** AnySearch 的 JSON 解析：认不出来就报结构化错误，不编造。 */
function parseSearchBody(text) {
  let body;
  try {
    body = JSON.parse(text);
  } catch (error) {
    throw new WebError(
      `AnySearch 返回的不是 JSON：${text.slice(0, 200)}`,
      'WEB_PROVIDER_ERROR',
      { cause: error },
    );
  }
  const data = body?.data;
  const list = data?.results;
  if (!Array.isArray(list)) {
    throw new WebError(
      `AnySearch 响应里没有 data.results（code=${body?.code} message=${body?.message}）`,
      'WEB_PROVIDER_ERROR',
    );
  }
  const sources = [];
  for (const item of list) {
    if (item === null || typeof item !== 'object') continue;
    const url = typeof item.url === 'string' ? item.url.trim() : '';
    if (url.length === 0) continue; // 没有 URL 的结果不算"可引用来源"
    const title = typeof item.title === 'string' ? item.title.trim() : '';
    const snippet =
      typeof item.snippet === 'string' && item.snippet.trim().length > 0
        ? item.snippet.trim()
        : (typeof item.content === 'string' ? item.content.trim().slice(0, 500) : '');
    sources.push({
      url,
      ...(title.length > 0 ? { title } : {}),
      ...(snippet.length > 0 ? { snippet } : {}),
    });
  }
  return {
    sources,
    truncated: sources.length >= ANYSEARCH_DEFAULT_MAX_RESULTS,
    ...(data?.metadata?.total_results != null
      ? { totalResults: data.metadata.total_results }
      : {}),
  };
}

/** 一次搜索：把请求发出去，把响应映射成 seam 的形状。 */
async function runSearch(options, request, signal) {
  if (signal?.aborted === true) {
    throw new WebError('AnySearch 搜索已取消', 'WEB_ABORTED');
  }
  const base = String(options.baseURL ?? ANYSEARCH_DEFAULT_BASE_URL).replace(/\/+$/u, '');
  const url = `${base}/v1/search`;
  const headers = {
    'content-type': 'application/json',
    accept: 'application/json',
    [ANYSEARCH_CLIENT_HEADER]: USER_AGENT,
  };
  // Key 是**可选**的：没有就是匿名（官方支持，只是限流低）。
  const apiKey = await options.resolveApiKey();
  if (typeof apiKey === 'string' && apiKey.trim().length > 0) {
    headers.authorization = `Bearer ${apiKey.trim()}`;
  }
  const body = {
    query: request.query,
    max_results: request.maxResults ?? ANYSEARCH_DEFAULT_MAX_RESULTS,
  };

  const controller = new AbortController();
  const timeoutMs = options.timeoutMs ?? ANYSEARCH_DEFAULT_TIMEOUT_MS;
  const timer = setTimeout(() => controller.abort(new Error('timeout')), timeoutMs);
  const merged = signal === undefined
    ? controller.signal
    : AbortSignal.any([signal, controller.signal]);

  let response;
  try {
    response = await fetch(url, {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
      signal: merged,
    });
  } catch (error) {
    clearTimeout(timer);
    if (signal?.aborted === true) {
      throw new WebError('AnySearch 搜索已取消', 'WEB_ABORTED', { cause: error });
    }
    throw new WebError(`连不上 AnySearch：${String(error)}`, 'WEB_PROVIDER_UNAVAILABLE', {
      cause: error,
    });
  }
  let text;
  try {
    text = await response.text();
  } finally {
    clearTimeout(timer);
  }
  if (response.status === 429) {
    throw new WebError(
      'AnySearch 限流了（匿名层限流较低）—— 等一会儿再试，或填一把免费 Key。',
      'WEB_PROVIDER_ERROR',
    );
  }
  if (response.status < 200 || response.status >= 300) {
    throw new WebError(
      `AnySearch HTTP ${response.status}：${text.slice(0, 200)}`,
      'WEB_PROVIDER_ERROR',
    );
  }
  return parseSearchBody(text);
}

/** provider 实例：seam 只认 `id` / `available()` / `search()` 三样。 */
class AnySearchProvider {
  constructor(resolveOptions) {
    this.id = ANYSEARCH_PROVIDER_ID;
    this._resolveOptions = resolveOptions;
  }

  /** 匿名层永远可用（**不做网络检查** —— 契约要求它是便宜的本地判断）。 */
  available() {
    return true;
  }

  search(request, signal) {
    return runSearch(this._resolveOptions(), request, signal);
  }
}

//#region cordis 插件
/** loader 诊断用的名字。 */
const name = 'web-search-anysearch';
/** 注册进哪个 seam。 */
const inject = ['web'];

const Config = z.object({
  apiKey: z.string().role('secret').volatile(),
  /** Key 从哪个环境变量读（App 会注入 `ANYSEARCH_API_KEY`；不注入就是匿名）。 */
  apiKeyEnv: z.string().role('credential-ref').default('ANYSEARCH_API_KEY').volatile(),
  baseURL: z.string().default(ANYSEARCH_DEFAULT_BASE_URL).volatile(),
  timeoutMs: z.number().step(1).min(1000).default(ANYSEARCH_DEFAULT_TIMEOUT_MS).volatile(),
});

function resolveOptions(ctx, config) {
  const apiKeyEnv = credentialRef(config.apiKeyEnv);
  const literal = config.apiKey !== undefined && config.apiKey.length > 0 ? config.apiKey : undefined;
  return {
    ...(literal === undefined ? {} : { apiKey: literal }),
    resolveApiKey: async () => {
      if (literal !== undefined) return literal;
      const credentials = ctx.get('credentials');
      if (credentials !== undefined) return (await credentials.resolve(apiKeyEnv))?.value;
      const ambient = launchEnvironmentOf(ctx).get(apiKeyEnv);
      return ambient !== undefined && ambient.value.length > 0 ? ambient.value : undefined;
    },
    baseURL: config.baseURL ?? ANYSEARCH_DEFAULT_BASE_URL,
    timeoutMs: config.timeoutMs,
  };
}

function apply(ctx, config) {
  ctx.web.registerSearchProvider(
    new AnySearchProvider(() =>
      resolveOptions(ctx, {
        apiKey: config.apiKey.get(),
        apiKeyEnv: config.apiKeyEnv.get(),
        baseURL: config.baseURL.get(),
        timeoutMs: config.timeoutMs.get(),
      }),
    ),
  );
}
//#endregion

export {
  ANYSEARCH_CLIENT_HEADER,
  ANYSEARCH_DEFAULT_BASE_URL,
  ANYSEARCH_DEFAULT_MAX_RESULTS,
  ANYSEARCH_DEFAULT_TIMEOUT_MS,
  ANYSEARCH_PROVIDER_ID,
  AnySearchProvider,
  Config,
  apply,
  inject,
  name,
  parseSearchBody,
  runSearch,
};
