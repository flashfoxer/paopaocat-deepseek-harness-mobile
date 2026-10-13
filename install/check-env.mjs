/**
 * 环境探测：磁盘、Java、Android SDK、Flutter 镜像可达性与最新 stable 版本。
 * 只读，不做任何安装。
 */

import os from 'node:os';
import { execSync } from 'node:child_process';

function tryExec(cmd) {
  try {
    return execSync(cmd, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return null;
  }
}

console.log('=== 系统 ===');
console.log(`platform=${process.platform} arch=${process.arch} cpus=${os.cpus().length} ` +
  `mem=${Math.round(os.totalmem() / 1024 ** 3)}GB free=${Math.round(os.freemem() / 1024 ** 3)}GB`);

console.log('\n=== Java ===');
const javaVersion = tryExec('java -version');
console.log(javaVersion ? javaVersion.split('\n')[0] : '未安装（Flutter 构建 Android 需要 JDK 17+）');
const javac = tryExec('javac -version');
console.log(javac ? `javac: ${javac}` : 'javac: 未安装');

console.log('\n=== Android 环境 ===');
console.log(`ANDROID_HOME=${process.env.ANDROID_HOME ?? '(未设)'}`);
console.log(`ANDROID_SDK_ROOT=${process.env.ANDROID_SDK_ROOT ?? '(未设)'}`);
for (const p of ['D:\\Android', 'C:\\Android', 'D:\\Programs\\Android', `${process.env.LOCALAPPDATA}\\Android`]) {
  if (p && tryExec(`cmd /c if exist "${p}" echo yes`) === 'yes') console.log(`发现目录: ${p}`);
}

console.log('\n=== Flutter ===');
for (const p of ['D:\\flutter', 'D:\\Programs\\flutter', 'C:\\flutter', 'C:\\src\\flutter']) {
  if (tryExec(`cmd /c if exist "${p}" echo yes`) === 'yes') console.log(`发现目录: ${p}`);
}

console.log('\n=== 镜像可达性 ===');
const mirrors = [
  ['storage.flutter-io.cn', 'https://storage.flutter-io.cn/flutter_infra_release/releases/releases_windows.json'],
  ['storage.googleapis.com', 'https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json'],
];

for (const [name, url] of mirrors) {
  const started = Date.now();
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(20_000) });
    console.log(`${name}: HTTP ${res.status} (${Date.now() - started}ms)`);
    if (!res.ok) continue;
    const data = await res.json();
    const stableHash = data.current_release?.stable;
    const release = (data.releases ?? []).find((r) => r.hash === stableHash);
    console.log(`  最新 stable: ${release?.version}  archive=${release?.archive}`);
  } catch (err) {
    console.log(`${name}: 失败 - ${err.message} (${Date.now() - started}ms)`);
  }
}
