// zen-proxy.mjs 的测试（本地假上游，不碰真上游）。
//
// ## 为什么用假上游
//
// 要验的是**代理的形状是否正确**：门禁要求的会话 id 形状、`stream:true`、
// `bash`/`read` 两个工具、以及流式原样回传与错误映射。
// 这些全部可以在本地断言 —— 而且**不该**拿真上游做测试（那是往人家服务上打请求）。
//
// 用法：node install/test-zen-proxy.mjs
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = fileURLToPath(new URL('.', import.meta.url));
const REPO = join(HERE, '..');
const SCRIPT = join(REPO, 'app', 'assets', 'toolbox', 'zen-proxy.mjs');

let passed = 0;
const failures = [];
function test(name, fn) {
  return Promise.resolve().then(fn).then(
    () => { passed += 1; console.log(`  ✓ ${name}`); },
    (e) => { failures.push([name, e]); console.log(`  ✗ ${name}\n      ${e.message}`); },
  );
}
function section(t) { console.log(`\n== ${t} ==`); }

const work = mkdtempSync(join(tmpdir(), 'zen-proxy-test-'));
process.on('exit', () => { try { rmSync(work, { recursive: true, force: true }); } catch {} });

/** 起一个假上游；handler(rec, res, hits) 决定怎么答。 */
async function withUpstream(handler, fn) {
  const hits = [];
  const server = createServer((req, res) => {
    let body = '';
    req.on('data', (d) => (body += d.toString()));
    req.on('end', () => {
      const rec = {
        method: req.method,
        url: req.url,
        headers: req.headers,
        body,
        json: (() => { try { return JSON.parse(body); } catch { return null; } })(),
      };
      hits.push(rec);
      handler(rec, res, hits);
    });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  try {
    return await fn({ upstream: `http://127.0.0.1:${port}`, hits });
  } finally {
    await new Promise((r) => server.close(r));
  }
}

/** 起代理（指向给定上游），返回 { port, proc, stop }。 */
async function startProxy(upstream) {
  const proc = spawn(process.execPath, [
    SCRIPT, '--port', '0', '--upstream', upstream, '--state', work, '--ttl-hours', '12',
  ], { stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '';
  let err = '';
  proc.stdout.on('data', (d) => { out += d.toString(); });
  proc.stderr.on('data', (d) => { err += d.toString(); });
  const port = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`代理没就绪。stdout=${out} stderr=${err}`)), 20000);
    proc.stdout.on('data', () => {
      const m = /listening on http:\/\/127\.0\.0\.1:(\d+)/.exec(out);
      if (m) { clearTimeout(timer); resolve(Number(m[1])); }
    });
    proc.on('error', reject);
  });
  return {
    port,
    stop: () => new Promise((r) => { proc.on('close', r); proc.kill('SIGKILL'); }),
    logs: () => ({ out, err }),
  };
}

/**
 * 只挑**对话**请求。
 * ⚠️ 代理启动时会预热模型列表（发一个 GET /v1/models），所以 `hits[0]` 往往是
 * 那个请求 —— 早期版本就是因此误判（断言 stream/tools 时拿到了 models 请求）。
 */
function chatHits(hits) {
  return hits.filter((h) => h.method === 'POST' && String(h.url).includes('/chat/completions'));
}

async function proxyFetch(port, path, init) {
  const res = await fetch(`http://127.0.0.1:${port}${path}`, init);
  const text = await res.text();
  return { status: res.status, text, json: (() => { try { return JSON.parse(text); } catch { return null; } })() };
}

/** 假上游的 SSE 响应（两段增量 + 结束）。 */
function sseReply(res) {
  res.writeHead(200, { 'content-type': 'text/event-stream' });
  res.write('data: {"choices":[{"delta":{"content":"你"}}]}\n\n');
  res.write('data: {"choices":[{"delta":{"content":"好"}}]}\n\n');
  res.end('data: [DONE]\n\n');
}

// ─────────────────────────────────────────────────────────────────────

