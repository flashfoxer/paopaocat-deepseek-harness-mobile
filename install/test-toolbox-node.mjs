// 工具箱（`app/assets/toolbox/*`）的 node 侧测试 —— 针对审计 P0-2 与 P0-3 的加固。
//
// 为什么单独有一个 node 测试：这两个改动都在 **node 脚本**里（`flutter test`
// 跑不到它们），而它们守的都是**凭据边界** —— 写错了不会崩，只会静默地
// "又能读到 Key 了"。这类缺陷必须被测试钉住。
//
// 跑法：node install/test-toolbox-node.mjs   （不需要设备、不需要网络）
// 退出码：0 全过；1 有失败。

import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync, readFileSync, existsSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = fileURLToPath(new URL('.', import.meta.url));
const REPO = resolve(HERE, '..');
const require = createRequire(import.meta.url);

let passed = 0;
const failures = [];

function test(name, fn) {
  try {
    fn();
    passed += 1;
    console.log(`  ok   ${name}`);
  } catch (e) {
    failures.push([name, e]);
    console.log(`  FAIL ${name}\n       ${e && e.message ? e.message : e}`);
  }
}

async function testAsync(name, fn) {
  try {
    await fn();
    passed += 1;
    console.log(`  ok   ${name}`);
  } catch (e) {
    failures.push([name, e]);
    console.log(`  FAIL ${name}\n       ${e && e.message ? e.message : e}`);
  }
}

function section(title) {
  console.log(`\n== ${title} ==`);
}

// ─────────────────────────────────────────── P0-2a：exec shim 的凭据白名单

