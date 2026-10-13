// 把文章发到微信公众号（默认只建**草稿**，加 --publish 才提交发布）。
//
// 流程（每步都要 access_token，所以先取 token）：
//   1. GET  /cgi-bin/token                         取 access_token
//   2. POST /cgi-bin/media/uploadimg               逐张上传**正文图** → 拿微信域名下的 url
//      （正文里的图片必须是微信自己的 URL，不能是外链，也不能是 base64）
//   3. POST /cgi-bin/material/add_material?type=image  上传**封面图** → thumb_media_id
//   4. POST /cgi-bin/draft/add                     建草稿
//   5. 可选：POST /cgi-bin/freepublish/submit      提交发布（不可撤回，且会推送给粉丝）
//
// 用法: node wechat-publish.mjs <appid> <secret> [--publish]
//   也可以不写参数，改用环境变量（**推荐**：密钥不会留在命令行里，
//   命令行会被 shell 历史 / 会话记录原样记下来）：
//       $env:WECHAT_APPID='wx…'; $env:WECHAT_SECRET='…'; node wechat-publish.mjs --publish
//
// 为什么用 node 原生 fetch：本机 curl 有 schannel 证书问题、Invoke-WebRequest 会被断，
// 而 undici 实测可用（见 HANDOFF 的容器修复技巧）。
//
// 注意：控制台是 cp936，中文标题/摘要直接 print 会变乱码 ——
// 所以明细一律写进 docs/logs/wechat-publish.txt（UTF-8），控制台只打 ASCII。
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = dirname(HERE);
const DOCS = join(ROOT, 'docs');
const LOG = join(DOCS, 'logs', 'wechat-publish.txt');

const argv = process.argv.slice(2);
const flags = argv.filter((a) => a.startsWith('--'));
const positional = argv.filter((a) => !a.startsWith('--'));
const doPublish = flags.includes('--publish');

// 命令行参数优先；没给就读环境变量（密钥不落命令行）
const appid = positional[0] || process.env.WECHAT_APPID || '';
const secret = positional[1] || process.env.WECHAT_SECRET || '';

if (!appid || !secret) {
  console.error('usage: node wechat-publish.mjs <appid> <secret> [--publish]');
  console.error('   or: set WECHAT_APPID / WECHAT_SECRET env vars and pass only flags');
  process.exit(2);
}

// 标题/摘要默认沿用预览版那篇；`install/md_to_wechat_html.py --wechat` 会把
// 本次要发的标题/摘要写进 docs/wechat-meta.json，有它就以它为准 ——
// 免得"正文换了、标题还是上一版的"。
let TITLE = '重大发布，手机版的智能体，泡泡猫DSH预览版';
let AUTHOR = '泡泡猫';
let DIGEST = '一个完全跑在手机里的 AI 智能体：会话、专家、技能、资料库、定时任务、工作区、'
  + '模型接入、附件与语音。预览版已可用，正式版马上发布。';
try {
  const meta = JSON.parse(readFileSync(join(DOCS, 'wechat-meta.json'), 'utf8'));
  if (meta.title) TITLE = meta.title;
  if (meta.author) AUTHOR = meta.author;
  if (meta.digest) DIGEST = meta.digest;
} catch {
  // 没有 meta 文件就按上面的默认值来（老流程不受影响）
}

const lines = [];
function log(m) {
  lines.push(m);
  writeFileSync(LOG, lines.join('\n'), 'utf8');
  // 控制台只打 ASCII，避免 cp936 乱码
  process.stdout.write(m.replace(/[^\x20-\x7e\n]/g, '?') + '\n');
}

function fail(step, data) {
  log(`FAIL at ${step}: ${JSON.stringify(data)}`);
  if (data && data.errcode === 40164) {
    log('提示: 40164 = 调用来源 IP 不在公众号后台的 IP 白名单里。');
    log('      去 公众号后台 -> 设置与开发 -> 基本配置 -> IP 白名单 添加报错里那个 IP。');
  }
  process.exit(1);
}

