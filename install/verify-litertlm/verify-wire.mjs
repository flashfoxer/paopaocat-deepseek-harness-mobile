// 用 DSH 手机运行时里**真正的那份 openai SDK（v6.40.0）**去解析 LiteRtLmBridge 的响应。
//
// 目的：验证桥发出的**字节级** HTTP/SSE 形状能被 DSH 的客户端栈接受 —— 包括
//   * 只有 Connection: close、**没有** Content-Length / Transfer-Encoding 的分帧
//     （writeSseHeaders 就是这么写的）；
//   * data: {...}\n\n 分片 + data: [DONE]\n\n 收尾；
//   * 收尾分片里 delta 为空、带 finish_reason:"stop"。
//
// 运行：cd /tmp/sdktest/app && node verify-wire.mjs
import net from 'node:net';
import OpenAI from 'openai';

// ── 与 LiteRtLmBridge 输出**逐字段一致**的两段正文 ────────────────────────
const timings = { prompt_ms: 123.4, prompt_n: 2, prompt_per_second: 0, predicted_n: 24, predicted_ms: 500, predicted_per_second: 48.0, approx: true, reused: false };
const bodyChunks = [
  { id: 'litertlm', object: 'chat.completion.chunk', model: 'local', choices: [{ index: 0, delta: { content: '黑洞' } }] },
  { id: 'litertlm', object: 'chat.completion.chunk', model: 'local', choices: [{ index: 0, delta: { content: '是时空弯曲' } }] },
  { id: 'litertlm', object: 'chat.completion.chunk', model: 'local', choices: [{ index: 0, delta: { content: '到极致的天体。' } }] },
];

// 收尾分片：修复前 choices:[]，修复后带 finish_reason
function finishChunk(withFinishReason) {
  return {
    id: 'litertlm', object: 'chat.completion.chunk', model: 'local',
    choices: withFinishReason
      ? [{ index: 0, delta: {}, finish_reason: 'stop' }]
      : [],
    timings,
  };
}

function bridgeResponseBytes(withFinishReason) {
  // 与 LiteRtLmBridge.writeSseHeaders 一致：**没有** Content-Length / Transfer-Encoding
  const head =
    'HTTP/1.1 200 OK\r\n' +
    'Content-Type: text/event-stream; charset=utf-8\r\n' +
    'Cache-Control: no-cache\r\n' +
    'Connection: close\r\n\r\n';
  const sse =
    [...bodyChunks, finishChunk(withFinishReason)]
      .map((c) => 'data: ' + JSON.stringify(c) + '\n\n')
      .join('') + 'data: [DONE]\n\n';
  return head + sse;
}

/** 裸 TCP：收到完整请求头后，把桥的**原始字节**写回去，然后关闭（模拟 client.use 结束）。 */
function startServer(withFinishReason) {
  const bytes = Buffer.from(bridgeResponseBytes(withFinishReason), 'utf8');
  const server = net.createServer((sock) => {
    let buf = '';
    sock.on('data', (d) => {
      buf += d.toString('latin1');
      if (!buf.includes('\r\n\r\n')) return;
      sock.write(bytes);
      sock.end();
    });
    sock.on('error', () => {});
  });
  return new Promise((res) => server.listen(0, '127.0.0.1', () => res({ server, port: server.address().port })));
}

async function runCase(withFinishReason, label) {
  const { server, port } = await startServer(withFinishReason);
  const client = new OpenAI({ apiKey: 'local', baseURL: `http://127.0.0.1:${port}/v1`, maxRetries: 0 });
  let text = '';
  let finish = null;
  let chunkCount = 0;
  let sdkError = null;
  try {
    const stream = await client.chat.completions.create({
      model: 'local',
      stream: true,
      messages: [{ role: 'user', content: '你好' }],
    });
    for await (const chunk of stream) {
      chunkCount++;
      const choice = chunk.choices?.[0];
      if (!choice) continue;
      if (choice.delta?.content) text += choice.delta.content;
      if (choice.finish_reason) finish = choice.finish_reason;
    }
  } catch (e) {
    sdkError = e.message;
  }
  server.close();

  // ── 再套一遍 pi-ai 的抛错条件（openai-completions.js:501）──
  const supportsFinishReason = true; // detectCompat() 默认
  const hasFinishReason = finish !== null;
  const wouldThrow = (supportsFinishReason && !hasFinishReason);

  console.log(`[${label}]`);
  console.log(`   SDK 报错      : ${sdkError ?? '(无)'}`);
  console.log(`   收到分片数    : ${chunkCount}`);
  console.log(`   拼出的正文    : "${text}"`);
  console.log(`   finish_reason : ${finish === null ? '(未收到)' : finish}`);
  console.log(`   pi-ai 会不会抛: ${wouldThrow ? '会 ❌ Stream ended without finish_reason' : '不会 ✅'}`);
  return { sdkError, text, finish, wouldThrow };
}

const oldR = await runCase(false, '修复前（收尾 choices: []）');
const newR = await runCase(true, '修复后（收尾带 finish_reason）');

const ok =
  oldR.sdkError === null &&
  newR.sdkError === null &&
  newR.text === '黑洞是时空弯曲到极致的天体。' &&
  newR.finish === 'stop' &&
  oldR.wouldThrow === true &&
  newR.wouldThrow === false;
console.log();
console.log(ok
  ? '✅ 结论：桥的字节级 HTTP/SSE 形状能被真 openai SDK 正常解析；修复前的收尾会被 pi-ai 判为流非法，修复后合法且正文完整'
  : '❌ 结论不符，见上面各项');
process.exit(ok ? 0 : 1);
