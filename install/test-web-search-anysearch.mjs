#!/usr/bin/env node
// 验证 `runtime-plugins/dsh-web-search-anysearch`（把 AnySearch 接成 ctx.web 的搜索后端）。
//
// 两类检查：
//   * **纯函数**（`parseSearchBody`）：形状映射与"认不出来就报结构化错误"；
//   * **一次真搜索**（`runSearch`）：对着**真 AnySearch 匿名层**打一次（本机实测可通），
//     再对着**本地假服务**验 429 / 非 200 / 坏 JSON / 取消。
//
// ⚠️ 它**不启动 DSH**（手机运行时是 arm64，本机跑不起来），所以这里证明的是
//    "provider 的实现与 seam 契约一致"，不等于"已经在手机上生效" —— 后者要真机。
import { createServer } from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';

// ── 让插件能 import 到 DSH 的包 ─────────────────────────────────────────────
//
// 插件里 `import { WebError } from '@deepseek-ai/dsh-web'` 这些是**裸包名**，
// 而仓库本身没有 node_modules（那棵树在 App 的运行时压缩包里）。
// 所以这里：把插件**拷**到一个临时目录，并在它的 node_modules 里给这几个依赖
// 建符号链接指向**已解开的运行时**（默认 /tmp/rt-run/app，可用 DSH_RUNTIME_DIR 覆盖）。
// 这样用的是运行时**真实的那份** dsh-web / dsh-credentials，不是替身。
const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..');
const RUNTIME = process.env.DSH_RUNTIME_DIR || '/tmp/rt-run/app';
const runtimeModules = path.join(RUNTIME, 'node_modules');
if (!fs.existsSync(runtimeModules)) {
  console.error(`✗ 找不到运行时依赖树：${runtimeModules}\n` +
    '  先把 dsh-runtime-*.zip 解开（见 docs/CHANGES-2026-10-15.md 第 14 节），' +
    '或用 DSH_RUNTIME_DIR 指向它。');
  process.exit(2);
}
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'anysearch-provider-'));
const pkgDir = path.join(TMP, 'node_modules', '@deepseek-ai', 'dsh-web-search-anysearch');
fs.mkdirSync(path.dirname(pkgDir), { recursive: true });
fs.cpSync(path.join(REPO, 'runtime-plugins', 'dsh-web-search-anysearch'), pkgDir, { recursive: true });
for (const dep of ['dsh-web', 'dsh-credentials', 'dsh-launch-environment', 'schemastery']) {
  const target = path.join(runtimeModules, '@deepseek-ai', dep);
  const link = path.join(TMP, 'node_modules', '@deepseek-ai', dep);
  if (fs.existsSync(target)) fs.symlinkSync(target, link, 'dir');
}
const MOD = await import(pathToFileURL(path.join(pkgDir, 'lib', 'index.js')).href);
const { parseSearchBody, runSearch, AnySearchProvider, ANYSEARCH_PROVIDER_ID } = MOD;

let pass = 0;
let fail = 0;
function ok(name, cond, extra = '') {
  if (cond) {
    pass += 1;
    console.log(`  ✓ ${name}`);
  } else {
    fail += 1;
    console.log(`  ✗ ${name}${extra ? `\n      ${extra}` : ''}`);
  }
}
async function throwsWeb(name, fn, code) {
  try {
    await fn();
    ok(name, false, '本该抛错但没有');
  } catch (error) {
    const got = error?.code ?? '';
    ok(`${name}（code=${got || '无'}）`, code === undefined || got === code);
  }
}

console.log('== 纯函数：形状映射 ==');
{
  const r = parseSearchBody(JSON.stringify({
    code: 0,
    message: 'success',
    data: {
      results: [
        { title: '标题一', url: 'https://a.example/x', snippet: '摘要一' },
        { title: '只有 content', url: 'https://b.example/y', content: '长内容'.repeat(300) },
        { title: '没有 URL 的丢掉', url: '' },
        null,
        { title: 'URL 要 trim', url: '  https://c.example/z  ' },
      ],
      metadata: { total_results: 5, search_time_ms: 12 },
    },
  }));
  ok('只留有 URL 的来源（丢弃空 URL / null）', r.sources.length === 3, `实得 ${r.sources.length}`);
  ok('title / snippet 映射正确', r.sources[0].title === '标题一' && r.sources[0].snippet === '摘要一');
  ok('没有 snippet 时回落到 content', typeof r.sources[1].snippet === 'string' && r.sources[1].snippet.length > 0);
  ok('URL 被 trim', r.sources[2].url === 'https://c.example/z');
}

