'use strict';
/**
 * android-exec-shim.cjs —— 让 `bash` / `node` 在 Android 上真的能跑。
 *
 * ════════════════════════════════════════════════════════════════════════════
 * 这是什么 / 为什么需要它
 * ════════════════════════════════════════════════════════════════════════════
 *
 * DSH 的 bash 工具（`@deepseek-ai/dsh-bash-local`）把启动命令**写死**为
 * `spawn('bash', ['-c', 命令])` —— 它在桌面 Linux/macOS 上没问题，但 Android 上：
 *
 *   1. **没有 bash**。`/system/bin/sh` 是唯一可用的 shell，而且它是 mksh（不是 bash）。
 *      所以 `spawn('bash', ...)` 直接 ENOENT，模型一调 bash 就失败。
 *   2. **没有 node 在 PATH 里**。node 只是一个随包的 `libnode.so`，必须带上
 *      `--expose-internals --require <fs-shim>` 才能跑（放在 nativeLibraryDir 才能执行）。
 *      模型在 bash 里写 `node xxx.mjs` 同样 ENOENT。
 *   3. **Android 从 10 起禁止执行 App 数据目录里的文件**（SELinux 的 `app_data_file`
 *      没有 execute 权限）。所以**不能**靠"往 filesDir 里塞一个 bash 脚本/一个
 *      `node` 包装脚本然后把目录加进 PATH"来绕 —— 那样只会得到 EACCES。
 *      唯一能执行的东西是系统分区里的 `/system/bin/sh`（以及 nativeLibraryDir 下的
 *      `.so`，那是 Android 专门开的口子）。
 *
 * 于是这里做一件很直接的事：**在 DSH 的业务代码 import child_process 之前，
 * 把 child_process 的几个导出函数换成我们的版本**，在上面把
 *   `bash -c CMD`  →  `/system/bin/sh -c "<prelude>; CMD"`
 *   `node ...`     →  `<libnode.so> --expose-internals --require <fs-shim> --require <exec-shim> ...`
 *   `exec(CMD)`    →  同样换 shell 到 `/system/bin/sh` 并注入 prelude
 * 其它命令**一律原样透传**（刻意不假装 python / pandoc 存在：假装存在只会把
 * "工具缺失"这种明确错误变成更难查的怪错误）。
 *
 * ════════════════════════════════════════════════════════════════════════════
 * 用法（由 App 侧接线，不要手工改 Dart）
 * ════════════════════════════════════════════════════════════════════════════
 *
 * 通过 `node --require` 预加载；Node 保证 --require 的模块在业务代码之前执行，
 * 所以改写一定发生在 `import { spawn } from 'node:child_process'` 之前
 * （内置模块的 ESM 具名导出是首次 import 时从 CJS 导出对象上取的快照，
 *  预加载先跑 → 拿到的是我们改过的函数）。
 *
 *   <node> --expose-internals --require <filesDir>/shims/android-fs-shim.cjs \
 *                  --require <filesDir>/toolbox/android-exec-shim.cjs <入口>
 *
 * 需要的 4 个环境变量（**缺任何一个就完全不改写、原样透传**，避免半残状态）：
 *
 *   DSH_ANDROID_NODE_BIN  node 二进制绝对路径（就是那个 libnode.so）
 *   DSH_ANDROID_FS_SHIM   android-fs-shim.cjs 绝对路径
 *   DSH_ANDROID_EXEC_SHIM 本文件自己的绝对路径
 *   DSH_ANDROID_TMPDIR    可写临时目录（不要用 /data/local/tmp，Android 10+ 不可写）
 *
 * 调试：`DSH_ANDROID_SHIM_DEBUG=1` 会在 stderr 打一行说明（是否启用/缺哪个变量/
 * 每次改写的结果）。shim 内部出错绝不吞掉：打一行 stderr 然后**退回透传**，
 * 保证正常命令不会被这个 shim 弄坏。
 *
 * ════════════════════════════════════════════════════════════════════════════
 * prelude（注入到每个 `-c` 命令前面的一小段 shell 代码）
 * ════════════════════════════════════════════════════════════════════════════
 *
 * 定义 shell 函数 `node`（自动带 --expose-internals/--require）与
 * `bash`/`sh`（转发到 /system/bin/sh），并导出 LD_LIBRARY_PATH 与
 * DSH_ANDROID_*，这样嵌套调用还能命中 shim。
 *
 * 关于 `bash()`：规范形态是 `exec /system/bin/sh "$@"`。但 shell 函数**不会**
 * 通过 fork/exec 传给子 shell（没有 `export -f` 这回事），所以嵌套的
 * `bash -c 'node a.mjs'` 会丢函数、`node` 又 ENOENT。这里因此在 `-c`/`-lc`
 * 形态下**把 prelude 再注入一次**（通过导出的 $DSH_ANDROID_PRELUDE），
 * 其余形态仍然是 `exec /system/bin/sh "$@"`。不需要 exec 的形态刻意不用 exec，
 * 否则 `bash -c 'a; b'` 里没法再跑别的命令。
 *
 * 已知限制（如实写在这里，不要期待它做到）：
 *   * 脚本里的 `#!/usr/bin/env node` shebang、`env node`、`command node`
 *     **绕不过**：Android 上没有 node 可执行文件在 PATH 里，只能走 shell 函数，
 *     或者用 `$DSH_ANDROID_NODE_BIN` 绝对路径。
 *   * 用 bash 专有语法（数组、`[[ ]]`、`{a,b}` 展开…）的脚本在 mksh 上仍会失败，
 *     这是 Android 没有 bash 的既成事实，不是本 shim 能修的。
 */

