#!/usr/bin/env node
/**
 * 桥协议 · 权限审批链路测试（确定性）
 *
 * 覆盖：
 *  ① 批准（allow_once）           → 工具执行成功
 *  ② 拒绝（reject_once）          → 工具被拒，模型收到拒绝结果
 *  ③ 会话级允许（allow_session）  → 工具执行成功，且桥记住该命令
 *  ④ 再发同一命令                 → 桥**不再**询问，直接放行（走记忆）
 *
 * 关键断言：
 *  - 审批请求里必须带 command（桥要能从 toolCallId 回查 ACP 的 rawInput，
 *    否则 App 只能看到"有个操作要批准"而不知道是什么——审批就形同虚设）
 *  - riskFlags 必须标出破坏性命令
 *  - permission_decision 必须被回执（permission_ack）
 *
 * 前置：桥运行在 BRIDGE_PORT（默认 8788），且 DSH_BIN 指向 probes/mock-acp-server.mjs
 */

const PORT = Number(process.env.BRIDGE_PORT ?? 8788);
const BASE = `http://127.0.0.1:${PORT}`;

let failed = false;
const fail = (m) => {
  console.error('[perm][FAIL]', m);
  failed = true;
};
const log = (...a) => console.log('[perm]', ...a);
const ok = (m) => console.log('[perm][ok]', m);

function connect(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    ws.addEventListener('open', () => resolve(ws));
    ws.addEventListener('error', (e) => reject(new Error(`ws error: ${e.message ?? 'unknown'}`)));
  });
}

function withTimeout(promise, ms, label) {
  return Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error(`等待 ${label} 超时（${ms}ms）`)), ms)),
  ]);
}

function waitFor(ws, predicate, timeoutMs, label) {
  return withTimeout(
    new Promise((resolve) => {
      const onMsg = (ev) => {
        const msg = JSON.parse(ev.data.toString());
        if (!predicate(msg)) return;
        ws.removeEventListener('message', onMsg);
        resolve(msg);
      };
      ws.addEventListener('message', onMsg);
    }),
    timeoutMs,
    label,
  );
}

