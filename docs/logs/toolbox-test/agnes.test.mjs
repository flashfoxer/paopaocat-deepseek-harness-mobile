// make-image.mjs / make-video.mjs 端到端验证（本地假上游，无需真实 Agnes Key）
// 覆盖：请求方法/路径/头/体是否符合官方文档、轮询与兜底、下载落盘、成功行格式、失败路径中文报错
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const IMAGE_SCRIPT = process.argv[2];
const VIDEO_SCRIPT = process.argv[3];
const OUTDIR = process.argv[4];
const work = join(OUTDIR, 'agnes-work');
mkdirSync(work, { recursive: true });

const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
  'base64',
);
const FAKE_MP4 = Buffer.from('FAKE-MP4-BYTES-0123456789', 'utf8');
const refPng = join(work, 'ref.png');
writeFileSync(refPng, PNG);

let failures = 0;
function check(ok, label, extra) {
  console.log(`${ok ? '  ✓' : '  ✗'} ${label}${!ok && extra !== undefined ? '  ← ' + JSON.stringify(extra) : ''}`);
  if (!ok) failures += 1;
}

// ───────────────────────────────── 假上游
const seen = [];
function readRequestBody(req) {
  return new Promise((res) => {
    let b = '';
    req.on('data', (c) => { b += c; });
    req.on('end', () => res(b));
  });
}
const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  const raw = await readRequestBody(req);
  let json = null;
  try { json = JSON.parse(raw); } catch { /* 非 JSON 也记录原文 */ }
  const entry = { method: req.method, path: url.pathname, query: Object.fromEntries(url.searchParams), headers: req.headers, raw, json };
  seen.push(entry);
  const prompt = (json && json.prompt) || '';
  const jsonOut = (status, obj, extraHeaders) => {
    const body = Buffer.from(JSON.stringify(obj), 'utf8');
    res.writeHead(status, { 'content-type': 'application/json', 'content-length': String(body.length), ...(extraHeaders || {}) });
    res.end(body);
  };

  // ---- 图片
  if (req.method === 'POST' && url.pathname === '/v1/images/generations') {
    if (prompt.includes('FAIL400')) return jsonOut(400, { error: { message: 'invalid size for this model', type: 'bad_request' } });
    if (prompt.includes('B64')) return jsonOut(200, { created: 1, data: [{ url: null, b64_json: PNG.toString('base64'), revised_prompt: null }] });
    if (prompt.includes('DL404')) return jsonOut(200, { created: 1, data: [{ url: `${origin}/files/missing.png`, b64_json: null }] });
    return jsonOut(200, { created: 1780000000, data: [{ url: `${origin}/files/out.png`, b64_json: null, revised_prompt: null }] });
  }
  // ---- 视频创建
  if (req.method === 'POST' && url.pathname === '/v1/videos') {
    if (prompt.includes('FAIL400')) return jsonOut(400, { detail: 'size must be 720P' });
    // 轮询是 GET（没有 body），所以"行为模式"必须靠 video_id 带过去
    const vid = prompt.includes('FALLBACK')
      ? 'vid-fallback'
      : prompt.includes('PENDING')
        ? 'vid-pending'
        : prompt.includes('TASKFAIL')
          ? 'vid-fail'
          : 'vid-123';
    return jsonOut(200, { video_id: vid, id: 'task_abc', task_id: 'task_abc', status: 'queued', object: 'video' });
  }
  // ---- 视频查询（官方推荐路径）
  if (req.method === 'GET' && url.pathname === '/agnesapi') {
    const vid = url.searchParams.get('video_id');
    if (vid === 'vid-fallback') return jsonOut(404, { detail: 'not found' });
    if (vid === 'vid-pending') return jsonOut(200, { status: 'processing', progress: 40, internal_status: 'pending' });
    if (vid === 'vid-fail') return jsonOut(200, { status: 'failed', error: '内容被平台拒绝（假上游模拟）', progress: 0 });
    const n = seen.filter((s) => s.path === '/agnesapi').length;
    if (n <= 1) return jsonOut(200, { status: 'processing', progress: 40, internal_status: 'pending', internal_progress: 0 });
    return jsonOut(200, { status: 'completed', progress: 100, url: `${origin}/files/out.mp4`, seconds: '5', size: '720P' });
  }
  // ---- 视频查询（兜底老写法）
  if (req.method === 'GET' && /^\/v1\/videos\/[^/]+$/.test(url.pathname)) {
    return jsonOut(200, { status: 'completed', progress: 100, url: `${origin}/files/out.mp4` });
  }
  // ---- 文件下载
  if (req.method === 'GET' && url.pathname === '/files/out.png') {
    res.writeHead(200, { 'content-type': 'image/png', 'content-length': String(PNG.length) });
    return res.end(PNG);
  }
  if (req.method === 'GET' && url.pathname === '/files/out.mp4') {
    res.writeHead(200, { 'content-type': 'video/mp4', 'content-length': String(FAKE_MP4.length) });
    return res.end(FAKE_MP4);
  }
  if (req.method === 'GET' && url.pathname === '/files/missing.png') {
    const b = Buffer.from('{"detail":"no such object"}', 'utf8');
    res.writeHead(404, { 'content-type': 'application/json', 'content-length': String(b.length) });
    return res.end(b);
  }
  jsonOut(404, { detail: 'unknown path ' + url.pathname });
});