const path = require('node:path');

const DEBUG = process.env.DSH_ANDROID_SHIM_DEBUG === '1';

/** 打一行调试信息（只在显式开 DEBUG 时）。 */
function debug(msg) {
  if (DEBUG) process.stderr.write('[android-exec-shim] ' + msg + '\n');
}

/** shim 自身的问题（改写失败等）**一定**要打出来，不能静默吞掉。 */
function warn(msg) {
  process.stderr.write('[android-exec-shim] ' + msg + '\n');
}

// ─────────────────────────────────────────────────────────── 配置

const CFG = {
  nodeBin: String(process.env.DSH_ANDROID_NODE_BIN || '').trim(),
  fsShim: String(process.env.DSH_ANDROID_FS_SHIM || '').trim(),
  execShim: String(process.env.DSH_ANDROID_EXEC_SHIM || '').trim(),
  tmpDir: String(process.env.DSH_ANDROID_TMPDIR || '').trim(),
};

/**
 * **可选**能力：ffmpeg / ffprobe。
 *
 * ⚠️ 刻意**不放进 [CFG]**：`ACTIVE` 的判定是"CFG 里有一个空值就整体不启用"，
 * 而 ffmpeg 不是每个包都有（比如没把二进制打进来时）—— 放进去会让"没有 ffmpeg"
 * 顺带把 node 的改写也一起关掉，那是最糟的连锁反应。
 *
 * 为什么 ffmpeg 也要走这里的 shell 函数、而不是放数据目录 + 加 PATH：
 * 与 node 完全同因 —— Android 不允许从 App 数据目录执行文件（实测 EACCES），
 * 二进制只能以 `<nativeLibraryDir>/libffmpeg.so` 的形式存在（名字必须是 lib*.so，
 * 否则 Gradle 不会把它当原生库打进包），所以：
 *   · 环境变量 `DSH_ANDROID_FFMPEG` / `AGNES_FFMPEG` 指向绝对路径（给认变量的代码用）；
 *   · prelude 里再定义 `ffmpeg()` / `ffprobe()` 两个 shell 函数（给直接写
 *     `ffmpeg -i ...` 的技能脚本用）。
 */
const FFMPEG = {
  ffmpeg: String(process.env.DSH_ANDROID_FFMPEG || '').trim(),
  ffprobe: String(process.env.DSH_ANDROID_FFPROBE || '').trim(),
};

