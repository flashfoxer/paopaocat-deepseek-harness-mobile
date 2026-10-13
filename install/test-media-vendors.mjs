/**
 * `assets/toolbox/media-vendors.mjs` 的**形状对账**测试（纯 node，不需要真机/网络）。
 *
 * 为什么要有：这张表是"发给上游的请求长什么样"的**唯一来源**。写错了的后果不是崩溃，
 * 而是**真机上必然失败、而且报错指向"参数不对"** —— 很容易被当成"这家模型不支持"。
 *
 * 2026-10-12 用户要求核实端点真实性，对官方文档逐条查之后抓到 MiniMax 三处错
 * （见下面的 minimax 组），所以把对账口径钉在这里。
 *
 * 跑法：node install/test-media-vendors.mjs
 */
import { VENDORS, VENDOR_IDS, imagePlan, videoPlan, registerUrl } from '../app/assets/toolbox/media-vendors.mjs';

let pass = 0;
let fail = 0;
const eq = (got, want, what) => {
  if (got === want) { pass++; console.log(`  ✅ ${what}`); }
  else { fail++; console.log(`  ❌ ${what}\n     期望 ${JSON.stringify(want)}\n     实际 ${JSON.stringify(got)}`); }
};
const ok = (cond, what, extra = '') => {
  if (cond) { pass++; console.log(`  ✅ ${what}`); }
  else { fail++; console.log(`  ❌ ${what}${extra ? `\n     ${extra}` : ''}`); }
};

// ── ① 每一家的 base 与注册地址都得是 https 且非空（unknown 除外）──────
console.log('\n① base / 注册地址');
for (const id of VENDOR_IDS) {
  if (id === 'unknown') continue;
  const v = VENDORS[id];
  ok(/^https:\/\//.test(v.base), `${id}.base 是 https 且非空 → ${v.base}`);
  ok(/^https:\/\//.test(registerUrl(id)), `${id}.register 是 https → ${registerUrl(id)}`);
}
eq(registerUrl('unknown'), '', '自定义厂家没有注册地址（**不猜**，界面据此不显示链接）');

// ── ② 端点逐条对官方文档（2026-10-12 核实）────────────────────────────
console.log('\n② 端点与官方文档一致');

// 通义万相（阿里云百炼）：异步创建 + /api/v1/tasks/{id} 查询
// 依据：https://help.aliyun.com/zh/model-studio/first-call-to-image-and-video-api
{
  const p = imagePlan('dashscope', { model: 'wan2.6-t2i', prompt: 'x', size: '1024*1024' });
  eq(p.endpoint, 'https://dashscope.aliyuncs.com/api/v1/services/aigc/text2image/image-synthesis',
     '万相·图像创建任务 URL');
  eq(p.body.parameters.size, '1024*1024', '万相·尺寸用星号（不是 x）');
  eq(p.headers['x-dashscope-async'], 'enable',
     '万相·必须带 X-DashScope-Async: enable（缺了会报 current user api does not support synchronous calls）');
  const v = videoPlan('dashscope', { model: 'wan2.1-t2v-turbo', prompt: 'x', seconds: 5 });
  eq(v.submit.url, 'https://dashscope.aliyuncs.com/api/v1/services/aigc/video-generation/video-synthesis',
     '万相·视频创建任务 URL');
  eq(v.poll.url('T1'), 'https://dashscope.aliyuncs.com/api/v1/tasks/T1',
     '万相·任务查询 → /api/v1/tasks/{id}（图像与视频共用）');
}

// MiniMax：**V2**（H3）—— 这一组是本次修掉的真 bug
{
  const v = videoPlan('minimax', { model: 'MiniMax-H3', prompt: '一只猫', seconds: 6, resolution: '768P', ratio: '16:9' });
  eq(v.submit.url, 'https://api.minimax.cn/v2/video_generation',
     'MiniMax·创建任务走 **v2**（文档：platform.minimax.cn/docs/api-reference/video-generation-v2-create）');
  // ⚠️ v2 没有 prompt 字段，文本必须放进 content[] —— 发 prompt 会回
  //    invalid params, content must include a non-empty text item (2013)
  eq(v.submit.body.prompt, undefined, 'MiniMax v2 **不许**有 prompt 字段');
  ok(Array.isArray(v.submit.body.content), 'MiniMax v2 用 content 数组');
  eq(v.submit.body.content[0].type, 'text', 'content[0] 是文本项');
  eq(v.submit.body.content[0].text, '一只猫', 'content[0].text 就是提示词');
  eq(v.submit.body.ratio, '16:9', '文生视频给具体比例');
  eq(v.poll.url('T1'), 'https://api.minimax.cn/v2/query/video_generation/T1',
     'MiniMax·查询走 **v2** 且 task_id 是**路径段**（v1 才是 ?task_id=）');

  // 图生视频：首帧进 content[]，比例强制 adaptive
  const i = videoPlan('minimax', {
    model: 'MiniMax-H3', prompt: '动起来', seconds: 6, resolution: '768P', ratio: '16:9',
    firstFrame: { dataUri: 'data:image/png;base64,AAA' },
  });
  eq(i.submit.body.first_frame, undefined, 'MiniMax v2 **不许**有 first_frame 字段（那是 v1 的）');
  eq(i.submit.body.content[1].role, 'first_frame', '首帧用 content[].role=first_frame');
  eq(i.submit.body.content[1].image_url.url, 'data:image/png;base64,AAA', '首帧地址在 image_url.url');
  eq(i.submit.body.ratio, 'adaptive', '图生视频比例必须是 adaptive（文档要求）');

  // 成功响应解析：v2 是 {task:{status, content:{url}}}
  eq(v.pick({ task: { status: 'succeeded', content: { url: 'https://x/a.mp4' } } }).url, 'https://x/a.mp4',
     'MiniMax v2 成功响应取 task.content.url');
  eq(v.pick({ task: { status: 'running' } }).state, 'running', 'running 状态');
  const bad = v.pick({ task: { status: 'failed', error: { code: 2013, message: '参数不对' } } });
  eq(bad.state, 'failed', 'failed 状态');
  eq(bad.message, '参数不对', 'v2 的错误是对象 —— 要取 .message，不能 String(对象) 变成 [object Object]');
}

// SiliconFlow：/video/submit + /video/status（{requestId}）
{
  const v = videoPlan('siliconflow', { model: 'Wan-AI/Wan2.2-T2V-A14B', prompt: 'x' });
  ok(v.submit.url.endsWith('/video/submit'), `SiliconFlow·提交 → ${v.submit.url}`);
  eq(v.poll.url('R1').endsWith('/video/status'), true, 'SiliconFlow·查询 → /video/status');
  eq(v.poll.bodyOf('R1').requestId, 'R1', 'SiliconFlow·查询体是 {requestId}');
}

// OpenAI / 智谱 / 豆包 / 硅基流动：图像走 OpenAI 兼容的 /images/generations
for (const [id, base] of [
  ['openai', 'https://api.openai.com/v1'],
  ['zhipu', 'https://open.bigmodel.cn/api/paas/v4'],
  ['doubao', 'https://ark.cn-beijing.volces.com/api/v3'],
  ['siliconflow', 'https://api.siliconflow.cn/v1'],
]) {
  const p = imagePlan(id, { model: 'm', prompt: 'x', size: '1024x1024' });
  eq(p.endpoint, `${base}/images/generations`, `${id}·图像 → /images/generations`);
}

console.log(`\n${fail === 0 ? '全部通过' : '有失败'}：${pass} 通过 / ${fail} 失败`);
process.exit(fail === 0 ? 0 : 1);
