// 把 exec-shim 的 prelude 写成可直接用 POSIX shell 跑的文件，用于语法/行为验证
'use strict';
const fs = require('node:fs');
const path = require('node:path');

const SHIM = process.argv[2];
const NODE_EXE = process.argv[3];
const DUMMY_FS = process.argv[4];
const OUT_CMD = process.argv[5];   // 输出：prelude + 用户命令（模拟 bash -c 实际收到的字符串）
const OUT_PRELUDE = process.argv[6]; // 输出：纯 prelude（用于 bash -n 语法检查）

process.env.DSH_ANDROID_NODE_BIN = NODE_EXE;
process.env.DSH_ANDROID_FS_SHIM = DUMMY_FS;
process.env.DSH_ANDROID_EXEC_SHIM = SHIM;
process.env.DSH_ANDROID_TMPDIR = '/data/user/0/com.paopao.dsh/files/tmp';

const shim = require(SHIM);
const r = shim.rewriteCommand('bash', ['-c', 'echo hello-from-mksh; node -e "console.log(2+2)"'], {});
fs.writeFileSync(OUT_PRELUDE, shim.prelude());
fs.writeFileSync(OUT_CMD, r.args[1] + '\n');
console.log('wrote', path.basename(OUT_PRELUDE), path.basename(OUT_CMD));