const MISSING = Object.keys(CFG).filter((k) => !CFG[k]);
/** 4 个变量齐全才启用改写；否则完全透传（并如实说明缺哪个）。 */
const ACTIVE = MISSING.length === 0;

/** Android 上唯一可执行的 shell。 */
const SH = '/system/bin/sh';

/** node 二进制所在目录：子进程要靠 LD_LIBRARY_PATH 找到随包的那堆 .so。 */
const NODE_DIR = ACTIVE ? path.dirname(CFG.nodeBin) : '';

// ─────────────────────────────────────────────────────────── prelude

/** POSIX 单引号转义：' → '\'' （mksh/bash 都认）。 */
function shQuote(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'";
}

/** 要 export 给子进程（含嵌套 shell 函数）的 DSH 四件套。 */
function dshEnv() {
  const env = {
    DSH_ANDROID_NODE_BIN: CFG.nodeBin,
    DSH_ANDROID_FS_SHIM: CFG.fsShim,
    DSH_ANDROID_EXEC_SHIM: CFG.execShim,
    DSH_ANDROID_TMPDIR: CFG.tmpDir,
  };
  // 可选：有才带上（空值也带上没坏处，但保持"缺了就是缺了"更清楚）
  if (FFMPEG.ffmpeg) env.DSH_ANDROID_FFMPEG = FFMPEG.ffmpeg;
  if (FFMPEG.ffprobe) env.DSH_ANDROID_FFPROBE = FFMPEG.ffprobe;
  return env;
}

/**
 * 拼出 prelude。刻意只用 mksh 兼容语法（不依赖 bash 扩展）：
 * `if/then/else/fi`、`case`、`[ ]`、函数定义，mksh 全支持。
 *
 * 注意：prelude 是**直接拼进 `sh -c` 的那个字符串**里的，不经过二次解析，
 * 所以内部路径必须自己用单引号包好（见 shQuote）。
 */