section('门禁形状：会话 id / stream / bash+read 工具');
{
  await test('转发时会带上**官方形状**的会话 id 与 CLI 头', async () => {
    await withUpstream(async (rec, res) => { sseReply(res); }, async ({ upstream, hits }) => {
      const p = await startProxy(upstream);
      try {
        await proxyFetch(p.port, '/v1/chat/completions', {
          method: 'POST',
          // ⚠️ 故意带一个假 Authorization：DSH 注入的占位值（`local-zen`）长的
          //    就是这样 —— 它**不是**这条通道认的凭据，绝不能透传到上游。
          headers: { 'content-type': 'application/json', authorization: 'Bearer local-zen' },
          body: JSON.stringify({ model: 'big-pickle', messages: [{ role: 'user', content: '你好' }] }),
        });
        const chat = chatHits(hits);
        assert.equal(chat.length, 1, `应该只有一次对话请求，实际 ${chat.length}（hits: ${hits.map((x) => x.method + ' ' + x.url).join(', ')}）`);
        const h = chat[0].headers;
        // ⚠️ 这是整件事的关键：形状必须是 ses_ + 12 位小写 hex + 14 位 Base62
        assert.match(h['x-opencode-session'], /^ses_[0-9a-f]{12}[0-9A-Za-z]{14}$/,
          `会话 id 形状不对：${h['x-opencode-session']}`);
        assert.equal(h['x-opencode-client'], 'cli');
        assert.match(h['user-agent'], /^opencode\//);
        assert.equal(h['x-opencode-session'], h['x-session-affinity']);
        // 「不用写 Key」的凭据就是字面量 `public`（官方实现的形状），且**必须覆盖**
        // 调用方自带的头 —— 透传 `local-zen` 会让上游认不出这条匿名通道。
        assert.equal(h['authorization'], 'Bearer public',
          `上游凭据应是 Bearer public，实际 ${h['authorization']}`);
      } finally { await p.stop(); }
    });
  });

  await test('客户端没带工具 → 自动补上 bash 与 read，并强制 stream:true', async () => {
    await withUpstream(async (rec, res) => { sseReply(res); }, async ({ upstream, hits }) => {
      const p = await startProxy(upstream);
      try {
        await proxyFetch(p.port, '/v1/chat/completions', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ model: 'big-pickle', stream: false, messages: [] }),
        });
        const chat = chatHits(hits);
        assert.equal(chat.length, 1);
        const body = chat[0].json;
        assert.equal(body.stream, true, '门禁要求 stream:true');
        const names = (body.tools || []).map((t) => t.function && t.function.name);
        assert.ok(names.includes('bash'), `缺 bash 工具：${JSON.stringify(names)}`);
        assert.ok(names.includes('read'), `缺 read 工具：${JSON.stringify(names)}`);
      } finally { await p.stop(); }
    });
  });

  await test('客户端已经带了自己的 bash/read → 不重复注入（保持请求原样）', async () => {
    await withUpstream(async (rec, res) => { sseReply(res); }, async ({ upstream, hits }) => {
      const p = await startProxy(upstream);
      try {
        await proxyFetch(p.port, '/v1/chat/completions', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({
            model: 'big-pickle',
            stream: true,
            messages: [],
            tools: [
              { type: 'function', function: { name: 'bash', description: 'DSH 自己的 bash', parameters: { type: 'object' } } },
              { type: 'function', function: { name: 'read', description: 'DSH 自己的 read', parameters: { type: 'object' } } },
            ],
          }),
        });
        const chat = chatHits(hits);
        assert.equal(chat.length, 1);
        const body = chat[0].json;
        const bashTools = (body.tools || []).filter((t) => t.function?.name === 'bash');
        assert.equal(bashTools.length, 1, '不该重复注入 bash');
        assert.equal(bashTools[0].function.description, 'DSH 自己的 bash',
          '客户端自己的工具必须被保留，不能被我们的占位工具覆盖');
      } finally { await p.stop(); }
    });
  });

  await test('同一个会话种子 → 同一个会话 id（保持上游 prompt cache 亲和）', async () => {
    await withUpstream(async (rec, res) => { sseReply(res); }, async ({ upstream, hits }) => {
      const p = await startProxy(upstream);
      try {
        for (let i = 0; i < 2; i += 1) {
          await proxyFetch(p.port, '/v1/chat/completions', {
            method: 'POST',
            headers: { 'content-type': 'application/json', 'x-zen-seed': 'conv-abc' },
            body: JSON.stringify({ model: 'big-pickle', messages: [{ role: 'user', content: 'hi' }] }),
          });
        }
        const chat = chatHits(hits);
        assert.equal(chat.length, 2, `应该两次对话请求，实际 ${chat.length}`);
        assert.equal(chat[0].headers['x-opencode-session'], chat[1].headers['x-opencode-session']);
      } finally { await p.stop(); }
    });
  });
}

