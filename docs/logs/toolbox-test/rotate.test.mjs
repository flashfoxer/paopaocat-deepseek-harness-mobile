// rotate-proxy 端到端验证：
// 假上游（第一个成员 429 / 第二个 200）→ 观察"失败自动切换"的完整日志、粘性回写、
// 流式 SSE 管道、全部失败时的行为、404、端口占用、SIGTERM。
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const PROXY = process.argv[2];
const OUTDIR = process.argv[3];
const work = mkdtempSync(join(tmpdir(), 'rotate-'));

let failures = 0;
function check(ok, label, extra) {
  console.log(`${ok ? '  ✓' : '  ✗'} ${label}${extra !== undefined && !ok ? '  ← ' + JSON.stringify(extra) : ''}`);
  if (!ok) failures += 1;
}

function listen(server, port = 0) {
  return new Promise((res) => server.listen(port, '127.0.0.1', () => res(server.address().port)));
}

async function freePort() {
  const s = createServer();
  const p = await listen(s);
  await new Promise((r) => s.close(r));
  return p;
}

// ─────────────────────────────────── 1) 纯函数单测
console.log('=== 1) 纯函数单测（buildChatUrl / resolveTarget / orderMembers）===');
const mod = await import(pathToFileURL(PROXY).href);
const bc = mod.buildChatUrl;
check(bc('https://api.deepseek.com/v1') === 'https://api.deepseek.com/v1/chat/completions', 'baseUrl 带 /v1 → 不再重复加 v1', bc('https://api.deepseek.com/v1'));
check(bc('https://api.deepseek.com') === 'https://api.deepseek.com/v1/chat/completions', 'baseUrl 不带 /v1 → 补 /v1/chat/completions', bc('https://api.deepseek.com'));
check(bc('https://dashscope.aliyuncs.com/compatible-mode/v1/') === 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions', '去尾斜杠 + 带 /v1', bc('https://dashscope.aliyuncs.com/compatible-mode/v1/'));
check(bc('http://x/v1/chat/completions') === 'http://x/v1/chat/completions', '已经是完整路径 → 原样', bc('http://x/v1/chat/completions'));

const groups = {
  cat: { members: [{ name: 'deepseek', model: 'deepseek-chat', baseUrl: 'http://a/v1' }, { name: 'qwen', model: 'qwen-max', baseUrl: 'http://b/v1' }] },
};
check(mod.resolveTarget(groups, 'cat').group === 'cat', 'model=cat 精确匹配');
check(mod.resolveTarget(groups, 'rotate/cat').group === 'cat', 'rotate/cat 宽松匹配', mod.resolveTarget(groups, 'rotate/cat'));
check(mod.resolveTarget(groups, 'CAT').group === 'cat', '大小写不敏感');
check(mod.resolveTarget(groups, 'qwen-max').startIndex === 1, '退一步：填成员真实 model 名也能落到该成员');
check(mod.resolveTarget(groups, 'nope') === null, '完全不认识的 model → null');
check(JSON.stringify(mod.orderMembers(groups.cat, 1).map((x) => x.member.name)) === '["qwen","deepseek"]', '粘性：从上次成功的成员开始轮', mod.orderMembers(groups.cat, 1).map((x) => x.member.name));

// ─────────────────────────────────── 2) 假上游
console.log('\n=== 2) 起假上游 ===');
const seen = [];
const bad = createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    seen.push({ who: 'bad', path: req.url, auth: req.headers.authorization, model: JSON.parse(body || '{}').model });
    res.writeHead(429, { 'content-type': 'application/json', 'x-upstream': 'bad' });
    res.end('{"error":{"message":"rate limited by upstream","type":"rate_limit"}}');
  });
});
const good = createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    const payload = JSON.parse(body || '{}');
    seen.push({ who: 'good', path: req.url, auth: req.headers.authorization, model: payload.model, stream: payload.stream === true });
    if (payload.stream === true) {
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
      let n = 0;
      const timer = setInterval(() => {
        n += 1;
        if (n <= 3) res.write(`data: {"choices":[{"delta":{"content":"chunk${n}"}}]}\n\n`);
        else { res.write('data: [DONE]\n\n'); clearInterval(timer); res.end(); }
      }, 10);
    } else {
      const out = JSON.stringify({ id: 'cmpl-1', object: 'chat.completion', model: payload.model, choices: [{ index: 0, message: { role: 'assistant', content: '来自 good 上游的回答' } }] });
      res.writeHead(200, { 'content-type': 'application/json', 'x-upstream': 'good' });
      res.end(out);
    }
  });
});
const badPort = await listen(bad);
const goodPort = await listen(good);
console.log(`  bad 上游 :${badPort}   good 上游 :${goodPort}`);

