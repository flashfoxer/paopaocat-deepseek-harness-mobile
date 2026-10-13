#!/usr/bin/env node
/**
 * 桥协议 · 断线恢复测试（确定性，需要 mock ACP）
 *
 * 覆盖两个真机上必然遇到、但很容易做错的场景：
 *
 *   场景 1 · seq 补拉
 *     App 断开期间 Agent 继续产出更新；重连后必须能按 lastSeq 补齐，
 *     且不重复、不跳号。
 *
 *   场景 2 · 审批补发
 *     审批请求产生时 App 不在线（后台/断线）—— 请求**不能**被静默丢弃，
 *     否则 DSH 只能干等超时自动拒绝，用户看到的是"命令莫名被拒"。
 *
 * 前置：桥运行在 BRIDGE_PORT（默认 8790，明文 ws 即可），DSH_BIN 指向 mock-acp-server.mjs
 */

const PORT = Number(process.env.BRIDGE_PORT ?? 8790);
const BASE = `http://127.0.0.1:${PORT}`;

let failed = false;
const fail = (m) => {
  console.error('[reconnect][FAIL]', m);
  failed = true;
};
const ok = (m) => console.log('[reconnect][ok]', m);
const log = (...a) => console.log('[reconnect]', ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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

/** 一个最小的测试客户端（与 App 说的同一套协议）。 */
class Client {
  constructor(ws) {
    this.ws = ws;
    this.seq = 0;
    this.frames = [];
    ws.addEventListener('message', (ev) => {
      try {
        this.frames.push(JSON.parse(ev.data.toString()));
      } catch {}
    });
  }

  static async connect(port = PORT) {
    const ws = new WebSocket(`ws://127.0.0.1:${port}`);
    await new Promise((resolve, reject) => {
      ws.addEventListener('open', () => resolve());
      ws.addEventListener('error', (e) => reject(new Error(`ws error: ${e.message}`)));
    });
    return new Client(ws);
  }

  send(type, payload = {}) {
    this.ws.send(JSON.stringify({ v: 1, type, id: `r${++this.seq}`, ...payload }));
  }

  async pair(code, deviceName) {
    const p = waitFor(this.ws, (m) => m.type === 'pair_ok', 10_000, 'pair_ok');
    this.send('pair', { code, deviceName });
    return p;
  }

  async hello(token) {
    const p = waitFor(this.ws, (m) => m.type === 'hello_ok', 10_000, 'hello_ok');
    this.send('hello', { deviceToken: token, client: { platform: 'test', appVersion: '0.1.0' } });
    return p;
  }

  wait(predicate, ms, label) {
    return waitFor(this.ws, predicate, ms, label, this.frames);
  }

  updates() {
    return this.frames.filter((m) => m.type === 'update');
  }

  lastSeq() {
    const seqs = this.updates().map((m) => m.seq);
    return seqs.length ? Math.max(...seqs) : 0;
  }

  close() {
    try {
      this.ws.close();
    } catch {}
  }
}

/** 自动应答审批（模拟用户点「仅本次允许」）。 */
function autoApprove(client) {
  const handler = (ev) => {
    const msg = JSON.parse(ev.data.toString());
    if (msg.type !== 'permission_request') return;
    client.send('permission_decision', {
      sessionId: msg.sessionId,
      requestId: msg.requestId,
      decision: 'allow_once',
    });
  };
  client.ws.addEventListener('message', handler);
  return () => client.ws.removeEventListener('message', handler);
}

async function main() {
  const health = await fetch(`${BASE}/health`).then((r) => r.json());
  if (health.agent?.name !== 'mock-acp') {
    fail(`期望 mock ACP，实际 ${health.agent?.name}`);
    return;
  }

  // 配对一次，后面所有连接复用这个 token（协议允许同一 token 多连接）
  const pairInfo = await fetch(`${BASE}/pair`).then((r) => r.json());
  const boot = await Client.connect();
  const paired = await boot.pair(pairInfo.code, 'reconnect-test');
  const token = paired.deviceToken;
  boot.close();
  await sleep(150);

  // ============================================================ 场景 1
  log('场景 1：断线期间的更新能否补拉');

  const a = await Client.connect();
  await a.hello(token);
  a.send('new_session', { cwd: health.cwd });
  const created = await a.wait((m) => m.type === 'session', 20_000, 'session');
  const sessionId = created.session.id;
  a.send('subscribe', { sessionId, fromSeq: 0 });
  await a.wait((m) => m.type === 'subscribed', 10_000, 'subscribed');

  const stopAutoApprove = autoApprove(a);
  a.send('prompt', { sessionId, text: 'turn one', clientMsgId: 'one' });
  await a.wait((m) => m.type === 'session_status' && m.state === 'idle', 60_000, 'idle#1');
  const seqAfterOne = a.lastSeq();
  if (seqAfterOne <= 0) fail('第一轮没有产生任何 update');
  else ok(`第一轮结束，lastSeq=${seqAfterOne}`);

  a.close();
  stopAutoApprove();
  await sleep(200);
  log('A 已断开');

  // 断开期间，由另一个连接驱动第二轮（模拟 Agent 继续工作）
  const b = await Client.connect();
  await b.hello(token);
  const stopAutoApproveB = autoApprove(b);
  b.send('prompt', { sessionId, text: 'turn two', clientMsgId: 'two' });

  // B 未订阅，应通过「无订阅者 → 广播」拿到审批请求
  let broadcastPermission = null;
  try {
    broadcastPermission = await b.wait((m) => m.type === 'permission_request', 30_000, 'broadcast permission');
    ok('无订阅者时审批被广播（不会静默丢弃）');
  } catch (e) {
    fail(`无订阅者时审批丢失：${e.message}`);
  }
  void broadcastPermission;

  await sleep(1200); // 让 mock 完成该轮并写入事件

  // 现在订阅并补拉：应拿到第二轮的全部事件
  b.send('subscribe', { sessionId, fromSeq: seqAfterOne });
  const subscribed = await b.wait((m) => m.type === 'subscribed', 10_000, 'subscribed#2');
  if (subscribed.needSnapshot) fail('不应需要快照（事件窗口远未溢出）');
  await sleep(300);

  const backfilled = b.updates().filter((m) => m.seq > seqAfterOne);
  const seqs = backfilled.map((m) => m.seq);
  log(`补拉到 ${backfilled.length} 条更新，seq = ${JSON.stringify(seqs)}`);

  if (backfilled.length === 0) {
    fail('断线期间产生的更新没有被补拉回来');
  } else {
    // 连续性：从 seqAfterOne+1 开始，逐个递增
    const expected = Array.from({ length: seqs.length }, (_, i) => seqAfterOne + 1 + i);
    const contiguous = seqs.every((s, i) => s === expected[i]);
    if (!contiguous) fail(`补拉的 seq 不连续：期望 ${expected[0]}..${expected[expected.length - 1]}，实际 ${JSON.stringify(seqs)}`);
    else ok(`补拉的 seq 连续且无重复（${seqs[0]}..${seqs[seqs.length - 1]}）`);

    const kinds = backfilled.map((m) => m.update.kind);
    if (!kinds.includes('tool_result')) fail(`补拉内容不完整，缺少 tool_result：${JSON.stringify(kinds)}`);
    else ok(`补拉内容完整：${JSON.stringify([...new Set(kinds)])}`);
  }

  stopAutoApproveB();
  b.close();
  await sleep(150);

  // ============================================================ 场景 2
  log('场景 2：审批请求在无人订阅时是否会被补发');

  const c = await Client.connect();
  await c.hello(token);
  c.send('new_session', { cwd: health.cwd });
  const created2 = await c.wait((m) => m.type === 'session', 20_000, 'session#2');
  const sessionId2 = created2.session.id;

  // 起一轮后**立刻断开**，让审批请求在无任何订阅者时产生
  c.send('prompt', { sessionId: sessionId2, text: 'turn three', clientMsgId: 'three' });
  await c.wait((m) => m.type === 'accepted', 10_000, 'accepted#3');
  c.close();
  await sleep(1500); // 期间 mock 会请求审批，但没有任何连接在线

  const d = await Client.connect();
  await d.hello(token);
  d.send('subscribe', { sessionId: sessionId2, fromSeq: 0 });

  let resent = null;
  try {
    resent = await d.wait((m) => m.type === 'permission_request', 15_000, 'resent permission');
    ok(`订阅时补发了未决审批（requestId=${resent.requestId}）`);
  } catch (e) {
    fail(`未决审批没有被补发：${e.message}`);
  }

  if (resent) {
    if (!resent.command) fail('补发的审批缺少 command');
    d.send('permission_decision', {
      sessionId: resent.sessionId,
      requestId: resent.requestId,
      decision: 'allow_once',
    });
    try {
      await d.wait((m) => m.type === 'permission_ack', 10_000, 'permission_ack');
      ok('补发的审批仍可被正常应答');
    } catch (e) {
      fail(`应答补发审批失败：${e.message}`);
    }
  }

  d.close();
  log(failed ? '存在失败项' : '断线恢复测试全部通过 ✓');
  process.exitCode = failed ? 1 : 0;
}

main().catch((err) => {
  fail(err.message);
  process.exit(1);
});
