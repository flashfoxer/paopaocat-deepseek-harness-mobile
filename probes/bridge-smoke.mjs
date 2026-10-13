#!/usr/bin/env node
/**
 * 桥的端到端冒烟测试：扮演 App，走一遍桥协议 v1 的主路径。
 *
 * 前置：桥已在运行（node src/bridge.mjs serve）
 * 用法：node probes/bridge-smoke.mjs
 */

const PORT = Number(process.env.BRIDGE_PORT ?? 8788);
const BASE = `http://127.0.0.1:${PORT}`;
const CWD = process.env.PROBE_CWD ?? 'C:\\Users\\25894\\dsh-mobile-sandbox';

const log = (...a) => console.log('[smoke]', ...a);
const fail = (msg) => {
  console.error('[smoke][FAIL]', msg);
  process.exitCode = 1;
};

function connect(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    ws.addEventListener('open', () => resolve(ws));
    ws.addEventListener('error', (e) => reject(new Error(`ws error: ${e.message ?? 'unknown'}`)));
  });
}

function once(ws, type, timeoutMs) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`等待 ${type} 超时（${timeoutMs}ms）`)), timeoutMs);
    const onMsg = (ev) => {
      const msg = JSON.parse(ev.data.toString());
      if (msg.type !== type) return;
      clearTimeout(timer);
      ws.removeEventListener('message', onMsg);
      resolve(msg);
    };
    ws.addEventListener('message', onMsg);
  });
}

/** 等待满足谓词的第一条消息（用于区分 running / idle）。 */
function waitFor(ws, predicate, timeoutMs) {
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
      reject(new Error(`等待条件超时（${timeoutMs}ms）`));
    }, timeoutMs);
    ws.addEventListener('message', onMsg);
  });
}

async function main() {
  // 1. 取配对码
  const pairInfo = await fetch(`${BASE}/pair`).then((r) => r.json());
  log('配对码', pairInfo.code, '工作目录', pairInfo.cwd);

  const ws = await connect(`ws://127.0.0.1:${PORT}`);
  const incoming = [];
  ws.addEventListener('message', (ev) => {
    const msg = JSON.parse(ev.data.toString());
    incoming.push(msg);
    if (msg.type !== 'update' && msg.type !== 'pong') log('←', msg.type, JSON.stringify(msg).slice(0, 160));
  });

  let seq = 0;
  const send = (type, payload = {}) => {
    const id = `c${++seq}`;
    ws.send(JSON.stringify({ v: 1, type, id, ...payload }));
    return id;
  };

  // 2. 配对
  send('pair', { code: pairInfo.code, deviceName: 'smoke-test' });
  const paired = await once(ws, 'pair_ok', 10_000);
  log('配对成功 deviceId =', paired.deviceId);

  // 3. 握手
  send('hello', { deviceToken: paired.deviceToken, client: { platform: 'smoke', appVersion: '0.1.0' } });
  const hello = await once(ws, 'hello_ok', 10_000);
  log('握手成功 host =', JSON.stringify(hello.host), '会话数 =', hello.sessions.length);

  // 4. 新建会话
  send('new_session', { cwd: CWD });
  const created = await once(ws, 'session', 60_000);
  const sessionId = created.session.id;
  log('新会话', sessionId, '配置项 =', (created.session.configOptions ?? []).map((o) => o.id).join(','));

  // 5. 订阅
  send('subscribe', { sessionId, fromSeq: 0 });
  const sub = await once(ws, 'subscribed', 10_000);
  log('订阅成功 fromSeq =', sub.fromSeq, 'toSeq =', sub.toSeq);

  // 6. 发一条消息
  const before = incoming.length;
  send('prompt', { sessionId, text: '只回答两个字：收到', clientMsgId: 'smoke-1' });
  const accepted = await once(ws, 'accepted', 10_000);
  log('已入队 clientMsgId =', accepted.clientMsgId);

  // 7. 等 idle —— 注意 running 状态也会先到，必须等到 state === 'idle'
  const idle = await waitFor(ws, (m) => m.type === 'session_status' && m.state === 'idle', 180_000).catch((e) => {
    fail(`未等到 idle：${e.message}`);
    return null;
  });
  if (idle) log('轮次结束状态 =', idle.state);

  const updates = incoming.slice(before).filter((m) => m.type === 'update');
  log(`本轮收到 ${updates.length} 条 update：`);
  for (const u of updates) {
    const text = u.update.text ? ` text="${u.update.text.slice(0, 40)}"` : '';
    console.log(`   seq=${u.seq} kind=${u.update.kind}${text}`);
  }
  if (!updates.some((u) => u.update.kind === 'message')) fail('没有收到 kind=message 的 update');

  // 8. 关闭会话
  send('close_session', { sessionId });
  const closed = await once(ws, 'closed', 30_000).catch(() => null);
  if (closed) log('会话已关闭', closed.sessionId);
  else fail('关闭会话超时');

  ws.close();
  log(process.exitCode ? '完成（有失败项）' : '全部通过 ✓');
}

main().catch((err) => {
  fail(err.message);
  process.exit(1);
});
