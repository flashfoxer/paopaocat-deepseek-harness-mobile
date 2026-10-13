/**
 * clip-video.mjs —— 手机上最常用的那几刀：**剪一段 / 拼接 / 抽音频 / 抽一帧 / 压小**。
 *
 * ## 为什么要有它
 *
 * 「工作台 → 短剧 / 口播」是**生成**（把图片和配音合成一条片子），
 * 而这个脚本管的是**手上已经有视频之后**的活：剪掉一段、把几段拼起来、
 * 把声音抽出来、截一张封面、压小一点好发出去。
 * 这两件事在手机上经常同时需要，但以前只有前者。
 *
 * ## 为什么不用那种"多轨时间线剪辑器"
 *
 * 桌面上的开源剪辑器（如 OpenCut）是"任意多轨 + 实时预览"的形态：它需要一个
 * 真正的媒体内核（连 OpenCut 自己的重写版第一步也是**发一个 ffmpeg 二进制**，
 * 见其 `crates/media/setup/ffmpeg.json`）。手机上做那个形态，要么做不成、
 * 要么做成一个很差的仿制品。**所以这里只做"能真跑、能验证"的那几刀**：
 * 除 `compress` 与 `--exact` 外全部走 `-c copy`（不重编码），
 * 一段 10 分钟的视频剪一刀通常**几秒**就完事，也不掉画质。
 *
 * ## 用法
 *
 *   node clip-video.mjs probe    <in>
 *   node clip-video.mjs trim     <in> <out> --start 0:05 --end 1:20 [--exact]
 *   node clip-video.mjs concat   <out> <in1> <in2> [in3 ...] [--reencode]
 *   node clip-video.mjs audio    <in> <out.m4a|out.mp3>
 *   node clip-video.mjs frame    <in> <out.jpg|out.png> [--at 0:03]
 *   node clip-video.mjs compress <in> <out> [--max-width 1280] [--crf 28] [--preset veryfast]
 *
 * 通用选项：`--ffmpeg <path>` / `--ffprobe <path>`
 *
 * ffmpeg/ffprobe 从哪来（与 `make-narration.mjs` 同一套约定，两边必须一致）：
 *   1. `--ffmpeg` / `--ffprobe`；
 *   2. 环境变量 `DSH_ANDROID_FFMPEG` / `DSH_ANDROID_FFPROBE`（本 App 的约定）；
 *   3. 环境变量 `AGNES_FFMPEG` / `AGNES_FFPROBE`（桌面端影视工具插件认的名字）；
 *   4. PATH 里的 `ffmpeg` / `ffprobe`（在电脑上跑测试时走这条）。
 *
 * ## 三件**必须知道**的事
 *
 * 1. **`-c copy` 不重编码，所以剪的位置会对齐到最近的关键帧** —— 可能差零点几秒到
 *    一两秒。要精确到帧就加 `--exact`（重编码，手机上慢很多）。这条会如实写在
 *    App 界面上，不假装"剪得刚刚好"。
 * 2. **拼接时几段的参数不一致就不要硬拼** —— 检测到不一致会**直接报错**并让你加
 *    `--reencode`（先把每段统一成同一套参数，再拼）。硬拼出来的片子会出现
 *    画面错位/声音错位，而那是"看着像成功"的失败。
 * 3. **`.mp3` 不是所有 ffmpeg 构建都有编码器**（随包那套是精简构建）—— 所以先问
 *    一次 `ffmpeg -encoders`，没有就**明确报错并建议改用 `.m4a`**，而不是给一个
 *    悄悄失败或空文件。
 *
 * 退出码：0 成功；1 执行失败；2 参数或环境错误（含找不到 ffmpeg）。
 * 成功标记（**Dart 侧按它认结果，格式不要改**）：
 *   `[clip] ok file=<绝对路径> bytes=<字节数> seconds=<秒数> op=<操作>`
 *   ⚠️ `file=` 与 `bytes=` **必须紧跟 `ok `** —— `MediaService._run` 认的是这套
 *      与其它工具箱脚本（make-image / make-video / make-narration / edit-image）
 *      **同一个形状**的成功标记。
 */

import { execFile } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, extname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// ─────────────────────────────────────────────────────────── 输出

function info(message) {
  process.stderr.write(`[clip] ${message}\n`);
}

