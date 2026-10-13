#!/usr/bin/env node
/**
 * 起一个极简 HTTP 服务，方便手机浏览器下载 dist/ 里的 APK。
 *
 * 用法：node install/serve-apk.mjs
 * 然后用手机浏览器打开打印出来的地址（需与电脑同一 Wi-Fi/Tailscale）。
 */

import http from 'node:http';
import { createReadStream, readdirSync, statSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DIST = path.resolve(HERE, '..', 'dist');
const PORT = Number(process.env.APK_PORT ?? 8000);
const MIME = 'application/vnd.android.package-archive';

function listApks() {
  try {
    return readdirSync(DIST).filter((f) => f.toLowerCase().endsWith('.apk'));
  } catch {
    return [];
  }
}

const server = http.createServer((req, res) => {
  const files = listApks();

  if (req.url === '/' || req.url === '/index.html') {
    const items = files
      .map((f) => {
        const size = (statSync(path.join(DIST, f)).size / 1024 / 1024).toFixed(1);
        return `<li style="margin:8px 0"><a href="/${f}" style="font-size:18px">${f}</a> <span style="color:#888">${size} MB</span></li>`;
      })
      .join('');
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(
      `<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
       <body style="font-family:system-ui;padding:20px">
       <h2>DSH Mobile APK</h2>
       <ul style="list-style:none;padding:0">${items || '<li>dist/ 下没有 APK，请先运行 install/build-apk.ps1</li>'}</ul>
       <p style="color:#888;font-size:13px">下载后点击安装；若提示“未知来源”，请在系统设置里允许本浏览器安装应用。</p>
       </body>`,
    );
    return;
  }

  const name = path.basename(decodeURIComponent(req.url));
  const file = path.join(DIST, name);
  if (!files.includes(name) || !file.startsWith(DIST)) {
    res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('not found');
    return;
  }

  const size = statSync(file).size;
  res.writeHead(200, { 'content-type': MIME, 'content-length': size });
  createReadStream(file).pipe(res);
});

server.listen(PORT, '0.0.0.0', () => {
  const addrs = Object.values(os.networkInterfaces())
    .flat()
    .filter((a) => a && a.family === 'IPv4' && !a.internal)
    .map((a) => a.address);

  console.log(`\nAPK 下载服务已启动（端口 ${PORT}）`);
  console.log('手机浏览器打开：');
  for (const a of addrs) console.log(`  http://${a}:${PORT}/`);
  console.log('\n注意：如果打不开，多半是 Windows 防火墙拦了（见 docs/PHONE-TEST.md 第 2 步）。');
  console.log('按 Ctrl+C 停止。\n');
});