await throwsWeb('坏 JSON → WebError', async () => parseSearchBody('不是 JSON'), 'WEB_PROVIDER_ERROR');
await throwsWeb('没有 data.results → WebError', async () => parseSearchBody('{"code":0,"data":{}}'), 'WEB_PROVIDER_ERROR');

console.log('== 假服务：429 / 500 / 坏 JSON / 取消 ==');
{
  let mode = 'ok';
  const server = createServer(async (req, res) => {
    // 把请求头回读给调用方（验证匿名不带 Authorization、带 Key 时带 Bearer）
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const body = Buffer.concat(chunks).toString('utf8');
    globalThis.__lastReq = { headers: req.headers, url: req.url, body };
    if (mode === '429') {
      res.writeHead(429, { 'content-type': 'application/json' });
      res.end('{"message":"rate limited"}');
      return;
    }
    if (mode === '500') {
      res.writeHead(500, { 'content-type': 'text/plain' });
      res.end('boom');
      return;
    }
    if (mode === 'badjson') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end('{不是 JSON');
      return;
    }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({
      code: 0,
      data: { results: [{ title: 'T', url: 'https://a.example/1', snippet: 'S' }] },
    }));
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;

  const anonymous = { baseURL: base, resolveApiKey: async () => undefined };
  const r = await runSearch(anonymous, { query: '你好', maxResults: 3 });
  ok('正常：映射出 sources', r.sources.length === 1 && r.sources[0].url === 'https://a.example/1');
  ok('请求体带 query 与 max_results', /"query":"你好"/.test(globalThis.__lastReq.body) && /"max_results":3/.test(globalThis.__lastReq.body));
  ok('匿名：**不发** Authorization', globalThis.__lastReq.headers.authorization === undefined);
  ok('带客户端标识头（官方要求）', globalThis.__lastReq.headers['x-anysearch-client'] !== undefined);
  ok('打在 /v1/search 上', globalThis.__lastReq.url === '/v1/search');

  const withKey = { baseURL: base, resolveApiKey: async () => '  as_sk_test  ' };
  await runSearch(withKey, { query: 'x' });
  ok('带 Key：发 Bearer 且去掉空格', globalThis.__lastReq.headers.authorization === 'Bearer as_sk_test');

  mode = '429';
  await throwsWeb('429 → WebError（提示限流）', async () => runSearch(anonymous, { query: 'x' }), 'WEB_PROVIDER_ERROR');
  mode = '500';
  await throwsWeb('500 → WebError', async () => runSearch(anonymous, { query: 'x' }), 'WEB_PROVIDER_ERROR');
  mode = 'badjson';
  await throwsWeb('坏 JSON → WebError', async () => runSearch(anonymous, { query: 'x' }), 'WEB_PROVIDER_ERROR');

  // 取消
  const aborted = new AbortController();
  aborted.abort();
  await throwsWeb('已经取消 → WEB_ABORTED', async () => runSearch(anonymous, { query: 'x' }, aborted.signal), 'WEB_ABORTED');

  await new Promise((r) => server.close(r));
}

console.log('== provider 对象的形状（seam 只认三样）==');
{
  const p = new AnySearchProvider(() => ({ baseURL: 'https://api.anysearch.com', resolveApiKey: async () => undefined }));
  ok('id 是稳定字符串', p.id === ANYSEARCH_PROVIDER_ID && typeof p.id === 'string');
  ok('available() 是本地判断且为 true（匿名永远可用）', p.available() === true);
  ok('search 是函数（返回 Promise）', typeof p.search === 'function');
}

console.log('== 真网络：匿名打一次 AnySearch（证明"免 Key 真能搜"）==');
{
  try {
    const r = await runSearch(
      { baseURL: 'https://api.anysearch.com', resolveApiKey: async () => undefined, timeoutMs: 30000 },
      { query: 'deepseek harness', maxResults: 3 },
    );
    ok(`真搜索拿到 ${r.sources.length} 条来源`, r.sources.length > 0);
    ok('每条来源都有 URL', r.sources.every((s) => typeof s.url === 'string' && s.url.length > 0));
  } catch (error) {
    // 网络不可用不算"实现错"，但要说清（测试不允许静默通过）
    ok('真网络搜索可用（本机可达时）', false, `失败：${String(error).slice(0, 160)}`);
  }
}

console.log(`\n${'='.repeat(60)}`);
console.log(fail === 0
  ? `全部通过（${pass} 项）`
  : `失败 ${fail} 项 / 通过 ${pass} 项`);
try {
  fs.rmSync(TMP, { recursive: true, force: true });
} catch {}
process.exit(fail === 0 ? 0 : 1);
