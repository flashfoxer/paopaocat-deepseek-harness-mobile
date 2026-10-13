#!/usr/bin/env node
/**
 * 桥 · DSH 崩溃自动重启测试（确定性，需要 mock ACP）
 *
 * 真机上这件事一定会发生（用户手动结束、DSH 自身出错、内存不足）。
 * 桥必须：检测到子进程 exit → 通知 App → 指数退避重启 → 恢复可用。
 *
 * 前置：桥运行在 BRIDGE_PORT（默认 8790），DSH_BIN 指向 mock-acp-server.mjs
 */

const PORT = Number(process.env.BRIDGE_PORT ?? 8790);
const BASE = `http://127.0.0.1:${PORT}`;

let failed = false;
const fail = (m) => {
  console.error('[crash][FAIL]', m);
  failed = true;
};
const ok = (m) => console.log('[crash][ok]', m);
const log = (...a) => console.log('[crash]', ...a);

function waitFor(ws, predicate, ms, label, stash) {
  return new Promise((resolve, reject) => {
    const onMsg = (ev) => {
      const msg = JSON.parse(ev.data.toString());
      stash?.push(msg);
      if (!predicate(msg)) return;
      clearTimeout(timer);
      ws.removeEventListener('message', onMsg);
      resolve(msg);
    };
    const timer = setTimeout(() => {
      ws.removeEventListener('message', onMsg);
      reject(new Error(`等待 ${label} 超时（${ms}ms）`));
    }, ms);
    ws.addEventListener('message', onMsg);
  });
}

async function main() {
  const before = await fetch(`${BASE}/health`).then((r) => r.json());
  if (before.agent?.name !== 'mock-acp') {
    fail(`期望 mock ACP，实际 ${before.agent?.name}`);
    return;
  }

  const pairInfo = await fetch(`${BASE}/pair`).then((r) => r.json());
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
  await new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve);
    ws.addEventListener('error', (e) => reject(new Error(e.message)));
  });

  const frames = [];
  ws.addEventListener('message', (ev) => {
    try {
      frames.push(JSON.parse(ev.data.toString()));
    } catch {}
  });

  let seq = 0;
  const send = (type, payload = {}) => ws.send(JSON.stringify({ v: 1, type, id: `c${++seq}`, ...payload }));

  send('pair', { code: pairInfo.code, deviceName: 'crash-test' });
  const paired = await waitFor(ws, (m) => m.type === 'pair_ok', 10_000, 'pair_ok', frames);
  send('hello', { deviceToken: paired.deviceToken, client: { platform: 'test', appVersion: '0.1.0' } });
  await waitFor(ws, (m) => m.type === 'hello_ok', 10_000, 'hello_ok', frames);

  send('new_session', { cwd: before.cwd });
  const created = await waitFor(ws, (m) => m.type === 'session', 20_000, 'session', frames);
  const sessionId = created.session.id;
  send('subscribe', { sessionId, fromSeq: 0 });
  await waitFor(ws, (m) => m.type === 'subscribed', 10_000, 'subscribed', frames);
  ok('连接与订阅就绪');

  // ---- 触发崩溃 ----
  log('发送 crash 指令，让 DSH 子进程退出…');
  const sawFailed = waitFor(
    ws,
    (m) => m.type === 'bridge_status' && (m.dsh === 'failed' || m.dsh === 'restarting'),
    20_000,
    'bridge_status(failed/restarting)',
    frames,
  );
  send('prompt', { sessionId, text: 'crash now please', clientMsgId: 'crash' });

  try {
    const msg = await sawFailed;
    ok(`桥在 DSH 退出后通知了 App：dsh=${msg.dsh}`);
  } catch (e) {
    fail(`DSH 崩溃后桥没有通知 App：${e.message}`);
  }

  // ---- 等自动重启完成 ----
  try {
    const revived = await waitFor(ws, (m) => m.type === 'bridge_status' && m.dsh === 'running', 60_000, 'dsh running', frames);
    ok(`桥已自动恢复：dsh=${revived.dsh}`);
  } catch (e) {
    fail(`桥没有自动恢复：${e.message}`);
  }

  // ---- 重启后桥必须真的可用（新会话）----
  send('new_session', { cwd: before.cwd });
  try {
    const created2 = await waitFor(ws, (m) => m.type === 'session', 30_000, 'session after restart', frames);
    ok(`重启后可正常建会话（${created2.session.id}）`);
  } catch (e) {
    fail(`重启后桥不可用：${e.message}`);
  }

  // ---- health 应回到 running ----
  const after = await fetch(`${BASE}/health`).then((r) => r.json());
  if (after.dsh !== 'running') fail(`health 显示 dsh=${after.dsh}，期望 running`);
  else ok('health 端点的 dsh 状态已回到 running');

  const statuses = frames.filter((m) => m.type === 'bridge_status').map((m) => m.dsh);
  log('收到的 bridge_status 序列：', JSON.stringify(statuses));

  ws.close();
  log(failed ? '存在失败项' : 'DSH 崩溃重启测试通过 ✓');
  process.exitCode = failed ? 1 : 0;
}

main().catch((err) => {
  fail(err.message);
  process.exit(1);
});
