/**
 * 会话注册表：把 ACP 的会话/更新翻译成桥协议。
 *
 * 职责：
 *  - 桥会话 id（对外稳定）与 ACP sessionId（内部、不泄漏）的双向映射
 *  - session/update → 桥协议归一化 update
 *  - 每会话单调递增 seq 与有界事件日志（断线补拉）
 *  - 工具详情缓存（ACP 的权限请求只给 toolCallId，必须回查 rawInput）
 */

const MAX_EVENTS_PER_SESSION = 2000;

export function textOfContent(content) {
  if (!Array.isArray(content)) return '';
  return content
    .map((c) => {
      if (c?.type === 'content') return c.content?.text ?? '';
      if (c?.type === 'text') return c.text ?? '';
      return '';
    })
    .filter(Boolean)
    .join('\n');
}

/** ACP session/update → 桥协议 update（未知类型返回 null，由调用方忽略）。 */
export function normalizeUpdate(u) {
  switch (u?.sessionUpdate) {
    case 'agent_message_chunk':
      return { kind: 'message', messageId: u.messageId, text: u.content?.text ?? '', complete: true };
    case 'agent_thought_chunk':
      return { kind: 'thought', messageId: u.messageId, text: u.content?.text ?? '' };
    case 'tool_call':
      return {
        kind: 'tool_call',
        toolCallId: u.toolCallId,
        title: u.title ?? null,
        toolKind: u.kind ?? null,
        status: u.status ?? null,
        command: u.rawInput?.command ?? null,
        description: u.rawInput?.description ?? null,
      };
    case 'tool_call_update':
      return {
        kind: 'tool_result',
        toolCallId: u.toolCallId,
        status: u.status ?? null,
        output: textOfContent(u.content),
      };
    case 'usage_update':
      return { kind: 'usage', used: u.used ?? null, size: u.size ?? null };
    default:
      return null;
  }
}

export class SessionRegistry {
  #sessions = new Map(); // 桥 id -> session
  #byAcp = new Map(); // ACP sessionId -> 桥 id
  #counter = 0;

  /**
   * @param {(session: object, event: object) => void} onEvent 有新事件时回调（用于推送）
   * @param {(sessionId: string, status: string) => void} onStatus 状态变化回调
   */
  constructor({ onEvent = () => {}, onStatus = () => {} } = {}) {
    this.onEvent = onEvent;
    this.onStatus = onStatus;
  }

  nextId() {
    this.#counter += 1;
    return `s_${this.#counter}`;
  }

  add({ acpSessionId, cwd, configOptions = null }) {
    const session = {
      id: this.nextId(),
      acpSessionId,
      cwd,
      title: null, // ACP 不提供标题
      status: 'idle', // idle | running | cancelling
      seq: 0,
      events: [],
      toolCalls: new Map(), // toolCallId -> { title, command, description }
      pendingPermissions: new Map(), // requestId -> { acpRequestId, toolCallId, options, expiresAt }
      configOptions,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    this.#sessions.set(session.id, session);
    if (acpSessionId) this.#byAcp.set(acpSessionId, session.id);
    return session;
  }

  get(id) {
    return this.#sessions.get(id) ?? null;
  }

  byAcpId(acpSessionId) {
    const id = this.#byAcp.get(acpSessionId);
    return id ? this.#sessions.get(id) : null;
  }

  remove(id) {
    const session = this.#sessions.get(id);
    if (!session) return false;
    if (session.acpSessionId) this.#byAcp.delete(session.acpSessionId);
    this.#sessions.delete(id);
    return true;
  }

  list() {
    return [...this.#sessions.values()]
      .sort((a, b) => b.updatedAt - a.updatedAt)
      .map((s) => ({
        id: s.id,
        cwd: s.cwd,
        title: s.title,
        status: s.status,
        lastSeq: s.seq,
        updatedAt: s.updatedAt,
      }));
  }

  setStatus(id, status) {
    const session = this.get(id);
    if (!session || session.status === status) return;
    session.status = status;
    session.updatedAt = Date.now();
    this.onStatus(id, status);
  }

  /** 归一化并入队一条 ACP 更新。返回事件或 null。 */
  pushUpdate(acpSessionId, rawUpdate) {
    const session = this.byAcpId(acpSessionId);
    if (!session) return null;
    const update = normalizeUpdate(rawUpdate);
    if (!update) return null;

    if (update.kind === 'tool_call' && update.toolCallId) {
      session.toolCalls.set(update.toolCallId, {
        title: update.title,
        command: update.command,
        description: update.description,
      });
    }

    session.seq += 1;
    session.updatedAt = Date.now();
    const event = { seq: session.seq, at: Date.now(), update };
    session.events.push(event);
    if (session.events.length > MAX_EVENTS_PER_SESSION) session.events.shift();
    this.onEvent(session, event);
    return event;
  }

  /** 补拉：返回 [fromSeq, toSeq] 区间内的事件，以及是否已超出日志窗口。 */
  eventsSince(id, fromSeq) {
    const session = this.get(id);
    if (!session) return null;
    const oldest = session.events.length ? session.events[0].seq : session.seq;
    const needSnapshot = session.events.length >= MAX_EVENTS_PER_SESSION && fromSeq < oldest;
    const events = session.events.filter((e) => e.seq > fromSeq);
    return { fromSeq, toSeq: session.seq, needSnapshot, events };
  }

  /** 构造快照（补拉窗口不足时使用）。 */
  snapshot(id) {
    const session = this.get(id);
    if (!session) return null;
    return {
      kind: 'snapshot',
      status: session.status,
      messages: session.events
        .filter((e) => e.update.kind === 'message' || e.update.kind === 'thought')
        .map((e) => e.update),
      pendingPermissions: [...session.pendingPermissions.entries()].map(([requestId, p]) => ({
        requestId,
        toolCallId: p.toolCallId,
        expiresAt: p.expiresAt,
      })),
    };
  }
}
