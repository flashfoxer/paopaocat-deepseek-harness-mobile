/** 探测 Gradle 发行版与 Maven 仓库镜像可达性。 */

const targets = [
  ['gradle 官方', 'https://services.gradle.org/distributions/gradle-9.3.1-all.zip'],
  ['gradle 腾讯镜像', 'https://mirrors.cloud.tencent.com/gradle/gradle-9.3.1-all.zip'],
  ['gradle 腾讯镜像(bin)', 'https://mirrors.cloud.tencent.com/gradle/gradle-9.3.1-bin.zip'],
  ['maven 阿里 public', 'https://maven.aliyun.com/repository/public/'],
  ['maven 阿里 google', 'https://maven.aliyun.com/repository/google/'],
  ['maven 阿里 gradle-plugin', 'https://maven.aliyun.com/repository/gradle-plugin/'],
  ['maven central', 'https://repo1.maven.org/maven2/'],
];

const mb = (n) => (n / 1024 / 1024).toFixed(1);

for (const [name, url] of targets) {
  const started = Date.now();
  try {
    const res = await fetch(url, {
      method: 'GET',
      headers: url.endsWith('.zip') ? { range: 'bytes=0-0' } : {},
      redirect: 'follow',
      signal: AbortSignal.timeout(25_000),
    });
    const len = res.headers.get('content-range') ?? res.headers.get('content-length') ?? '?';
    let sizeInfo = '';
    const m = /bytes 0-0\/(\d+)/.exec(len);
    if (m) sizeInfo = ` (${mb(Number(m[1]))}MB)`;
    console.log(`[${res.status}] ${name}  ${Date.now() - started}ms${sizeInfo}`);
    try {
      await res.body?.cancel();
    } catch {}
  } catch (err) {
    console.log(`[ERR] ${name}  ${Date.now() - started}ms  ${err.message}`);
  }
}