const port = await new Promise((r) => server.listen(0, '127.0.0.1', () => r(server.address().port)));
const origin = `http://127.0.0.1:${port}`;
console.log(`假上游: ${origin}（base URL 用 ${origin}/v1）`);

// ───────────────────────────────── 运行助手
// 必须用异步 spawn：假上游就跑在本进程里，spawnSync 会把事件循环卡住 → 假上游无法响应 → 死锁
function runScript(script, argv, env) {
  return new Promise((resolve) => {
    const merged = { ...process.env, AGNES_BASE_URL: `${origin}/v1`, AGNES_API_KEY: 'sk-test-123', ...env };
    for (const [k, v] of Object.entries(env || {})) if (v === null) delete merged[k];
    const child = spawn(process.execPath, [script, ...argv], { env: merged });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    const timer = setTimeout(() => child.kill('SIGKILL'), 90_000);
    child.on('close', (code) => {
      clearTimeout(timer);
      resolve({ code, stdout: stdout.trim(), stderr: stderr.trim() });
    });
  });
}
const lastOf = (path) => [...seen].reverse().find((s) => s.path === path);
const since = (n, path) => seen.slice(n).filter((s) => s.path === path);

// ═════════════════════════════════ 图片
console.log('\n=== make-image.mjs ===');
const imgOut = join(work, 'nested', 'art.png'); // 目录不存在，验证自动创建
const before = seen.length;
const r1 = await runScript(IMAGE_SCRIPT, ['一只戴头盔的猫，电影级光影，16:9', imgOut, '--size', '2K', '--ratio', '16:9', '--ref', refPng]);
check(r1.code === 0, '退出码 0（生成+下载成功）', r1);
check(/^\[agnes-image\] ok file=.+ bytes=\d+ model=agnes-image-2\.5-flash$/.test(r1.stdout), '成功行格式符合约定', r1.stdout);
check(existsSync(imgOut) && statSync(imgOut).size === PNG.length, '文件落盘且字节数正确（目录自动创建）', existsSync(imgOut) ? statSync(imgOut).size : 'missing');
const req1 = lastOf('/v1/images/generations');
check(req1.method === 'POST' && req1.path === '/v1/images/generations', 'POST /v1/images/generations', req1.path);
check(req1.headers.authorization === 'Bearer sk-test-123', 'Authorization: Bearer <KEY>', req1.headers.authorization);
check(String(req1.headers['content-type']).includes('application/json'), 'Content-Type: application/json', req1.headers['content-type']);
const b1 = req1.json;
check(b1.model === 'agnes-image-2.5-flash' && b1.prompt.includes('猫') && b1.size === '2K' && b1.ratio === '16:9', 'body: model/prompt/size/ratio 正确', b1);
check(b1.extra_body && b1.extra_body.response_format === 'url', 'response_format 在 extra_body 里', b1.extra_body);
check(!('response_format' in b1), '顶层没有 response_format（官方点名的错误写法）', Object.keys(b1));
check(Array.isArray(b1.extra_body.image) && b1.extra_body.image.length === 1, '参考图放 extra_body.image 数组里', b1.extra_body.image);
check(b1.extra_body.image[0].startsWith('data:image/png;base64,'), '本地参考图转成了 Data URI', String(b1.extra_body.image[0]).slice(0, 40));
check(!('image' in b1) && !('tags' in b1), '顶层没有 image、也没有多余的 tags', Object.keys(b1));

