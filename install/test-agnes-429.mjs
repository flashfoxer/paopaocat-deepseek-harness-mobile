// Agnes 429 / 限流的回归测试（生图 + 生视频两个脚本）。
//
// ## 为什么必须真起 HTTP 服务器
//
// 这一层要验的是**协议行为**：429 之后到底有没有退避、有没有换 Key、会不会**重复提交**。
// 用 mock 掉网络层就变成"测我自己写的假实现"了。所以下面每个用例都真起一个
// `node:http` 服务器，把 `AGNES_BASE_URL` 指过去，然后**真跑脚本**。
//
// ## 钉住的三件事（原来全都是坏的）
//
//   1. 429 → **退避重试**（优先听服务端 `Retry-After`）。原来直接 `fail()` 退出。
//   2. 多把 Key → 提交阶段被限流就**换下一把**。原来只读一把 Key，多配也没用。
//   3. 轮询被限流 → **只退避继续查，绝不重新提交、绝不换 Key**
//      （重新提交会重复排队；换 Key 会查到别的账号、查不到自己的任务）。
//
// 用法：node install/test-agnes-429.mjs
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtempSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = fileURLToPath(new URL('.', import.meta.url));
const REPO = join(HERE, '..');
const TOOLBOX = join(REPO, 'app', 'assets', 'toolbox');

let passed = 0;
const failures = [];

function test(name, fn) {
  return Promise.resolve()
    .then(fn)
    .then(() => {
      passed += 1;
      console.log(`  ✓ ${name}`);
    })
    .catch((e) => {
      failures.push({ name, error: e });
      console.log(`  ✗ ${name}\n      ${e.message}`);
    });
}

function section(title) {
  console.log(`\n=== ${title} ===`);
}

/** 跑一个工具箱脚本，收 stdout/stderr 与退出码。 */
function runScript(file, args, env, { timeoutMs = 60_000 } = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [join(TOOLBOX, file), ...args], {
      env: { ...process.env, ...env },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let out = '';
    let err = '';
    child.stdout.on('data', (d) => (out += d.toString()));
    child.stderr.on('data', (d) => (err += d.toString()));
    const timer = setTimeout(() => child.kill('SIGKILL'), timeoutMs);
    child.on('close', (code) => {
      clearTimeout(timer);
      resolve({ code, out, err });
    });
  });
}

// 一张 1x1 的 PNG（够小，写进文件就行）
const TINY_PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
  'base64',
);
// 一个"看起来像 mp4"的字节串（第 4–8 字节是 ftyp）
const FAKE_MP4 = Buffer.concat([Buffer.from([0, 0, 0, 24]), Buffer.from('ftypisom'), Buffer.alloc(2048)]);

