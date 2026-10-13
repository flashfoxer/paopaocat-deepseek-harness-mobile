/**
 * 补齐 Android 运行时的库文件名。
 *
 * 为什么需要：Termux 的包里用符号链接把同一个 .so 暴露成多个名字
 *   libicui18n.so.78 -> libicui18n.so.78.3
 * 而 Windows 解包无法创建符号链接（需要管理员/开发者模式），
 * 于是我们只拿到了实体文件；但 node 二进制的 DT_NEEDED 里写的是
 * `libicui18n.so.78`，名字对不上就会加载失败。
 *
 * 做法：扫描 node 与所有 .so 里出现的 `lib*.so*` 字符串（即潜在依赖名），
 * 对每个缺失的名字，找一个“以它开头”的实体文件复制成该名字，迭代到收敛。
 *
 * 用法：node normalize-runtime-libs.mjs <arch>
 */

import { copyFileSync, existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';

const arch = process.argv[2] ?? 'x86_64';
const root = `D:/dev/android-node/runtime/${arch}`;
const libDir = path.join(root, 'lib');
const nodeBin = path.join(root, 'bin', 'node');

// 注意 {1,40} 而不是 {2,40}：库名可以只有一个字符（libz.so），
// 早先写成 {2,40} 导致 libz.so.1 这个别名从未被补齐，
// 而 libnode.so 与 libsqlite3.so 都依赖它。
const NAME_RE = /lib[A-Za-z0-9_+\-.]{1,40}?\.so(\.\d+)*/g;

function elfStrings(file) {
  const buf = readFileSync(file);
  const text = buf.toString('latin1');
  const found = new Set();
  for (const m of text.matchAll(NAME_RE)) {
    const s = m[0];
    // 过滤明显的噪音
    if (s.length < 6 || s.length > 45) continue;
    found.add(s);
  }
  return found;
}

function listLibs() {
  return readdirSync(libDir).filter((f) => f.includes('.so'));
}

// 收敛式补齐
for (let round = 1; round <= 6; round += 1) {
  const libs = listLibs();
  const have = new Set(libs);

  // 收集所有 ELF（node + 库）声明的依赖名
  const needed = new Set();
  for (const target of [nodeBin, ...libs.map((f) => path.join(libDir, f))]) {
    if (!existsSync(target)) continue;
    try {
      for (const name of elfStrings(target)) needed.add(name);
    } catch {}
  }

  const created = [];
  for (const name of needed) {
    if (have.has(name)) continue;
    // 找一个以该名字开头的实体文件（libicui18n.so.78.3 覆盖 libicui18n.so.78）
    const source = listLibs().find((f) => f.startsWith(name) && f !== name);
    if (!source) continue;
    copyFileSync(path.join(libDir, source), path.join(libDir, name));
    created.push(`${name}  <-  ${source}`);
  }

  console.log(`\n=== 第 ${round} 轮 ===`);
  console.log(`  已有库: ${libs.length} 个`);
  console.log(`  依赖名: ${needed.size} 个`);
  if (created.length === 0) {
    console.log('  无需补齐，收敛。');
    break;
  }
  created.forEach((c) => console.log(`  + ${c}`));
}

console.log('\n=== 最终库列表 ===');
for (const f of listLibs().sort()) {
  console.log(`  ${f.padEnd(28)} ${(statSync(path.join(libDir, f)).size / 1024 / 1024).toFixed(2)} MB`);
}

// 检查是否仍有缺失
const have = new Set(listLibs());
const missing = [];
for (const target of [nodeBin, ...listLibs().map((f) => path.join(libDir, f))]) {
  for (const name of elfStrings(target)) {
    // 只关心看起来像 Termux 提供的那些
    if (/^lib(cares|crypto|ssl|ffi|icu|sqlite|z)/.test(name) && !have.has(name)) {
      missing.push(name);
    }
  }
}
console.log('');
if (missing.length) {
  console.log('仍缺失（需要人工确认）:', [...new Set(missing)].join(', '));
} else {
  console.log('所有 Termux 侧依赖名均已就位 ✓');
}