const r2 = await runScript(IMAGE_SCRIPT, ['B64 模式测试', join(work, 'b64.png')]);
check(r2.code === 0 && existsSync(join(work, 'b64.png')) && statSync(join(work, 'b64.png')).size === PNG.length, 'b64_json 返回也能落盘', r2);
check(/^\[agnes-image\] ok /.test(r2.stdout), 'b64 路径成功行正常', r2.stdout);

const r3 = await runScript(IMAGE_SCRIPT, ['没有 Key 的测试', join(work, 'nokey.png')], { AGNES_API_KEY: null });
check(r3.code === 2, '没有 Key → 退出码 2', r3.code);
check(r3.stderr.includes('AGNES_API_KEY') && r3.stderr.includes('platform.agnes-ai.cn') && r3.stderr.includes('免费注册'), '没有 Key 的中文报错说清去哪注册', r3.stderr.split('\n')[0]);
check(!existsSync(join(work, 'nokey.png')), '没有 Key 时绝不假装生成成功（文件没被创建）');

const r4 = await runScript(IMAGE_SCRIPT, ['FAIL400 测试', join(work, 'bad.png')]);
check(r4.code === 1, '上游 400 → 退出码 1', r4.code);
check(r4.stderr.includes('HTTP 400') && r4.stderr.includes('invalid size'), '上游 400 的报错带状态码 + 响应体前 200 字符', r4.stderr.split('\n')[0]);

const r5 = await runScript(IMAGE_SCRIPT, ['DL404 测试', join(work, 'dl404.png')]);
check(r5.code === 1 && r5.stderr.includes('下载失败：HTTP 404') && r5.stderr.includes('no such object'), '下载 404 如实报错（状态码 + 响应体）', r5.stderr.split('\n')[0]);

const r6 = await runScript(IMAGE_SCRIPT, ['x', join(work, 'r6.png'), '--ref', join(work, '不存在.png')]);
check(r6.code === 2 && r6.stderr.includes('参考图不存在'), '本地参考图不存在 → 参数错误', r6.stderr.split('\n')[0]);

const r7 = await runScript(IMAGE_SCRIPT, ['x', join(work, 'r7.png'), '--size', '8K']);
check(r7.code === 2 && r7.stderr.includes('--size'), '非法 --size → 参数错误', r7.stderr.split('\n')[0]);
const r8 = await runScript(IMAGE_SCRIPT, ['x', join(work, 'r8.png'), '--ratio', '5:4']);
check(r8.code === 2 && r8.stderr.includes('--ratio') && r8.stderr.includes('16:9'), '非法 --ratio → 报错并列出官方支持值', r8.stderr.split('\n')[0]);
const r9 = await runScript(IMAGE_SCRIPT, ['x', join(work, 'r9.png'), '--size', '1k']);
check(r9.code === 0 && lastOf('/v1/images/generations').json.size === '1K', '--size 1k 会规范成 1K', lastOf('/v1/images/generations').json.size);

