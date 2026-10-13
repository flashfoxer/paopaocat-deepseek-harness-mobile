// 验证：--require 预加载后，ESM 的具名导入拿到的到底是不是被改写的函数
// （DSH 的 bash 工具是 ESM：`import { spawn } from 'node:child_process'`，
//  如果具名导出还是原函数，这个 shim 就白写了 —— 必须实测）
import { spawn } from 'node:child_process';
import cp from 'node:child_process';

console.log('esm named  spawn.name =', spawn.name);
console.log('esm default spawn.name =', cp.spawn.name);
console.log('same function =', spawn === cp.spawn);

// 真的跑一个 node 子进程：如果具名导入命中了 shim，子进程会带上 execArgv
const child = spawn('node', ['-e', 'process.stdout.write(JSON.stringify(process.execArgv))'], {
  stdio: ['ignore', 'pipe', 'inherit'],
});
let buf = '';
child.stdout.on('data', (d) => { buf += d; });
child.on('close', (code) => {
  console.log('child exit =', code);
  console.log('child execArgv =', buf);
});
