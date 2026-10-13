/**
 * 修补 Android 版 node 二进制里硬编码的 Termux shell 路径。
 *
 * 背景（实测）：
 *   Termux 编译的 node 把默认 shell 固定为 `$PREFIX/bin/sh`，
 *   即 /data/data/com.termux/files/usr/bin/sh —— 而 Android 上只有 /system/bin/sh。
 *   于是 child_process 全部失败：
 *     spawnSync /data/data/com.termux/files/usr/bin/sh ENOENT
 *   这会让 DSH 的所有命令执行工具瘫痪。
 *
 * 做法：在二进制里做**同长度替换**（新路径更短，用 \0 补齐），
 * 不改变 ELF 任何结构（这些字符串位于 .rodata，定长读取不受影响）。
 *
 * 用法：node patch-node-shell.mjs <arch>
 */

import { copyFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs';

const arch = process.argv[2] ?? 'x86_64';
const bin = `D:/dev/android-node/runtime/${arch}/bin/node`;
const backup = `${bin}.orig`;

const OLD = '/data/data/com.termux/files/usr/bin/sh';
const NEW = '/system/bin/sh';

if (!existsSync(bin)) {
  console.error(`找不到: ${bin}`);
  process.exit(1);
}

// 保留一份原始二进制，便于重跑
if (!existsSync(backup)) {
  copyFileSync(bin, backup);
  console.log(`已备份原始二进制 -> ${backup}`);
}

const buf = readFileSync(bin);
const oldBuf = Buffer.from(OLD, 'latin1');
const newBuf = Buffer.from(NEW, 'latin1');

if (newBuf.length > oldBuf.length) {
  console.error('新路径不能比旧路径长（会破坏定长字符串）');
  process.exit(1);
}

let count = 0;
let idx = 0;
while ((idx = buf.indexOf(oldBuf, idx)) !== -1) {
  buf.write(NEW, idx, 'latin1');
  buf.fill(0, idx + NEW.length, idx + OLD.length); // 补 \0
  count += 1;
  idx += OLD.length;
}

if (count === 0) {
  console.log('未找到该路径（可能已被修补过，或是另一个架构）');
} else {
  writeFileSync(bin, buf);
  console.log(`已替换 ${count} 处：`);
  console.log(`  ${OLD}`);
  console.log(`  -> ${NEW}`);
}

// 顺便报告还剩余多少 Termux 硬编码路径（仅提示，不一定都有害）
const remainder = new Set();
for (const m of buf.toString('latin1').matchAll(/\/data\/data\/com\.termux\/files\/usr[\/A-Za-z0-9._-]*/g)) {
  remainder.add(m[0]);
}
console.log(`\n仍存在的 Termux 路径（共 ${remainder.size} 种）：`);
for (const r of [...remainder].sort().slice(0, 20)) console.log(`  ${r}`);
