// 验证 LiteRtLmBridge 发出去的 SSE 会不会被 DSH 客户端判为「流非法」。
//
// 判定逻辑**逐行抄自** DSH 客户端的真实文件：
//   app/node_modules/@earendil-works/pi-ai/dist/api/openai-completions.js
//   （chunk 循环在 378-412 行；抛错条件在 494-502 行；supportsFinishReason 默认 true 在 1282 行）
//
// 运行：node verify-sse.mjs

// detectCompat() 对 OpenAI 兼容 provider 的默认值（openai-completions.js:1282）
const supportsFinishReason = true;

function parseSse(raw, label) {
  let hasFinishReason = false;
  let stopReason = "pending";
  let text = "";
  for (const line of raw.split("\n")) {
    if (!line.startsWith("data: ")) continue;
    const data = line.slice(6).trim();
    if (data === "[DONE]") continue;
    const chunk = JSON.parse(data);

    // ↓↓↓ 以下判定抄自 openai-completions.js 的 chunk 循环 ↓↓↓
    const choice = Array.isArray(chunk.choices) ? chunk.choices[0] : undefined;
    if (!choice) continue; // choices 为空的分片直接跳过
    if (choice.finish_reason) {
      stopReason = choice.finish_reason === "stop" ? "stop" : choice.finish_reason;
      hasFinishReason = true;
    }
    if (choice.delta) {
      if (
        choice.delta.content !== null &&
        choice.delta.content !== undefined &&
        choice.delta.content.length > 0
      ) {
        text += choice.delta.content;
      }
    }
    // ↑↑↑ 抄完 ↑↑↑
  }
  if (!hasFinishReason && !supportsFinishReason) {
    stopReason = "stop";
  }
  if ((supportsFinishReason && !hasFinishReason) || stopReason === "pending") {
    return { label, ok: false, err: "Stream ended without finish_reason", text };
  }
  return { label, ok: true, err: null, text, stopReason };
}

const timings = { prompt_ms: 123, predicted_per_second: 42.0, predicted_n: 24 };

// 旧写法：收尾分片 choices 为空数组
function sseOld() {
  const cs = [
    { id: "litertlm", object: "chat.completion.chunk", model: "local", choices: [{ index: 0, delta: { content: "黑洞" } }] },
    { id: "litertlm", object: "chat.completion.chunk", model: "local", choices: [{ index: 0, delta: { content: "是一种天体。" } }] },
    { id: "litertlm", object: "chat.completion.chunk", model: "local", choices: [], timings },
  ];
  return cs.map((c) => "data: " + JSON.stringify(c) + "\n\n").join("") + "data: [DONE]\n\n";
}

// 新写法：收尾分片带 finish_reason:"stop"
function sseNew() {
  const cs = [
    { id: "litertlm", object: "chat.completion.chunk", model: "local", choices: [{ index: 0, delta: { content: "黑洞" } }] },
    { id: "litertlm", object: "chat.completion.chunk", model: "local", choices: [{ index: 0, delta: { content: "是一种天体。" } }] },
    { id: "litertlm", object: "chat.completion.chunk", model: "local", choices: [{ index: 0, delta: {}, finish_reason: "stop" }], timings },
  ];
  return cs.map((c) => "data: " + JSON.stringify(c) + "\n\n").join("") + "data: [DONE]\n\n";
}

const rOld = parseSse(sseOld(), "旧（choices: []）");
const rNew = parseSse(sseNew(), "新（带 finish_reason）");

for (const r of [rOld, rNew]) {
  console.log(
    `[${r.label}] ok=${r.ok}` +
      (r.ok ? ` stopReason=${r.stopReason} 正文="${r.text}"` : ` 报错="${r.err}"`)
  );
}
const ok = rOld.ok === false && rNew.ok === true && rNew.text === "黑洞是一种天体。";
console.log();
console.log(ok
  ? "✅ 结论：旧写法会被 DSH 判为「流非法」（生成成功却报错）；新写法合法且正文完整"
  : "❌ 结论不符");
process.exit(ok ? 0 : 1);
