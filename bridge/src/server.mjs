/**
 * 桥服务端：WebSocket + 桥协议 v1（见 ../bridge-protocol.md）。
 *
 * 设计要点（来自 W1 实测）：
 *  - ACP 请求 id 与客户端 id 空间独立：权限请求用 ACP 自己的 id 原样回复。
 *  - ACP 权限请求只带 toolCallId：必须回查缓存的 tool_call 才能显示命令。
 *  - ACP 只有 allow_once / reject_once：allow_session 由桥自己记忆。
 *  - ACP 无 load/delete/fork：close 即销毁，UI 必须区分 unsubscribe 与 close_session。
 */

import http from 'node:http';
import https from 'node:https';
import { existsSync, readFileSync } from 'node:fs';
import { WebSocketServer } from 'ws';
import { SessionRegistry } from './sessions.mjs';

const PROTOCOL_VERSION = 1;
const PERMISSION_TIMEOUT_MS = 120_000;
const AUTH_GRACE_MS = 10_000;

const RISK_PATTERNS = [
  { re: /\brm\s+-rf\b/i, flag: 'destructive' },
  { re: /curl[^|]*\|\s*(sh|bash)/i, flag: 'remote-exec' },
  { re: /Invoke-Expression|iex\b|-enc(odedcommand)?\b/i, flag: 'remote-exec' },
  { re: /\.ssh|\.env|credentials|id_rsa/i, flag: 'secret-access' },
  { re: /git\s+push\s+.*--force/i, flag: 'history-rewrite' },
  { re: /C:\\(Windows|Program Files)|chmod\s+777/i, flag: 'system-write' },
];

function riskFlagsOf(command) {
  if (!command) return [];
  return RISK_PATTERNS.filter((p) => p.re.test(command)).map((p) => p.flag);
}