/** ⚠️ 错误一律写成 `错误：…` 走 stderr —— Dart 侧按这个前缀挑"给用户看的原因"。 */
function fail(message, code) {
  process.stderr.write('错误：' + message + '\n');
  process.exit(code === undefined ? 1 : code);
}

// ─────────────────────────────────────────────────────────── 参数

const argv = process.argv.slice(2);
const flags = new Map();
const positional = [];
for (let i = 0; i < argv.length; i += 1) {
  const a = argv[i];
  if (a.startsWith('--')) {
    const eq = a.indexOf('=');
    if (eq > 0) {
      flags.set(a.slice(2, eq), a.slice(eq + 1));
    } else {
      const next = argv[i + 1];
      if (next !== undefined && !next.startsWith('--')) {
        flags.set(a.slice(2), next);
        i += 1;
      } else {
        flags.set(a.slice(2), '1');
      }
    }
  } else {
    positional.push(a);
  }
}

const op = positional[0];
const VERSION_WANTED = ['probe', 'trim', 'concat', 'audio', 'frame', 'compress'];

// ─────────────────────────────────────────────────────────── ffmpeg 定位

function which(name) {
  const dirs = (process.env.PATH || '').split(':').filter(Boolean);
  for (const d of dirs) {
    const p = join(d, name);
    if (existsSync(p)) return p;
  }
  return '';
}

function locateFfmpeg() {
  const explicit = flags.get('ffmpeg');
  if (explicit) {
    if (!existsSync(explicit)) fail(`--ffmpeg 指的文件不存在：${explicit}`, 2);
    return explicit;
  }
  const env =
    process.env.DSH_ANDROID_FFMPEG || process.env.AGNES_FFMPEG || '';
  if (env && existsSync(env)) return env;
  const found = which('ffmpeg');
  if (found) return found;
  fail('找不到 ffmpeg。手机上是 App 随包的那一个（环境变量 DSH_ANDROID_FFMPEG）；电脑上请装 ffmpeg 或加 --ffmpeg <路径>', 2);
}

function locateFfprobe() {
  const explicit = flags.get('ffprobe');
  if (explicit) {
    if (!existsSync(explicit)) fail(`--ffprobe 指的文件不存在：${explicit}`, 2);
    return explicit;
  }
  const env =
    process.env.DSH_ANDROID_FFPROBE || process.env.AGNES_FFPROBE || '';
  if (env && existsSync(env)) return env;
  const found = which('ffprobe');
  if (found) return found;
  // 没有 ffprobe 也别立即死：`probe` 之外的操作里，ffprobe 只用来算时长/选缩放。
  return '';
}

const FFMPEG = op && VERSION_WANTED.includes(op) ? locateFfmpeg() : '';
const FFPROBE = op && VERSION_WANTED.includes(op) ? locateFfprobe() : '';

// ─────────────────────────────────────────────────────────── 小工具

function run(bin, args) {
  return new Promise((done) => {
    execFile(bin, args, { maxBuffer: 32 * 1024 * 1024 }, (err, stdout, stderr) => {
      done({ code: err ? (err.code ?? 1) : 0, stdout: String(stdout || ''), stderr: String(stderr || '') });
    });
  });
}

/**
 * 时间写法：`12` / `1:05` / `0:01:05.5`（秒/分:秒/时:分:秒）。认不出返回 null。
 * ⚠️ 故意**不**接受 `-5` 这种负数：那会变成"从结尾倒着数"，含义容易理解错，
 *    而我们没有把它写进任何界面文案 —— 宁可不支持，也不要默默按别的意思做。
 */
export function parseTime(input) {
  if (input === undefined || input === null) return null;
  const t = String(input).trim();
  if (t === '') return null;
  if (/^\d+(\.\d+)?$/.test(t)) return parseFloat(t);
  const parts = t.split(':');
  if (parts.length < 2 || parts.length > 3) return null;
  let seconds = 0;
  for (const p of parts) {
    if (!/^\d+(\.\d+)?$/.test(p)) return null;
    seconds = seconds * 60 + parseFloat(p);
  }
  return seconds;
}

