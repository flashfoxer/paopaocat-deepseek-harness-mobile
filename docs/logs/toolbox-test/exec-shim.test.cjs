// exec-shim 测试（临时产物，放在 docs/logs 下）
// 1) 纯函数改写规则  2) 预加载后真实子进程  3) 退出码/错误透传
'use strict';
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');

const SHIM = process.argv[2];
const NODE_EXE = process.argv[3];

// 环境变量必须在 require shim 之前设好（shim 在加载时读配置）
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-shim-'));
const dummyFs = path.join(tmp, 'android-fs-shim.cjs');
fs.writeFileSync(dummyFs, "'use strict';\n");
const dummyTmp = path.join(tmp, 'tmp');
fs.mkdirSync(dummyTmp, { recursive: true });

process.env.DSH_ANDROID_NODE_BIN = NODE_EXE;
process.env.DSH_ANDROID_FS_SHIM = dummyFs;
process.env.DSH_ANDROID_EXEC_SHIM = SHIM;
process.env.DSH_ANDROID_TMPDIR = dummyTmp;

const shim = require(SHIM);
const cp = require('node:child_process');

const out = [];
function say(s) { out.push(s); }

say('active = ' + shim.isActive());
say('missing = ' + JSON.stringify(shim.missingEnv()));

// ---- 1) 纯函数改写规则
function rw(cmd, args, opts) {
  const r = shim.rewriteCommand(cmd, args, opts);
  if (!r) return 'null(透传)';
  return JSON.stringify({
    command: r.command,
    args: r.args.map((a) => (a.length > 60 ? a.slice(0, 60) + `…(+${a.length - 60})` : a)),
    shell: r.options ? r.options.shell : undefined,
    env: r.env ? Object.keys(r.env).sort() : undefined,
    ldPathDir: r.ldPathDir,
  });
}
say('bash -c      -> ' + rw('bash', ['-c', 'echo hi'], {}));
say('bash -lc     -> ' + rw('bash', ['-lc', 'echo hi'], {}));
say('bash 脚本    -> ' + rw('bash', ['script.sh'], {}));
say('sh -c        -> ' + rw('sh', ['-c', 'echo hi'], {}));
say('node         -> ' + rw('node', ['a.mjs'], {}));
say('/bin/bash    -> ' + rw('/bin/bash', ['-c', 'x'], {}));
say('python3      -> ' + rw('python3', ['-c', 'x'], {}));
say('pandoc       -> ' + rw('pandoc', ['a.md'], {}));
say('shell:true   -> ' + rw('node a.mjs', [], { shell: true }));

