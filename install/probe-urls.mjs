/**
 * 探测各下载源可达性（含重定向后的最终地址与文件大小）。
 * 只做 HEAD / 小范围 GET，不下载完整文件。
 */

const targets = [
  ['Flutter SDK (flutter-io.cn)', 'https://storage.flutter-io.cn/flutter_infra_release/releases/stable/windows/flutter_windows_3.47.6-stable.zip'],
  ['Flutter SDK (googleapis)', 'https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.47.6-stable.zip'],
  ['JDK17 Adoptium API', 'https://api.adoptium.net/v3/binary/latest/17/ga/windows/x64/jdk/hotspot/normal/eclipse'],
  ['JDK17 Microsoft', 'https://aka.ms/download-jdk/microsoft-jdk-17-windows-x64.zip'],
  ['JDK17 清华 Adoptium 目录', 'https://mirrors.tuna.tsinghua.edu.cn/Adoptium/17/jdk/x64/windows/'],
  ['Android cmdline-tools (google)', 'https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip'],
  ['Android cmdline-tools (腾讯镜像)', 'https://mirrors.cloud.tencent.com/AndroidSDK/commandlinetools-win-11076708_latest.zip'],
  ['Android platform-tools (google)', 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'],
];

const mb = (n) => (n / 1024 / 1024).toFixed(1);

for (const [name, url] of targets) {
  const started = Date.now();
  try {
    const res = await fetch(url, { method: 'GET', headers: { range: 'bytes=0-0' }, redirect: 'follow', signal: AbortSignal.timeout(25_000) });
    const len = res.headers.get('content-range') ?? res.headers.get('content-length') ?? '?';
    const finalUrl = res.url === url ? '' : `\n      最终地址: ${res.url}`;
    console.log(`[${res.status}] ${name}  (${Date.now() - started}ms)\n      ${url}${finalUrl}\n      长度: ${len}`);
    try { await res.body?.cancel(); } catch {}
  } catch (err) {
    console.log(`[ERR] ${name}  (${Date.now() - started}ms)\n      ${url}\n      ${err.message}`);
  }
}
