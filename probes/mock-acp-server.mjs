#!/usr/bin/env node
/**
 * Mock ACP 服务端 —— 用于确定性验证桥的权限审批链路。
 *
 * 为什么需要它：真实 DSH 只会在**模型主动申请提权**时发出
 * `session/request_permission`（W1 实测：取决于模型决策，不确定）。
 * 桥的审批链路是 objective 的核心能力，不能靠运气验证，
 * 所以这里用一个假 ACP 服务端，在收到 session/prompt 时**必定**发一次权限请求。
 *
 * 用法：桥启动时把 DSH_BIN 指向本文件即可
 *   $env:DSH_BIN = '<本文件绝对路径>'
 *   node bridge/src/bridge.mjs serve
 *
 * 协议：换行分帧 JSON-RPC 2.0，与真实 dsh --profile acp 一致（多传的
 * --profile / --patch 参数会被忽略）。
 */

import { createInterface } from 'node:readline';

const SESSION_ID = 'mock-session-1';
const TOOL_CALL_ID = 'call_mock_1';
const MOCK_COMMAND = 'rm -rf ./dist';

// 故意构造一个高风险命令，验证桥的 riskFlags 检测
const PERMISSION_OPTIONS = [
  { optionId: 'allow-once', name: 'Allow once', kind: 'allow_once' },
  { optionId: 'reject-once', name: 'Reject', kind: 'reject_once' },
];

const rl = createInterface({ input: process.stdin });

let serverRequestId = 0;
const pendingServerRequests = new Map();
const trace = [];

function log(...args) {
  // 只写 stderr —— stdout 是协议通道，混入任何内容都会破坏分帧
  process.stderr.write(`[mock-acp] ${args.join(' ')}\n`);
}

function send(msg) {
  trace.push({ dir: 'out', msg });
  process.stdout.write(JSON.stringify(msg) + '\n');
}

function notify(method, params) {
  send({ jsonrpc: '2.0', method, params });
}

let pendingCancel = null;

/** slow prompt 用：等待一条 session/cancel 通知（或超时）。 */
function waitForCancel(ms) {
  return new Promise((resolve) => {
    pendingCancel = resolve;
    setTimeout(() => {
      if (pendingCancel === resolve) {
        pendingCancel = null;
        resolve(false);
      }
    }, ms);
  });
}

function requestPermission(toolCallId) {
  const id = serverRequestId++;
  return new Promise((resolve) => {
    pendingServerRequests.set(id, resolve);
    send({
      jsonrpc: '2.0',
      id,
      method: 'session/request_permission',
      params: { sessionId: SESSION_ID, toolCall: { toolCallId }, options: PERMISSION_OPTIONS },
    });
  });
}

rl.on('line', async (line) => {
  const text = line.trim();
  if (!text) return;
  let msg;
  try {
    msg = JSON.parse(text);
  } catch {
    return;
  }
  trace.push({ dir: 'in', msg });

  // 客户端对我们请求的应答
  if (msg.id !== undefined && msg.method === undefined) {
    const resolve = pendingServerRequests.get(msg.id);
    if (resolve) {
      pendingServerRequests.delete(msg.id);
      resolve(msg.result);
    }
    return;
  }

  // 通知：取消（无 id）
  if (msg.method === 'session/cancel') {
    log('收到 session/cancel');
    if (pendingCancel) {
      const resolve = pendingCancel;
      pendingCancel = null;
      resolve(true);
    }
    return;
  }

  switch (msg.method) {
    case 'initialize':
      send({
        jsonrpc: '2.0',
        id: msg.id,
        result: {
          protocolVersion: 1,
          agentInfo: { name: 'mock-acp', version: '0.0.1' },
          authMethods: [],
          agentCapabilities: {
            mcpCapabilities: { http: false },
            promptCapabilities: { image: false, audio: false, embeddedContext: false },
            sessionCapabilities: { close: {}, list: {}, resume: {} },
          },
        },
      });
      return;

    case 'session/new':
      send({ jsonrpc: '2.0', id: msg.id, result: { sessionId: SESSION_ID, configOptions: [] } });
      return;

    case 'session/list':
      send({ jsonrpc: '2.0', id: msg.id, result: { sessions: [] } });
      return;

    case 'session/resume':
      send({ jsonrpc: '2.0', id: msg.id, result: {} });
      return;

    case 'session/close':
      send({ jsonrpc: '2.0', id: msg.id, result: {} });
      return;

    case 'session/prompt': {
      const promptText = msg.params?.prompt?.[0]?.text ?? '';

      // crash 模式：模拟 DSH 子进程崩溃，用于验证桥的自动重启
      if (promptText.includes('crash')) {
        log('收到 crash 指令，模拟 DSH 进程崩溃');
        process.exit(1);
      }

      // slow 模式：用于验证取消链路（等待 session/cancel 而不是立刻完成）
      if (promptText.includes('slow')) {
        log('slow prompt：等待 session/cancel（最多 30s）');
        const cancelled = await waitForCancel(30_000);
        log(`slow prompt 结束：${cancelled ? 'cancelled' : 'timeout'}`);
        send({ jsonrpc: '2.0', id: msg.id, result: { stopReason: cancelled ? 'cancelled' : 'end_turn' } });
        return;
      }

      log('收到 prompt，开始推送更新并请求权限');

      notify('session/update', {
        sessionId: SESSION_ID,
        update: {
          sessionUpdate: 'agent_message_chunk',
          messageId: 'mock-msg-1',
          content: { type: 'text', text: '准备执行命令。' },
        },
      });

      notify('session/update', {
        sessionId: SESSION_ID,
        update: {
          sessionUpdate: 'tool_call',
          toolCallId: TOOL_CALL_ID,
          title: 'pwsh',
          kind: 'other',
          status: 'in_progress',
          rawInput: { command: MOCK_COMMAND, description: 'mock destructive command' },
        },
      });

      const result = await requestPermission(TOOL_CALL_ID);
      const outcome = result?.outcome?.outcome;
      const optionId = result?.outcome?.optionId;
      const approved = outcome === 'selected' && optionId === 'allow-once';
      log(`收到审批结果 outcome=${outcome} optionId=${optionId} → ${approved ? '执行' : '拒绝'}`);

      notify('session/update', {
        sessionId: SESSION_ID,
        update: {
          sessionUpdate: 'tool_call_update',
          toolCallId: TOOL_CALL_ID,
          status: approved ? 'completed' : 'failed',
          content: [
            { type: 'content', content: { type: 'text', text: approved ? 'mock-executed' : 'mock-rejected-by-user' } },
          ],
        },
      });

      send({ jsonrpc: '2.0', id: msg.id, result: { stopReason: 'end_turn' } });
      return;
    }

    default:
      if (msg.id !== undefined) {
        send({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: `mock: unsupported ${msg.method}` } });
      }
  }
});

process.stdin.on('close', () => {
  log('stdin 关闭，退出');
  process.exit(0);
});

log('mock ACP 服务端已启动');
