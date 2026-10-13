/**
 * ACP 子进程客户端：管理 `dsh --profile acp`，提供换行分帧 JSON-RPC 2.0 传输。
 *
 * 设计约束（来自 W1 实测）：
 *  - 服务端请求 id 与客户端 id 空间**独立**，必须原样回 `msg.id`。
 *  - `session/request_permission` 是唯一的 agent→client 请求，由上层决定应答。
 *  - cwd 决定 workspace-write 沙箱的工作区根，必须 ACL 可改。
 */

import { spawn } from 'node:child_process';
import { EventEmitter } from 'node:events';
import { createInterface } from 'node:readline';

const DEFAULT_TIMEOUT_MS = 120_000;

export class AcpClient extends EventEmitter {
  #proc = null;
  #rl = null;
  #nextId = 1;
  #pending = new Map();
  #stopping = false;
  #stderrTail = [];

  constructor({ dshBin, profile = 'acp', patches = [], cwd, permissionMode, extraEnv = {} }) {
    super();
    if (!dshBin) throw new Error('dshBin is required');
    this.dshBin = dshBin;
    this.profile = profile;
    this.patches = patches;
    this.cwd = cwd;
    this.permissionMode = permissionMode;
    this.extraEnv = extraEnv;
    this.agentInfo = null;
    this.agentCapabilities = null;
    this.negotiatedVersion = null;
  }

  get running() {
    return this.#proc !== null && this.#proc.exitCode === null;
  }

  get stderrTail() {
    return this.#stderrTail.join('');
  }

  start() {
    if (this.#proc) throw new Error('AcpClient already started');
    const args = [this.dshBin, '--profile', this.profile];
    for (const p of this.patches) args.push('--patch', p);

    const env = { ...process.env, ...this.extraEnv };
    if (this.permissionMode) env.DSH_PERMISSION_MODE = this.permissionMode;

    const proc = spawn(process.execPath, args, {
      cwd: this.cwd,
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: true,
      env,
    });
    this.#proc = proc;

    proc.on('error', (err) => this.emit('error', err));
    proc.on('exit', (code, signal) => {
      const expected = this.#stopping;
      this.#proc = null;
      const err = new Error(`dsh exited code=${code} signal=${signal}`);
      for (const [, p] of this.#pending) p.reject(err);
      this.#pending.clear();
      this.emit('exit', { code, signal, expected });
    });
    proc.stderr.on('data', (chunk) => {
      const text = chunk.toString();
      this.#stderrTail.push(text);
      if (this.#stderrTail.length > 200) this.#stderrTail.shift();
      this.emit('stderr', text);
    });

    this.#rl = createInterface({ input: proc.stdout });
    this.#rl.on('line', (line) => this.#onLine(line));
    return this;
  }

  #onLine(line) {
    const text = line.trim();
    if (!text) return;
    let msg;
    try {
      msg = JSON.parse(text);
    } catch {
      this.emit('unparsable', text);
      return;
    }

    // 响应
    if (msg.id !== undefined && msg.method === undefined) {
      const p = this.#pending.get(msg.id);
      if (!p) return;
      this.#pending.delete(msg.id);
      if (msg.error) {
        const err = new Error(msg.error.message ?? 'jsonrpc error');
        err.code = msg.error.code;
        err.data = msg.error.data;
        p.reject(err);
      } else {
        p.resolve(msg.result);
      }
      return;
    }

    // agent → client 请求（id + method）：交给上层应答
    if (msg.id !== undefined && msg.method !== undefined) {
      this.emit('server-request', msg);
      return;
    }

    // 通知
    this.emit('notification', msg);
    if (msg.method === 'session/update') this.emit('update', msg.params);
  }

  request(method, params, timeoutMs = DEFAULT_TIMEOUT_MS) {
    if (!this.#proc) return Promise.reject(new Error('AcpClient is not running'));
    const id = this.#nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new Error(`timeout after ${timeoutMs}ms: ${method}`));
      }, timeoutMs);
      this.#pending.set(id, {
        resolve: (v) => {
          clearTimeout(timer);
          resolve(v);
        },
        reject: (e) => {
          clearTimeout(timer);
          reject(e);
        },
      });
      this.#proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    });
  }

  respond(id, result) {
    if (!this.#proc) return;
    this.#proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, result }) + '\n');
  }

  /** 发送通知（无 id，无需应答），例如 session/cancel。 */
  notify(method, params) {
    if (!this.#proc) return;
    this.#proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n');
  }

  respondError(id, code, message) {
    if (!this.#proc) return;
    this.#proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, error: { code, message } }) + '\n');
  }

  /** 握手：请求 ACP v1（实测 DSH 就回 1），并记录 agent 能力。 */
  async initialize({ name = 'dsh-mobile-bridge', version = '0.1.0' } = {}) {
    const result = await this.request('initialize', {
      protocolVersion: 1,
      clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
      clientInfo: { name, version },
    });
    this.agentInfo = result?.agentInfo ?? null;
    this.agentCapabilities = result?.agentCapabilities ?? null;
    this.negotiatedVersion = result?.protocolVersion ?? null;
    if (this.negotiatedVersion !== 1) {
      throw new Error(`unsupported ACP protocolVersion: ${this.negotiatedVersion}`);
    }
    return result;
  }

  async stop() {
    this.#stopping = true;
    try {
      this.#rl?.close();
    } catch {}
    try {
      this.#proc?.stdin.end();
    } catch {}
    await new Promise((resolve) => {
      if (!this.#proc) return resolve();
      const timer = setTimeout(() => {
        try {
          this.#proc?.kill();
        } catch {}
        resolve();
      }, 3000);
      this.#proc.once('exit', () => {
        clearTimeout(timer);
        resolve();
      });
    });
  }
}
