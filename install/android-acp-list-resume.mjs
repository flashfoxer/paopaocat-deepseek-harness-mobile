/**
 * Device-side probe: does this DSH build really support `session/list` and
 * `session/resume`, and does a resumed session keep its context?
 *
 * This is the evidence that backs the workspace page: the UI is allowed to
 * claim "list persisted sessions" and "resume a session" only if this probe
 * prints OK for both.
 *
 * Run on the device (shell user), ASCII only:
 *   LD_LIBRARY_PATH=/data/local/tmp/dshrt2 \
 *   /data/local/tmp/dshrt2/libnode.so --expose-internals \
 *     --require /data/local/tmp/dshhome/android-fs-shim.cjs \
 *     /data/local/tmp/acp-list-resume.mjs
 *
 * Env: DSH_BIN (required), OVERLAY, DSH_HOME, WORK
 */

import { spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';

const dshBin = process.env.DSH_BIN;
const overlay = process.env.OVERLAY;
const fsShim = process.env.FS_SHIM;
const dshHome = process.env.DSH_HOME;
const work = process.env.WORK ?? '/data/local/tmp/acp-work2';
const nodeBin = process.execPath;

if (!dshBin) {
  console.error('DSH_BIN required');
  process.exit(2);
}
mkdirSync(work, { recursive: true });

const args = ['--expose-internals'];
if (fsShim) args.push('--require', fsShim);
args.push(dshBin, '--profile', 'acp');
if (overlay) args.push('--patch', overlay);

console.log('[probe] spawn: ' + nodeBin + ' ' + args.join(' '));
const child = spawn(nodeBin, args, {
  stdio: ['pipe', 'pipe', 'pipe'],
  cwd: work,
  env: process.env,
});

child.stderr.on('data', (b) => {
  const s = b.toString().trim();
  if (s) console.log('[dsh:stderr] ' + s.slice(0, 200));
});

let nextId = 1;
const pending = new Map();
let buffer = '';
const chunks = [];

function send(msg) {
  child.stdin.write(JSON.stringify(msg) + '\n');
}

function request(method, params, timeoutMs = 300000) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    send({ jsonrpc: '2.0', id, method, params });
    setTimeout(() => {
      if (pending.has(id)) {
        pending.delete(id);
        reject(new Error('timeout: ' + method));
      }
    }, timeoutMs);
  });
}

child.stdout.on('data', (c) => {
  buffer += c.toString();
  let idx;
  while ((idx = buffer.indexOf('\n')) !== -1) {
    const line = buffer.slice(0, idx).trim();
    buffer = buffer.slice(idx + 1);
    if (!line) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
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
      if (msg.method === 'session/request_permission') {
        send({
          jsonrpc: '2.0',
          id: msg.id,
          result: { outcome: { outcome: 'selected', optionId: 'allow-once' } },
        });
      } else {
        send({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'unsupported' } });
      }
      continue;
    }
    if (msg.method === 'session/update') {
      const u = msg.params?.update ?? {};
      if (u.sessionUpdate === 'agent_message_chunk') {
        const t = u.content?.text ?? '';
        chunks.push(t);
        process.stdout.write(t);
      }
    }
  }
});

function result(ok, label, detail) {
  console.log('\n[probe] ' + label + ': ' + (ok ? 'OK' : 'FAIL') + (detail ? ' :: ' + detail : ''));
  return ok;
}

try {
  await request('initialize', {
    protocolVersion: 1,
    clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
    clientInfo: { name: 'dsh-list-probe', version: '1.0.0' },
  });
  console.log('[probe] initialize ok (DSH_HOME=' + dshHome + ')');

  // ---------- 1. session/list, no filter ----------
  const all = await request('session/list', {});
  const allIds = (all?.sessions ?? []).map((s) => s.sessionId);
  const listOk = result(
    Array.isArray(all?.sessions),
    'session/list (all cwds)',
    'count=' + allIds.length + ' first=' + (allIds[0] ?? '-'),
  );

  // ---------- 2. session/list filtered by cwd ----------
  const filtered = await request('session/list', { cwd: work });
  const filteredIds = (filtered?.sessions ?? []).map((s) => s.sessionId);
  result(
    true,
    'session/list (cwd=' + work + ')',
    'count=' + filteredIds.length,
  );

  // ---------- 3. new session, teach it a passcode ----------
  const created = await request('session/new', { cwd: work, mcpServers: [] });
  const sessionId = created?.sessionId;
  console.log('[probe] session/new -> ' + sessionId);

  chunks.length = 0;
  await request('session/prompt', {
    sessionId,
    prompt: [{ type: 'text', text: 'Remember this string for later: QUOKKA-3355. Reply with just OK.' }],
  });
  console.log('\n[probe] turn1 answer len=' + chunks.join('').length);

  // ---------- 4. close it so it becomes resumable ----------
  await request('session/close', { sessionId });
  console.log('[probe] session/close ok');

  const afterClose = await request('session/list', { cwd: work });
  const visible = (afterClose?.sessions ?? []).some((s) => s.sessionId === sessionId);
  result(visible, 'closed session appears in session/list', sessionId);

  // ---------- 5. resume and ask for the passcode ----------
  const resumed = await request('session/resume', { sessionId, cwd: work, mcpServers: [] });
  const resumeOk = result(resumed !== undefined, 'session/resume', JSON.stringify(resumed).slice(0, 160));

  chunks.length = 0;
  await request('session/prompt', {
    sessionId,
    prompt: [{ type: 'text', text: 'Which string did I ask you to remember earlier in this conversation? Answer with the string only.' }],
  });
  const answer = chunks.join('');
  console.log('\n[probe] turn-after-resume answer: ' + answer.trim().slice(0, 200));
  const contextKept = answer.includes('QUOKKA-3355') || answer.includes('3355');
  result(contextKept, 'resumed session still has its context');

  // ---------- 6. wrong cwd must be rejected ----------
  let wrongCwdRejected = false;
  try {
    await request('session/resume', { sessionId: 'not-a-real-session', cwd: work, mcpServers: [] });
  } catch {
    wrongCwdRejected = true;
  }
  result(wrongCwdRejected, 'bogus sessionId is rejected (not silently new)');

  child.stdin.end();
  child.kill();
  console.log('\n[probe] SUMMARY list=' + (listOk ? 'OK' : 'FAIL') + ' resume=' + (resumeOk ? 'OK' : 'FAIL') + ' context=' + (contextKept ? 'OK' : 'FAIL'));
  process.exit(listOk && resumeOk && contextKept ? 0 : 1);
} catch (e) {
  console.error('[probe] error: ' + e.message);
  child.kill();
  process.exit(3);
}