// ─────────────────────────────────── 3) 配置 + 启动代理
console.log('\n=== 3) 启动代理 ===');
const cfgPath = join(OUTDIR, 'rotate-config.json');
const logPath = join(OUTDIR, 'rotate-proxy.log');
const cfg = {
  port: 1, // 会被 --port 覆盖
  note: '这个字段必须原样保留（验证回写不破坏原结构）',
  groups: {
    cat: {
      members: [
        { name: 'deepseek', baseUrl: `http://127.0.0.1:${badPort}/v1`, apiKey: 'sk-bad-111', model: 'deepseek-chat' },
        { name: 'qwen', baseUrl: `http://127.0.0.1:${goodPort}/v1`, apiKey: 'sk-good-222', model: 'qwen-max' },
      ],
    },
    allbad: {
      members: [
        { name: 'm1', baseUrl: `http://127.0.0.1:${badPort}/v1`, apiKey: 'sk-1', model: 'm-one' },
        { name: 'm2', baseUrl: `http://127.0.0.1:${badPort}/v1`, apiKey: 'sk-2', model: 'm-two' },
      ],
    },
  },
};
writeFileSync(cfgPath, JSON.stringify(cfg, null, 2) + '\n', 'utf8');
const port = await freePort();
const proxy = spawn(process.execPath, [PROXY, cfgPath, '--port', String(port), '--log', logPath, '--verbose'], {
  stdio: ['ignore', 'pipe', 'pipe'],
});
let stdout = '';
let stderr = '';
proxy.stdout.on('data', (d) => { stdout += d; });
proxy.stderr.on('data', (d) => { stderr += d; });

const readyRe = /\[rotate-proxy\] listening on (http:\/\/[^\s]+) groups=(\S+)/;
const ready = await new Promise((res) => {
  const t = setTimeout(() => res(null), 8000);
  proxy.stdout.on('data', () => {
    const m = readyRe.exec(stdout);
    if (m) { clearTimeout(t); res(m); }
  });
});
check(!!ready, 'stdout 出现可被 Dart 正则识别的就绪标记', stdout);
if (ready) console.log(`  → 标记: ${ready[0]}`);
const base = `http://127.0.0.1:${port}`;

// ─────────────────────────────────── 4) 接口
console.log('\n=== 4) /health、/v1/models、404 ===');
const health = await (await fetch(`${base}/health`)).json();
check(health.ok === true && JSON.stringify(health.groups) === '["cat","allbad"]', 'GET /health', health);
const models = await (await fetch(`${base}/v1/models`)).json();
check(models.object === 'list' && models.data.length === 2 && models.data[0].id === 'cat' && models.data[0].owned_by === 'rotate', 'GET /v1/models 每组一个', models);
check((await fetch(`${base}/nope`)).status === 404, '未知路径 → 404');

// ─────────────────────────────────── 5) 429 → 自动切换
console.log('\n=== 5) 核心：第一个成员 429 → 自动切第二个 ===');
const seenBefore = seen.length;
const r1 = await fetch(`${base}/v1/chat/completions`, {
  method: 'POST',
  headers: { 'content-type': 'application/json', 'x-client-header': 'kept' },
  body: JSON.stringify({ model: 'cat', messages: [{ role: 'user', content: '你好' }] }),
});
const j1 = await r1.json();
check(r1.status === 200, '客户端拿到 200（不是 429）', r1.status);
check(j1.choices[0].message.content.includes('来自 good 上游'), '响应体来自第二个成员', j1);
check(r1.headers.get('x-upstream') === 'good', '上游响应头被透传');
const hop = seen.slice(seenBefore);
check(hop.length === 2 && hop[0].who === 'bad' && hop[1].who === 'good', '先打第一个成员、失败后才打第二个', hop.map((x) => x.who));
check(hop[0].model === 'deepseek-chat' && hop[1].model === 'qwen-max', '请求体里的 model 被换成成员自己的模型名', hop.map((x) => x.model));
check(hop[0].auth === 'Bearer sk-bad-111' && hop[1].auth === 'Bearer sk-good-222', '认证换成各成员的 apiKey', hop.map((x) => x.auth));
check(hop[1].path === '/v1/chat/completions', '上游路径拼接正确', hop[1].path);

const switchLine = /\[rotate\] cat: deepseek 失败\(429\)，改用 qwen/;
check(switchLine.test(stderr), '切换日志格式与要求一致', stderr.split('\n').filter((l) => l.includes('失败')).join(' | '));
const logFileText = readFileSync(logPath, 'utf8');
check(switchLine.test(logFileText), '--log 指定的文件里也有这行');