section('P0-2a exec shim：模型驱动的 shell 能继承哪些环境变量');
{
  const shimPath = join(REPO, 'app/assets/toolbox/android-exec-shim.cjs');
  // 这份 shim 是"给真机用的"：只有需要的环境变量都在才会真的接管 child_process。
  // 这里**故意不让它激活**（只 require 纯函数），导出里也没有副作用。
  const shim = require(shimPath);

  const ENV_BEFORE = { ...process.env };
  function withEnv(patch, fn) {
    for (const k of Object.keys(process.env)) delete process.env[k];
    Object.assign(process.env, patch);
    try {
      return fn();
    } finally {
      for (const k of Object.keys(process.env)) delete process.env[k];
      Object.assign(process.env, ENV_BEFORE);
    }
  }

  // 一份"典型的手机运行时环境"：既有该放行的，也有**绝不能**放行的。
  const RUNTIME = {
    // 该放行（随包功能真的要用）
    DSH_ANDROID_TOOLBOX: '/data/app/toolbox',
    AGNES_API_KEY: 'agnes-key',
    AGNES_BASE_URL: 'https://agnes.example',
    LOCAL_IMAGE_BASE_URL: 'http://127.0.0.1:8080',
    // 绝不能放行（这是 P0-2 的整个要点）
    DEEPSEEK_API_KEY: 'sk-deepseek-secret',
    OPENAI_API_KEY: 'sk-openai-secret',
    COM_API_KEY: 'com-secret',
    ROTATE_API_KEY: 'rotate-token',
    PATH: '/system/bin',
  };

  test('默认不再全量继承：provider 的 Key 一个都到不了子进程', () => {
    const got = withEnv(RUNTIME, () => Object.keys(shim.parentEnvBase()).sort());
    for (const k of ['DEEPSEEK_API_KEY', 'OPENAI_API_KEY', 'COM_API_KEY', 'ROTATE_API_KEY']) {
      assert.ok(!got.includes(k), `默认白名单漏了凭据 ${k} —— P0-2 回归了`);
    }
  });

  test('「打开本机应用」取消后，DSH_DEVICE_ 不该再被放行（白名单不留无用口子）', () => {
    const got = withEnv(RUNTIME, () => shim.parentEnvBase());
    // 该通道已随功能一起删除；如果哪天有人把前缀加回白名单，
    // 说明要么功能复活了（那就该连功能一起加回来），要么留了个没人用的口子。
    assert.ok(!Object.keys(got).some((k) => k.startsWith('DSH_DEVICE_')),
      'DSH_DEVICE_ 前缀还在白名单里，但那条设备通道已经删了');
  });

  test('默认放行随包功能真正需要的那几个（少一个就是把功能修坏了）', () => {
    const got = withEnv(RUNTIME, () => shim.parentEnvBase());
    // DSH_ANDROID_TOOLBOX：所有技能文件都靠它找脚本
    assert.equal(got.DSH_ANDROID_TOOLBOX, '/data/app/toolbox', '技能找不到工具箱了');
    // AGNES_*：免费生图 / 生视频
    assert.equal(got.AGNES_API_KEY, 'agnes-key', '免费生图/生视频会失效');
    assert.equal(got.AGNES_BASE_URL, 'https://agnes.example');
    // LOCAL_*：本机出图
    assert.equal(got.LOCAL_IMAGE_BASE_URL, 'http://127.0.0.1:8080');
  });

  test('ROTATE_API_KEY 必须**不在**白名单里（否则模型能自己用用户的 Key 打代理）', () => {
    const got = withEnv(RUNTIME, () => Object.keys(shim.parentEnvBase()));
    assert.ok(!got.includes('ROTATE_API_KEY'), 'ROTATE_API_KEY 不该进 shell（P0-3 的边界）');
  });

  test('none：什么都不继承', () => {
    const got = withEnv({ ...RUNTIME, DSH_ANDROID_ENV_PASSTHROUGH: 'none' }, () =>
      Object.keys(shim.parentEnvBase()),
    );
    assert.deepEqual(got, []);
  });

  test('all：显式回到全量继承（仅调试用，通路必须还在）', () => {
    const got = withEnv({ ...RUNTIME, DSH_ANDROID_ENV_PASSTHROUGH: 'all' }, () =>
      shim.parentEnvBase(),
    );
    assert.equal(got.DEEPSEEK_API_KEY, 'sk-deepseek-secret');
    assert.equal(got.AGNES_API_KEY, 'agnes-key');
  });

  test('自定义前缀仍然可用（覆盖默认表）', () => {
    const got = withEnv({ ...RUNTIME, DSH_ANDROID_ENV_PASSTHROUGH: 'AGNES_' }, () =>
      Object.keys(shim.parentEnvBase()).sort(),
    );
    assert.deepEqual(got, ['AGNES_API_KEY', 'AGNES_BASE_URL']);
  });

  test('默认表是一份**常量**，且逐条就是这几个前缀（少一条 = 把功能修坏）', () => {
    assert.ok(Array.isArray(shim.DEFAULT_ENV_PASSTHROUGH));
    // ⚠️ 这里从「length >= 4」改成**逐条列明**：
    //   * 长度不是重点，"放行了哪几个前缀"才是 —— 数字断言既挡不住少放一个
    //     必需前缀（3 个也可能 >= 3），也说不清该有哪几个；
    //   * 「打开本机应用」取消后 `DSH_DEVICE_` 已移除，所以现在是三个。
    //   改这张表时**必须一起改这条** —— 那一步就是你的确认动作。
    assert.deepEqual(
      [...shim.DEFAULT_ENV_PASSTHROUGH].sort(),
      ['AGNES_', 'DSH_ANDROID_', 'LOCAL_'],
      '默认环境白名单与预期不一致（改功能时请同步这条断言）',
    );
  });
}

// ─────────────────────────────────────────── P0-3：轮换代理的客户端鉴权

