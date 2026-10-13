#!/usr/bin/env node
/**
 * `.tar.bz2` → 解包到一个目录（**手机上没有 tar / bzip2**，所以这一步在 node 里做）。
 *
 * ## 为什么需要它（2026-10-13，本机离线配音 B 方案）
 *
 * sherpa-onnx 的中文模型是以 `.tar.bz2` 发布的（`vits-icefall-zh-aishell3.tar.bz2`，31.5 MB），
 * 而 Android 系统里**既没有 `tar` 也没有 `bzip2`**，随包的 node 也只有 `zlib`
 * （能解 gzip/deflate/brotli，**不能解 bzip2**）。所以：
 *
 *   * bzip2 解码 → vendor 一份 MIT 的 `seek-bzip`（纯 JS，约 31 KB，见 `vendor/seek-bzip/`）；
 *   * tar 解包  → 就是本文件里自己写的那几十行（tar 头是定长 512 字节，很简单）。
 *
 * ## 用法
 *
 * ```
 * node untar-bz2.mjs <input.tar.bz2> <outDir> [--only=<路径前缀>] [--skip=<文件名,..>] [--dry]
 * ```
 *
 * 输出（成功）：`[untar] ok files=<n> bytes=<m> out=<绝对路径>`
 * 失败统一：`错误：...` + 括号里的原因，退出码 2（与其它 toolbox 脚本一致）。
 *
 * ## 安全
 *
 * 解包目标由调用方指定（App 私有目录）。**绝对路径与 `..` 一律拒绝** ——
 * 一个下载下来的压缩包不该有能力往目标目录外面写文件（tar 的经典漏洞）。
 */

import { readFileSync, mkdirSync, writeFileSync, existsSync, statSync } from 'node:fs';
import { dirname, join, resolve, sep } from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const here = dirname(fileURLToPath(import.meta.url));
// vendor 是 CJS（上游原样拷贝），用 require 引进来最省事。
const seekBzip = require(join(here, 'vendor', 'seek-bzip', 'lib', 'index.js'));

function fail(msg, code = 2) {
  console.log(`错误：${msg}`);
  process.exit(code);
}

const args = process.argv.slice(2);
const flags = args.filter((a) => a.startsWith('--'));
const positional = args.filter((a) => !a.startsWith('--'));
const only = (flags.find((f) => f.startsWith('--only=')) || '').slice('--only='.length);
// `--skip=`：**不解出来的**文件名（逗号分隔，按路径末段精确匹配）。
//
// 为什么需要它（2026-10-13，省 172 MB）：sherpa 的中文模型包里有个
// `rule.far` 172 MB，而实测**它对我们没用**（带它反而把数字读得更短、加载慢 3 倍）。
// 没有这个开关的话，解包会先把它写出来再删 —— 峰值占用 204 MB，
// 而真实需要的只有 31 MB。手机存储紧张，这一步不能省。
const skip = (flags.find((f) => f.startsWith('--skip=')) || '')
  .slice('--skip='.length)
  .split(',')
  .map((x) => x.trim())
  .filter((x) => x !== '');
const dry = flags.includes('--dry');

const [input, outDirRaw] = positional;
if (!input || !outDirRaw) {
  fail('用法：node untar-bz2.mjs <input.tar.bz2> <outDir> [--only=<前缀>] [--dry]');
}
if (!existsSync(input)) fail(`找不到输入文件：${input}`);

const outDir = resolve(outDirRaw);
const root = resolve(outDir) + sep;

/** tar 里的八进制数字（允许前后空格与 NUL 结尾）。 */
function octal(buf) {
  const s = buf.toString('latin1').replace(/\0.*$/, '').trim();
  if (s === '') return 0;
  const v = parseInt(s, 8);
  return Number.isFinite(v) ? v : 0;
}

/**
 * 解析 tar 并返回 `[{name, bytes}]`。
 * 支持：普通文件(0/\0)、GNU 长文件名(L)、跳过 pax 扩展头(x/g)与目录(5)、
 * 跳过符号链接(2)/硬链接(1)（不跟着链接写文件）。
 */
