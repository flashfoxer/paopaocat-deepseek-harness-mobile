/**
 * 在 Android 设备上直接验证 ACP 多轮对话（不经过 Flutter UI）。
 *
 * 目的：App 的 Dart 侧客户端说的是同一套协议，把协议层单独验证掉，
 * 就不用靠不稳定的 UI 自动化（软键盘弹出会改变坐标、adb input text 不支持中文）。
 *
 * 用法（在设备上）：
 *   node --expose-internals --require <fs-shim.cjs> android-acp-smoke.mjs
 * 环境变量：DSH_BIN=<dsh>/lib/bin.js  OVERLAY=<overlay.yml>  WORKSPACE=<cwd>
 */

import { spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

const dshBin = process.env.DSH_BIN;
const overlay = process.env.OVERLAY;
const workspace = process.env.WORKSPACE ?? '/data/local/tmp/acp-work';
const nodeBin = process.execPath;

if (!dshBin) {
  console.error('需要 DSH_BIN');
  process.exit(2);
}
mkdirSync(dirname(dshBin), { recursive: true });
mkdirSync(workspace, { recursive: true });

const fsShim = process.env.FS_SHIM;

const args = ['--expose-internals'];
// 与 App 的 AcpClient 保持一致：子进程同样需要 filesystem shim，
// 否则会话持久化的 link() 会被 SELinux 拒绝（EACCES）。
if (fsShim) args.push('--require', fsShim);
args.push(dshBin, '--profile', 'acp');
if (overlay) args.push('--patch', overlay);

console.log(`[smoke] spawn: ${nodeBin} ${args.join(' ')}`);
const child = spawn(nodeBin, args, {
  stdio: ['pipe', 'pipe', 'pipe'],
  cwd: workspace,
  env: process.env,
});

child.stderr.on('data', (b) => {
  const s = b.toString().trim();
  if (s) console.log(`[dsh:stderr] ${s.slice(0, 200)}`);
});
child.on('exit', (code) => console.log(`[smoke] dsh exited: ${code}`));

// ---- 换行分帧 JSON-RPC ----
let nextId = 1;
const pending = new Map();
let buffer = '';

const notifications = [];

function send(msg) {
  child.stdin.write(`${JSON.stringify(msg)}\n`);
}

function request(method, params) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    send({ jsonrpc: '2.0', id, method, params });
    setTimeout(() => {
      if (pending.has(id)) {
        pending.delete(id);
        reject(new Error(`timeout: ${method}`));
      }
    }, 300000);
  });
}

child.stdout.on('data', (chunk) => {
  buffer += chunk.toString();
  let idx;
  while ((idx = buffer.indexOf('\n')) !== -1) {
    const line = buffer.slice(0, idx).trim();
    buffer = buffer.slice(idx + 1);
    if (!line) continue;

    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      console.log(`[smoke] 非 JSON 行: ${line.slice(0, 120)}`);
      continue;
    }

    if (msg.id !== undefined && msg.method === undefined) {
      const p = pending.get(msg.id);
      if (p) {
        pending.delete(msg.id);
        msg.error ? p.reject(new Error(JSON.stringify(msg.error))) : p.resolve(msg.result);
      }
      continue;
    }

    if (msg.id !== undefined && msg.method !== undefined) {
      // 服务端请求：权限确认。这里一律允许一次。
      if (msg.method === 'session/request_permission') {
        console.log('[smoke] << 权限请求，自动允许一次');
        send({
          jsonrpc: '2.0',
          id: msg.id,
          result: { outcome: { outcome: 'selected', optionId: 'allow-once' } },
        });
      } else {
        send({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: `unsupported ${msg.method}` } });
      }
      continue;
    }

    if (msg.method === 'session/update') {
      const u = msg.params?.update ?? {};
      const kind = u.sessionUpdate;
      if (kind === 'agent_message_chunk') {
        const t = u.content?.text ?? '';
        notifications.push(t);
        process.stdout.write(`\n[agent] ${t}\n`);
      } else if (kind === 'agent_thought_chunk') {
        const t = u.content?.text ?? '';
        process.stdout.write(`[think] ${t.slice(0, 100)}\n`);
      } else if (kind === 'tool_call') {
        console.log(`[tool] ${u.title} :: ${JSON.stringify(u.rawInput ?? {}).slice(0, 120)}`);
      } else if (kind === 'tool_call_update') {
        console.log(`[tool-update] ${u.toolCallId} status=${u.status}`);
      } else {
        console.log(`[update] ${kind}`);
      }
    }
  }
});

function textOf(update) {
  return update?.content?.text ?? '';
}

// ---- 流程 ----
try {
  const init = await request('initialize', {
    protocolVersion: 1,
    clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
    clientInfo: { name: 'android-smoke', version: '1.0.0' },
  });
  console.log(`[smoke] initialize ok: ${JSON.stringify(init?.agentInfo ?? {})}`);

  const session = await request('session/new', { cwd: workspace, mcpServers: [] });
  const sessionId = session?.sessionId;
  console.log(`[smoke] session: ${sessionId}`);

  // 第 1 轮：让它记住一个口令
  console.log('\n===== 第 1 轮 =====');
  notifications.length = 0;
  const r1 = await request('session/prompt', {
    sessionId,
    prompt: [{ type: 'text', text: 'Please remember this passcode: ZEBRA-7741. Just acknowledge.' }],
  });
  console.log(`[smoke] 第 1 轮 stopReason=${r1?.stopReason}`);
  console.log(`[smoke] 第 1 轮回答长度=${notifications.join('').length}`);

  // 第 2 轮：问它口令是什么 —— 只有多轮上下文成立才会答对
  console.log('\n===== 第 2 轮（考验多轮上下文）=====');
  notifications.length = 0;
  const r2 = await request('session/prompt', {
    sessionId,
    prompt: [{ type: 'text', text: 'What passcode did I just ask you to remember? Answer with the code only.' }],
  });
  const answer = notifications.join('');
  console.log(`[smoke] 第 2 轮 stopReason=${r2?.stopReason}`);
  console.log(`[smoke] 第 2 轮回答: ${answer.trim().slice(0, 300)}`);

  const remembered = answer.includes('ZEBRA-7741') || answer.includes('7741');
  console.log(`\n[smoke] 多轮上下文: ${remembered ? '✓ 成立（答对了口令）' : '✗ 未成立（没答出口令）'}`);

  child.stdin.end();
  child.kill();
  process.exit(remembered ? 0 : 1);
} catch (e) {
  console.error(`[smoke] 失败: ${e.message}`);
  child.kill();
  process.exit(3);
}
