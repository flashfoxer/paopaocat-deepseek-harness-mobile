#!/usr/bin/env node
/**
 * dsh-mobile-bridge · CLI 入口
 *
 *   node src/bridge.mjs serve              启动桥（常驻）
 *   node src/bridge.mjs pair               生成一次性配对码（需 serve 在跑）
 *   node src/bridge.mjs health             查看桥/DSH 状态
 *   node src/bridge.mjs devices            列出已配对设备
 *   node src/bridge.mjs revoke <deviceId>  吊销某台设备
 *   node src/bridge.mjs revoke-all         吊销全部设备
 */

import { existsSync, readFileSync } from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { AcpClient } from './acp-client.mjs';
import { BridgeServer } from './server.mjs';
import { Store } from './store.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const BRIDGE_DIR = path.resolve(HERE, '..');

function loadConfig() {
  const file = path.join(BRIDGE_DIR, 'config.json');
  let cfg = {};
  if (existsSync(file)) {
    try {
      cfg = JSON.parse(readFileSync(file, 'utf8'));
    } catch (err) {
      console.error(`[bridge] config.json 解析失败：${err.message}（改用默认值）`);
    }
  }
  return {
    dshBin: process.env.DSH_BIN ?? cfg.dshBin ?? 'D:/Programs/PaopaocatDSH/app/lib/bin.js',
    cwd: process.env.DSH_MOBILE_CWD ?? cfg.cwd ?? process.cwd(),
    permissionMode: cfg.permissionMode ?? process.env.DSH_PERMISSION_MODE ?? 'workspace-write',
    host: process.env.DSH_MOBILE_HOST ?? cfg.host ?? '127.0.0.1',
    port: Number(process.env.DSH_MOBILE_PORT ?? cfg.port ?? 8788),
    patches: cfg.patches ?? [path.join(BRIDGE_DIR, 'acp-model.overlay.yml')],
    hostName: cfg.hostName ?? os.hostname(),
    dataDir: cfg.dataDir ?? path.join(BRIDGE_DIR, 'data'),
    // TLS：bridge/tls/bridge.pfx 存在即启用 wss（用 install/gen-tls-cert.ps1 生成）。
    // DSH_MOBILE_TLS=0 可强制回退到明文 ws —— 仅建议在 Tailscale 这类已加密的私有网络里这么做。
    tls: process.env.DSH_MOBILE_TLS === '0' ? null : (cfg.tls ?? {
      pfxPath: process.env.DSH_MOBILE_TLS_PFX ?? path.join(BRIDGE_DIR, 'tls', 'bridge.pfx'),
      pfxPassword: process.env.DSH_MOBILE_TLS_PASSWORD ?? 'dsh-mobile-bridge',
      fingerprintPath: path.join(BRIDGE_DIR, 'tls', 'fingerprint.txt'),
    }),
  };
}

/**
 * 管理端点请求。
 *
 * 桥在 wss 模式下主 server 是 https（自签证书），在 ws 模式下是 http，
 * 而 CLI 事先并不知道是哪种，所以两种协议都试一遍。
 * 只连 127.0.0.1，因此忽略自签证书是可接受的（数据不出本机）。
 */
