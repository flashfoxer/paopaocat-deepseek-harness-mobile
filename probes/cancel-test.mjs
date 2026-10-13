#!/usr/bin/env node
/**
 * 桥协议 · 取消链路测试（确定性）
 *
 * 覆盖 objective 里的"取消"能力：
 *   App 发 cancel → 桥转发 ACP 通知 session/cancel → mock 以 stopReason=cancelled 结束
 *   → 桥把会话状态从 cancelling 推回 idle
 *
 * 前置：桥运行在 BRIDGE_PORT，且 DSH_BIN 指向 probes/mock-acp-server.mjs
 */

const PORT = Number(process.env.BRIDGE_PORT ?? 8790);
const BASE = `http://127.0.0.1:${PORT}`;

let failed = false;
const fail = (m) => {
  console.error('[cancel][FAIL]', m);
  failed = true;
};
const log = (...a) => console.log('[cancel]', ...a);
const ok = (m) => console.log('[cancel][ok]', m);

function connect(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    ws.addEventListener('open', () => resolve(ws));
    ws.addEventListener('error', (e) => reject(new Error(`ws error: ${e.message ?? 'unknown'}`)));
  });
}

function waitFor(ws, predicate, timeoutMs, label) {
  return new Promise((resolve, reject) => {
    const onMsg = (ev) => {
      const msg = JSON.parse(ev.data.toString());
      if (!predicate(msg)) return;
      clearTimeout(timer);
      ws.removeEventListener('message', onMsg);
      resolve(msg);
    };
    const timer = setTimeout(() => {
      ws.removeEventListener('message', onMsg);
      reject(new Error(`等待 ${label} 超时（${timeoutMs}ms）`));
    }, timeoutMs);
    ws.addEventListener('message', onMsg);
  });
}

async function main() {
  const health = await fetch(`${BASE}/health`).then((r) => r.json());
  if (health.agent?.name !== 'mock-acp') {
    fail(`期望 mock ACP，实际 ${health.agent?.name}（请用 DSH_BIN 指向 mock-acp-server.mjs）`);
    return;
  }

  const pairInfo = await fetch(`${BASE}/pair`).then((r) => r.json());
  const ws = await connect(`ws://127.0.0.1:${PORT}`);

  const states = [];
  ws.addEventListener('message', (ev) => {
    const msg = JSON.parse(ev.data.toString());
    if (msg.type === 'session_status') states.push(msg.state);
  });

  let seq = 0;
  const send = (type, payload = {}) => ws.send(JSON.stringify({ v: 1, type, id: `c${++seq}`, ...payload }));

  send('pair', { code: pairInfo.code, deviceName: 'cancel-test' });
  const paired = await waitFor(ws, (m) => m.type === 'pair_ok', 10_000, 'pair_ok');
  send('hello', { deviceToken: paired.deviceToken, client: { platform: 'test', appVersion: '0.1.0' } });
  const hello = await waitFor(ws, (m) => m.type === 'hello_ok', 10_000, 'hello_ok');

  send('new_session', { cwd: hello.host.cwd });
  const created = await waitFor(ws, (m) => m.type === 'session', 20_000, 'session');
  const sessionId = created.session.id;
  send('subscribe', { sessionId, fromSeq: 0 });
  await waitFor(ws, (m) => m.type === 'subscribed', 10_000, 'subscribed');

  // ---- 起一个不会自己结束的轮次 ----
  log('发送 slow prompt（mock 会一直等到 cancel）');
  send('prompt', { sessionId, text: 'slow turn please', clientMsgId: 'slow-1' });
  await waitFor(ws, (m) => m.type === 'accepted', 10_000, 'accepted');
  await waitFor(ws, (m) => m.type === 'session_status' && m.state === 'running', 15_000, 'running');
  ok('轮次进入 running');

  // ---- 取消 ----
  log('发送 cancel');
  send('cancel', { sessionId });

  try {
    await waitFor(ws, (m) => m.type === 'session_status' && m.state === 'cancelling', 15_000, 'cancelling');
    ok('桥已把状态推为 cancelling');
  } catch (e) {
    fail(e.message);
  }

  try {
    await waitFor(ws, (m) => m.type === 'session_status' && m.state === 'idle', 60_000, 'idle');
    ok('取消后回到 idle');
  } catch (e) {
    fail(`取消后未回到 idle：${e.message}`);
  }

  // ---- 断言状态序列 ----
  const indexRunning = states.indexOf('running');
  const indexCancelling = states.indexOf('cancelling');
  const indexIdle = states.lastIndexOf('idle');
  log('状态序列：', JSON.stringify(states));
  if (!(indexRunning >= 0 && indexCancelling > indexRunning && indexIdle > indexCancelling)) {
    fail(`状态顺序不对：running@${indexRunning} cancelling@${indexCancelling} idle@${indexIdle}`);
  }

  // ---- 取消后必须能继续发消息 ----
  log('取消后发一条普通消息，确认会话仍可用');
  send('prompt', { sessionId, text: 'turn after cancel', clientMsgId: 'after-1' });
  try {
    await waitFor(ws, (m) => m.type === 'accepted', 10_000, 'accepted(2)');
    ok('取消后仍可发送新消息');
  } catch (e) {
    fail(`取消后无法继续：${e.message}`);
  }

  send('close_session', { sessionId });
  await waitFor(ws, (m) => m.type === 'closed', 20_000, 'closed').catch(() => {});
  ws.close();

  log(failed ? '存在失败项' : '取消链路测试通过 ✓');
  process.exitCode = failed ? 1 : 0;
}

main().catch((err) => {
  fail(err.message);
  process.exit(1);
});
