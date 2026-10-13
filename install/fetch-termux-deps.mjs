/**
 * 从 Termux 仓库抓取 node 的全部运行时依赖（.deb），用于组装 Android 内嵌运行时。
 *
 * node 包的 control 声明：Depends: libc++, openssl, c-ares, libicu, libsqlite, zlib, libffi
 *
 * 两种架构都抓：
 *   aarch64 → 真机（arm64 手机）
 *   x86_64  → 模拟器（本机验证用）
 */

import { createWriteStream, existsSync, mkdirSync, statSync } from 'node:fs';
import path from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

const BASE = 'https://packages.termux.dev/apt/termux-main/pool/main';
const PKGS = ['libc++', 'openssl', 'c-ares', 'libicu', 'libsqlite', 'zlib', 'libffi'];
const ARCHES = ['aarch64', 'x86_64'];
const OUT = 'D:/dev/android-node/deps';

const mb = (n) => (n / 1024 / 1024).toFixed(1);

async function listDebs(pkg) {
  // Termux 的 pool 结构：
  //   c-ares  -> pool/main/c/c-ares/
  //   openssl -> pool/main/o/openssl/
  //   libicu  -> pool/main/libi/libicu/      （lib 开头的包用 lib<第4个字符>）
  //   libc++  -> pool/main/libc/libc++/
  const dir = pkg.startsWith('lib') ? 'lib' + pkg[3] : pkg[0];
  const url = `${BASE}/${dir}/${pkg}/`;
  const res = await fetch(url, { signal: AbortSignal.timeout(30_000) });
  if (!res.ok) throw new Error(`列目录失败 HTTP ${res.status}`);
  const html = await res.text();
  return [...html.matchAll(/href="([^"]+\.deb)"/g)].map((m) => m[1]);
}

async function download(url, dest) {
  mkdirSync(path.dirname(dest), { recursive: true });
  const res = await fetch(url, { redirect: 'follow', signal: AbortSignal.timeout(300_000) });
  if (!res.ok || !res.body) throw new Error(`HTTP ${res.status}`);
  await pipeline(Readable.fromWeb(res.body), createWriteStream(dest));
  return statSync(dest).size;
}

for (const arch of ARCHES) {
  console.log(`\n===== ${arch} =====`);
  for (const pkg of PKGS) {
    try {
      const files = await listDebs(pkg);
      const candidates = files.filter((f) => f.includes(`_${arch}.deb`));
      if (candidates.length === 0) {
        console.log(`  ${pkg.padEnd(12)} 仓库里没有 ${arch} 版本（共 ${files.length} 个 deb）`);
        continue;
      }
      // 文件名形如 libicu_78.1-1_aarch64.deb；排序取最后一个（版本最大）
      candidates.sort();
      const file = candidates[candidates.length - 1];
      const dest = path.join(OUT, arch, file);
      if (existsSync(dest)) {
        console.log(`  ${pkg.padEnd(12)} ${file.padEnd(34)} 已存在，跳过`);
        continue;
      }
      const dir = pkg.startsWith('lib') ? 'lib' + pkg[3] : pkg[0];
      const url = `${BASE}/${dir}/${pkg}/${file}`;
      const size = await download(url, dest);
      console.log(`  ${pkg.padEnd(12)} ${file.padEnd(34)} ${mb(size)} MB`);
    } catch (err) {
      console.log(`  ${pkg.padEnd(12)} 失败: ${err.message}`);
    }
  }
}

console.log('\n完成。');
