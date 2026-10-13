/**
 * 把 Android 运行时转换成可打进 APK 的 jniLibs 布局（按依赖闭包精确挑选）。
 *
 * 三个必须处理的事实：
 *   1. Android 只允许从 nativeLibraryDir（APK 的 lib/<abi>/）执行原生程序，
 *      所以 node 二进制必须以 libnode.so 名义进包；
 *   2. AGP 要求 jniLibs 下的原生库形如 lib*.so，
 *      而 Termux 的库叫 libcrypto.so.3 / libicui18n.so.78 / libz.so.1 —— 不合规；
 *   3. 改名之后，node 与库内部的 DT_NEEDED 也必须指向新名字。
 *
 * 所以这里真的解析 ELF 的 .dynamic/.dynstr 取 DT_NEEDED，
 * 从 libnode.so 出发做**依赖闭包**，只输出闭包内的库（改名并改写引用）。
 *
 * 用法：node prepare-jnilibs.mjs <arch>     arch: aarch64 | x86_64
 */

import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const ABI = { aarch64: 'arm64-v8a', x86_64: 'x86_64' };
const arch = process.argv[2] ?? 'x86_64';
const abi = ABI[arch];
if (!abi) {
  console.error(`未知架构: ${arch}`);
  process.exit(1);
}

const srcRoot = `D:/dev/android-node/runtime/${arch}`;
const outRoot = `D:/dev/android-node/jnilibs/${abi}`;

/** 不合规库名 -> 合规库名（必须以 lib 开头、以 .so 结尾） */
const RENAME = {
  'libcrypto.so.3': 'libcrypto3.so',
  'libssl.so.3': 'libssl3.so',
  'libicui18n.so.78': 'libicui18n78.so',
  'libicuuc.so.78': 'libicuuc78.so',
  'libicudata.so.78': 'libicudata78.so',
  'libicuio.so.78': 'libicuio78.so',
  'libicutu.so.78': 'libicutu78.so',
  'libicutest.so.78': 'libicutest78.so',
  'libz.so.1': 'libz1.so',
};

/** Android 系统 guaranteed 提供的库，不必随包分发 */
const SYSTEM_LIBS = new Set(['libc.so', 'libm.so', 'libdl.so', 'liblog.so', 'libandroid.so']);

// ---------------------------------------------------------------- ELF 解析

/** 读出 ELF 的 DT_NEEDED 列表（支持 ELF64 小端，覆盖本次全部目标）。 */
function readDtNeeded(filePath) {
  const buf = readFileSync(filePath);
  if (buf[0] !== 0x7f || buf[1] !== 0x45) return []; // 非 ELF
  const is64 = buf[4] === 2;
  if (!is64) return [];

  const e_shoff = Number(buf.readBigUInt64LE(0x28));
  const e_shentsize = buf.readUInt16LE(0x3a);
  const e_shnum = buf.readUInt16LE(0x3c);

  const sections = [];
  for (let i = 0; i < e_shnum; i += 1) {
    const off = e_shoff + i * e_shentsize;
    sections.push({
      type: buf.readUInt32LE(off + 4),
      offset: Number(buf.readBigUInt64LE(off + 0x18)),
      size: Number(buf.readBigUInt64LE(off + 0x20)),
      link: buf.readUInt32LE(off + 0x28),
      entsize: Number(buf.readBigUInt64LE(off + 0x38)),
    });
  }

  const dyn = sections.find((s) => s.type === 6); // SHT_DYNAMIC
  if (!dyn) return [];
  const dynstr = sections[dyn.link];
  if (!dynstr) return [];

  const needed = [];
  const entrySize = dyn.entsize || 16;
  for (let off = dyn.offset; off < dyn.offset + dyn.size; off += entrySize) {
    const tag = Number(buf.readBigUInt64LE(off));
    if (tag === 0) break; // DT_NULL
    if (tag !== 1) continue; // DT_NEEDED
    const val = Number(buf.readBigUInt64LE(off + 8));
    let end = dynstr.offset + val;
    while (end < buf.length && buf[end] !== 0) end += 1;
    needed.push(buf.toString('latin1', dynstr.offset + val, end));
  }
  return needed;
}