async function main() {
  const health = await fetch(`${BASE}/health`).then((r) => r.json());
  log(`桥 cwd=${health.cwd}`);
  log(`agent=${JSON.stringify(health.agent)}`);
  if (health.dsh !== 'running') {
    fail(`DSH 不在 running：${health.dsh}（确认 DSH_BIN 指向 mock-acp-server.mjs）`);
    return;
  }
  if (health.agent?.name !== 'mock-acp') {
    fail(`期望连到 mock ACP，实际是 ${health.agent?.name}（请用 DSH_BIN 指向 mock-acp-server.mjs 重启桥）`);
    return;
  }

  const pairInfo = await fetch(`${BASE}/pair`).then((r) => r.json());
  const ws = await connect(`ws://127.0.0.1:${PORT}`);

  let sessionId = null;
  const permissionQueue = [];
  const updateQueue = [];
  let permissionWaiter = null;
  let idleWaiter = null;

  ws.addEventListener('message', (ev) => {
    const msg = JSON.parse(ev.data.toString());

    if (msg.type === 'permission_request') {
      if (permissionWaiter) {
        const r = permissionWaiter;
        permissionWaiter = null;
        r(msg);
      } else {
        permissionQueue.push(msg);
      }
      return;
    }
    if (msg.type === 'update' && msg.sessionId === sessionId) {
      updateQueue.push(msg.update);
      return;
    }
    if (msg.type === 'session_status' && msg.state === 'idle') {
      if (idleWaiter) {
        const r = idleWaiter;
        idleWaiter = null;
        r(msg);
      }
    }
  });

  let seq = 0;
  const send = (type, payload = {}) => ws.send(JSON.stringify({ v: 1, type, id: `t${++seq}`, ...payload }));

  const nextPermission = (ms) =>
    permissionQueue.length
      ? Promise.resolve(permissionQueue.shift())
      : withTimeout(new Promise((r) => (permissionWaiter = r)), ms, 'permission_request');

  const nextIdle = (ms) => withTimeout(new Promise((r) => (idleWaiter = r)), ms, 'idle');

  // ---- 握手 ----
  send('pair', { code: pairInfo.code, deviceName: 'permission-test' });
  const paired = await waitFor(ws, (m) => m.type === 'pair_ok', 10_000, 'pair_ok');
  send('hello', { deviceToken: paired.deviceToken, client: { platform: 'test', appVersion: '0.1.0' } });
  const hello = await waitFor(ws, (m) => m.type === 'hello_ok', 10_000, 'hello_ok');

  // ---- 建会话 + 订阅 ----
  send('new_session', { cwd: hello.host.cwd });
  const created = await waitFor(ws, (m) => m.type === 'session', 20_000, 'session');
  sessionId = created.session.id;
  send('subscribe', { sessionId, fromSeq: 0 });
  await waitFor(ws, (m) => m.type === 'subscribed', 10_000, 'subscribed');

  // ---- 单轮执行辅助 ----
  async function runTurn({ decision, expectPermission, label }) {
    updateQueue.length = 0;
    permissionQueue.length = 0;
    const idlePromise = nextIdle(60_000);
    const permissionPromise = nextPermission(60_000).catch(() => null);

    send('prompt', { sessionId, text: `mock turn: ${label}`, clientMsgId: `turn-${label}` });
    await waitFor(ws, (m) => m.type === 'accepted', 10_000, 'accepted');

    const permission = await permissionPromise;
    let ack = null;

    if (expectPermission) {
      if (!permission) {
        fail(`[${label}] 期望收到 permission_request，但没有`);
      } else {
        if (!permission.command) fail(`[${label}] 审批请求缺少 command（App 无法展示要执行什么）`);
        if (!permission.options?.length) fail(`[${label}] 审批请求缺少 options`);
        if (!permission.requestId) fail(`[${label}] 审批请求缺少 requestId`);

        const expectedFlags = ['destructive'];
        const hasDestructive = (permission.riskFlags ?? []).includes('destructive');
        if (!hasDestructive) fail(`[${label}] riskFlags 未标记 destructive：${JSON.stringify(permission.riskFlags)}（期望含 ${expectedFlags}）`);

        send('permission_decision', { sessionId, requestId: permission.requestId, decision });
        ack = await waitFor(ws, (m) => m.type === 'permission_ack', 15_000, 'permission_ack').catch((e) => {
          fail(`[${label}] 未收到 permission_ack：${e.message}`);
          return null;
        });
      }
    } else if (permission) {
      fail(`[${label}] 不应再询问审批，却收到了 requestId=${permission.requestId}`);
    }

    try {
      await idlePromise;
    } catch (e) {
      fail(`[${label}] ${e.message}`);
    }

    const toolResults = updateQueue.filter((u) => u.kind === 'tool_result');
    return { permission, ack, toolResults, updates: [...updateQueue] };
  }

  // ---- ① 批准 ----
  log('① allow_once');
  {
    const r = await runTurn({ decision: 'allow_once', expectPermission: true, label: 'allow-once' });
    const output = r.toolResults.map((t) => t.output).join('|');
    if (!output.includes('mock-executed')) fail(`① 批准后工具未执行成功，output=${JSON.stringify(output)}`);
    else ok(`批准路径通过（command=${JSON.stringify(r.permission?.command)}，riskFlags=${JSON.stringify(r.permission?.riskFlags)}，status=${r.toolResults[0]?.status}）`);

    const stored = r.permission?.command;
    if (stored) globalThis.__mockCommand = stored;
  }

  // ---- ② 拒绝 ----
  log('② reject_once');
  {
    const r = await runTurn({ decision: 'reject_once', expectPermission: true, label: 'reject' });
    const output = r.toolResults.map((t) => t.output).join('|');
    if (!output.includes('mock-rejected-by-user')) fail(`② 拒绝后 mock 未收到拒绝，output=${JSON.stringify(output)}`);
    else ok(`拒绝路径通过（status=${r.toolResults[0]?.status}）`);
  }

  // ---- ③ 会话级允许 ----
  log('③ allow_session');
  {
    const r = await runTurn({ decision: 'allow_session', expectPermission: true, label: 'allow-session' });
    if (r.ack?.applied !== true) fail('③ permission_ack.applied 不为 true');
    const output = r.toolResults.map((t) => t.output).join('|');
    if (!output.includes('mock-executed')) fail(`③ 会话级允许后工具未执行成功，output=${JSON.stringify(output)}`);
    else ok('会话级允许路径通过');
  }

  // ---- ④ 记忆生效：同一命令不再询问 ----
  log('④ 再发同一命令（期望桥走记忆，不再询问）');
  {
    const r = await runTurn({ decision: 'allow_once', expectPermission: false, label: 'remembered' });
    const output = r.toolResults.map((t) => t.output).join('|');
    if (!output.includes('mock-executed')) fail(`④ 记忆放行后工具未执行，output=${JSON.stringify(output)}`);
    else ok('会话级记忆放行通过（未再次弹审批）');
  }

  send('close_session', { sessionId });
  await waitFor(ws, (m) => m.type === 'closed', 30_000, 'closed').catch(() => fail('关闭会话超时'));
  ws.close();

  log(failed ? '存在失败项' : '审批链路全部通过 ✓');
  process.exitCode = failed ? 1 : 0;
}

main().catch((err) => {
  fail(err.message);
  process.exit(1);
});