/** 把秒写成人能读的 `1:05.3`（给日志用）。 */
function fmtTime(seconds) {
  if (!Number.isFinite(seconds)) return '?';
  const s = Math.max(0, seconds);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const rest = s % 60;
  const rs = rest.toFixed(1).padStart(4, '0');
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${rs}` : `${m}:${rs}`;
}

async function probe(file) {
  if (!existsSync(file)) fail(`输入文件不存在：${file}`, 2);
  if (!FFPROBE) fail('这一操作需要 ffprobe（用来读时长/分辨率），但没找到它', 2);
  const r = await run(FFPROBE, [
    '-v', 'error',
    '-print_format', 'json',
    '-show_format',
    '-show_streams',
    file,
  ]);
  if (r.code !== 0) fail(`读不出这个文件的媒体信息（ffprobe 说是）：${lastLines(r.stderr, 2)}`, 1);
  let json;
  try {
    json = JSON.parse(r.stdout);
  } catch {
    fail('ffprobe 的输出不是合法 JSON，读不出媒体信息', 1);
  }
  const streams = Array.isArray(json.streams) ? json.streams : [];
  const v = streams.find((s) => s.codec_type === 'video');
  const a = streams.find((s) => s.codec_type === 'audio');
  const duration = parseFloat((json.format && json.format.duration) || (v && v.duration) || '');
  return {
    file,
    duration: Number.isFinite(duration) ? duration : null,
    width: v ? Number(v.width) : null,
    height: v ? Number(v.height) : null,
    vcodec: v ? String(v.codec_name || '') : '',
    acodec: a ? String(a.codec_name || '') : '',
    hasAudio: Boolean(a),
    hasVideo: Boolean(v),
    fps: parseFps(v && v.r_frame_rate),
  };
}

function parseFps(rate) {
  if (!rate || typeof rate !== 'string') return null;
  const [n, d] = rate.split('/').map(Number);
  if (!Number.isFinite(n) || !Number.isFinite(d) || d === 0) return null;
  return n / d;
}

function lastLines(text, count) {
  const lines = String(text || '')
    .split('\n')
    .map((l) => l.trim())
    .filter(Boolean);
  return lines.slice(-count).join(' / ');
}

function ensureParent(file) {
  const dir = resolve(file, '..');
  if (!existsSync(dir)) fail(`输出目录不存在：${dir}`, 2);
}

function reportOk(result, opName, out) {
  const seconds = result && Number.isFinite(result.duration) ? result.duration.toFixed(3) : '0';
  const bytes = existsSync(out) ? statSync(out).size : 0;
  process.stdout.write(
    `[clip] ok file=${resolve(out)} bytes=${bytes} seconds=${seconds} op=${opName}\n`
  );
}

/** 输出文件必须**不**是输入文件本身（否则会把源文件剪坏）。 */
function refuseSameFile(inputs, out) {
  const o = resolve(out);
  for (const i of inputs) {
    if (resolve(i) === o) fail(`输出文件不能和输入文件是同一个（${o}）—— 请换个文件名`, 2);
  }
}

// ─────────────────────────────────────────────────────────── 编码器能力（缓存）

let encoderListCache = null;

async function hasEncoder(name) {
  if (encoderListCache === null) {
    const r = await run(FFMPEG, ['-hide_banner', '-loglevel', 'error', '-encoders']);
    encoderListCache = `${r.stdout}\n${r.stderr}`;
  }
  return new RegExp(`\\b${name}\\b`).test(encoderListCache);
}

// ─────────────────────────────────────────────────────────── 各操作

async function opProbe() {
  const input = positional[1];
  if (!input) fail('用法: probe <in>', 2);
  const p = await probe(input);
  process.stdout.write(
    `[clip] probe file=${resolve(input)} seconds=${p.duration ?? ''} width=${p.width ?? ''} height=${p.height ?? ''} ` +
      `vcodec=${p.vcodec} acodec=${p.acodec} has_audio=${p.hasAudio ? 1 : 0}\n`
  );
  process.stdout.write(
    `[clip] json=${JSON.stringify({ seconds: p.duration, width: p.width, height: p.height, vcodec: p.vcodec, acodec: p.acodec, hasAudio: p.hasAudio })}\n`
  );
}

async function opTrim() {
  const [input, out] = [positional[1], positional[2]];
  if (!input || !out) fail('用法: trim <in> <out> --start <时间> [--end <时间>] [--exact]', 2);
  refuseSameFile([input], out);
  if (!existsSync(input)) fail(`输入文件不存在：${input}`, 2);
  ensureParent(out);

  const start = parseTime(flags.get('start'));
  if (start === null) fail('--start 读不出来。写成 12（秒）、1:05（分:秒）或 0:01:05.5 都行', 2);
  const endRaw = flags.get('end');
  const end = endRaw === undefined ? null : parseTime(endRaw);
  if (endRaw !== undefined && end === null) fail('--end 读不出来。写成 12、1:05 或 0:01:05.5 都行', 2);
  if (end !== null && end <= start) fail(`--end（${fmtTime(end)}）必须大于 --start（${fmtTime(start)}）`, 2);

  const source = await probe(input);
  if (source.duration !== null && start >= source.duration) {
    fail(
      `--start（${fmtTime(start)}）已经超过了这段视频的长度（${fmtTime(source.duration)}）——` +
        '再剪下去是空的',
      2
    );
  }
  if (end !== null && source.duration !== null && end > source.duration + 0.5) {
    fail(
      `--end（${fmtTime(end)}）超过了这段视频的长度（${fmtTime(source.duration)}）`,
      2
    );
  }
  const exact = flags.has('exact');
  const duration = end !== null ? end - start : source.duration !== null ? Math.max(0, source.duration - start) : null;

  const args = ['-hide_banner', '-nostdin', '-loglevel', 'error', '-y'];
  // `-ss` 放在 `-i` **前面**：快（不用从头解），配 `-c copy` 时本来就只能落在关键帧上。
  args.push('-ss', String(start), '-i', input);
  if (duration !== null) args.push('-t', duration.toFixed(3));
  if (exact) {
    args.push('-c:v', 'libx264', '-crf', flags.get('crf') || '20', '-preset', 'veryfast', '-c:a', 'aac', '-b:a', '192k');
  } else {
    args.push('-c', 'copy');
    // ⚠️ 这里**不要**加 `-avoid_negative_ts make_zero`（本机实测踩过）：
    //    加了之后 `-t` 会失效 —— 请求"从 2 秒剪 2 秒"会输出**整整 4 秒的原片**
    //    （退出码 0、命令不报错，只有量产物才会发现）。去掉它，同一组参数
    //    实测就是准的 2.000 秒。
  }
  args.push('-movflags', '+faststart', out);

  const r = await run(FFMPEG, args);
  if (r.code !== 0 || !existsSync(out)) {
    fail(`剪这一刀失败了：${lastLines(r.stderr, 3) || 'ffmpeg 没有说明原因'}`, 1);
  }
  info(`剪好了：${fmtTime(start)} → ${duration === null ? '结尾' : fmtTime(start + duration)}${exact ? '（已重编码，帧级精确）' : '（未重编码，对齐到关键帧）'}`);
  reportOk(await probe(out), 'trim', out);
}

/** 拼接前先确认几段的参数真能直接拼（否则要用户明确同意重编码）。 */
function sameEnough(list) {
  const first = list[0];
  return list.every(
    (p) =>
      p.vcodec === first.vcodec &&
      p.width === first.width &&
      p.height === first.height &&
      p.acodec === first.acodec &&
      (p.fps === null || first.fps === null || Math.abs(p.fps - first.fps) < 0.1)
  );
}

function describe(p) {
  return `${basename(p.file)}（${p.width}x${p.height} ${p.vcodec}/${p.acodec || '无音轨'}）`;
}

async function opConcat() {
  const out = positional[1];
  const inputs = positional.slice(2);
  if (!out || inputs.length < 2) fail('用法: concat <out> <in1> <in2> [in3 ...] [--reencode]', 2);
  refuseSameFile(inputs, out);
  for (const i of inputs) if (!existsSync(i)) fail(`输入文件不存在：${i}`, 2);
  ensureParent(out);

  const probes = [];
  for (const i of inputs) probes.push(await probe(i));
  const noVideo = probes.find((p) => !p.hasVideo);
  if (noVideo) fail(`这一段里没有画面轨，拼不了：${describe(noVideo)}`, 2);

  const reencode = flags.has('reencode');
  // ⚠️ 参数不一致时**报错退出**，不擅自开始重编码：
  //    手机上重编码一段几分钟的视频要好几分钟，用户点一下却不知道为什么在等，
  //    比"多问一句"坏得多。界面那边有「参数不一致时重新编码」的勾选项，
  //    用户勾了才带 `--reencode` 过来。
  if (!reencode && !sameEnough(probes)) {
    const first = probes[0];
    const bad = probes.find(
      (p) =>
        p.vcodec !== first.vcodec ||
        p.width !== first.width ||
        p.height !== first.height ||
        p.acodec !== first.acodec
    );
    fail(
      `这几段的参数不一致（${describe(first)} 和 ${describe(bad)} 不是同一种画面/声音格式），` +
        '直接拼会出现画面错位或声音错位。确认它们本来就是同一次拍摄的，' +
        '或者加 --reencode 让工具先把每段统一成同一套参数再拼（要重编码，手机上会慢一些）',
      2
    );
  }

  const work = mkdtempSync(join(tmpdir(), 'dsh-clip-'));
  try {
    let parts = inputs;
    if (reencode) {
      // ⚠️ 统一到**第一段**的尺寸，不是每段自己的尺寸。
      //    各按各的归一化再拼，等于把"参数不一致"原样留在成品里（拼能拼上、
      //    画面尺寸中途变化，播放器表现五花八门）—— 那正是要避免的事。
      const w = (probes[0].width || 1280) % 2 === 0 ? probes[0].width || 1280 : (probes[0].width || 1280) + 1;
      const h = (probes[0].height || 720) % 2 === 0 ? probes[0].height || 720 : (probes[0].height || 720) + 1;
      info(`先把每段统一成 ${w}x${h} / 30fps / aac（这一步要重编码，手机上会慢一些）`);
      // 逐段归一化（分辨率/帧率/像素格式/取样率都统一），再按普通拼接把它们接起来。
      // 为什么要"先归一化、再 copy 拼接"而不是一条 `concat` 滤镜：
      // 后者对"某段没有音轨"这类情况会直接失败，而且一条命令里出错很难说清是哪一段。
      const normalized = [];
      for (let i = 0; i < probes.length; i += 1) {
        const p = probes[i];
        const target = join(work, `norm-${i}.mp4`);
        const args = [
          '-hide_banner', '-nostdin', '-loglevel', 'error', '-y',
          '-i', p.file,
        ];
        // ⚠️ 有声音轨就用**它自己的**，没有才补一路静音。
        //    一开始这里无条件 `-map 1:a:0` 接 anullsrc，等于把所有段的声音都换成静音 ——
        //    输出照样"成功"、照样能播，只是没声了（典型的"看着像成功"的失败）。
        if (p.hasAudio) {
          args.push('-map', '0:v:0', '-map', '0:a:0');
        } else {
          args.push('-f', 'lavfi', '-i', 'anullsrc=channel_layout=stereo:sample_rate=48000');
          args.push('-map', '0:v:0', '-map', '1:a:0', '-shortest');
        }
        args.push(
          // `setsar=1` 很重要 —— 不统一像素宽高比的话，拼出来会出现某一段被横向拉扁
          //（看着像"剪坏了"）。
          '-vf', `scale=${w}:${h}:force_original_aspect_ratio=decrease,pad=${w}:${h}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30`,
          '-c:v', 'libx264', '-crf', '20', '-preset', 'veryfast', '-pix_fmt', 'yuv420p',
          '-c:a', 'aac', '-b:a', '160k', '-ar', '48000', '-ac', '2',
          target
        );
        info(`统一第 ${i + 1}/${probes.length} 段：${describe(p)}`);
        const r = await run(FFMPEG, args);
        if (r.code !== 0 || !existsSync(target)) {
          fail(`第 ${i + 1} 段（${basename(p.file)}）统一参数时失败：${lastLines(r.stderr, 3)}`, 1);
        }
        normalized.push(target);
      }
      parts = normalized;
    }
    const listFile = writeConcatList(work, parts);
    const r = await run(FFMPEG, [
      '-hide_banner', '-nostdin', '-loglevel', 'error', '-y',
      '-f', 'concat', '-safe', '0', '-i', listFile,
      '-c', 'copy', '-movflags', '+faststart', out,
    ]);
    if (r.code !== 0 || !existsSync(out)) {
      fail(`拼接失败了：${lastLines(r.stderr, 3) || 'ffmpeg 没有说明原因'}`, 1);
    }
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
  info(`拼好了：${inputs.length} 段 → 一条`);
  reportOk(await probe(out), 'concat', out);
}

/**
 * 写 concat 用的清单文件，返回它的路径。
 * ⚠️ 路径里的单引号必须按 ffmpeg 的规则转义（`'` → `'\''`）——
 *    不转义的话文件名里带撇号就会**静默拼错或直接报错**。
 */
function writeConcatList(dir, files) {
  const lines = files.map((f) => `file '${resolve(f).replace(/'/g, "'\\''")}'`);
  const listFile = join(dir, 'list.txt');
  writeFileSync(listFile, lines.join('\n') + '\n', 'utf8');
  return listFile;
}