function requestOnce(mod, port, pathname) {
  return new Promise((resolve, reject) => {
    const req = mod.request(
      {
        host: '127.0.0.1',
        port,
        path: pathname,
        method: 'GET',
        timeout: 4000,
        rejectUnauthorized: false,
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
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    req.end();
  });
}

async function adminGet(config, pathname) {
  const errors = [];
  for (const mod of [https, http]) {
    const label = mod === https ? 'https' : 'http';
    try {
      const body = await requestOnce(mod, config.port, pathname);
      return { ok: true, status: 200, body, scheme: label };
    } catch (err) {
      errors.push(`${label}: ${err.message}`);
    }
  }
  return { ok: false, status: 0, body: null, error: errors.join(' | ') };
}

function lanHint() {
  const nets = os.networkInterfaces();
  const out = [];
  for (const [name, addrs] of Object.entries(nets)) {
    for (const a of addrs ?? []) {
      if (a.family === 'IPv4' && !a.internal) out.push(`${name}: ${a.address}`);
    }
  }
  return out;
}

async function cmdServe() {
  const config = loadConfig();
  const store = new Store(config.dataDir);
  const acp = new AcpClient({
    dshBin: config.dshBin,
    profile: 'acp',
    patches: config.patches,
    cwd: config.cwd,
    permissionMode: config.permissionMode,
  });
  const server = new BridgeServer({ acp, store, config, log: console.log });

  await server.start();
  console.log('\n================ DSH Mobile Bridge ================');
  console.log(`工作目录     : ${config.cwd}`);
  console.log(`权限模式     : ${config.permissionMode}（workspace-write 才有手机端审批）`);
  console.log(`监听地址     : ${server.protocol}://${config.host}:${config.port}`);
  if (server.fingerprint) console.log(`证书指纹     : ${server.fingerprint}`);
  for (const line of lanHint()) console.log(`  可用网卡   : ${line}`);
  console.log(`管理端点     : ${server.protocol === 'wss' ? 'https' : 'http'}://127.0.0.1:${config.port}/health （仅本机）`);
  console.log('---------------------------------------------------');
  console.log('下一步：另开一个终端运行  node src/bridge.mjs pair');
  console.log('===================================================\n');

  const shutdown = async () => {
    console.log('\n[bridge] 正在关闭…');
    await server.stop();
    process.exit(0);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

async function cmdPair() {
  const config = loadConfig();
  const res = await adminGet(config, '/pair');
  if (!res.ok) {
    console.error(`无法连接桥（${res.error ?? res.status}）。请先启动：node src/bridge.mjs serve`);
    process.exit(1);
  }
  const { code, ttlSeconds, host, port, cwd, protocol, fingerprint } = res.body;
  console.log('\n================ 手机配对 ================');
  console.log(`配对码   : ${code}`);
  console.log(`有效期   : ${ttlSeconds} 秒（一次性）`);
  console.log(`服务器   : ${protocol}://${host}:${port}`);
  console.log(`工作目录 : ${cwd}`);
  if (fingerprint) console.log(`证书指纹 : ${fingerprint}`);
  console.log('------------------------------------------');
  console.log('在 App 里填：');
  console.log(`  地址 ${host} / 端口 ${port} / 协议 ${protocol} / 配对码 ${code}`);
  if (fingerprint) console.log(`  证书指纹 ${fingerprint}`);
  console.log('------------------------------------------');
  console.log('或粘贴下面这行 URI 一键填入：');
  const fpParam = fingerprint ? `&fp=${encodeURIComponent(fingerprint)}` : '';
  console.log(`  dsh-mobile://pair?host=${host}&port=${port}&code=${code}&protocol=${protocol}${fpParam}&v=1`);
  console.log('==========================================\n');
}

async function cmdHealth() {
  const config = loadConfig();
  const res = await adminGet(config, '/health');
  if (!res.ok) {
    console.error(`桥未运行（${res.error ?? res.status}）`);
    process.exit(1);
  }
  console.log(JSON.stringify(res.body, null, 2));
}

async function cmdDevices() {
  const config = loadConfig();
  const res = await adminGet(config, '/devices');
  if (!res.ok) {
    console.error(`桥未运行（${res.error ?? res.status}）`);
    process.exit(1);
  }
  const devices = res.body.devices ?? [];
  if (!devices.length) return console.log('还没有已配对的设备。');
  for (const d of devices) {
    console.log(`${d.revoked ? '[已吊销]' : '[有效]  '} ${d.deviceId}  ${d.name}  最后连接=${d.lastSeenAt ?? '从未'}`);
  }
}

async function cmdRevoke(deviceId, all = false) {
  const config = loadConfig();
  if (all) {
    const devices = (await adminGet(config, '/devices')).body?.devices ?? [];
    for (const d of devices.filter((x) => !x.revoked)) await adminGet(config, `/devices/revoke?deviceId=${d.deviceId}`);
    return console.log(`已吊销 ${devices.filter((x) => !x.revoked).length} 台设备。`);
  }
  const res = await adminGet(config, `/devices/revoke?deviceId=${deviceId}`);
  if (!res.ok) {
    console.error(`吊销失败（${res.error ?? res.status}）`);
    process.exit(1);
  }
  console.log(res.body.revoked ? `已吊销 ${deviceId}` : `未找到 ${deviceId}`);
}

const [command, ...rest] = process.argv.slice(2);

switch (command) {
  case 'serve':
    await cmdServe();
    break;
  case 'pair':
    await cmdPair();
    break;
  case 'health':
    await cmdHealth();
    break;
  case 'devices':
    await cmdDevices();
    break;
  case 'revoke':
    if (!rest[0]) {
      console.error('用法：node src/bridge.mjs revoke <deviceId>');
      process.exit(1);
    }
    await cmdRevoke(rest[0]);
    break;
  case 'revoke-all':
    await cmdRevoke(null, true);
    break;
  default:
    console.log(readFileSync(path.join(BRIDGE_DIR, 'bridge-protocol.md'), 'utf8').split('\n').slice(0, 3).join('\n'));
    console.log(`
用法：node src/bridge.mjs <command>

  serve                启动桥（常驻，自动拉起 dsh --profile acp）
  pair                 生成一次性配对码
  health               查看桥与 DSH 状态
  devices              列出已配对设备
  revoke <deviceId>    吊销某台设备
  revoke-all           吊销全部设备

环境变量：
  DSH_BIN               dsh 的 lib/bin.js 路径
  DSH_MOBILE_CWD        Agent 的工作目录（必须 ACL 可改）
  DSH_MOBILE_HOST       监听地址，默认 127.0.0.1（Tailscale 场景用 0.0.0.0）
  DSH_MOBILE_PORT       监听端口，默认 8788
  DSH_PERMISSION_MODE   workspace-write（默认，有手机端审批） / danger-full-access
`);
    process.exit(command ? 1 : 0);
}