function parseTar(buf) {
  const out = [];
  let pos = 0;
  let longName = null;
  while (pos + 512 <= buf.length) {
    const header = buf.subarray(pos, pos + 512);
    // 连续两个全零块 = 结束
    if (header.every((b) => b === 0)) break;
    let name = header.subarray(0, 100).toString('utf8').replace(/\0.*$/, '');
    const size = octal(header.subarray(124, 136));
    const typeflag = String.fromCharCode(header[156] || 48); // '0'
    const prefix = header.subarray(345, 345 + 155).toString('utf8').replace(/\0.*$/, '');
    if (prefix) name = `${prefix}/${name}`;
    if (longName !== null) {
      name = longName;
      longName = null;
    }
    pos += 512;
    const body = buf.subarray(pos, pos + size);
    pos += Math.ceil(size / 512) * 512;

    if (typeflag === 'L') {
      // GNU 长文件名：这一块的内容就是下一个条目的名字
      longName = body.toString('utf8').replace(/\0.*$/, '');
      continue;
    }
    if (typeflag === 'x' || typeflag === 'g') continue; // pax 扩展头：跳过
    if (typeflag === '5') continue; // 目录：按文件路径自动建，不用单独处理
    if (typeflag !== '0' && typeflag !== '\0') continue; // 链接/设备等一律跳过
    out.push({ name, bytes: Buffer.from(body) });
  }
  return out;
}

let raw;
try {
  raw = readFileSync(input);
} catch (e) {
  fail(`读不了输入文件：${e.message}`);
}

let tarBuf;
const t0 = Date.now();
try {
  tarBuf = seekBzip.decode(raw);
} catch (e) {
  fail(`bzip2 解压失败（文件不完整或不是 bz2）：${e.message}`);
}
const unzipMs = Date.now() - t0;

let entries;
try {
  entries = parseTar(tarBuf);
} catch (e) {
  fail(`tar 解析失败：${e.message}`);
}
if (only) entries = entries.filter((e) => e.name.startsWith(only));
const skipped = [];
if (skip.length > 0) {
  entries = entries.filter((e) => {
    const base = e.name.split('/').pop();
    if (skip.includes(base)) {
      skipped.push(e.name);
      return false;
    }
    return true;
  });
}
if (entries.length === 0) fail('压缩包里没有可解出的文件（或 --only / --skip 过滤后为空）');

const written = [];
let total = 0;
for (const e of entries) {
  // ⚠️ 路径安全：拒绝绝对路径与任何 `..`（tar 经典漏洞）
  if (e.name.startsWith('/') || e.name.split('/').includes('..')) {
    fail(`压缩包里有一个不安全的路径，已中止：${e.name}`);
  }
  const dest = join(outDir, e.name);
  if (!resolve(dest).startsWith(root)) {
    fail(`解包目标逃出了输出目录，已中止：${e.name}`);
  }
  if (!dry) {
    mkdirSync(dirname(dest), { recursive: true });
    writeFileSync(dest, e.bytes);
  }
  written.push({ name: e.name, size: e.bytes.length });
  total += e.bytes.length;
}

// 给人看的一行：成功标志 + 关键数字（App 侧按 `[untar] ok` 判断）
console.log(
  `[untar] ok files=${written.length} bytes=${total} out=${outDir} ` +
    `(bz2 ${unzipMs}ms, tar ${Date.now() - t0 - unzipMs}ms` +
    `${skipped.length ? `, skipped=${skipped.length}` : ''})`,
);
if (skipped.length > 0) {
  for (const nm of skipped) console.log(`  跳过（--skip）：${nm}`);
}
for (const w of written.slice(0, 8)) {
  console.log(`  ${w.size}  ${w.name}`);
}
if (written.length > 8) console.log(`  …还有 ${written.length - 8} 个文件`);
