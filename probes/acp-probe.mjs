#!/usr/bin/env node
/**
 * DSH Mobile · ACP 行为探针 (W1)
 *
 * 目的：把 DSH 的 ACP 服务端真实行为打成夹具，作为桥与 App 的实现依据。
 * 实测项：
 *   1. initialize —— protocolVersion 协商、agentCapabilities、agentInfo、authMethods
 *   2. session/new —— sessionId、configOptions、modes
 *   3. session/prompt —— 纯对话：session/update 的真实粒度与字段
 *   4. session/prompt —— 触发工具调用：是否发 session/request_permission、options 长什么样
 *   5. session/list / session/close —— 实际支持情况
 *   6. agent→client 请求清单（fs / terminal / elicitation 等），判断 DSH 是否依赖客户端环境能力
 *
 * 输出：fixtures/acp-probe-<ts>.jsonl（全量原始帧）+ fixtures/acp-probe-<ts>.summary.json
 */

import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import path from 'node:path';

const DSH_BIN = 'D:/Programs/PaopaocatDSH/app/lib/bin.js';
const ROOT = 'D:/新建文件夹/新建文件夹/新建文件夹/新建文件夹/dsh-mobile';
const SANDBOX = process.env.PROBE_SANDBOX ?? path.join(ROOT, 'fixtures', 'acp-sandbox');
const OUTDIR = path.join(ROOT, 'fixtures');
const OVERLAY = path.join(ROOT, 'bridge', 'acp-model.overlay.yml');

const REQUEST_TIMEOUT_MS = 180_000; // 首次初始化 acp profile 可能较慢
const TOTAL_TIMEOUT_MS = 900_000;

const ts = new Date().toISOString().replace(/[:.]/g, '-');
const LABEL = `acp-probe-${ts}`;

mkdirSync(SANDBOX, { recursive: true });
mkdirSync(OUTDIR, { recursive: true });

// ---------- 采集状态 ----------
const frames = [];
const stderrChunks = [];
const serverRequests = []; // agent -> client 请求
const notifications = [];
const updateKinds = new Map();
const permissionRequests = [];
const steps = [];
const pending = new Map();
let nextId = 1;

mkdirSync(OUTDIR, { recursive: true });

function record(dir, msg) {
  frames.push({ t: Date.now(), dir, msg });
}
function note(step, data) {
  steps.push({ step, at: new Date().toISOString(), data });
  console.log(`[probe] ${step}`, data === undefined ? '' : JSON.stringify(data).slice(0, 600));
}

// ---------- 传输 ----------
const proc = spawn(process.execPath, [DSH_BIN, '--profile', 'acp', '--patch', OVERLAY], {
  cwd: SANDBOX,
  stdio: ['pipe', 'pipe', 'pipe'],
  windowsHide: true,
  env: { ...process.env, DSH_PERMISSION_MODE: process.env.PROBE_PERMISSION_MODE ?? 'danger-full-access' },
});

proc.on('error', (e) => note('spawn-error', { message: e.message }));
proc.on('exit', (code, signal) => {
  note('proc-exit', { code, signal });
  for (const [, p] of pending) p.reject(new Error(`dsh exited code=${code} signal=${signal}`));
  pending.clear();
});
proc.stderr.on('data', (d) => stderrChunks.push(d.toString()));

function send(msg) {
  record('out', msg);
  proc.stdin.write(JSON.stringify(msg) + '\n');
}
function request(method, params, timeoutMs = REQUEST_TIMEOUT_MS) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`timeout after ${timeoutMs}ms: ${method}`));
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
function respond(id, result) {
  send({ jsonrpc: '2.0', id, result });
}
function respondError(id, code, message) {
  send({ jsonrpc: '2.0', id, error: { code, message } });
}

const rl = createInterface({ input: proc.stdout });
rl.on('line', (line) => {
  const text = line.trim();
  if (!text) return;
  let msg;
  try {
    msg = JSON.parse(text);
  } catch {
    record('in-unparsable', { raw: text.slice(0, 4000) });
    return;
  }
  record('in', msg);

  // 响应
  if (msg.id !== undefined && msg.method === undefined) {
    const p = pending.get(msg.id);
    if (!p) return;
    pending.delete(msg.id);
    if (msg.error) {
      const err = new Error(msg.error.message || 'jsonrpc error');
      err.code = msg.error.code;
      err.data = msg.error.data;
      p.reject(err);
    } else {
      p.resolve(msg.result);
    }
    return;
  }

  // agent -> client 请求（需要回复，否则 DSH 会卡住）
  if (msg.id !== undefined && msg.method !== undefined) {
    serverRequests.push({ method: msg.method, params: msg.params });
    if (msg.method === 'session/request_permission') {
      permissionRequests.push(msg.params);
      const options = msg.params?.options ?? [];
      const allowOnce =
        options.find((o) => o.kind === 'allow_once') ??
        options.find((o) => o.kind === 'allow_always') ??
        options[0];
      if (allowOnce) {
        respond(msg.id, { outcome: { outcome: 'selected', optionId: allowOnce.optionId } });
      } else {
        respond(msg.id, { outcome: { outcome: 'cancelled' } });
      }
    } else {
      // 未声明能力的请求：明确拒绝，避免死锁，同时留下证据
      respondError(msg.id, -32601, `probe: unsupported client method ${msg.method}`);
    }
    return;
  }

  // 通知
  notifications.push({ method: msg.method, params: msg.params });
  if (msg.method === 'session/update') {
    const kind = msg.params?.update?.sessionUpdate ?? 'unknown';
    updateKinds.set(kind, (updateKinds.get(kind) ?? 0) + 1);
  }
});