function buildPreludeBase() {
  const q = shQuote;
  const ld = q(NODE_DIR);
  return [
    '# ---- DSH Android exec shim prelude（自动生成，勿手改）----',
    'DSH_ANDROID_NODE_BIN=' + q(CFG.nodeBin),
    'DSH_ANDROID_FS_SHIM=' + q(CFG.fsShim),
    'DSH_ANDROID_EXEC_SHIM=' + q(CFG.execShim),
    'DSH_ANDROID_TMPDIR=' + q(CFG.tmpDir),
    'export DSH_ANDROID_NODE_BIN DSH_ANDROID_FS_SHIM DSH_ANDROID_EXEC_SHIM DSH_ANDROID_TMPDIR',
    // DSH 的 subprocess 层会把父进程里所有 DSH_* 变量**剥掉**（scrubbedParentEnv），
    // 所以必须在这里重新导出一次，嵌套的 shell / node 才能再命中 shim。
    // PATH 兜一下：Android 只有 /system/bin（没有 /bin、没有 /usr/bin），
    // 万一调用方给的 env 里没有 PATH，echo 之类的内建命令还好，ls/cat 就找不到了。
    'case ":$PATH:" in *:/system/bin:*) ;; *) PATH="/system/bin:/system/xbin${PATH:+:$PATH}"; export PATH ;; esac',
    // LD_LIBRARY_PATH 用"前插"而不是覆盖：调用方可能已经有自己的搜索路径
    'if [ -n "$LD_LIBRARY_PATH" ]; then LD_LIBRARY_PATH=' + ld + ':"$LD_LIBRARY_PATH"; else LD_LIBRARY_PATH=' + ld + '; fi',
    'export LD_LIBRARY_PATH',
    'if [ -d "$DSH_ANDROID_TMPDIR" ]; then TMPDIR="$DSH_ANDROID_TMPDIR"; export TMPDIR; fi',
    // 模型在 bash 里写 `node xxx.mjs` 就走这个函数
    'node() { "$DSH_ANDROID_NODE_BIN" --expose-internals --require "$DSH_ANDROID_FS_SHIM" --require "$DSH_ANDROID_EXEC_SHIM" "$@"; }',
    // 显式别名，便于脚本在 PATH 被清空时仍能拿到带 shim 的 node。
    // 注意名字只能用下划线：mksh（/system/bin/sh）按 POSIX 语法只接受合法标识符，
    // `dsh-node` 这种带横线的函数名在 bash 里能过、在 mksh 上会直接报
    // "not a valid identifier"（已实测：bash --posix 复现）。
    'dsh_node() { node "$@"; }',
    // ffmpeg / ffprobe：与 node 同理（二进制在 nativeLibraryDir，名字是 lib*.so）。
    // 只有真的打进包了才定义函数 —— 没打进来时保持"命令不存在"，
    // 让技能如实报错，而不是给一个指向空气的函数。
    'DSH_ANDROID_FFMPEG=' + q(FFMPEG.ffmpeg || ''),
    'DSH_ANDROID_FFPROBE=' + q(FFMPEG.ffprobe || ''),
    'AGNES_FFMPEG=' + q(FFMPEG.ffmpeg || ''),
    'export DSH_ANDROID_FFMPEG DSH_ANDROID_FFPROBE AGNES_FFMPEG',
    'if [ -n "$DSH_ANDROID_FFMPEG" ]; then ffmpeg() { "$DSH_ANDROID_FFMPEG" "$@"; }; fi',
    'if [ -n "$DSH_ANDROID_FFPROBE" ]; then ffprobe() { "$DSH_ANDROID_FFPROBE" "$@"; }; fi',
    // bash/sh：统一交给 /system/bin/sh；-c 形态顺手把 prelude 再注入一次，
    // 让嵌套的 `bash -c 'node a.mjs'` 也能跑（见文件头部说明）。
    '_dsh_sh_run() {',
    '  case "$1" in',
    '    -c|-*c) _dsh_flag="$1" ;;',
    '    *) _dsh_flag="" ;;',
    '  esac',
    '  if [ -n "$_dsh_flag" ] && [ -n "$2" ] && [ -n "$DSH_ANDROID_PRELUDE" ]; then',
    '    _dsh_cmd="$2"',
    '    shift 2',
    '    /system/bin/sh "$_dsh_flag" "$DSH_ANDROID_PRELUDE',
    '$_dsh_cmd" "$@"',
    '  else',
    '    exec /system/bin/sh "$@"',
    '  fi',
    '}',
    'bash() { _dsh_sh_run "$@"; }',
    'sh() { _dsh_sh_run "$@"; }',
    '',
  ].join('\n');
}

let _prelude = null;
/**
 * 完整 prelude（含自引用：把 base 文本放进 $DSH_ANDROID_PRELUDE 并导出，
 * 供嵌套 shell 的 bash()/sh() 复用）。base 里没有这一行，所以嵌套 shell 用的是
 * 从环境继承下来的同一份文本 —— 递归任意深度都成立，且没有循环定义。
 */
function prelude() {
  if (_prelude === null) {
    const base = buildPreludeBase();
    _prelude = base + 'DSH_ANDROID_PRELUDE=' + shQuote(base) + '\nexport DSH_ANDROID_PRELUDE\n';
  }
  return _prelude;
}

// ─────────────────────────────────────────────────────────── 改写规则

/**
 * 一个参数是不是 shell 的 "带 -c" 组合标志（`-c`、`-lc`、`-ec`…）。
 * 只认"以 - 开头、以 c 结尾"的短标志，避免把 `--command` 之类误判。
 */
function isDashCFlag(arg) {
  return typeof arg === 'string' && /^-[A-Za-z]*c$/.test(arg);
}

/** options.shell 是否被显式打开（true 或某个 shell 路径）。 */
function shellEnabled(opts) {
  const s = opts && opts.shell;
  return s !== undefined && s !== null && s !== false;
}