async function opAudio() {
  const [input, out] = [positional[1], positional[2]];
  if (!input || !out) fail('用法: audio <in> <out.m4a|out.mp3>', 2);
  refuseSameFile([input], out);
  if (!existsSync(input)) fail(`输入文件不存在：${input}`, 2);
  ensureParent(out);
  const p = await probe(input);
  if (!p.hasAudio) fail('这段视频里没有声音轨，抽不出音频', 2);

  const ext = extname(out).toLowerCase();
  const args = ['-hide_banner', '-nostdin', '-loglevel', 'error', '-y', '-i', input, '-vn'];
  if (ext === '.mp3') {
    if (!(await hasEncoder('libmp3lame'))) {
      fail(
        '这套 ffmpeg 里没有 mp3 编码器（随包的是精简构建），所以存不了 .mp3。' +
          '改成 .m4a（音质一样，安卓/苹果/电脑都能放）就能用',
        2
      );
    }
    args.push('-c:a', 'libmp3lame', '-q:a', '2');
  } else if (ext === '.m4a' || ext === '.aac' || ext === '.mp4') {
    args.push('-c:a', p.acodec === 'aac' ? 'copy' : 'aac', '-b:a', '192k');
    if (p.acodec !== 'aac') args.push('-movflags', '+faststart');
  } else if (ext === '.wav') {
    args.push('-c:a', 'pcm_s16le');
  } else {
    fail(`不确定 .${ext.replace('.', '')} 这种音频容器怎么写。用 .m4a（推荐）/ .mp3 / .wav`, 2);
  }
  args.push(out);

  const r = await run(FFMPEG, args);
  if (r.code !== 0 || !existsSync(out)) {
    fail(`抽音频失败了：${lastLines(r.stderr, 3) || 'ffmpeg 没有说明原因'}`, 1);
  }
  info(p.acodec === 'aac' && ext !== '.mp3' && ext !== '.wav' ? '声音是原样搬过去的（没有重新编码）' : '声音已重新编码');
  reportOk(await probe(out), 'audio', out);
}

