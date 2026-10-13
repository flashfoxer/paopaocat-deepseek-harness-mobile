// 0.13 设备端「会话里能不能跑命令」的机制探针。
//
// 它**不经过模型、不经过界面**，直接用 App 真正用的那个 node 二进制 + 那两份 shim +
// 那套环境变量，去调 child_process —— 也就是 DSH 的 bash 工具在会话里做的事。
// 修前：`spawn bash ENOENT`（Android 上没有 bash）。修后：三条命令都该有输出。
//
// 判定（三行都要看）：
//   [bash-echo]    → DSH_SHIM_OK + TOOLBOX/EXEC_SHIM 路径（证明 bash 被换成 /system/bin/sh）
//   [bash-node]    → NODE_OK vXX（证明 shell 里的 node 函数指向随包 libnode）
//   [node-direct]  → NODE_DIRECT_OK（证明 shim 把裸 `node` 也改了）
'use strict';
const cp = require('node:child_process');

function show(tag, cmd, args) {
  const r = cp.spawnSync(cmd, args, { encoding: 'utf8', timeout: 60000 });
  const err = r.error ? `${r.error.code || 'ERR'} ${r.error.message}` : 'none';
  console.log(`[${tag}] error=${err} status=${r.status}`);
  console.log(`[${tag}] stdout=${String(r.stdout || '').trim()}`);
  if (r.stderr) console.log(`[${tag}] stderr=${String(r.stderr).trim()}`);
}

show('bash-echo', 'bash', [
  '-c',
  'echo DSH_SHIM_OK; echo "TOOLBOX=$DSH_ANDROID_TOOLBOX"; echo "SH=$0"; uname -s',
]);
show('bash-node', 'bash', ['-c', 'node -e "console.log(1+1)"']);
show('node-direct', 'node', ['-e', 'console.log("NODE_DIRECT_OK")']);
console.log('probe done');