/**
 * 核心改写。返回 null 表示"不处理，调用方原样透传"。
 *
 * 返回 { command, args, options?: 覆盖用的 options, env?: 追加的环境变量,
 *        ldPathDir?: 需要前插进 LD_LIBRARY_PATH 的目录 }
 */
function rewriteCommand(command, args, options) {
  if (typeof command !== 'string' || command === '') return null;
  const argv = Array.isArray(args) ? args.slice() : [];
  const opts = options && typeof options === 'object' ? options : {};

  // ① 调用方开了 shell:true / exec()：参数是一整条**命令行**，不是命令名。
  //    那种情况下正确做法是换 shell + 注入 prelude（含 node/bash 函数），
  //    而不是去改"命令名"（`bash -c 'x'` 这一整串由 mksh 自己解释）。
  if (shellEnabled(opts)) {
    const o = Object.assign({}, opts);
    o.shell = SH; // Android 没有 /bin/sh，这就是默认值会踩的坑
    return { command: prelude() + command, args: argv, options: o, env: dshEnv() };
  }

  // ② 命令名里带 `/`（绝对/相对路径）→ 一律透传：调用方明确知道自己要执行什么。
  if (command.includes('/')) return null;

  const base = path.basename(command).toLowerCase();

  // ③ bash / sh → /system/bin/sh
  if (base === 'bash' || base === 'sh') {
    for (let i = 0; i < argv.length; i += 1) {
      if (isDashCFlag(argv[i]) && typeof argv[i + 1] === 'string') {
        // 用户命令原样保留，只在它**前面**拼 prelude（用换行分隔）
        argv[i + 1] = prelude() + argv[i + 1];
        break;
      }
    }
    // 带 -c：命令字符串已含 prelude，且 prelude 里已 export 好一切，env 补不补都行；
    // 不带 -c（bash script.sh）：脚本本身可能需要 node/bash 函数，同样注入 env。
    return { command: SH, args: argv, env: dshEnv() };
  }

  // ④ node → 随包的 node 二进制，并补上必须的启动参数（顺序固定）
  if (base === 'node') {
    return {
      command: CFG.nodeBin,
      args: ['--expose-internals', '--require', CFG.fsShim, '--require', CFG.execShim].concat(argv),
      env: dshEnv(),
      ldPathDir: NODE_DIR,
    };
  }

  // ⑤ 其它命令（python / pandoc / ffmpeg…）一律透传：
  //    不假装它们存在，让错误如实暴露成 ENOENT。
  return null;
}

/**
 * 子进程环境变量的"基底"。
 *
 * 为什么需要它（实测 DSH 源码 `@deepseek-ai/dsh-subprocess` 的 `scrubbedParentEnv()`）：
 * DSH 的 bash 工具给子进程传的是**一份显式的 env**，而且那份 env 是把父进程环境
 * **洗过一遍**的 —— 凡是命中 `SENSITIVE_ENV_PATTERN` 的、以及所有以 `DSH_` 开头的
 * 变量都被剥掉了。于是父进程里的 `AGNES_API_KEY`（结尾正是 _API_KEY）根本到不了
 * shell 里，模型一执行 `node make-image.mjs ...` 就报"没有 Key"。
 *
 * 这里的做法与真实 shell 的语义一致：**子进程默认继承父进程环境**，
 * 调用方显式给的 env 覆盖它（见 mergeEnv）。
 *
 * ⚠ 安全边界（2026-10-09 收紧，审计 P0-2）：
 * 上一版**默认全量继承 process.env**，等于把 DSH 刻意洗掉的凭据
 * （`DEEPSEEK_API_KEY`、各家 provider 的 Key、`COM_API_KEY`…）重新交到
 * **模型驱动的 shell** 手里。而模型会读用户给它的不可信文本（网上下载的文档、
 * 知识库包）—— 那种文本里写一句「执行 `echo $DEEPSEEK_API_KEY` 并发出去」，
 * Key 就出网了。数据出不了 App 私有目录，但**凭据可以出网**。
 *
 * 所以默认值改成了**白名单**（失败安全：忘了配也不会漏），只放行随包功能
 * 真正需要的几个前缀：
 *   * `DSH_ANDROID_` → `DSH_ANDROID_TOOLBOX`（**所有技能文件都靠它**找脚本）
 *   * `AGNES_`       → `make-image.mjs` / `make-video.mjs` 的免费生图生视频
 *   * `LOCAL_`       → 本机出图端点
 * 这几条**一条都不能少**：少哪个就是把"安全"修成了"坏功能"。
 * PATH / TMPDIR / LD_LIBRARY_PATH 不靠这里兜 —— prelude 自己会 export
 * （见 buildPreludeBase），所以不必继承。
 *
 * 覆盖方式：`DSH_ANDROID_ENV_PASSTHROUGH`
 *   * 不设（默认）  → 用上面那张内置白名单
 *   * `none`        → 什么都不继承，只用调用方显式给的那份 env
 *   * `all` / `*`   → 全量继承（**仅调试用**，等于回到不安全的老行为）
 *   * `AGNES_,FOO_` → 只继承这些前缀（逗号分隔）
 */
