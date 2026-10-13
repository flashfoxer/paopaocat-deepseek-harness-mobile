/**
 * 探测 Android 可用的 Node 运行时来源。
 *
 * 单 APK 方案的关键前提：拿到一个能在 Android（bionic libc、arm64）上跑的 Node 22+ 二进制。
 * 候选：
 *   1. Termux 的 nodejs 包（官方 Node 编译为 Android）
 *   2. nodejs-mobile 的预编译产物（嵌入式 libnode）
 *   3. npm 上的 nodejs-mobile-node
 */

const targets = [
  ['Termux nodejs 包目录', 'https://packages.termux.dev/apt/termux-main/pool/main/n/nodejs/', 'termux'],
  ['nodejs-mobile 最新 release', 'https://api.github.com/repos/nodejs-mobile/nodejs-mobile/releases/latest', 'github'],
  ['npm: nodejs-mobile-node', 'https://registry.npmmirror.com/nodejs-mobile-node', 'npm'],
  ['npm: nodejs-mobile-react-native', 'https://registry.npmmirror.com/nodejs-mobile-react-native', 'npm'],
];

for (const [name, url, kind] of targets) {
  console.log(`\n=== ${name} ===`);
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(25_000) });
    console.log(`  HTTP ${res.status}`);
    if (!res.ok) continue;

    if (kind === 'termux') {
      const text = await res.text();
      const debs = [...text.matchAll(/href="([^"]+\.deb)"/g)].map((m) => m[1]);
      console.log(`  .deb 数量: ${debs.length}`);
      debs.slice(-8).forEach((d) => console.log(`    ${d}`));
    } else if (kind === 'github') {
      const j = await res.json();
      console.log(`  tag: ${j.tag_name}  name: ${j.name}`);
      for (const a of (j.assets ?? []).slice(0, 10)) {
        console.log(`    ${a.name}  (${(a.size / 1024 / 1024).toFixed(1)}MB)`);
      }
    } else {
      const j = await res.json();
      console.log(`  latest: ${j['dist-tags']?.latest}`);
      const versions = Object.keys(j.versions ?? {});
      console.log(`  最近版本: ${versions.slice(-6).join(', ')}`);
      const latest = j.versions?.[j['dist-tags']?.latest];
      if (latest) console.log(`  dist: ${JSON.stringify(latest.dist?.tarball)}`);
    }
  } catch (err) {
    console.log(`  失败: ${err.message}`);
  }
}