export class BridgeServer {
  constructor({ acp, store, config, log = console.log }) {
    this.acp = acp;
    this.store = store;
    this.config = config;
    this.log = log;
    this.conns = new Set();
    this.permissionSeq = 0;
    this.dshState = 'starting';
    this.httpServer = null;
    this.wss = null;
    this.restarting = false;
    this.protocol = 'ws'; // 'ws' 或 'wss'，由 start() 按证书是否存在决定
    this.fingerprint = null;

    this.registry = new SessionRegistry({
      onEvent: (session, event) => this.#broadcast(session.id, {
        v: PROTOCOL_VERSION, type: 'update', sessionId: session.id, seq: event.seq, update: event.update,
      }),
      onStatus: (sessionId, status) => this.#broadcast(sessionId, {
        v: PROTOCOL_VERSION, type: 'session_status', sessionId, state: status,
      }),
    });
  }

  // ---------------------------------------------------------------- lifecycle

  async start() {
    await this.#spawnAcp();
    await this.#hydrateFromAcpList();

    const handler = (req, res) => this.#handleHttp(req, res);
    const tls = this.config.tls;

    if (tls?.pfxPath && existsSync(tls.pfxPath)) {
      const pfx = readFileSync(tls.pfxPath);
      this.httpServer = https.createServer({ pfx, passphrase: tls.pfxPassword ?? '' }, handler);
      this.protocol = 'wss';
      if (tls.fingerprintPath && existsSync(tls.fingerprintPath)) {
        this.fingerprint = readFileSync(tls.fingerprintPath, 'utf8').trim();
      }
    } else {
      this.httpServer = http.createServer(handler);
      this.protocol = 'ws';
      if (tls?.pfxPath) this.log(`[bridge] 未找到 PFX（${tls.pfxPath}），回退为明文 ws`);
    }

    this.wss = new WebSocketServer({ server: this.httpServer });
    this.wss.on('connection', (ws, req) => this.#onConnection(ws, req));

    await new Promise((resolve) => {
      this.httpServer.listen(this.config.port, this.config.host, () => resolve());
    });
    this.log(`[bridge] 已监听 ${this.protocol}://${this.config.host}:${this.config.port}`);
    if (this.fingerprint) this.log(`[bridge] 证书 SHA-256 指纹（App 配对需 pin）：${this.fingerprint}`);
    this.log(`[bridge] 管理端点 http://127.0.0.1:${this.config.port}/health （仅本机）`);
    return this;
  }

  async stop() {
    for (const conn of this.conns) {
      try { conn.ws.close(); } catch {}
    }
    this.conns.clear();
    await new Promise((resolve) => this.wss?.close(() => resolve()) ?? resolve());
    await new Promise((resolve) => this.httpServer?.close(() => resolve()) ?? resolve());
    await this.acp.stop();
  }

  async #spawnAcp() {
    this.dshState = 'starting';
    this.#broadcastAll({ v: PROTOCOL_VERSION, type: 'bridge_status', dsh: 'starting' });
    this.acp.removeAllListeners();
    this.#wireAcp();
    this.acp.start();
    await this.acp.initialize({ name: 'dsh-mobile-bridge', version: '0.1.0' });
    this.dshState = 'running';
    this.log(
      `[bridge] dsh 就绪 agent=${this.acp.agentInfo?.name}@${this.acp.agentInfo?.version} ` +
        `caps=${JSON.stringify(this.acp.agentCapabilities?.sessionCapabilities ?? {})}`,
    );
    this.#broadcastAll({ v: PROTOCOL_VERSION, type: 'bridge_status', dsh: 'running' });
  }

  #wireAcp() {
    this.acp.on('update', (params) => {
      const session = this.registry.byAcpId(params.sessionId);
      if (session) this.registry.pushUpdate(params.sessionId, params.update);
    });

    this.acp.on('server-request', (msg) => this.#onAcpServerRequest(msg));

    this.acp.on('stderr', (text) => {
      const line = text.trim();
      if (line) this.log('[dsh]', line);
    });

    this.acp.on('exit', ({ code, expected }) => {
      this.dshState = 'failed';
      this.#broadcastAll({ v: PROTOCOL_VERSION, type: 'bridge_status', dsh: 'failed', detail: `dsh exited code=${code}` });
      if (expected) return;
      if (this.restarting) return;
      this.restarting = true;
      this.#restartAcp().finally(() => { this.restarting = false; });
    });
  }

  async #restartAcp() {
    let delay = 1000;
    for (let attempt = 1; attempt <= 8; attempt += 1) {
      this.dshState = 'restarting';
      this.#broadcastAll({
        v: PROTOCOL_VERSION, type: 'bridge_status', dsh: 'restarting',
        detail: `retry #${attempt} in ${delay}ms`,
      });
      await new Promise((r) => setTimeout(r, delay));
      delay = Math.min(delay * 2, 30_000);
      try {
        await this.#spawnAcp();
        await this.#hydrateFromAcpList();
        return;
      } catch (err) {
        this.log(`[bridge] dsh 重启失败（第 ${attempt} 次）：${err.message}`);
      }
    }
    this.dshState = 'failed';
    this.#broadcastAll({ v: PROTOCOL_VERSION, type: 'bridge_status', dsh: 'failed', detail: '重启次数耗尽' });
  }

  /** 把 ACP 侧已持久化的会话登记进桥（幂等）。 */
  async #hydrateFromAcpList() {
    try {
      const listed = await this.acp.request('session/list', { cwd: this.config.cwd }, 30_000);
      for (const s of listed?.sessions ?? []) {
        if (this.registry.byAcpId(s.sessionId)) continue;
        this.registry.add({ acpSessionId: s.sessionId, cwd: s.cwd ?? this.config.cwd });
      }
      this.log(`[bridge] ACP 侧可恢复会话 ${listed?.sessions?.length ?? 0} 个`);
    } catch (err) {
      this.log(`[bridge] session/list 失败（不致命）：${err.message}`);
    }
  }

  // ---------------------------------------------------------------- ACP → App

  async #onAcpServerRequest(msg) {
    if (msg.method !== 'session/request_permission') {
      this.acp.respondError(msg.id, -32601, `bridge: unsupported client method ${msg.method}`);
      return;
    }
    const params = msg.params ?? {};
    const session = this.registry.byAcpId(params.sessionId);
    if (!session) {
      this.acp.respond(msg.id, { outcome: { outcome: 'cancelled' } });
      return;
    }

    const toolCallId = params.toolCall?.toolCallId ?? null;
    const cached = (toolCallId && session.toolCalls.get(toolCallId)) || {};
    const command = cached.command ?? null;

    // 桥侧记忆的"本次会话允许"
    if (command && session.allowedCommands?.has(command)) {
      this.log(`[bridge] 会话 ${session.id} 命中记住的允许：${command}`);
      this.acp.respond(msg.id, { outcome: { outcome: 'selected', optionId: 'allow-once' } });
      return;
    }

    const requestId = `req_${++this.permissionSeq}`;
    const expiresAt = Date.now() + PERMISSION_TIMEOUT_MS;

    // 构造好对外帧并缓存：断线重连后凭它补发，App 才不会漏掉审批。
    const frame = {
      v: PROTOCOL_VERSION,
      type: 'permission_request',
      sessionId: session.id,
      requestId,
      toolCallId,
      title: cached.title ?? null,
      command,
      cwd: session.cwd,
      riskFlags: riskFlagsOf(command),
      options: [
        { id: 'allow_once', label: '仅本次允许' },
        { id: 'allow_session', label: '本次会话始终允许' },
        { id: 'reject_once', label: '拒绝' },
      ],
      expiresAt,
    };

    const entry = {
      acpRequestId: msg.id,
      toolCallId,
      command,
      options: params.options ?? [],
      expiresAt,
      sessionId: session.id,
      frame,
      timer: null,
    };
    entry.timer = setTimeout(() => {
      if (!session.pendingPermissions.has(requestId)) return;
      session.pendingPermissions.delete(requestId);
      this.log(`[bridge] 权限请求 ${requestId} 超时，自动拒绝`);
      this.acp.respond(entry.acpRequestId, { outcome: { outcome: 'reject-once' } });
      this.#broadcast(session.id, {
        v: PROTOCOL_VERSION, type: 'error', code: 'permission_timeout',
        message: '审批超时，已自动拒绝', ref: requestId,
      });
    }, PERMISSION_TIMEOUT_MS);
    session.pendingPermissions.set(requestId, entry);

    this.#broadcastPermission(session.id, frame);
  }

  /// 审批请求的投递策略：优先给订阅了该会话的连接；**无人订阅时退化为全网广播**。
  /// 否则 App 在后台或断线期间产生的审批会被静默丢弃，DSH 只能干等超时自动拒绝。
  #broadcastPermission(sessionId, frame) {
    let delivered = 0;
    for (const conn of this.conns) {
      if (conn.device && conn.subscribed.has(sessionId)) {
        this.#send(conn, frame);
        delivered += 1;
      }
    }
    if (delivered === 0) {
      for (const conn of this.conns) {
        if (conn.device) this.#send(conn, frame);
      }
    }
  }

  // ---------------------------------------------------------------- connections

  #onConnection(ws, req) {
    const conn = {
      ws,
      remote: req.socket.remoteAddress,
      device: null,
      subscribed: new Set(),
      authTimer: null,
    };
    this.conns.add(conn);

    conn.authTimer = setTimeout(() => {
      if (!conn.device) {
        this.#send(conn, { v: PROTOCOL_VERSION, type: 'error', code: 'auth_required', message: '未在时限内完成握手' });
        ws.close();
      }
    }, AUTH_GRACE_MS);

    ws.on('message', (raw) => {
      let msg;
      try {
        msg = JSON.parse(raw.toString());
      } catch {
        this.#send(conn, { v: PROTOCOL_VERSION, type: 'error', code: 'bad_request', message: '不是合法 JSON' });
        return;
      }
      this.#handle(conn, msg).catch((err) => {
        this.log('[bridge] 处理消息失败：', err.message);
        this.#send(conn, { v: PROTOCOL_VERSION, type: 'error', id: msg.id, code: 'internal', message: err.message });
      });
    });

    ws.on('close', () => {
      clearTimeout(conn.authTimer);
      this.conns.delete(conn);
    });
    ws.on('error', (err) => this.log('[bridge] ws 错误：', err.message));
  }

  #send(conn, frame) {
    if (conn.ws.readyState !== 1) return;
    conn.ws.send(JSON.stringify(frame));
  }

  #broadcast(sessionId, frame) {
    for (const conn of this.conns) {
      if (conn.device && conn.subscribed.has(sessionId)) this.#send(conn, frame);
    }
  }

  #broadcastAll(frame) {
    for (const conn of this.conns) {
      if (conn.device) this.#send(conn, frame);
    }
  }

  #error(conn, id, code, message) {
    this.#send(conn, { v: PROTOCOL_VERSION, type: 'error', id, code, message });
  }

  async #handle(conn, msg) {
    const type = msg?.type;

    // ---- 未认证前的两条通道
    if (type === 'pair') {
      try {
        const { deviceId, deviceToken, deviceName } = this.store.pair(msg.code, msg.deviceName);
        conn.device = { deviceId, name: deviceName };
        clearTimeout(conn.authTimer);
        this.log(`[bridge] 新设备配对成功：${deviceName} (${deviceId})`);
        this.#send(conn, { v: PROTOCOL_VERSION, type: 'pair_ok', id: msg.id, deviceId, deviceToken });
      } catch (err) {
        this.#error(conn, msg.id, err.code ?? 'pair_failed', err.message);
      }
      return;
    }

    if (type === 'hello') {
      const device = this.store.verifyToken(msg.deviceToken);
      if (!device) {
        this.#error(conn, msg.id, msg.deviceToken ? 'auth_failed' : 'auth_required', '设备凭据无效或已被吊销');
        return;
      }
      conn.device = { deviceId: device.deviceId, name: device.name };
      clearTimeout(conn.authTimer);
      this.#send(conn, {
        v: PROTOCOL_VERSION,
        type: 'hello_ok',
        id: msg.id,
        deviceId: device.deviceId,
        protocolVersion: PROTOCOL_VERSION,
        host: {
          name: this.config.hostName,
          dshVersion: this.acp.agentInfo?.version ?? null,
          cwd: this.config.cwd,
          permissionMode: this.config.permissionMode,
        },
        sessions: this.registry.list(),
      });
      return;
    }

    if (!conn.device) {
      this.#error(conn, msg.id, 'auth_required', '请先配对或握手');
      return;
    }

    // ---- 已认证
    switch (type) {
      case 'ping':
        this.#send(conn, { v: PROTOCOL_VERSION, type: 'pong', id: msg.id });
        return;

      case 'list_sessions': {
        await this.#hydrateFromAcpList();
        this.#send(conn, { v: PROTOCOL_VERSION, type: 'sessions', id: msg.id, sessions: this.registry.list() });
        return;
      }

      case 'new_session': {
        const cwd = msg.cwd || this.config.cwd;
        const created = await this.acp.request('session/new', { cwd, mcpServers: [] });
        const session = this.registry.add({ acpSessionId: created.sessionId, cwd, configOptions: created.configOptions ?? null });
        this.#send(conn, {
          v: PROTOCOL_VERSION, type: 'session', id: msg.id,
          session: { id: session.id, cwd: session.cwd, configOptions: session.configOptions, lastSeq: 0 },
        });
        return;
      }

      case 'resume_session': {
        const session = this.registry.get(msg.sessionId);
        if (!session) return this.#error(conn, msg.id, 'session_not_found', '会话不存在');
        await this.acp.request('session/resume', { sessionId: session.acpSessionId, cwd: session.cwd });
        this.#send(conn, {
          v: PROTOCOL_VERSION, type: 'session', id: msg.id,
          session: { id: session.id, cwd: session.cwd, configOptions: session.configOptions, lastSeq: session.seq },
        });
        return;
      }

      case 'close_session': {
        const session = this.registry.get(msg.sessionId);
        if (!session) return this.#error(conn, msg.id, 'session_not_found', '会话不存在');
        await this.acp.request('session/close', { sessionId: session.acpSessionId });
        this.registry.remove(session.id);
        this.#send(conn, { v: PROTOCOL_VERSION, type: 'closed', id: msg.id, sessionId: session.id });
        return;
      }

      case 'subscribe': {
        const session = this.registry.get(msg.sessionId);
        if (!session) return this.#error(conn, msg.id, 'session_not_found', '会话不存在');
        conn.subscribed.add(session.id);

        // 先补发断线期间未决的审批请求：它们比历史事件更需要被立即看到
        for (const entry of session.pendingPermissions.values()) {
          if (entry.frame) this.#send(conn, entry.frame);
        }

        const fromSeq = Number.isFinite(msg.fromSeq) ? msg.fromSeq : session.seq;
        const slice = this.registry.eventsSince(session.id, fromSeq);
        this.#send(conn, {
          v: PROTOCOL_VERSION, type: 'subscribed', id: msg.id, sessionId: session.id,
          fromSeq, toSeq: slice.toSeq, needSnapshot: slice.needSnapshot,
        });
        if (slice.needSnapshot) {
          this.#send(conn, {
            v: PROTOCOL_VERSION, type: 'update', sessionId: session.id, seq: slice.toSeq,
            update: this.registry.snapshot(session.id),
          });
        } else {
          for (const event of slice.events) {
            this.#send(conn, {
              v: PROTOCOL_VERSION, type: 'update', sessionId: session.id, seq: event.seq, update: event.update,
            });
          }
        }
        return;
      }

      case 'unsubscribe':
        conn.subscribed.delete(msg.sessionId);
        this.#send(conn, { v: PROTOCOL_VERSION, type: 'unsubscribed', id: msg.id, sessionId: msg.sessionId });
        return;

      case 'prompt': {
        const session = this.registry.get(msg.sessionId);
        if (!session) return this.#error(conn, msg.id, 'session_not_found', '会话不存在');
        if (session.status !== 'idle') return this.#error(conn, msg.id, 'busy', '该会话正在执行，请先等待或取消');

        this.#send(conn, {
          v: PROTOCOL_VERSION, type: 'accepted', id: msg.id, sessionId: session.id,
          clientMsgId: msg.clientMsgId ?? null, queued: true,
        });
        this.registry.setStatus(session.id, 'running');
        this.acp
          .request('session/prompt', { sessionId: session.acpSessionId, prompt: [{ type: 'text', text: msg.text ?? '' }] })
          .catch((err) => {
            this.#broadcast(session.id, {
              v: PROTOCOL_VERSION, type: 'error', code: 'dsh_error', message: err.message,
            });
          })
          .finally(() => this.registry.setStatus(session.id, 'idle'));
        return;
      }

      case 'cancel': {
        const session = this.registry.get(msg.sessionId);
        if (!session) return this.#error(conn, msg.id, 'session_not_found', '会话不存在');
        this.registry.setStatus(session.id, 'cancelling');
        this.acp.notify('session/cancel', { sessionId: session.acpSessionId });
        this.#send(conn, { v: PROTOCOL_VERSION, type: 'session_status', id: msg.id, sessionId: session.id, state: 'cancelling' });
        return;
      }

      case 'permission_decision': {
        const session = this.registry.get(msg.sessionId);
        if (!session) return this.#error(conn, msg.id, 'session_not_found', '会话不存在');
        const entry = session.pendingPermissions.get(msg.requestId);
        if (!entry) return this.#error(conn, msg.id, 'permission_timeout', '该审批已失效');
        clearTimeout(entry.timer);
        session.pendingPermissions.delete(msg.requestId);

        if (msg.decision === 'allow_session') {
          session.allowedCommands ??= new Set();
          if (entry.command) session.allowedCommands.add(entry.command);
        }
        const optionId = msg.decision === 'reject_once' ? 'reject-once' : 'allow-once';
        this.acp.respond(entry.acpRequestId, { outcome: { outcome: 'selected', optionId } });
        this.#send(conn, { v: PROTOCOL_VERSION, type: 'permission_ack', id: msg.id, requestId: msg.requestId, applied: true });
        return;
      }

      case 'set_config': {
        const session = this.registry.get(msg.sessionId);
        if (!session) return this.#error(conn, msg.id, 'session_not_found', '会话不存在');
        const result = await this.acp.request('session/set_config_option', {
          sessionId: session.acpSessionId, configId: msg.configId, value: msg.value,
        });
        session.configOptions = result?.configOptions ?? session.configOptions;
        this.#send(conn, {
          v: PROTOCOL_VERSION, type: 'config', id: msg.id, sessionId: session.id, configOptions: session.configOptions,
        });
        return;
      }

      default:
        this.#error(conn, msg.id, 'unknown_type', `桥不认识的 type: ${type}`);
    }
  }

  // ---------------------------------------------------------------- management

  #handleHttp(req, res) {
    const isLoopback =
      req.socket.remoteAddress === '127.0.0.1' ||
      req.socket.remoteAddress === '::1' ||
      req.socket.remoteAddress === '::ffff:127.0.0.1';
    if (!isLoopback) {
      res.writeHead(403, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: '管理端点仅允许本机访问' }));
      return;
    }

    const url = new URL(req.url, 'http://localhost');
    const json = (code, body) => {
      res.writeHead(code, { 'content-type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify(body, null, 2));
    };

    if (url.pathname === '/health') {
      return json(200, {
        ok: true,
        protocol: this.protocol,
        fingerprint: this.fingerprint,
        dsh: this.dshState,
        agent: this.acp.agentInfo,
        capabilities: this.acp.agentCapabilities,
        permissionMode: this.config.permissionMode,
        cwd: this.config.cwd,
        sessions: this.registry.list().length,
        devices: this.store.listDevices().filter((d) => !d.revoked).length,
      });
    }
    if (url.pathname === '/pair') {
      const { code, expiresAt, ttlSeconds } = this.store.createPairCode();
      return json(200, {
        code,
        expiresAt,
        ttlSeconds,
        host: this.config.host,
        port: this.config.port,
        cwd: this.config.cwd,
        protocol: this.protocol,
        fingerprint: this.fingerprint,
      });
    }
    if (url.pathname === '/devices') return json(200, { devices: this.store.listDevices() });
    if (url.pathname === '/devices/revoke' && req.method === 'POST') {
      const deviceId = url.searchParams.get('deviceId');
      if (!deviceId) return json(400, { error: 'deviceId required' });
      return json(200, { revoked: this.store.revokeDevice(deviceId) });
    }
    if (url.pathname === '/sessions') return json(200, { sessions: this.registry.list() });

    return json(404, { error: 'not found' });
  }
}