section('P0-3 轮换代理：必须有客户端令牌，且比对是等时的');
const PROXY = join(REPO, 'app/assets/toolbox/rotate-proxy.mjs');
{
  const proxy = await import(PROXY);

  test('constantTimeEqual：相同为真、不同为假、长度无关不抛', () => {
    assert.equal(proxy.constantTimeEqual('abc', 'abc'), true);
    assert.equal(proxy.constantTimeEqual('abc', 'abd'), false);
    assert.equal(proxy.constantTimeEqual('abc', 'abcdefgh'), false);
    assert.equal(proxy.constantTimeEqual('', ''), true);
    assert.equal(proxy.constantTimeEqual('x', ''), false);
  });

  test('clientToken：认 Authorization: Bearer 与 x-api-key', () => {
    assert.equal(proxy.clientToken({ headers: { authorization: 'Bearer t0k' } }), 't0k');
    assert.equal(proxy.clientToken({ headers: { authorization: 'bearer t0k' } }), 't0k');
    assert.equal(proxy.clientToken({ headers: { 'x-api-key': 't0k' } }), 't0k');
    assert.equal(proxy.clientToken({ headers: { authorization: 'Basic zzz' } }), '');
    assert.equal(proxy.clientToken({ headers: {} }), '');
  });

  test('parseArgs：--config-stdin 与 --port 0 的解析', () => {
    const a = proxy.parseArgsForTest(['--config-stdin', '--port', '0']);
    assert.equal(a.configStdin, true);
    assert.equal(a.port, 0);
    const b = proxy.parseArgsForTest(['c.json', '--state', 's.json', '--port=8080']);
    assert.equal(b.config, 'c.json');
    assert.equal(b.state, 's.json');
    assert.equal(b.port, 8080);
  });

  // ⚠️ 参数错误不能在**进程内**测：`die()` 会 `process.exit()`，会把测试进程自己
  // 杀掉（第一版就是这么把整套测试截断的）。所以走子进程，顺便把真实退出码也钉住。
  await testAsync('参数/配置错误的退出码：2（参数）、3（没令牌）', async () => {
    const run = (args, stdin) =>
      new Promise((res) => {
        const c = spawn(process.execPath, [PROXY, ...args], { stdio: ['pipe', 'pipe', 'pipe'] });
        let err = '';
        c.stderr.on('data', (d) => { err += d.toString(); });
        if (stdin !== undefined) c.stdin.write(stdin);
        c.stdin.end();
        c.on('exit', (code) => res({ code, err }));
      });

    assert.equal((await run(['--config-stdin', 'x.json'])).code, 2, '既给 stdin 又给文件名');
    assert.equal((await run([])).code, 2, '什么都没给');
    assert.equal((await run(['c.json', '--port', '-1'])).code, 2, '端口为负');
    assert.equal((await run(['/nonexistent/nope.json'])).code, 2, '配置文件不存在');
    // 配置给了但没有 token、也没 --no-auth → 3（失败安全）
    const noTok = await run(
      ['--config-stdin', '--port', '0'],
      JSON.stringify({ groups: { cat: { members: [{ baseUrl: 'https://x/v1', model: 'm' }] } } }),
    );
    assert.equal(noTok.code, 3, `没令牌应该以 3 退出；stderr=${noTok.err}`);
  });

  test('validateConfig：token 从配置里读出来', () => {
    const cfg = proxy.validateConfig(
      JSON.stringify({
        token: 'the-token',
        groups: { cat: { members: [{ baseUrl: 'https://x/v1', model: 'm' }] } },
      }),
      '测试配置',
    );
    assert.equal(cfg.token, 'the-token');
    assert.equal(cfg.groups.cat.members[0].name, 'member1');
  });

  await testAsync('端到端：带对令牌 200 且能转发；不带/带错令牌 401', async () => {
    // 一个假的"上游"：只要被调到就回 200 + 固定 JSON。
    const https = await import('node:http');
    let upstreamHits = 0;
    const upstream = https.createServer((req, res) => {
      upstreamHits += 1;
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true, model: 'upstream' }));
    });
    await new Promise((r) => upstream.listen(0, '127.0.0.1', r));
    const upPort = upstream.address().port;

    const TOKEN = 'tok-' + Math.random().toString(16).slice(2);
    const dir = mkdtempSync(join(tmpdir(), 'rotate-'));
    const statePath = join(dir, 'state.json');
    const cfgJson = JSON.stringify({
      token: TOKEN,
      groups: {
        cat: {
          members: [
            { name: 'a', baseUrl: `http://127.0.0.1:${upPort}/v1`, apiKey: 'up-key', model: 'm' },
          ],
        },
      },
    });

    const child = spawn(
      process.execPath,
      [PROXY, '--config-stdin', '--state', statePath, '--port', '0'],
      { stdio: ['pipe', 'pipe', 'pipe'] },
    );
    child.stdin.write(cfgJson);
    child.stdin.end();

    let out = '';
    let err = '';
    child.stdout.on('data', (d) => { out += d.toString(); });
    child.stderr.on('data', (d) => { err += d.toString(); });

    // 等就绪行里的真实端口（这就是 Dart 侧做的事）
    const port = await new Promise((res, rej) => {
      const t = setTimeout(() => rej(new Error(`代理没就绪；stdout=${out} stderr=${err}`)), 10000);
      const check = () => {
        const m = /listening on http:\/\/127\.0\.0\.1:(\d+)/.exec(out);
        if (m) { clearTimeout(t); res(Number(m[1])); }
        else setTimeout(check, 50);
      };
      check();
    });

    assert.ok(port > 0, '真实端口应该是系统挑的（不是 argv 里的 0）');

    const call = (headers) =>
      fetch(`http://127.0.0.1:${port}/v1/chat/completions`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', ...headers },
        body: JSON.stringify({ model: 'cat', messages: [{ role: 'user', content: 'hi' }] }),
      });

    try {
      const noTok = await call({});
      assert.equal(noTok.status, 401, '不带令牌必须是 401');
      assert.equal(upstreamHits, 0, '未授权请求绝不能打到上游（那是花用户的 Key）');

      const badTok = await call({ authorization: 'Bearer wrong-token' });
      assert.equal(badTok.status, 401, '错令牌必须是 401');
      assert.equal(upstreamHits, 0);

      const ok = await call({ authorization: `Bearer ${TOKEN}` });
      assert.equal(ok.status, 200, `带对令牌应该 200；body=${await ok.text()}`);
      assert.equal(upstreamHits, 1, '带对令牌必须真的转发');

      // x-api-key 这条也要通（DSH 万一用那个头）
      const ok2 = await call({ 'x-api-key': TOKEN });
      assert.equal(ok2.status, 200);
      assert.equal(upstreamHits, 2);

      // /health 也要令牌 —— 否则它就是一个"免费探测这个端口是不是轮换代理"的信号
      const health = await fetch(`http://127.0.0.1:${port}/health`);
      assert.equal(health.status, 401, '/health 也必须鉴权');
    } finally {
      child.kill('SIGKILL');
      upstream.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  await testAsync('没有令牌又没 --no-auth：拒绝启动（失败安全，不能静默裸奔）', async () => {
    const child = spawn(process.execPath, [PROXY, '--config-stdin', '--port', '0'], {
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    child.stdin.write(JSON.stringify({
      groups: { cat: { members: [{ baseUrl: 'https://x/v1', model: 'm' }] } },
    }));
    child.stdin.end();
    let err = '';
    child.stderr.on('data', (d) => { err += d.toString(); });
    const code = await new Promise((r) => child.on('exit', r));
    assert.equal(code, 3, `应该以 3 退出；stderr=${err}`);
    assert.match(err, /令牌/, '错误信息要讲清"没令牌"这件事');
  });

  await testAsync('--token 作为兜底通路仍然可用（虽然不推荐：会进 cmdline）', async () => {
    const child = spawn(process.execPath, [PROXY, '--config-stdin', '--token', 'from-argv', '--port', '0'], {
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    child.stdin.write(JSON.stringify({
      groups: { cat: { members: [{ baseUrl: 'https://x/v1', model: 'm' }] } },
    }));
    child.stdin.end();
    let out = '';
    child.stderr.on('data', () => {});
    child.stdout.on('data', (d) => { out += d.toString(); });
    const port = await new Promise((res, rej) => {
      const t = setTimeout(() => rej(new Error('没就绪')), 10000);
      const check = () => {
        const m = /listening on http:\/\/127\.0\.0\.1:(\d+)/.exec(out);
        if (m) { clearTimeout(t); res(Number(m[1])); } else setTimeout(check, 50);
      };
      check();
    });
    try {
      const bad = await fetch(`http://127.0.0.1:${port}/health`);
      assert.equal(bad.status, 401);
      const good = await fetch(`http://127.0.0.1:${port}/health`, {
        headers: { authorization: 'Bearer from-argv' },
      });
      assert.equal(good.status, 200);
    } finally {
      child.kill('SIGKILL');
    }
  });

  await testAsync('--no-auth：显式关掉鉴权（调试通路），请求能通', async () => {
    const http = await import('node:http');
    const upstream = http.createServer((req, res) => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
    });
    await new Promise((r) => upstream.listen(0, '127.0.0.1', r));
    const upPort = upstream.address().port;

    const child = spawn(process.execPath, [PROXY, '--config-stdin', '--no-auth', '--port', '0'], {
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    child.stdin.write(JSON.stringify({
      groups: { cat: { members: [{ name: 'a', baseUrl: `http://127.0.0.1:${upPort}/v1`, model: 'm' }] } },
    }));
    child.stdin.end();
    let out = '';
    child.stdout.on('data', (d) => { out += d.toString(); });
    const port = await new Promise((res, rej) => {
      const t = setTimeout(() => rej(new Error('没就绪')), 10000);
      const check = () => {
        const m = /listening on http:\/\/127\.0\.0\.1:(\d+)/.exec(out);
        if (m) { clearTimeout(t); res(Number(m[1])); } else setTimeout(check, 50);
      };
      check();
    });
    try {
      const r = await fetch(`http://127.0.0.1:${port}/health`);
      assert.equal(r.status, 200);
    } finally {
      child.kill('SIGKILL');
      upstream.close();
    }
  });

  await testAsync('lastGood 只写状态文件，且**不含任何凭据**', async () => {
    const cfg = proxy.validateConfig(
      JSON.stringify({
        token: 't',
        groups: { cat: { members: [{ name: 'a', baseUrl: 'https://x/v1', model: 'm', apiKey: 'SECRET' }] } },
      }),
      '测试配置',
    );
    const dir = mkdtempSync(join(tmpdir(), 'rotate-state-'));
    cfg.statePath = join(dir, 'state.json');
    try {
      const sticky = proxy.makeSticky(cfg);
      sticky.set('cat', 0);
      const raw = readFileSync(cfg.statePath, 'utf8');
      assert.ok(!raw.includes('SECRET'), 'lastGood 状态文件里不该出现凭据');
      assert.ok(!raw.includes('https://x/v1'), 'lastGood 状态文件里不该出现配置');
      assert.deepEqual(JSON.parse(raw), { lastGood: { cat: 0 } });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // 守住"凭据不落盘"这条。注意**不能**简单搜 "rotate-config.json" ——
  // 那个名字还留着（注释里在解释"为什么不能写它"），搜它只会误报。
  // 这里断言的是**那次回归的精确形状**：旧的回写逻辑是把**整份 config**
  // （含各厂家真实 Key）读出来改个字段再写回去（`JSON.stringify(raw, ...)`）。
  test('代理源码不再把整份 config 回写（那次凭据落盘的形状）', () => {
    const src = readFileSync(PROXY, 'utf8');
    assert.ok(
      !/JSON\.stringify\(raw/.test(src),
      '又把整份配置写回磁盘了？Key 会落盘（P0-2 回归）',
    );
    assert.ok(/createHash|timingSafeEqual/.test(src), '等时比对不见了？（P0-3 回归）');
    assert.ok(/statePath/.test(src), 'lastGood 应该写到不含凭据的 statePath');
  });
}

// ─────────────────────────────── ffmpeg：prelude 里的 shell 函数（可选能力）

section('ffmpeg / ffprobe：shim 的 prelude 与"缺了不许拖累别的"');
{
  const shimPath = join(REPO, 'app/assets/toolbox/android-exec-shim.cjs');
  const SHIM_ENV = {
    DSH_ANDROID_NODE_BIN: '/data/app/lib/libnode.so',
    DSH_ANDROID_FS_SHIM: '/data/files/shims/android-fs-shim.cjs',
    DSH_ANDROID_EXEC_SHIM: '/data/files/toolbox/android-exec-shim.cjs',
    DSH_ANDROID_TMPDIR: '/data/files/tmp',
  };

  /** CFG 是"require 时"从 process.env 抓的，所以换环境必须清缓存重 require。 */
  function shimWith(env) {
    const saved = { ...process.env };
    for (const k of Object.keys(process.env)) delete process.env[k];
    Object.assign(process.env, env);
    try {
      delete require.cache[require.resolve(shimPath)];
      return require(shimPath);
    } finally {
      for (const k of Object.keys(process.env)) delete process.env[k];
      Object.assign(process.env, saved);
    }
  }

  await test('打进包了：prelude 定义 ffmpeg()/ffprobe() 并导出变量', () => {
    const shim = shimWith({
      ...SHIM_ENV,
      DSH_ANDROID_FFMPEG: '/data/app/lib/libffmpeg.so',
      DSH_ANDROID_FFPROBE: '/data/app/lib/libffprobe.so',
    });
    const pre = shim.buildPrelude();
    assert.match(pre, /ffmpeg\(\) \{ "\$DSH_ANDROID_FFMPEG" "\$@"; \}/,
      'prelude 必须定义 ffmpeg 函数 —— 技能脚本里直接写 `ffmpeg -i` 就走它');
    assert.match(pre, /ffprobe\(\) \{ "\$DSH_ANDROID_FFPROBE" "\$@"; \}/);
    assert.ok(pre.includes("DSH_ANDROID_FFMPEG='/data/app/lib/libffmpeg.so'"),
      '要导出绝对路径（认变量的代码用它）');
    assert.ok(pre.includes("AGNES_FFMPEG='/data/app/lib/libffmpeg.so'"),
      'AGNES_FFMPEG 是桌面插件认的名字，两边对齐');
  });

  await test('⚠️ 没打进包时：变量导出成空串，运行时不定义函数 —— 且**绝不许**把 shim 关掉', () => {
    const shim = shimWith(SHIM_ENV); // 故意不给 ffmpeg 变量
    assert.equal(shim.isActive(), true,
      'ffmpeg 是可选能力，缺了绝不能让 node 的改写也失效（那是最糟的连锁反应）');
    const pre = shim.buildPrelude();
    // 函数那行**带 `-n` 守卫**（`if [ -n "$DSH_ANDROID_FFMPEG" ]; then ffmpeg() …`）：
    // 文本总在，运行时才决定是否真的定义 —— 与 prelude 里 TMPDIR 那条同一个写法。
    assert.ok(pre.includes("DSH_ANDROID_FFMPEG=''"),
      '没打进包时变量必须是空串，守卫才不会定义函数（否则等于给一个指向空气的命令）');
    assert.match(pre, /if \[ -n "\$DSH_ANDROID_FFMPEG" \]; then ffmpeg\(\)/,
      '必须是"有才定义"的守卫形式，不是无条件定义');
  });

  await test('ffmpeg 变量随「改写后的命令 env」传下去（嵌套 shell 里函数还在）', () => {
    const shim = shimWith({
      ...SHIM_ENV,
      DSH_ANDROID_FFMPEG: '/data/app/lib/libffmpeg.so',
      DSH_ANDROID_FFPROBE: '/data/app/lib/libffprobe.so',
    });
    // shell:true 形态（DSH 的 bash 工具就是这条）会把 prelude + dshEnv 一起给出去
    const r = shim.rewriteCommand('bash -c "ffmpeg -version"', [], { shell: true });
    assert.ok(r, '应该被改写');
    assert.equal(r.env.DSH_ANDROID_FFMPEG, '/data/app/lib/libffmpeg.so');
    assert.equal(r.env.DSH_ANDROID_FFPROBE, '/data/app/lib/libffprobe.so');
  });
}

// ═══════════════════════════════════════════════════════════ 每个脚本的语法都得是好的

section('工具箱脚本：语法自检（node --check）');
{
  // ## 为什么要这一条（2026-10-11 的真实事故）
  //
  // 我给 `make-video.mjs` 的 `--help` 文本里加了一句带**反引号**的说明 ——
  // 而那段 help 本身就是**模板字符串**（反引号包的），于是反引号提前把字符串
  // 截断，整个脚本语法坏掉：手机上"生视频"会直接起不来。
  //
  // ⚠️ 当时 `flutter analyze` 全绿、**所有 Dart 测试全绿**（它们跑不到 node 脚本），
  // 只有 `install/test-agnes-429.mjs` 因为恰好 import 了这个脚本才炸出来。
  // 所以这里对**目录里每一个 .mjs** 都做一次 `node --check`：
  // 语法错在上手机之前就当场红，而不是等用户点了"生成视频"。
  const dir = join(REPO, 'app', 'assets', 'toolbox');
  const scripts = readdirSync(dir).filter((f) => f.endsWith('.mjs')).sort();
  assert.ok(scripts.length >= 6,
      `工具箱里应该有不少脚本，只找到 ${scripts.length} 个 —— 路径可能不对：${dir}`);
  for (const f of scripts) {
    test(`${f} 语法正确（node --check）`, () => {
      const r = spawnSync(process.execPath, ['--check', join(dir, f)], { encoding: 'utf8' });
      assert.equal(r.status, 0,
          `${f} 语法坏了：\n${(r.stderr || '').split('\n').slice(0, 6).join('\n')}`);
    });
  }
}

// ──────────────────────────────────────────────────────────────── 汇总

console.log(`\n${'='.repeat(64)}`);
if (failures.length) {
  console.log(`失败 ${failures.length} 项 / 通过 ${passed} 项`);
  for (const [name] of failures) console.log(`  · ${name}`);
  process.exit(1);
}
console.log(`全部通过（${passed} 项）`);
