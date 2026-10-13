// Android 上 Node 运行时能力自检 —— 逐项对应 DSH 的实际依赖
const { execSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');

const line = (label, value) => console.log(`${label.padEnd(22)} ${value}`);

line('node', process.version);
line('platform / arch', `${process.platform} / ${process.arch}`);
line('cpus / mem', `${os.cpus().length} / ${Math.round(os.totalmem() / 1024 / 1024)} MB`);

// 1) node:sqlite —— DSH 用它做会话索引（Node 22.5+ 才有）
try {
  const sqlite = require('node:sqlite');
  const { DatabaseSync } = sqlite;
  const db = new DatabaseSync(':memory:');
  db.exec('CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)');
  db.prepare('INSERT INTO t(name) VALUES (?)').run('hello');
  const row = db.prepare('SELECT name FROM t WHERE id = 1').get();
  db.close();
  line('node:sqlite', `OK -> ${row.name}`);
} catch (e) {
  line('node:sqlite', `FAILED -> ${e.message}`);
}

// 2) 子进程 —— DSH 的工具执行依赖它
try {
  const out = execSync('echo hello-from-android', { encoding: 'utf8' }).trim();
  line('child_process', `OK -> ${out}`);
} catch (e) {
  line('child_process', `FAILED -> ${e.message}`);
}

// 3) 文件系统 —— 会话持久化与读写工具依赖它
try {
  const p = '/data/local/tmp/dshrt/selftest.txt';
  fs.writeFileSync(p, 'written by node on android');
  line('fs write/read', `OK -> ${fs.readFileSync(p, 'utf8')}`);
} catch (e) {
  line('fs write/read', `FAILED -> ${e.message}`);
}

// 4) 网络（模型 API 是唯一的联网依赖）
try {
  const https = require('node:https');
  const req = https.request({ host: 'api.deepseek.com', port: 443, path: '/', method: 'HEAD', timeout: 15000 }, (res) => {
    line('https', `OK -> HTTP ${res.statusCode}`);
    process.exit(0);
  });
  req.on('timeout', () => { req.destroy(); line('https', 'TIMEOUT'); process.exit(0); });
  req.on('error', (e) => { line('https', `FAILED -> ${e.message}`); process.exit(0); });
  req.end();
} catch (e) {
  line('https', `FAILED -> ${e.message}`);
}