// ---- 2) prelude 内容抽样 + 语法检查用的文件
const pre = shim.prelude();
const preFile = path.join(tmp, 'prelude.sh');
fs.writeFileSync(preFile, pre);
say('prelude bytes = ' + Buffer.byteLength(pre, 'utf8') + ' lines=' + pre.split('\n').length);
say('prelude 自引用 export = ' + /DSH_ANDROID_PRELUDE='/.test(pre));
say('prelude 文件 = ' + preFile);

// ---- 3) 真实子进程：spawn('node', ...) 必须被改写后仍能跑
const p1 = cp.spawnSync('node', ['-e', 'console.log("child-ok " + JSON.stringify(process.execArgv))'], { encoding: 'utf8' });
say('spawnSync node status=' + p1.status + ' stdout=' + JSON.stringify((p1.stdout || '').trim()) + ' stderr=' + JSON.stringify((p1.stderr || '').trim()));

// ---- 4) spawn('bash', ...) 在 Windows 上应 ENOENT，且 path 指向改写后的 /system/bin/sh
const p2 = cp.spawnSync('bash', ['-c', 'echo hi'], { encoding: 'utf8' });
say('spawnSync bash status=' + p2.status + ' error.path=' + JSON.stringify(p2.error && p2.error.path) + ' code=' + (p2.error && p2.error.code));

// ---- 5) execFile('node', ...) 同样命中
const p3 = cp.execFileSync('node', ['-e', 'process.stdout.write("ef-ok")'], { encoding: 'utf8' });
say('execFileSync node stdout=' + JSON.stringify(p3.trim()));

// ---- 6) exec(command) 应换成 /system/bin/sh（Windows 上必然失败，但能证明改写）
const p4 = cp.spawnSync('bash', ['-c', 'echo x'], { shell: false });
say('shell=false 对照 status=' + p4.status);

// ---- 7) mergeEnv：调用方给了 env 时，必须"补"而不是"换掉"，也不能改调用方对象
const callerOpts = { env: { PATH: '/system/bin', MY_VAR: '1' }, encoding: 'utf8' };
const merged = shim.mergeEnv(callerOpts, shim.rewriteCommand('node', ['a.mjs'], {}));
say('mergeEnv 保留调用方变量 = ' + (merged.env.MY_VAR === '1' && merged.env.PATH === '/system/bin'));
say('mergeEnv 补上 DSH 四件套 = ' + ['DSH_ANDROID_NODE_BIN', 'DSH_ANDROID_FS_SHIM', 'DSH_ANDROID_EXEC_SHIM', 'DSH_ANDROID_TMPDIR'].every((k) => merged.env[k]));
say('mergeEnv 保留其它 options（encoding） = ' + (merged.encoding === 'utf8'));
say('mergeEnv 不修改调用方原对象 = ' + (Object.keys(callerOpts.env).length === 2 && callerOpts.env.DSH_ANDROID_NODE_BIN === undefined));
const withLd = shim.mergeEnv({ env: { LD_LIBRARY_PATH: '/opt/lib' } }, shim.rewriteCommand('node', ['a.mjs'], {}));
say('LD_LIBRARY_PATH 前插且保留原值 = ' + (withLd.env.LD_LIBRARY_PATH === path.dirname(NODE_EXE) + ':/opt/lib'));
const noEnvOpts = shim.mergeEnv({}, shim.rewriteCommand('node', ['a.mjs'], {}));
say('调用方没给 env 时从 process.env 继承并补 = ' + (Object.keys(noEnvOpts.env).some((k) => k.toUpperCase() === 'PATH') && !!noEnvOpts.env.DSH_ANDROID_NODE_BIN));
const shEnv = shim.rewriteCommand('bash', ['-c', 'echo x'], {}).env;
say('bash 改写只补 DSH 四件套（不塞 LD_LIBRARY_PATH 给 /system/bin/sh） = ' + (Object.keys(shEnv).length === 4 && !shEnv.LD_LIBRARY_PATH));

// ---- 8) 父环境继承（DSH 的 subprocess 层会 scrub 掉 SENSITIVE/DSH_*，必须由这里补回来）
process.env.AGNES_API_KEY = 'sk-agnes-probe';
process.env.MY_OWN_PROBE = 'from-parent';
const inh = shim.mergeEnv({ env: { PATH: '/system/bin' } }, shim.rewriteCommand('bash', ['-c', 'env'], {}));
say('继承父环境：AGNES_API_KEY 到达 shell = ' + (inh.env.AGNES_API_KEY === 'sk-agnes-probe'));
say('继承父环境：自定义变量到达 shell = ' + (inh.env.MY_OWN_PROBE === 'from-parent'));
// 关键性质：父进程里存在的变量都要到达子进程（LD_LIBRARY_PATH/TMPDIR 在 Windows 上本来就没有，
// 所以不写死变量名，只断言"父进程有的都在"）
const parentKeys = Object.keys(process.env).filter((k) => process.env[k] !== undefined);
say('继承父环境：父进程全部变量都到达 = ' + parentKeys.every((k) => inh.env[k] !== undefined) + ' (' + parentKeys.length + ' 个)');
say('继承父环境：DSH 四件套都在 = ' + ['DSH_ANDROID_NODE_BIN', 'DSH_ANDROID_FS_SHIM', 'DSH_ANDROID_EXEC_SHIM', 'DSH_ANDROID_TMPDIR'].every((k) => !!inh.env[k]));
const wins = shim.mergeEnv({ env: { MY_OWN_PROBE: 'explicit-wins' } }, shim.rewriteCommand('bash', ['-c', 'env'], {}));
say('调用方显式给的优先 = ' + (wins.env.MY_OWN_PROBE === 'explicit-wins'));
say('node 改写同样继承父环境 = ' + (shim.mergeEnv({}, shim.rewriteCommand('node', ['a.mjs'], {})).env.AGNES_API_KEY === 'sk-agnes-probe'));
process.env.DSH_ANDROID_ENV_PASSTHROUGH = 'none';
const noneMode = shim.mergeEnv({ env: { ONLY_THIS: '1' } }, shim.rewriteCommand('bash', ['-c', 'env'], {}));
say('PASSTHROUGH=none → 不继承父环境 = ' + (noneMode.env.AGNES_API_KEY === undefined && noneMode.env.ONLY_THIS === '1' && !!noneMode.env.DSH_ANDROID_TMPDIR));
process.env.DSH_ANDROID_ENV_PASSTHROUGH = 'AGNES_,DSH_ANDROID_';
const filtered = shim.mergeEnv({}, shim.rewriteCommand('bash', ['-c', 'env'], {}));
say('PASSTHROUGH=前缀白名单只放行匹配项 = ' + (filtered.env.AGNES_API_KEY === 'sk-agnes-probe' && filtered.env.MY_OWN_PROBE === undefined));
delete process.env.DSH_ANDROID_ENV_PASSTHROUGH;

console.log(out.join('\n'));
console.log('TMPDIR_FOR_TEST=' + tmp);