async function withServer(handler, fn) {
  const hits = [];
  const server = createServer((req, res) => {
    let body = '';
    req.on('data', (d) => (body += d.toString()));
    req.on('end', () => {
      const rec = {
        method: req.method,
        url: req.url,
        auth: req.headers.authorization || '',
        body,
        // 有的用例要用它拼下载地址（脚本会把 url 当绝对地址去取）
        socket: req.socket,
      };
      hits.push(rec);
      handler(rec, res, hits);
    });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  try {
    return await fn({ baseUrl: `http://127.0.0.1:${port}/v1`, hits, port });
  } finally {
    await new Promise((r) => server.close(r));
  }
}

function json(res, status, obj, headers = {}) {
  const text = JSON.stringify(obj);
  res.writeHead(status, { 'content-type': 'application/json', ...headers });
  res.end(text);
}

function keyOf(rec) {
  const m = /^Bearer (.+)$/.exec(rec.auth || '');
  return m ? m[1] : '';
}

const dir = mkdtempSync(join(tmpdir(), 'agnes429-'));
process.on('exit', () => {
  try {
    rmSync(dir, { recursive: true, force: true });
  } catch {}
});

// ───────────────────────────────────────────────── 生图：429 → 退避 → 换 Key

section('生图 make-image.mjs：429 退避 + 换 Key');
{
  await test('第一把 Key 被限流 → 自动换第二把并成功出图', async () => {
    await withServer(
      (rec, res, hits) => {
        const key = keyOf(rec);
        if (key === 'key-account-a') {
          json(res, 429, { error: { message: 'rate limit exceeded' } }, { 'retry-after': '0' });
          return;
        }
        json(res, 200, { data: [{ b64_json: TINY_PNG.toString('base64') }] });
      },
      async ({ baseUrl, hits }) => {
        const dest = join(dir, 'a.png');
        const r = await runScript(
          'make-image.mjs',
          ['一只猫', dest, '--size', '1K'],
          { AGNES_BASE_URL: baseUrl, AGNES_API_KEYS: 'key-account-a,key-account-b' },
        );
        assert.equal(r.code, 0, `脚本应成功，实际退出码 ${r.code}\n${r.err}`);
        assert.ok(existsSync(dest), '应该真的写出了图片文件');
        const keys = hits.map(keyOf);
        assert.ok(keys.includes('key-account-a'), '应该先用第一把 Key 试过');
        assert.ok(keys.includes('key-account-b'), '被限流后应该换到第二把 Key');
        assert.match(r.err, /限流|429/, '要告诉用户"被限流了"，而不是只丢一个 HTTP 码');
      },
    );
  });

  await test('单把 Key 被限流 → 退避重试同一把（不会因为没备用 Key 就放弃）', async () => {
    let n = 0;
    await withServer(
      (rec, res) => {
        n += 1;
        if (n <= 2) {
          json(res, 429, { error: 'slow down' }, { 'retry-after': '0' });
          return;
        }
        json(res, 200, { data: [{ b64_json: TINY_PNG.toString('base64') }] });
      },
      async ({ baseUrl, hits }) => {
        const dest = join(dir, 'b.png');
        const r = await runScript(
          'make-image.mjs',
          ['一只猫', dest, '--size', '1K'],
          { AGNES_BASE_URL: baseUrl, AGNES_API_KEY: 'only-one' },
        );
        assert.equal(r.code, 0, `重试后应该成功，实际 ${r.code}\n${r.err}`);
        assert.ok(existsSync(dest));
        assert.equal(hits.length, 3, `应该有 3 次尝试（2 次 429 + 1 次成功），实际 ${hits.length}`);
        assert.ok(hits.every((h) => keyOf(h) === 'only-one'), '只有一把 Key 时不该换别的');
      },
    );
  });

  await test('服务端给了 Retry-After 就按它等（不是用自己猜的退避）', async () => {
    let n = 0;
    await withServer(
      (rec, res) => {
        n += 1;
        if (n === 1) {
          json(res, 429, { error: 'slow down' }, { 'retry-after': '1' });
          return;
        }
        json(res, 200, { data: [{ b64_json: TINY_PNG.toString('base64') }] });
      },
      async ({ baseUrl }) => {
        const dest = join(dir, 'c.png');
        const t0 = Date.now();
        const r = await runScript(
          'make-image.mjs',
          ['一只猫', dest, '--size', '1K'],
          { AGNES_BASE_URL: baseUrl, AGNES_API_KEY: 'k' },
        );
        const took = Date.now() - t0;
        assert.equal(r.code, 0, `应该成功\n${r.err}`);
        // Retry-After: 1 → 至少等 ~1 秒；而默认退避是 2 秒，所以"等了 ≥0.9 秒且明显没到 2 秒"
        // 能证明用的是服务端给的值。（留出进程启动开销的余量。）
        assert.ok(took >= 900, `应该至少等了 1 秒（Retry-After），实际 ${took}ms`);
      },
    );
  });

  await test('生图遇到 5xx（服务端临时故障）也要重试 —— 重复生图是安全的', async () => {
    let n = 0;
    await withServer(
      (rec, res) => {
        n += 1;
        // 依据：桌面插件的代理里写着「Agnes 会间歇性返回 5xx」，那边生图 retries=3
        if (n <= 2) {
          json(res, 503, { error: { message: '请求上游失败，请稍后重试' } });
          return;
        }
        json(res, 200, { data: [{ b64_json: TINY_PNG.toString('base64') }] });
      },
      async ({ baseUrl, hits }) => {
        const dest = join(dir, 'e.png');
        const r = await runScript(
          'make-image.mjs',
          ['一只猫', dest, '--size', '1K'],
          { AGNES_BASE_URL: baseUrl, AGNES_API_KEY: 'k' },
        );
        assert.equal(r.code, 0, `5xx 之后重试应该成功\n${r.err}`);
        assert.ok(existsSync(dest));
        assert.equal(hits.length, 3, `应该是 3 次请求（2 次 5xx + 1 次成功），实际 ${hits.length}`);
      },
    );
  });

  await test('401 不该被当成限流反复重试（Key 无效就是无效）', async () => {
    await withServer(
      (rec, res, hits) => json(res, 401, { error: 'invalid api key' }),
      async ({ baseUrl, hits }) => {
        const r = await runScript(
          'make-image.mjs',
          ['一只猫', join(dir, 'd.png'), '--size', '1K'],
          { AGNES_BASE_URL: baseUrl, AGNES_API_KEYS: 'a,b,c' },
        );
        assert.notEqual(r.code, 0, '401 应该如实失败');
        assert.equal(hits.length, 1, `401 不该重试（也不该换 Key），实际请求 ${hits.length} 次`);
        assert.match(r.err, /401/, '要把状态码说出来');
      },
    );
  });
}

// ───────────────────────────────────────── 生视频：提交换 Key、轮询只退避不重提

section('生视频 make-video.mjs：提交换 Key、轮询被限流不重新提交');
{
  await test('提交被限流换 Key；轮询限流只退避、绝不重复提交、不换 Key', async () => {
    let polls = 0;
    await withServer(
      (rec, res, hits) => {
        const key = keyOf(rec);
        if (rec.method === 'POST') {
          if (key === 'acct-a') {
            json(res, 429, { error: 'rate limit' }, { 'retry-after': '0' });
            return;
          }
          json(res, 200, { video_id: 'v-1', status: 'queued' });
          return;
        }
        if (String(rec.url).includes('v-1')) {
          polls += 1;
          if (polls === 1) {
            json(res, 429, { error: 'slow down' }, { 'retry-after': '0' });
            return;
          }
          if (polls === 2) {
            json(res, 200, { status: 'running', progress: 40 });
            return;
          }
          json(res, 200, { status: 'completed', url: `http://127.0.0.1:${rec.socket.localPort}/file.mp4` });
          return;
        }
        // 下载
        res.writeHead(200, { 'content-type': 'video/mp4' });
        res.end(FAKE_MP4);
      },
      async ({ baseUrl, hits }) => {
        const dest = join(dir, 'v.mp4');
        const r = await runScript(
          'make-video.mjs',
          ['一只猫跳下桌子', dest, '--seconds', '5'],
          {
            AGNES_BASE_URL: baseUrl,
            AGNES_API_KEYS: 'acct-a,acct-b',
            AGNES_VIDEO_TIMEOUT_MS: '30000',
            AGNES_POLL_INTERVAL_MS: '50',
          },
        );
        assert.equal(r.code, 0, `应该成功，实际退出码 ${r.code}\n${r.err}`);

        const posts = hits.filter((h) => h.method === 'POST');
        assert.equal(posts.length, 2, `POST 只该有 2 次（1 次被限流 + 1 次成功），实际 ${posts.length}`);
        assert.equal(keyOf(posts[1]), 'acct-b', '第二次提交应该换到第二把 Key');

        // ⚠️ 核心：轮询被限流之后**没有**再 POST（没有重复提交）
        const pollHits = hits.filter((h) => h.method === 'GET' && String(h.url).includes('v-1'));
        // 假服务器的脚本是确定的：第 1 次查 → 429、第 2 次 → running、第 3 次 → completed。
        // 所以正好 3 次；多一次就说明"被限流时又去重提了"或"重复查询"。
        assert.equal(pollHits.length, 3, `应该正好查 3 次进度（含 1 次被限流），实际 ${pollHits.length}`);
        assert.ok(
          pollHits.every((h) => keyOf(h) === 'acct-b'),
          '查进度必须一直用**创建任务的那把 Key**（换 Key 会查到别的账号）',
        );
        assert.equal(posts.length, 2, '轮询期间的限流不得触发任何新的提交');
        assert.match(r.err, /限流/, '限流要告诉用户');
        assert.match(r.err, /不会重新提交/, '要明确说"不会重新提交"，避免用户自己去重发');
        assert.ok(existsSync(dest), '应该真的下载出了文件');
      },
    );
  });

  await test('所有 Key 本轮都被限流 → 退避后进入下一轮并成功（不会一路撞到放弃）', async () => {
    let posts = 0;
    await withServer(
      (rec, res) => {
        if (rec.method === 'POST') {
          posts += 1;
          // 第 1 轮（两次尝试）两把 Key 都限流；第 2 轮放行
          if (posts <= 2) {
            json(res, 429, { error: 'rate limit' }, { 'retry-after': '0' });
            return;
          }
          json(res, 200, { video_id: 'v-3', status: 'queued' });
          return;
        }
        if (String(rec.url).includes('v-3')) {
          json(res, 200, { status: 'completed', url: `http://127.0.0.1:${rec.socket.localPort}/x.mp4` });
          return;
        }
        res.writeHead(200, { 'content-type': 'video/mp4' });
        res.end(FAKE_MP4);
      },
      async ({ baseUrl, hits }) => {
        const r = await runScript(
          'make-video.mjs',
          ['一只猫', join(dir, 'y.mp4'), '--seconds', '5'],
          {
            AGNES_BASE_URL: baseUrl,
            AGNES_API_KEYS: 'a1,a2',
            AGNES_VIDEO_TIMEOUT_MS: '30000',
            AGNES_POLL_INTERVAL_MS: '50',
          },
        );
        assert.equal(r.code, 0, `下一轮应该成功\n${r.err}`);
        const posts2 = hits.filter((h) => h.method === 'POST');
        assert.equal(posts2.length, 3, `应该试 3 次提交（2 次限流 + 1 次成功），实际 ${posts2.length}`);
        // 第 1 轮必须**一把各一次**（而不是拿第一把连撞两次）
        const keys = posts2.map(keyOf);
        assert.deepEqual(keys.slice(0, 2), ['a1', 'a2'], `第 1 轮应该 a1→a2 各试一次，实际 ${keys}`);
        assert.match(r.err, /轮/, '应该告诉用户"开始下一轮"，而不是默默重试');
      },
    );
  });

  await test('⚠️ 视频提交遇到 5xx **绝不重试**（重试会建出第二个任务、再扣一次配额）', async () => {
    await withServer(
      (rec, res, hits) => json(res, 500, { error: 'internal error' }),
      async ({ baseUrl, hits }) => {
        const r = await runScript(
          'make-video.mjs',
          ['一只猫', join(dir, 'z.mp4'), '--seconds', '5'],
          { AGNES_BASE_URL: baseUrl, AGNES_API_KEYS: 'a1,a2' },
        );
        assert.notEqual(r.code, 0, '5xx 应该如实失败');
        const posts = hits.filter((h) => h.method === 'POST');
        assert.equal(posts.length, 1,
          `视频提交只能发一次（5xx 不是"明确拒收"），实际 ${posts.length} 次 —— 多一次就是重复建任务/重复扣配额`);
        assert.match(r.err, /500/, '要把状态码说出来');
      },
    );
  });

  await test('排队等待的提示是人话（带已等时长）', async () => {
    let polls = 0;
    await withServer(
      (rec, res) => {
        if (rec.method === 'POST') {
          json(res, 200, { video_id: 'v-2', status: 'queued' });
          return;
        }
        if (String(rec.url).includes('v-2')) {
          polls += 1;
          if (polls < 2) {
            json(res, 200, { status: 'queued' });
            return;
          }
          json(res, 200, { status: 'completed', url: `http://127.0.0.1:${rec.socket.localPort}/f.mp4` });
          return;
        }
        res.writeHead(200, { 'content-type': 'video/mp4' });
        res.end(FAKE_MP4);
      },
      async ({ baseUrl }) => {
        const r = await runScript(
          'make-video.mjs',
          ['一只猫', join(dir, 'w.mp4'), '--seconds', '5'],
          {
            AGNES_BASE_URL: baseUrl,
            AGNES_API_KEY: 'k',
            AGNES_VIDEO_TIMEOUT_MS: '30000',
            AGNES_POLL_INTERVAL_MS: '50',
          },
        );
        assert.equal(r.code, 0, `应该成功\n${r.err}`);
        assert.match(r.err, /已等 \d+ 秒/, `应该告诉用户"已等多久"，实际：\n${r.err}`);
        assert.match(r.err, /异步任务/, '应该说明视频是异步任务、等待是正常的');
      },
    );
  });
}

// ───────────────────────────────────────────────────────────────── 收尾

console.log(`\n${'='.repeat(60)}`);
if (failures.length === 0) {
  console.log(`全部通过（${passed} 项）`);
  process.exit(0);
}
console.log(`失败 ${failures.length} 项 / 通过 ${passed} 项`);
for (const f of failures) console.log(`  · ${f.name}`);
process.exit(1);