// ═════════════════════════════════ 视频
console.log('\n=== make-video.mjs ===');
const vidOut = join(work, 'video', 'out.mp4');
const v0 = seen.length;
const v1 = await runScript(VIDEO_SCRIPT, ['夜晚森林里三只猫组成铜管乐队', vidOut, '--seconds', '5', '--ratio', '16:9']);
check(v1.code === 0, '退出码 0（创建+轮询+下载）', v1);
check(/^\[agnes-video\] ok file=.+ bytes=\d+ seconds=5$/.test(v1.stdout), '成功行格式符合约定', v1.stdout);
check(existsSync(vidOut) && statSync(vidOut).size === FAKE_MP4.length, '视频落盘且字节数正确（目录自动创建）', existsSync(vidOut) ? statSync(vidOut).size : 'missing');
const createReq = lastOf('/v1/videos');
check(createReq.method === 'POST' && createReq.path === '/v1/videos', 'POST /v1/videos', createReq.path);
check(createReq.headers.authorization === 'Bearer sk-test-123', 'Authorization: Bearer <KEY>', createReq.headers.authorization);
const vb = createReq.json;
check(vb.model === 'agnes-video-2.5-flash' && vb.mode === 'text' && vb.size === '720P', 'body: model/mode/size(720P) 正确', vb);
check(vb.seconds === '5', 'seconds 是字符串 "5"（官方要求）', vb.seconds);
check(vb.aspect_ratio === '16:9' && vb.n === 1, 'aspect_ratio / n 正确', vb);
check(!('first_frame' in vb) && !('images' in vb) && !('audios' in vb), 'text 模式不带任何媒体字段', Object.keys(vb));
const polls = since(v0, '/agnesapi');
check(polls.length >= 2, `轮询 ≥2 次（实际 ${polls.length}）`, polls.length);
check(polls.every((p) => p.query.video_id === 'vid-123' && p.query.model_name === 'agnes-video-2.5-flash'), '轮询带 video_id + model_name（官方推荐写法）', polls[0] && polls[0].query);
check(polls.every((p) => p.headers.authorization === 'Bearer sk-test-123'), '轮询带 Authorization', polls[0] && polls[0].headers.authorization);
check(v1.stderr.includes('status=processing'), '中间态会如实打出进度日志', v1.stderr.split('\n').find((l) => l.includes('processing')));
check(since(v0, '/files/out.mp4').length === 1, '完成后确实下载了顶层 url 指向的文件');

const v2 = await runScript(VIDEO_SCRIPT, ['首帧尾帧测试', join(work, 'kf.mp4'), '--mode', 'keyframe', '--first-frame', `${origin}/a.png`, '--last-frame', refPng]);
check(v2.code === 0, 'keyframe 模式成功', v2.code);
const kfBody = lastOf('/v1/videos').json;
check(kfBody.mode === 'keyframe' && kfBody.first_frame === `${origin}/a.png`, 'keyframe: first_frame 原样传 URL', kfBody.first_frame);
check(String(kfBody.last_frame).startsWith('data:image/png;base64,'), 'keyframe: 本地尾帧图转 Data URI', String(kfBody.last_frame).slice(0, 30));
check(v2.stderr.includes('所有媒体 URL 都应可由 Agnes AI 服务公开访问'), '本地素材转 Data URI 时会警告视频接口可能拒绝');

const v3 = await runScript(VIDEO_SCRIPT, ['参考图音频', join(work, 'ref.mp4'), '--mode', 'reference', '--image', `${origin}/1.png`, '--image', refPng, '--audio', `${origin}/a.mp3`]);
check(v3.code === 0 && lastOf('/v1/videos').json.images.length === 2 && lastOf('/v1/videos').json.audios.length === 1, 'reference: images(2) + audios(1) 正确', lastOf('/v1/videos').json);

