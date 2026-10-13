/**
 * 通用下载器（带进度），用于 Flutter / JDK / Android SDK 安装包。
 * 用法：node download.mjs <url> <dest>
 */

import { createWriteStream, mkdirSync, rmSync, statSync } from 'node:fs';
import path from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

const [url, dest] = process.argv.slice(2);
if (!url || !dest) {
  console.error('用法: node download.mjs <url> <dest>');
  process.exit(1);
}

mkdirSync(path.dirname(dest), { recursive: true });

const mb = (n) => (n / 1024 / 1024).toFixed(1);
const started = Date.now();
console.log(`[dl] ${url}`);
console.log(`[dl] → ${dest}`);

let res;
try {
  res = await fetch(url, { redirect: 'follow' });
} catch (err) {
  console.error(`[dl] 请求失败：${err.message}`);
  process.exit(1);
}
if (!res.ok || !res.body) {
  console.error(`[dl] HTTP ${res.status} ${res.statusText}`);
  process.exit(1);
}

const total = Number(res.headers.get('content-length') ?? 0);
console.log(`[dl] HTTP ${res.status} 大小 ${total ? mb(total) + 'MB' : '未知'}`);

const timer = setInterval(() => {
  try {
    const got = statSync(dest).size;
    const secs = Math.max((Date.now() - started) / 1000, 0.001);
    const speed = mb(got) / secs;
    const pct = total ? ` ${((got / total) * 100).toFixed(1)}%` : '';
    const eta = total && speed > 0 ? ` 剩余约 ${Math.round((total - got) / 1024 / 1024 / speed)}s` : '';
    console.log(`[dl]   ${mb(got)}MB${pct}  ${speed.toFixed(1)}MB/s${eta}`);
  } catch {}
}, 5000);

try {
  await pipeline(Readable.fromWeb(res.body), createWriteStream(dest));
} catch (err) {
  clearInterval(timer);
  console.error(`[dl] 写入失败：${err.message}`);
  try {
    rmSync(dest, { force: true });
  } catch {}
  process.exit(1);
}
clearInterval(timer);

const size = statSync(dest).size;
console.log(`[dl] 完成：${mb(size)}MB，用时 ${((Date.now() - started) / 1000).toFixed(0)}s`);