async function opFrame() {
  const [input, out] = [positional[1], positional[2]];
  if (!input || !out) fail('用法: frame <in> <out.jpg|out.png> [--at 0:03]', 2);
  refuseSameFile([input], out);
  if (!existsSync(input)) fail(`输入文件不存在：${input}`, 2);
  ensureParent(out);

  const atRaw = flags.get('at');
  const at = atRaw === undefined ? 0 : parseTime(atRaw);
  if (at === null) fail('--at 读不出来。写成 3（秒）、0:03 或 0:00:03 都行', 2);

  const p = await probe(input);
  if (!p.hasVideo) fail('这个文件里没有画面轨，截不出图', 2);
  if (p.duration !== null && at > p.duration) {
    fail(`--at（${fmtTime(at)}）超过了这段视频的长度（${fmtTime(p.duration)}）`, 2);
  }

  const ext = extname(out).toLowerCase();
  const args = ['-hide_banner', '-nostdin', '-loglevel', 'error', '-y', '-ss', String(at), '-i', input, '-frames:v', '1'];
  if (ext === '.png') args.push('-c:v', 'png');
  else if (ext === '.jpg' || ext === '.jpeg') args.push('-q:v', '2');
  else fail(`截图的格式要写 .jpg 或 .png（给的是 ${ext || '没有扩展名'}）`, 2);
  args.push(out);

  const r = await run(FFMPEG, args);
  if (r.code !== 0 || !existsSync(out)) {
    fail(`截图失败了：${lastLines(r.stderr, 3) || 'ffmpeg 没有说明原因'}`, 1);
  }
  info(`截好了：第 ${fmtTime(at)} 那一帧`);
  reportOk({ duration: 0 }, 'frame', out);
}