section('流式透传与模型列表');
{
  await test('上游的 SSE 原样流回来（客户端能拿到两段内容 + [DONE]）', async () => {
    await withUpstream(async (rec, res) => { sseReply(res); }, async ({ upstream }) => {
      const p = await startProxy(upstream);
      try {
        const r = await proxyFetch(p.port, '/v1/chat/completions', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ model: 'big-pickle', messages: [{ role: 'user', content: '你好' }] }),
        });
        assert.equal(r.status, 200);
        assert.match(r.text, /"content":"你"/);
        assert.match(r.text, /"content":"好"/);
        assert.match(r.text, /\[DONE\]/);
      } finally { await p.stop(); }
    });
  });

  await test('模型列表只列**免费**的（付费模型不许出现在里面）', async () => {
    await withUpstream(async (rec, res) => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ data: [
        { id: 'big-pickle' },
        { id: 'gpt-5.9-paid' },
        { id: 'nemotron-3-ultra-free' },
        { id: 'claude-x-free' },
      ] }));
    }, async ({ upstream }) => {
      const p = await startProxy(upstream);
      try {
        const r = await proxyFetch(p.port, '/v1/models');
        assert.equal(r.status, 200);
        const ids = r.json.data.map((m) => m.id);
        assert.deepEqual(ids.sort(), ['big-pickle', 'claude-x-free', 'nemotron-3-ultra-free']);
        assert.ok(!ids.includes('gpt-5.9-paid'), '付费模型不该出现在免费通道的列表里');
      } finally { await p.stop(); }
    });
  });

  await test('上游列表取不到 → 退回静态已验证名单，且代理照常可用', async () => {
    await withUpstream(async (rec, res) => {
      res.writeHead(503, { 'content-type': 'application/json' });
      res.end('{"error":"nope"}');
    }, async ({ upstream }) => {
      const p = await startProxy(upstream);
      try {
        const r = await proxyFetch(p.port, '/v1/models');
        assert.equal(r.status, 200);
        assert.ok(r.json.data.length >= 3, `静态兜底名单不该是空的：${r.text}`);
        assert.ok(r.json.data.some((m) => m.id === 'big-pickle'));
      } finally { await p.stop(); }
    });
  });

  await test('健康检查能报告状态（App 用它显示"在跑/上次错误"）', async () => {
    await withUpstream(async (rec, res) => { sseReply(res); }, async ({ upstream }) => {
      const p = await startProxy(upstream);
      try {
        const r = await proxyFetch(p.port, '/healthz');
        assert.equal(r.status, 200);
        assert.equal(r.json.ok, true);
        assert.ok('lastError' in r.json);
      } finally { await p.stop(); }
    });
  });
}