const v4 = await runScript(VIDEO_SCRIPT, ['兜底路径测试 FALLBACK', join(work, 'fb.mp4')]);
check(v4.code === 0, 'agnesapi 404 时走兜底老写法仍成功', v4);
check(v4.stderr.includes('兜底') && v4.stderr.includes('404'), '兜底时如实记一行日志', v4.stderr.split('\n').find((l) => l.includes('兜底')));
check(since(0, '/v1/videos/vid-fallback').length >= 1, '确实调用了 GET /v1/videos/<ID>');

const v5 = await runScript(VIDEO_SCRIPT, ['超时测试 PENDING', join(work, 'to.mp4')], { AGNES_VIDEO_TIMEOUT_MS: '2500', AGNES_POLL_INTERVAL_MS: '300' });
check(v5.code === 1 && v5.stderr.includes('轮询超时'), '轮询超时 → 退出码 1 且说明超时', v5.stderr.split('\n')[0]);
check(v5.stderr.includes('可能仍在平台侧继续'), '超时提示说明任务可能仍在平台侧继续', v5.stderr.split('\n').find((l) => l.includes('仍在平台侧')));

const v6 = await runScript(VIDEO_SCRIPT, ['任务失败 TASKFAIL', join(work, 'tf.mp4')]);
check(v6.code === 1 && v6.stderr.includes('任务失败') && v6.stderr.includes('内容被平台拒绝'), 'status=failed → 读出 error 字段并报错', v6.stderr.split('\n')[0]);

const v7 = await runScript(VIDEO_SCRIPT, ['上游 400 FAIL400', join(work, 'v400.mp4')]);
check(v7.code === 1 && v7.stderr.includes('HTTP 400') && v7.stderr.includes('size must be 720P'), '创建任务 400 → 状态码 + 响应体', v7.stderr.split('\n')[0]);

const v8 = await runScript(VIDEO_SCRIPT, ['x', join(work, 'v8.mp4')], { AGNES_API_KEY: null });
check(v8.code === 2 && v8.stderr.includes('AGNES_API_KEY') && v8.stderr.includes('限时免费'), '没有 Key → 退出码 2 且口径是"限时免费"', v8.stderr.split('\n')[0]);

console.log('\n--- 本地规则校验（不该花掉一次请求）---');
const rules = [
  [['x', join(work, 'a.mp4'), '--mode', 'reference'], 'reference 无素材'],
  [['x', join(work, 'a.mp4'), '--mode', 'keyframe'], 'keyframe 无首尾帧'],
  [['x', join(work, 'a.mp4'), '--image', 'http://a/1.png'], 'text 带了 --image'],
  [['x', join(work, 'a.mp4'), '--seconds', '13'], 'seconds 越界'],
  [['x', join(work, 'a.mp4'), '--ratio', '5:4'], 'ratio 不在官方表里'],
  [['x', join(work, 'a.mp4'), '--mode', 'reference', '--image', '1', '--image', '2', '--image', '3', '--image', '4', '--image', '5', '--image', '6'], '参考图超 5 张'],
  [['x', join(work, 'a.mp4'), '--mode', 'reference', '--image', '1', '--audio', '2', '--audio', '3', '--audio', '4'], '参考音频超 3 段'],
];
const reqBefore = seen.length;
for (const [argv, label] of rules) {
  const r = await runScript(VIDEO_SCRIPT, argv);
  check(r.code === 2 && /错误：/.test(r.stderr), `${label} → 参数错误（退出码 2）`, r.code);
}
check(seen.length === reqBefore, '本地拦下的用例一次请求都没发出去', seen.length - reqBefore);

server.close();
console.log(`\n结果：${failures === 0 ? '全部通过 ✅' : failures + ' 项失败 ❌'}`);
process.exit(failures === 0 ? 0 : 1);
