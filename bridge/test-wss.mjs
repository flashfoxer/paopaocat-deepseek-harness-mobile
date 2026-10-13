#!/usr/bin/env node
/**
 * wss 验证：桥在 TLS 下工作，且**未受信任的客户端会被拒绝**。
 *
 * 用法（桥必须在 BRIDGE_PORT 运行，且 tls/bridge.pfx 存在）：
 *   node bridge/test-wss.mjs
 *
 * 验证三件事：
 *   1. /health 报告的 protocol 是 wss 且带证书指纹；
 *   2. 用该证书作 CA 能连上，并且在 wss 下配对/握手等协议帧工作正常；
 *   3. 不提供 CA 时连接**必须失败** —— 否则说明 TLS 形同虚设。
 */

import { readFileSync } from 'node:fs';
import https from 'node:https';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocket } from 'ws';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CERT_PATH = path.join(HERE, 'tls', 'bridge-cert.pem');
const FP_PATH = path.join(HERE, 'tls', 'fingerprint.txt');

const PORT = Number(process.env.BRIDGE_PORT ?? 8790);
const BASE = `http://127.0.0.1:${PORT}`;

let failed = false;
const fail = (m) => {
  console.error('[wss][FAIL]', m);
  failed = true;
};
const ok = (m) => console.log('[wss][ok]', m);

function waitFor(ws, predicate, ms, label) {
  return new Promise((resolve, reject) => {
    const onMsg = (data) => {
      const msg = JSON.parse(data.toString());
      if (!predicate(msg)) return;
      clearTimeout(timer);
      ws.off('message', onMsg);
      resolve(msg);
    };
    const timer = setTimeout(() => {
      ws.off('message', onMsg);
      reject(new Error(`等待 ${label} 超时（${ms}ms）`));
    }, ms);
    ws.on('message', onMsg);
  });
}

function open(url, options, ms = 8000) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, options);
    const timer = setTimeout(() => reject(new Error('open timeout')), ms);
    ws.on('open', () => {
      clearTimeout(timer);
      resolve(ws);
    });
    ws.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

/** wss 模式下管理端点也是 https（自签证书），因此这里要显式带上 ca。 */
function adminGet(port, pathname, ca) {
  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        host: '127.0.0.1',
        port,
        path: pathname,
        method: 'GET',
        ca,
        // 证书 SAN 里 127.0.0.1 被记为 DNS 项，而我们的安全模型是「pin 指纹」，
        // 因此跳过主机名校验、依靠 ca + 指纹 —— 与 App 侧做法一致。
        checkServerIdentity: () => undefined,
      },
      (res) => {
        let data = '';
        res.setEncoding('utf8');
        res.on('data', (chunk) => (data += chunk));
        res.on('end', () => {
          try {
            resolve(JSON.parse(data));
          } catch (err) {
            reject(err);
          }
        });
      },
    );
    req.on('error', reject);
    req.end();
  });
}

async function main() {
  const ca = readFileSync(CERT_PATH);
  const expectedFp = readFileSync(FP_PATH, 'utf8').trim();

  // ---- 1. health 报告 ----
  const health = await adminGet(PORT, '/health', ca);
  if (health.protocol !== 'wss') fail(`/health 报告 protocol=${health.protocol}，期望 wss`);
  else ok('健康检查确认协议为 wss');

  if (!health.fingerprint) fail('/health 未返回证书指纹');
  else if (health.fingerprint !== expectedFp) fail(`指纹不一致：health=${health.fingerprint} file=${expectedFp}`);
  else ok(`指纹一致：${health.fingerprint.slice(0, 23)}…`);

  // ---- 2. 受信任连接应成功，且协议正常 ----
  let ws;
  try {
    ws = await open(`wss://127.0.0.1:${PORT}`, { ca, checkServerIdentity: () => undefined });
    ok('用证书作 CA 连接成功');
  } catch (err) {
    fail(`受信任连接失败：${err.message}`);
    return;
  }

  const pairInfo = await adminGet(PORT, '/pair', ca);
  if (pairInfo.protocol !== 'wss') fail(`/pair 未返回 protocol=wss：${pairInfo.protocol}`);
  if (!pairInfo.fingerprint) fail('/pair 未返回指纹（App 配对时无法 pin）');
  else ok('/pair 带上了协议与指纹');

  let seq = 0;
  const send = (type, payload = {}) => ws.send(JSON.stringify({ v: 1, type, id: `w${++seq}`, ...payload }));

  send('pair', { code: pairInfo.code, deviceName: 'wss-test' });
  const paired = await waitFor(ws, (m) => m.type === 'pair_ok', 10_000, 'pair_ok');
  send('hello', { deviceToken: paired.deviceToken, client: { platform: 'test', appVersion: '0.1.0' } });
  const hello = await waitFor(ws, (m) => m.type === 'hello_ok', 10_000, 'hello_ok');
  ok(`wss 下协议正常（host=${hello.host.name}）`);
  ws.close();

  // ---- 3. 未受信任的连接必须被拒绝 ----
  try {
    const rogue = await open(`wss://127.0.0.1:${PORT}`, {});
    rogue.close();
    fail('未提供 CA 也能连上 —— TLS 没有起到鉴权作用');
  } catch {
    ok('未受信任的客户端被正确拒绝（TLS 生效）');
  }

  console.log(failed ? '\n[wss] 存在失败项' : '\n[wss] wss 验证通过 ✓');
  process.exitCode = failed ? 1 : 0;
}

main().catch((err) => {
  fail(err.message);
  process.exit(1);
});