// ⚠️ 2026-10-10：去掉了 `DSH_DEVICE_` —— 「打开本机应用」已按用户要求取消，
// 那条设备通道（device_bridge）连同它的 baseUrl / token 环境变量一起删了，
// 留着这个前缀只会让白名单多一条没有用途的口子。
const DEFAULT_ENV_PASSTHROUGH = ['DSH_ANDROID_', 'AGNES_', 'LOCAL_'];

function parentEnvBase() {
  const mode = String(process.env.DSH_ANDROID_ENV_PASSTHROUGH || '').trim();
  const out = {};
  if (mode.toLowerCase() === 'none') return out;
  if (mode === 'all' || mode === '*') {
    for (const [k, v] of Object.entries(process.env)) {
      if (v !== undefined) out[k] = v;
    }
    return out;
  }
  const prefixes = mode
    ? mode.split(',').map((s) => s.trim()).filter(Boolean)
    : DEFAULT_ENV_PASSTHROUGH;
  for (const [k, v] of Object.entries(process.env)) {
    if (v === undefined) continue;
    if (prefixes.some((p) => k.startsWith(p))) out[k] = v;
  }
  return out;
}

/**
 * 把 env / LD_LIBRARY_PATH 合进 options，返回**新的** options 对象（绝不改调用方的）。
 *
 * env = { ...process.env（继承父环境）, ...options.env（调用方显式给的优先）, ...本 shim 的补丁 }
 */
function mergeEnv(opts, r) {
  if (!r || (!r.env && !r.ldPathDir)) return opts;
  const explicit = opts && typeof opts.env === 'object' && opts.env ? opts.env : {};
  const env = Object.assign({}, parentEnvBase(), explicit, r.env || {});
  if (r.ldPathDir) {
    const cur = env.LD_LIBRARY_PATH ? String(env.LD_LIBRARY_PATH) : '';
    const parts = cur ? cur.split(':') : [];
    env.LD_LIBRARY_PATH = parts.indexOf(r.ldPathDir) === -1
      ? (cur ? r.ldPathDir + ':' + cur : r.ldPathDir)
      : cur;
  }
  return Object.assign({}, opts, { env });
}

// ─────────────────────────────────────────────────────────── 安装