const hardStop = setTimeout(() => {
  note('hard-stop', { reason: 'TOTAL_TIMEOUT_MS exceeded' });
  try {
    proc.kill();
  } catch {}
}, TOTAL_TIMEOUT_MS);
hardStop.unref?.();

// ---------- 主流程 ----------
async function main() {
  const initParams = (protocolVersion) => ({
    protocolVersion,
    clientCapabilities: {
      fs: { readTextFile: false, writeTextFile: false },
      terminal: false,
    },
    clientInfo: { name: 'dsh-mobile-probe', version: '0.1.0' },
  });

  let initResult = null;
  let usedVersion = null;
  for (const v of [1, 2]) {
    try {
      initResult = await request('initialize', initParams(v));
      usedVersion = v;
      break;
    } catch (e) {
      note('initialize-failed', { protocolVersion: v, message: e.message, data: e.data });
    }
  }
  if (!initResult) throw new Error('initialize failed for protocolVersion 1 and 2');
  note('initialize-ok', {
    requestedProtocolVersion: usedVersion,
    negotiated: initResult.protocolVersion,
    agentInfo: initResult.agentInfo,
    authMethods: initResult.authMethods,
    agentCapabilities: initResult.agentCapabilities,
  });

  // 2. session/new
  const created = await request('session/new', { cwd: SANDBOX, mcpServers: [] });
  const sessionId = created.sessionId;
  note('session-new-ok', {
    sessionId,
    keys: Object.keys(created),
    configOptions: created.configOptions,
    modes: created.modes,
  });

  // 3. 纯对话 prompt
  const before = notifications.length;
  let p1 = null;
  try {
    p1 = await request('session/prompt', {
      sessionId,
      prompt: [{ type: 'text', text: '请用大约 300 字介绍一下你自己能做什么，直接给正文，不要分点。' }],
    });
  } catch (e) {
    note('prompt-chat-failed', { message: e.message, code: e.code, data: e.data });
  }
  note('prompt-chat-done', {
    stopReason: p1?.stopReason ?? null,
    usage: p1?.usage ?? null,
    updates: notifications.length - before,
    updateKinds: [...updateKinds.entries()],
  });

  // 4. 触发工具调用 + 权限请求
  const before2 = notifications.length;
  const permsBefore = permissionRequests.length;
  let p2 = null;
  try {
    p2 = await request('session/prompt', {
      sessionId,
      prompt: [
        {
          type: 'text',
          text: '请执行 shell 命令 echo dsh-acp-probe-ok 并把命令的原始输出告诉我。',
        },
      ],
    });
  } catch (e) {
    note('prompt-tool-failed', { message: e.message, code: e.code, data: e.data });
  }
  note('prompt-tool-done', {
    stopReason: p2?.stopReason ?? null,
    updates: notifications.length - before2,
    permissionRequested: permissionRequests.length - permsBefore,
    serverRequests: serverRequests.map((r) => r.method),
    updateKinds: [...updateKinds.entries()],
  });

  // 5. session/list 与 session/close 实测
  try {
    const listed = await request('session/list', { cwd: SANDBOX }, 30_000);
    note('session-list-ok', { keys: Object.keys(listed), sessions: listed.sessions });
  } catch (e) {
    note('session-list-failed', { message: e.message, code: e.code, data: e.data });
  }

  try {
    const closed = await request('session/close', { sessionId }, 30_000);
    note('session-close-ok', { result: closed });
  } catch (e) {
    note('session-close-failed', { message: e.message, code: e.code, data: e.data });
  }

  // 6. 退出
  try {
    proc.stdin.end();
  } catch {}
}

main()
  .catch((e) => note('probe-error', { message: e.message, stack: (e.stack ?? '').split('\n').slice(0, 5) }))
  .finally(async () => {
    await new Promise((r) => setTimeout(r, 1500));
    try {
      proc.kill();
    } catch {}

    // 粒度统计：每个 session/update 的字符量
    const updateSizes = notifications
      .filter((n) => n.method === 'session/update')
      .map((n) => JSON.stringify(n.params?.update ?? null).length);

    const summary = {
      label: LABEL,
      generatedAt: new Date().toISOString(),
      dshBin: DSH_BIN,
      sandbox: SANDBOX,
      steps,
      frameCount: frames.length,
      updateKinds: Object.fromEntries(updateKinds),
      updateCount: updateSizes.length,
      updateBytes: {
        min: updateSizes.length ? Math.min(...updateSizes) : null,
        max: updateSizes.length ? Math.max(...updateSizes) : null,
        avg: updateSizes.length ? Math.round(updateSizes.reduce((a, b) => a + b, 0) / updateSizes.length) : null,
      },
      permissionRequests,
      serverRequestMethods: [...new Set(serverRequests.map((r) => r.method))],
      stderrTail: stderrChunks.join('').split('\n').slice(-40),
    };

    writeFileSync(path.join(OUTDIR, `${LABEL}.jsonl`), frames.map((f) => JSON.stringify(f)).join('\n'), 'utf8');
    writeFileSync(path.join(OUTDIR, `${LABEL}.summary.json`), JSON.stringify(summary, null, 2), 'utf8');

    console.log('\n========== PROBE SUMMARY ==========');
    console.log(JSON.stringify(summary, null, 2));
    console.log('===================================');
    console.log(`frames: ${OUTDIR}/${LABEL}.jsonl`);
    console.log(`summary: ${OUTDIR}/${LABEL}.summary.json`);
    process.exit(0);
  });