/** 在 ELF 缓冲区里替换库名（更短则用 \0 补齐）。 */
function patchNames(buf, mapping) {
  let total = 0;
  for (const [oldName, newName] of Object.entries(mapping)) {
    const oldBuf = Buffer.from(oldName, 'latin1');
    const newBuf = Buffer.from(newName, 'latin1');
    if (newBuf.length > oldBuf.length) throw new Error(`新名更长会破坏 ELF: ${oldName} -> ${newName}`);
    let idx = 0;
    while ((idx = buf.indexOf(oldBuf, idx)) !== -1) {
      buf.write(newName, idx, 'latin1');
      buf.fill(0, idx + newBuf.length, idx + oldBuf.length);
      total += 1;
      idx += oldBuf.length;
    }
  }
  return total;
}

// ---------------------------------------------------------------- 依赖闭包

const srcLibDir = path.join(srcRoot, 'lib');
const srcNode = path.join(srcRoot, 'bin', 'node');
if (!existsSync(srcLibDir) || !existsSync(srcNode)) {
  console.error(`运行时目录不完整: ${srcRoot}`);
  process.exit(1);
}

const available = new Set(readdirSync(srcLibDir));
const resolveName = (name) => RENAME[name] ?? name;

// 广度优先收集闭包
const closure = new Set();
const queue = [readDtNeeded(srcNode).map(resolveName)];
const seenRoots = new Set();

while (queue.length) {
  const level = queue.shift();
  for (const rawName of level) {
    const name = rawName;
    if (SYSTEM_LIBS.has(name)) continue;
    if (closure.has(name)) continue;
    // 找提供该名字的源文件：可能是改名后的目标，也可能是原名
    const source = Object.keys(RENAME).find((k) => RENAME[k] === name) ?? name;
    if (!available.has(source)) {
      // 尝试按前缀匹配（例如需要 libcrypto.so 而只有 libcrypto.so.3）
      const guess = [...available].find((f) => f.startsWith(name) || name.startsWith(f));
      if (!guess) continue;
      closure.add(name);
      if (!seenRoots.has(resolveName(guess))) {
        seenRoots.add(resolveName(guess));
        queue.push(readDtNeeded(path.join(srcLibDir, guess)).map(resolveName));
      }
      continue;
    }
    closure.add(name);
    const resolved = resolveName(source);
    if (!seenRoots.has(resolved)) {
      seenRoots.add(resolved);
      queue.push(readDtNeeded(path.join(srcLibDir, source)).map(resolveName));
    }
  }
}

// ---------------------------------------------------------------- 输出

rmSync(outRoot, { recursive: true, force: true });
mkdirSync(outRoot, { recursive: true });

const nodeBuf = readFileSync(srcNode);
const nodePatched = patchNames(nodeBuf, RENAME);
writeFileSync(path.join(outRoot, 'libnode.so'), nodeBuf);

const rows = [];
for (const wantName of [...closure].sort()) {
  const source = Object.keys(RENAME).find((k) => RENAME[k] === wantName) ?? wantName;
  const srcPath = path.join(srcLibDir, source);
  if (!existsSync(srcPath)) continue;
  const buf = readFileSync(srcPath);
  const patched = patchNames(buf, RENAME);
  writeFileSync(path.join(outRoot, wantName), buf);
  rows.push({ name: wantName, source, size: buf.length, patched });
}

console.log(`=== jniLibs/${abi} ===`);
console.log(`  libnode.so  ${(nodeBuf.length / 1024 / 1024).toFixed(1)} MB  (引用改写 ${nodePatched} 处)`);
for (const r of rows) {
  const renameNote = r.name === r.source ? '' : `  (原 ${r.source})`;
  console.log(`  ${r.name.padEnd(22)} ${(r.size / 1024 / 1024).toFixed(2)} MB${renameNote}`);
}

const total = readdirSync(outRoot).reduce((s, f) => s + statSync(path.join(outRoot, f)).size, 0);
console.log(`\n  文件数: ${readdirSync(outRoot).length}   总计: ${(total / 1024 / 1024).toFixed(1)} MB`);

// 自检：输出目录里不应再有旧名字
let leftover = 0;
for (const f of readdirSync(outRoot)) {
  const text = readFileSync(path.join(outRoot, f)).toString('latin1');
  for (const oldName of Object.keys(RENAME)) {
    if (text.includes(oldName)) {
      console.log(`  ⚠ ${f} 仍含旧名 ${oldName}`);
      leftover += 1;
    }
  }
}
console.log(leftover === 0 ? '  自检通过：无残留旧库名 ✓' : `  ⚠ 有 ${leftover} 处残留`);