/** spawn / spawnSync / execFile / execFileSync：签名都是 (command[, args][, options])。 */
function makeArgWrapper(original, name) {
  return function shimWrapper(...args) {
    try {
      const command = args[0];
      const hasArgv = Array.isArray(args[1]);
      const argv = hasArgv ? args[1] : [];
      let opts = hasArgv ? args[2] : args[1];
      if (opts === undefined || opts === null) opts = {};
      if (typeof opts === 'function') opts = {}; // execFile(file, cb)

      const r = rewriteCommand(command, argv, opts);
      if (!r) return original.apply(this, args); // 透传（保持原始参数与重载语义）

      const next = args.slice();
      next[0] = r.command;
      if (hasArgv) {
        next[1] = r.args;
        next[2] = mergeEnv(opts, r);
      } else {
        next[1] = mergeEnv(opts, r);
      }
      if (DEBUG) debug(name + ': ' + JSON.stringify(String(command)) + ' → ' + JSON.stringify(r.command));
      return original.apply(this, next);
    } catch (err) {
      warn(name + ' 改写失败，退回透传：' + (err && err.message ? err.message : String(err)));
      return original.apply(this, args);
    }
  };
}

/**
 * exec / execSync：`(command[, options][, callback])`。
 * exec 本来就是"交给 shell -c 执行"，所以永远要换 shell 到 /system/bin/sh
 * 并注入 prelude —— 即使命令里有 `/`（Android 没有 /bin/echo 这种东西）。
 */
function makeShellWrapper(original, name) {
  return function shimWrapper(...args) {
    try {
      const command = args[0];
      if (typeof command !== 'string' || command === '') return original.apply(this, args);

      let opts = {};
      let callback = null;
      for (let i = 1; i < args.length; i += 1) {
        const a = args[i];
        if (typeof a === 'function') callback = a;
        else if (a && typeof a === 'object') opts = a;
      }

      const r = rewriteCommand(command, [], Object.assign({}, opts, { shell: true }));
      if (!r) return original.apply(this, args);

      const merged = mergeEnv(opts, r);
      // 规范化成 (command, options[, callback])：callback 必须在 options 之后
      const next = callback ? [r.command, merged, callback] : [r.command, merged];
      if (DEBUG) debug(name + ': 注入 prelude + shell=' + SH);
      return original.apply(this, next);
    } catch (err) {
      warn(name + ' 改写失败，退回透传：' + (err && err.message ? err.message : String(err)));
      return original.apply(this, args);
    }
  };
}

function install() {
  const cp = require('node:child_process');
  if (process.__DSH_ANDROID_EXEC_SHIM_INSTALLED__) {
    debug('已经装过，跳过（避免重复包裹）');
    return;
  }
  process.__DSH_ANDROID_EXEC_SHIM_INSTALLED__ = true;

  // 先抓原始函数：包装里调用 original（不是 cp.xxx），避免自我递归
  const originals = {
    spawn: cp.spawn,
    spawnSync: cp.spawnSync,
    execFile: cp.execFile,
    execFileSync: cp.execFileSync,
    exec: cp.exec,
    execSync: cp.execSync,
  };

  cp.spawn = makeArgWrapper(originals.spawn, 'spawn');
  cp.spawnSync = makeArgWrapper(originals.spawnSync, 'spawnSync');
  cp.execFile = makeArgWrapper(originals.execFile, 'execFile');
  cp.execFileSync = makeArgWrapper(originals.execFileSync, 'execFileSync');
  cp.exec = makeShellWrapper(originals.exec, 'exec');
  cp.execSync = makeShellWrapper(originals.execSync, 'execSync'); // 顺带覆盖：exec 的同步版同样走 /bin/sh

  debug('已接管 child_process：' + Object.keys(originals).join(', '));
}

if (ACTIVE) {
  install();
  debug('启用：node=' + CFG.nodeBin + ' tmp=' + CFG.tmpDir);
} else {
  debug('未启用（缺环境变量：' + MISSING.join(', ') + '），child_process 保持原样');
}

// 仅供测试/排查用：可以直接 require 本文件拿到纯函数，
// 不需要在真实 Android 环境里跑（预加载时用不到这些导出）。
module.exports = {
  rewriteCommand,
  buildPrelude: buildPreludeBase,
  prelude,
  mergeEnv,
  parentEnvBase,
  DEFAULT_ENV_PASSTHROUGH,
  isActive: () => ACTIVE,
  missingEnv: () => MISSING.slice(),
};