async function getToken() {
  const url = 'https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential'
    + '&appid=' + encodeURIComponent(appid) + '&secret=' + encodeURIComponent(secret);
  const data = await (await fetch(url)).json();
  if (!data.access_token) fail('token', data);
  log(`OK token (len=${String(data.access_token).length}, expires=${data.expires_in}s)`);
  return data.access_token;
}

async function uploadBodyImage(token, filePath, index) {
  const buf = readFileSync(filePath);
  const fd = new FormData();
  fd.append('media', new Blob([buf], { type: 'image/png' }), `img${index}.png`);
  const url = `https://api.weixin.qq.com/cgi-bin/media/uploadimg?access_token=${token}`;
  const data = await (await fetch(url, { method: 'POST', body: fd })).json();
  if (!data.url) fail(`uploadimg #${index} (${filePath})`, data);
  log(`OK uploadimg #${index} -> ${data.url}`);
  return data.url;
}

async function uploadCover(token, filePath) {
  const buf = readFileSync(filePath);
  const fd = new FormData();
  fd.append('media', new Blob([buf], { type: 'image/png' }), 'cover.png');
  const url = `https://api.weixin.qq.com/cgi-bin/material/add_material?access_token=${token}&type=image`;
  const data = await (await fetch(url, { method: 'POST', body: fd })).json();
  if (!data.media_id) fail('add_material(cover)', data);
  log(`OK cover media_id=${data.media_id}`);
  return data.media_id;
}

async function addDraft(token, article) {
  const url = `https://api.weixin.qq.com/cgi-bin/draft/add?access_token=${token}`;
  const data = await (await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
    body: Buffer.from(JSON.stringify({ articles: [article] }), 'utf8'),
  })).json();
  if (!data.media_id) fail('draft/add', data);
  log(`OK draft media_id=${data.media_id}`);
  return data.media_id;
}

async function submitPublish(token, mediaId) {
  const url = `https://api.weixin.qq.com/cgi-bin/freepublish/submit?access_token=${token}`;
  const data = await (await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
    body: JSON.stringify({ media_id: mediaId }),
  })).json();
  if (data.errcode) fail('freepublish/submit', data);
  log(`OK submitted for publish: publish_id=${data.publish_id}`);
}

async function main() {
  log(`===== wechat publish @ ${new Date().toISOString()} =====`);
  log(`title: ${TITLE}`);
  log(`publish flag: ${doPublish}`);

  const token = await getToken();

  // 正文 + 图片对照表（由 install/md_to_wechat_html.py --wechat 生成）
  let content = readFileSync(join(DOCS, 'wechat-content.html'), 'utf8');
  const images = JSON.parse(readFileSync(join(DOCS, 'wechat-images.json'), 'utf8'));
  log(`content chars=${content.length}, images=${images.length}`);

  for (const item of images) {
    const abs = join(DOCS, item.path.replace(/\//g, '\\'));
    const url = await uploadBodyImage(token, abs, item.n);
    content = content.split(`{{IMG${item.n}}}`).join(url);
  }
  const left = (content.match(/\{\{IMG\d+\}\}/g) || []).length;
  if (left > 0) log(`WARN: 还有 ${left} 个占位符没被替换`);

  const thumb = await uploadCover(token, join(DOCS, 'article-assets', 'cover-900x383.png'));

  const mediaId = await addDraft(token, {
    title: TITLE,
    author: AUTHOR,
    digest: DIGEST,
    content,
    content_source_url: '',
    thumb_media_id: thumb,
    need_open_comment: 1,
    only_fans_can_comment: 0,
  });

  if (doPublish) {
    await submitPublish(token, mediaId);
  } else {
    log('（只建了草稿。要提交发布请在命令后加 --publish）');
  }
  log('===== DONE =====');
}

await main();