async function opCompress() {
  const [input, out] = [positional[1], positional[2]];
  if (!input || !out) fail('用法: compress <in> <out> [--max-width 1280] [--crf 28]', 2);
  refuseSameFile([input], out);
  if (!existsSync(input)) fail(`输入文件不存在：${input}`, 2);
  ensureParent(out);

  const crf = Number(flags.get('crf') || 28);
  if (!Number.isFinite(crf) || crf < 0 || crf > 51) fail('--crf 要写 0~51 之间的数（越大越糊越小）', 2);
  const maxWidth = Number(flags.get('max-width') || 1280);
  if (!Number.isFinite(maxWidth) || maxWidth < 160) fail('--max-width 要写不小于 160 的数', 2);
  const preset = flags.get('preset') || 'veryfast';

  const p = await probe(input);
  if (!p.hasVideo) fail('这个文件里没有画面轨，压不了', 2);

  const before = statSync(input).size;
  const args = ['-hide_banner', '-nostdin', '-loglevel', 'error', '-y', '-i', input];
  const vf = [];
  // ⚠️ 只在**真的更宽**时才缩放：`scale=1280:-2` 会把小视频放大，越压越大。
  //    这里用 ffprobe 读到的真实宽度来判断，不用 ffmpeg 表达式（表达式里的逗号
  //    在 filter 语法里要转义，容易写错）。
  if (p.width !== null && p.width > maxWidth) {
    vf.push(`scale=${Math.round(maxWidth / 2) * 2}:-2`);
    info(`按宽度 ${maxWidth} 缩小（原来是 ${p.width}）`);
  } else {
    info(`原片宽度 ${p.width ?? '?'} 没超 ${maxWidth}，只降码率、不缩放`);
  }
  vf.push('format=yuv420p');
  args.push('-vf', vf.join(','));
  args.push('-c:v', 'libx264', '-crf', String(crf), '-preset', preset);
  if (p.hasAudio) {
    if (p.acodec === 'aac') args.push('-c:a', 'copy');
    else args.push('-c:a', 'aac', '-b:a', '128k');
  }
  args.push('-movflags', '+faststart', out);

  const r = await run(FFMPEG, args);
  if (r.code !== 0 || !existsSync(out)) {
    fail(`压小失败了：${lastLines(r.stderr, 3) || 'ffmpeg 没有说明原因'}`, 1);
  }
  const after = statSync(out).size;
  info(`压好了：${(before / 1048576).toFixed(1)} MB → ${(after / 1048576).toFixed(1)} MB`);
  reportOk(await probe(out), 'compress', out);
}