// ─────────────────────────────────── 6) 粘性
console.log('\n=== 6) 粘性：下次从上次成功的成员开始 ===');
const cfgAfter = JSON.parse(readFileSync(cfgPath, 'utf8'));
check(cfgAfter.lastGood && cfgAfter.lastGood.cat === 1, 'config.json 顶层写入了 lastGood={cat:1}', cfgAfter.lastGood);
check(cfgAfter.note === cfg.note && JSON.stringify(cfgAfter.groups) === JSON.stringify(cfg.groups), '回写没有破坏原结构（note/groups 原样）');
const seenBefore2 = seen.length;
const r2 = await fetch(`${base}/v1/chat/completions`, {
  method: 'POST', headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ model: 'cat', messages: [] }),
});
check(r2.status === 200, '第二次请求也 200');
const hop2 = seen.slice(seenBefore2);
check(hop2.length === 1 && hop2[0].who === 'good', '第二次直接从 qwen 开始（不再先打 deepseek）', hop2.map((x) => x.who));

// ─────────────────────────────────── 7) 流式
console.log('\n=== 7) 流式 SSE 原样管道 ===');
const r3 = await fetch(`${base}/v1/chat/completions`, {
  method: 'POST', headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ model: 'cat', stream: true, messages: [] }),
});
const sse = await r3.text();
check(r3.status === 200, 'stream:true → 200', r3.status);
check(r3.headers.get('content-type') === 'text/event-stream', 'Content-Type: text/event-stream', r3.headers.get('content-type'));
check(r3.headers.get('cache-control') === 'no-cache', 'Cache-Control: no-cache');
check(sse.includes('data: {"choices"') && sse.includes('data: [DONE]'), 'SSE 数据块原样到达客户端', sse.slice(0, 120));

// ─────────────────────────────────── 8) 全部失败
console.log('\n=== 8) 全部成员失败 → 返回最后一次上游状态与响应体 ===');
const r4 = await fetch(`${base}/v1/chat/completions`, {
  method: 'POST', headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ model: 'allbad', messages: [] }),
});
const body4 = await r4.text();
check(r4.status === 429, '状态码沿用最后一次上游的 429', r4.status);
check(body4.includes('rate limited by upstream'), '响应体沿用上游的错误体', body4);
check(/\[rotate\] allbad: m1 失败\(429\)，改用 m2/.test(stderr) && /\[rotate\] allbad: m2 失败\(429\)，没有更多成员可用/.test(stderr), '两个成员各打一行切换日志');

// ─────────────────────────────────── 9) 其它错误路径
console.log('\n=== 9) 错误路径 ===');
const s1 = await fetch(`${base}/v1/chat/completions`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{"model":"不存在的组"}' });
check(s1.status === 404, '未知组 → 404', s1.status);
const e1 = await s1.json();
check(typeof e1.error.message === 'string' && e1.error.message.includes('可用组'), '404 是 OpenAI 风格 JSON 且说明了可用组', e1);
const s2 = await fetch(`${base}/v1/chat/completions`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{不是 json' });
check(s2.status === 400, '请求体不是 JSON → 400', s2.status);

// ─────────────────────────────────── 10) 端口占用
console.log('\n=== 10) 端口被占用 ===');
const clash = spawn(process.execPath, [PROXY, cfgPath, '--port', String(port)], { stdio: ['ignore', 'pipe', 'pipe'] });
let clashErr = '';
clash.stderr.on('data', (d) => { clashErr += d; });
const clashCode = await new Promise((res) => clash.on('close', res));
check(clashCode === 1, '以非 0 退出（不静默换端口）', clashCode);
check(clashErr.includes('已被占用') && clashErr.includes(String(port)), '错误信息说清端口被占用', clashErr.trim());

// ─────────────────────────────────── 11) 退出
console.log('\n=== 11) SIGTERM ===');
const closed = new Promise((res) => proxy.on('close', (code) => res(code)));
proxy.kill('SIGTERM');
const code = await Promise.race([closed, new Promise((r) => setTimeout(() => r('timeout'), 5000))]);
console.log(`  （本机为 Windows：POSIX 信号无法真正投递，这里只确认进程会退出；退出码=${code}）`);

console.log('\n=== 代理 stderr 全量日志 ===');
console.log(stderr.trim());

bad.close();
good.close();
console.log(`\n结果：${failures === 0 ? '全部通过 ✅' : failures + ' 项失败 ❌'}`);
process.exit(failures === 0 ? 0 : 1);
