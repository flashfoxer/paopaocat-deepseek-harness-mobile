#!/usr/bin/env node
/**
 * ACP · 图片内容块实测
 *
 * W1 从 initialize 的 agentCapabilities 看到 `promptCapabilities.image = false`，
 * 但那只说明"服务端不**公布**该能力"。本探针实际发一张图，看 DSH 到底怎么处理：
 *   - 拒绝并返回什么错误形态？
 *   - 还是接受（那说明 capability 声明与实际不一致，桥与 App 都要改）？
 *
 * 结论直接决定"手机上发图片"的方案（必须知道是走 image block 还是走文件路径引用）。
 *
 * 用法：node probes/image-probe.mjs
 */

import { spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { createInterface } from 'node:readline';
import path from 'node:path';

const DSH_BIN = 'D:/Programs/PaopaocatDSH/app/lib/bin.js';
const ROOT = 'D:/新建文件夹/新建文件夹/新建文件夹/新建文件夹/dsh-mobile';
const OVERLAY = path.join(ROOT, 'bridge', 'acp-model.overlay.yml');
// 沙箱根 = 子进程 cwd，必须 ACL 可改，否则工具会报 SetNamedSecurityInfoW
const SANDBOX = 'C:\\Users\\25894\\dsh-mobile-workspace';

// 1x1 透明 PNG
const PNG_1X1 =
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

mkdirSync(SANDBOX, { recursive: true });

const proc = spawn(process.execPath, [DSH_BIN, '--profile', 'acp', '--patch', OVERLAY], {
  cwd: SANDBOX,
  stdio: ['pipe', 'pipe', 'pipe'],
  windowsHide: true,
  env: { ...process.env, DSH_PERMISSION_MODE: 'workspace-write' },
});

const pending = new Map();
let nextId = 1;

function send(msg) {
  proc.stdin.write(JSON.stringify(msg) + '\n');
}
function request(method, params, timeoutMs = 120_000) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`timeout: ${method}`));
    }, timeoutMs);
    pending.set(id, {
      resolve: (v) => {
        clearTimeout(timer);
        resolve(v);
      },
      reject: (e) => {
        clearTimeout(timer);
        reject(e);
      },
    });
    send({ jsonrpc: '2.0', id, method, params });
  });
}

const rl = createInterface({ input: proc.stdout });
rl.on('line', (line) => {
  const text = line.trim();
  if (!text) return;
  let msg;
  try {
    msg = JSON.parse(text);
  } catch {
    return;
  }
  if (msg.id !== undefined && msg.method === undefined) {
    const p = pending.get(msg.id);
    if (!p) return;
    pending.delete(msg.id);
    if (msg.error) {
      const err = new Error(msg.error.message ?? 'error');
      err.code = msg.error.code;
      err.data = msg.error.data;
      p.reject(err);
    } else {
      p.resolve(msg.result);
    }
    return;
  }
  if (msg.id !== undefined && msg.method !== undefined) {
    // 不声明 fs/terminal 能力时不该出现；出现就明确拒绝，避免挂住
    send({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'probe: unsupported' } });
  }
});
proc.stderr.on('data', () => {});

async function main() {
  const init = await request('initialize', {
    protocolVersion: 1,
    clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
    clientInfo: { name: 'image-probe', version: '0.1.0' },
  });
  const caps = init.agentCapabilities?.promptCapabilities ?? {};
  console.log('published promptCapabilities =', JSON.stringify(caps));

  const created = await request('session/new', { cwd: SANDBOX, mcpServers: [] });
  const sessionId = created.sessionId;
  console.log('session =', sessionId);

  const pngBytes = Buffer.from(PNG_1X1, 'base64').length;
  console.log(`发送 prompt：text + image（PNG，${pngBytes} 字节，base64 ${PNG_1X1.length} 字符）`);

  try {
    const result = await request(
      'session/prompt',
      {
        sessionId,
        prompt: [
          { type: 'text', text: '这是一张图片，请描述它。' },
          { type: 'image', data: PNG_1X1, mimeType: 'image/png' },
        ],
      },
      180_000,
    );
    console.log('\n=== 结果：服务端**接受**了图片内容块 ===');
    console.log('stopReason =', result.stopReason);
    console.log('→ 与 published capability（image=false）不一致，需要重新评估图片方案');
  } catch (err) {
    console.log('\n=== 结果：服务端**拒绝**了图片内容块 ===');
    console.log('code    =', err.code);
    console.log('message =', err.message);
    if (err.data !== undefined) console.log('data    =', JSON.stringify(err.data).slice(0, 500));
    console.log('→ 与 published capability（image=false）一致');
  }

  try {
    await request('session/close', { sessionId }, 30_000);
  } catch {}
}

main()
  .catch((e) => console.error('probe 失败：', e.message))
  .finally(async () => {
    await new Promise((r) => setTimeout(r, 500));
    try {
      proc.kill();
    } catch {}
    process.exit(0);
  });