// ─────────────────────────────────────────────────────────── 入口

const OPS = {
  probe: opProbe,
  trim: opTrim,
  concat: opConcat,
  audio: opAudio,
  frame: opFrame,
  compress: opCompress,
};

async function main() {
  if (!op || op === 'help' || flags.has('help')) {
    process.stdout.write(
      '用法: node clip-video.mjs <probe|trim|concat|audio|frame|compress> ...\n' +
        '  probe    <in>\n' +
        '  trim     <in> <out> --start 0:05 [--end 1:20] [--exact]\n' +
        '  concat   <out> <in1> <in2> [in3 ...] [--reencode]\n' +
        '  audio    <in> <out.m4a|out.mp3|out.wav>\n' +
        '  frame    <in> <out.jpg|out.png> [--at 0:03]\n' +
        '  compress <in> <out> [--max-width 1280] [--crf 28]\n'
    );
    process.exit(op ? 0 : 2);
  }
  const fn = OPS[op];
  if (!fn) fail(`不认识的操作「${op}」。可用：${Object.keys(OPS).join(' / ')}`, 2);
  await fn();
}

// 只有**直接运行**时才执行（被 import 进来测试 `parseTime` 时不跑）。
if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  main().catch((err) => fail(`意外错误：${(err && err.message) || err}`, 1));
}

export { sameEnough, fmtTime };