section('错误呈现：不许假装成功，要说清"怎么办"');
{
  await test('上游 403 → 原样 403，并给出中文说明（说清"不是缺 Key"）', async () => {
    await withUpstream(async (rec, res) => {
      res.writeHead(403, { 'content-type': 'application/json' });
      res.end('{"error":{"message":"FreeTierError: free tier can only be used from within OpenCode"}}');
    }, async ({ upstream }) => {
      const p = await startProxy(upstream);
      try {
        const r = await proxyFetch(p.port, '/v1/chat/completions', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ model: 'big-pickle', messages: [] }),
        });
        assert.equal(r.status, 403);
        assert.match(r.json.error.message, /HTTP 403/);
        assert.match(r.json.error.message, /只对官方 CLI 开放|收紧/, '要说明这是上游的限制');
        // ⚠️ 2026-10-11 用户纠正："这个项目的特点就是不用写key" —— 403 时必须
        //    说清"不是你没配 Key"，而不是把用户打发去填一个根本不需要的 Key。
        assert.match(r.json.error.message, /不是"你没配 Key"|本来就不用 Key/,
          '要主动澄清：这不是"缺 Key"');
        assert.match(r.json.error.message, /FreeTierError/, '要带出上游原话，便于排查');
      } finally { await p.stop(); }
    });
  });

  await test('上游 429 → 说明"免费通道按 IP 限流，等一会儿"', async () => {
    await withUpstream(async (rec, res) => {
      res.writeHead(429, { 'content-type': 'text/plain' });
      res.end('rate limited');
    }, async ({ upstream }) => {
      const p = await startProxy(upstream);
      try {
        const r = await proxyFetch(p.port, '/v1/chat/completions', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ model: 'big-pickle', messages: [] }),
        });
        assert.equal(r.status, 429);
        assert.match(r.json.error.message, /限流/);
        assert.match(r.json.error.message, /按出口 IP/);
      } finally { await p.stop(); }
    });
  });

  await test('请求体不是 JSON → 400 且说明原因（不是 500）', async () => {
    await withUpstream(async (rec, res) => { sseReply(res); }, async ({ upstream }) => {
      const p = await startProxy(upstream);
      try {
        const r = await proxyFetch(p.port, '/v1/chat/completions', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: '{ not json',
        });
        assert.equal(r.status, 400);
        assert.match(r.json.error.message, /不是合法 JSON/);
      } finally { await p.stop(); }
    });
  });

  await test('未知路径 → 404（而不是把它转发到上游）', async () => {
    await withUpstream(async (rec, res, hits) => { sseReply(res); }, async ({ upstream, hits }) => {
      const p = await startProxy(upstream);
      try {
        const r = await proxyFetch(p.port, '/v1/embeddings', { method: 'POST', body: '{}' });
        assert.equal(r.status, 404);
        assert.equal(hits.length, 0, '不该把不认识的路径转发给上游');
      } finally { await p.stop(); }
    });
  });
}

  await test('会话 id 前 12 位必须是时间戳编码，不是种子摘要（2026-10-13 上游新门禁）', async () => {
    await withUpstream(async (rec, res) => { sseReply(res); }, async ({ upstream, hits }) => {
      const p = await startProxy(upstream);
      try {
        const send = (seed) => proxyFetch(p.port, '/v1/chat/completions', {
          method: 'POST',
          headers: { 'content-type': 'application/json', 'x-zen-seed': seed },
          body: JSON.stringify({ model: 'big-pickle', messages: [{ role: 'user', content: 'hi' }], stream: true }),
        });
        await send('sess-A'); await send('sess-A'); await send('sess-B');
        const ids = chatHits(hits).map((h) => h.headers['x-opencode-session'] || '');
        assert.equal(ids.length, 3, `应当有 3 个 chat 请求，实际 ${ids.length}`);
        for (const id of ids) assert.match(id, /^ses_[0-9a-f]{12}[0-9A-Za-z]{14}$/, `形状不对：${id}`);
        assert.equal(ids[0], ids[1], '同一个 x-zen-seed 两次必须拿到同一个会话 id（缓存亲和）');
        assert.notEqual(ids[0], ids[2], '不同种子应当拿到不同的会话 id');
        // 那 12 位 = ~(ms*0x1000 + counter) 的低 48 位 → 低 12 位必然很大（官方 id 总以 fff/ffe 收尾）。
        // 旧的「摘要派生」实现没有这个性质 —— 这就是这条测试要咬住的回归。
        for (const id of ids) {
          const low12 = parseInt(id.slice(13, 16), 16);
          assert.ok(low12 >= 0xf00, `低 12 位不像时间戳编码（${id}）：0x${low12.toString(16)}`);
        }
      } finally { await p.stop(); }
    });
  });

// ─────────────────────────────────────────────────────────────────────
console.log(`\n${'='.repeat(60)}`);
if (failures.length === 0) {
  console.log(`全部通过（${passed} 项）—— 全程只用了本地假上游，没有碰真上游`);
  process.exit(0);
}
console.log(`失败 ${failures.length} 项 / 通过 ${passed} 项`);
for (const [n] of failures) console.log(`  · ${n}`);
process.exit(1);
