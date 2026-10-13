/**
 * make-narration.mjs —— 把「每镜一张图 + 一段配音」合成一条成片。
 *
 * 口播与短剧**共用**这一个脚本：
 *   · 口播：文稿自动切成若干段 → 每段一张带字幕的图 + 一段 TTS 配音 → 成片；
 *   · 短剧：分镜列表 → 每镜一张图（生成的或用户选的）+ 一句配音 → 成片。
 * 两者在这条链路上是同一件事，所以只写一份。
 *
 * 用法：
 *   node make-narration.mjs <spec.json> <out.mp4> [--fps 25] [--crf 20] [--preset veryfast]
 *
 * spec.json 的形状：
 *   {
 *     "size": "1080x1920",              // 可选，默认 1080x1920（竖屏）
 *     "fps": 25,                        // 可选，默认 25
 *     "shots": [
 *       { "image": "/abs/a.png", "audio": "/abs/a.wav" },   // audio 可省（静音镜）
 *       ...
 *     ]
 *   }
 *
 * ffmpeg 从哪来（按顺序）：
 *   1. `--ffmpeg <path>`；
 *   2. 环境变量 `DSH_ANDROID_FFMPEG`（本 App 的约定）；
 *   3. 环境变量 `AGNES_FFMPEG`（桌面端影视工具插件认的名字，两边对齐）；
 *   4. PATH 里的 `ffmpeg`（在电脑上跑测试/本机调试时走这条）。
 *
 * ⚠️ 两件**必须知道**的事（决定了这个脚本为什么长这样）：
 *
 * 1. **字幕由 App 侧画好，不在这里烧**。随包的 ffmpeg 构建里**没有**
 *    `subtitles` / `drawtext` / `ass` 滤镜（NDK 里没有 libass/freetype，编不进去）。
 *    所以调用方交给这里的 `image` 是**已经带字幕的图**（App 用 Flutter 绘制，
 *    用手机自带中文字体）。这个脚本只做「图+音频 → 段」「段 → 拼接」。
 *
 * 2. **手机很慢，所以要 `-preset veryfast`**：桌面端插件用 medium，手机上会等到怀疑人生。
 *    默认值就是 veryfast，想更清楚可以用 `--preset medium`（慢 3~5 倍）。
 *
 * 3. **每镜必须显式 `-t <配音时长>`，不能只靠 `-shortest`**（本机实测）：
 *    对"无限循环的图（`-loop 1`）+ 一段音频"，`-shortest` **不会**停在配音结尾 ——
 *    1.045 秒的配音会产出 **3.16 秒**的视频流（末尾是一段卡住的静帧，成片被拉长，
 *    后面拼接出来的字幕时间轴也跟着错）。加上 `-t 1.045` 后逐流都是 1.045 秒。
 *    所以这里**先用 ffprobe 探出每段配音的真实时长**再 -t —— 随包的 ffprobe
 *    就是这个用途（不是可选项）。
 *
 * 退出码：0 成功；1 合成失败；2 参数或环境错误（含找不到 ffmpeg）。
 * 成功标记（**Dart 侧按它认结果，格式不要改**）：
 *   `[narration] ok file=<绝对路径> bytes=<字节数> shots=<镜数>`
 */

import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const DEFAULT_SIZE = '1080x1920'; // 竖屏：短剧/口播的主场景
const DEFAULT_FPS = 25;

// ─────────────────────────────────────────────────────────── 输出

function info(message) {
  process.stderr.write(`[narration] ${message}\n`);
}

/** ⚠️ 错误一律写成 `错误：…` 走 stderr —— Dart 侧按这个前缀挑"给用户看的原因"。 */
function fail(message, code) {
  process.stderr.write('错误：' + message + '\n');
  process.exit(code === undefined ? 1 : code);
}

const HELP = `用法: node make-narration.mjs <spec.json> <out.mp4> [选项]

选项:
  --ffmpeg <path>   指定 ffmpeg（默认按 DSH_ANDROID_FFMPEG → AGNES_FFMPEG → PATH 找）
  --ffprobe <path>  指定 ffprobe（同上；用来探每段配音的真实时长，**不是可选项**）
  --fps <n>         帧率，默认 ${DEFAULT_FPS}
  --crf <n>         画质（越小越清晰越大），默认 20
  --preset <name>   编码预设，默认 veryfast（手机要快；medium 会慢 3~5 倍）
  --size <WxH>      覆盖 spec 里的画幅
  --keep            保留中间文件（排查用）

spec.json 形状见本文件顶部注释。
`;

// ─────────────────────────────────────────────────────────── 参数

function parseArgs(argv) {
  const out = {
    spec: '', output: '', ffmpeg: '', fps: DEFAULT_FPS, crf: 20,
    preset: 'veryfast', size: '', keep: false,
  };
  const rest = [];
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    const need = () => {
      const v = argv[++i];
      if (v === undefined) fail(`选项 ${a} 后面缺参数`, 2);
      return v;
    };
    if (a === '--help' || a === '-h') { process.stdout.write(HELP); process.exit(0); }
    else if (a === '--ffmpeg') out.ffmpeg = need();
    else if (a === '--ffprobe') out.ffprobe = need();
    else if (a === '--fps') out.fps = Number(need());
    else if (a === '--crf') out.crf = Number(need());
    else if (a === '--preset') out.preset = need();
    else if (a === '--size') out.size = need();
    else if (a === '--keep') out.keep = true;
    else if (a.startsWith('--')) fail(`不认识的选项：${a}`, 2);
    else rest.push(a);
  }
  [out.spec, out.output] = rest;
  if (!out.spec) fail('缺少 spec.json 路径（第一个参数）', 2);
  if (!out.output) fail('缺少输出文件路径（第二个参数）', 2);
  if (!Number.isInteger(out.fps) || out.fps < 1 || out.fps > 60) {
    fail(`--fps 需要 1–60 的整数，收到 ${JSON.stringify(out.fps)}`, 2);
  }
  if (!Number.isFinite(out.crf) || out.crf < 0 || out.crf > 51) {
    fail(`--crf 需要 0–51，收到 ${JSON.stringify(out.crf)}`, 2);
  }
  return out;
}

/** 找 ffmpeg：显式 → DSH_ANDROID_FFMPEG → AGNES_FFMPEG → PATH。 */
function resolveFfmpeg(explicit) {
  const candidates = [];
  if (explicit) candidates.push(explicit);
  for (const k of ['DSH_ANDROID_FFMPEG', 'AGNES_FFMPEG']) {
    const v = (process.env[k] || '').trim();
    if (v) candidates.push(v);
  }
  candidates.push('ffmpeg'); // 靠 PATH（电脑上调试/测试走的这条）
  for (const c of candidates) {
    if (c === 'ffmpeg') return c; // 交给系统解析，成败由实际调用报出来
    if (existsSync(c)) return c;
  }
  return 'ffmpeg';
}

/** 找 ffprobe：与 ffmpeg 同一套规则（显式 → DSH_ANDROID_* → AGNES_* → PATH）。 */
function resolveFfprobe(explicit) {
  const candidates = [];
  if (explicit) candidates.push(explicit);
  for (const k of ['DSH_ANDROID_FFPROBE', 'AGNES_FFPROBE']) {
    const v = (process.env[k] || '').trim();
    if (v) candidates.push(v);
  }
  candidates.push('ffprobe');
  for (const c of candidates) {
    if (c === 'ffprobe') return c;
    if (existsSync(c)) return c;
  }
  return 'ffprobe';
}

// ─────────────────────────────────────────────────────────── 跑 ffmpeg

function run(cmd, args, timeoutMs) {
  return new Promise((resolvePromise) => {
    const child = spawn(cmd, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    let killed = false;
    const timer = setTimeout(() => { killed = true; child.kill('SIGKILL'); }, timeoutMs);
    child.stdout.on('data', (d) => { stdout += d.toString(); });
    child.stderr.on('data', (d) => { stderr += d.toString(); });
    child.on('error', (e) => {
      clearTimeout(timer);
      resolvePromise({ code: -1, stdout, stderr: stderr + `\n${e.message}`, killed });
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      resolvePromise({ code, stdout, stderr, killed });
    });
  });
}

/** 把 ffmpeg 的报错压成一句人话（最后几行通常最有信息）。 */
function tail(text, lines = 4) {
  const all = text.split('\n').map((l) => l.trim()).filter((l) => l !== '');
  return all.slice(-lines).join(' / ').slice(0, 400);
}

// ─────────────────────────────────────────────────────────── 主流程

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const ffmpeg = resolveFfmpeg(args.ffmpeg);
  const ffprobe = resolveFfprobe(args.ffprobe);

  let spec;
  try {
    spec = JSON.parse(readFileSync(args.spec, 'utf8'));
  } catch (e) {
    fail(`读不了 spec.json：${e.message}`, 2);
  }
  const size = args.size || spec.size || DEFAULT_SIZE;
  if (!/^\d{2,5}x\d{2,5}$/.test(size)) fail(`画幅格式应为 宽x高，收到 ${JSON.stringify(size)}`, 2);
  const [width, height] = size.split('x');
  const fps = Number(spec.fps) || args.fps;

  const shots = Array.isArray(spec.shots) ? spec.shots : [];
  if (shots.length === 0) fail('spec.shots 是空的 —— 没有内容可合成', 2);
  shots.forEach((s, i) => {
    if (!s || typeof s.image !== 'string' || s.image.trim() === '') {
      fail(`第 ${i + 1} 镜缺 image`, 2);
    }
    if (!existsSync(s.image)) fail(`第 ${i + 1} 镜的图不存在：${s.image}`, 2);
    if (s.audio && !existsSync(s.audio)) fail(`第 ${i + 1} 镜的配音不存在：${s.audio}`, 2);
  });

  const dest = resolve(args.output);
  /** 探一段媒体文件的时长（秒）；探不到返回 null（调用方退回 -shortest 并如实说明）。 */
  async function probeSeconds(path) {
    const r = await run(ffprobe, [
      '-v', 'error', '-show_entries', 'format=duration',
      '-of', 'default=nw=1:nk=1', path,
    ], 60_000);
    if (r.code !== 0) return null;
    const v = Number(String(r.stdout).trim());
    return Number.isFinite(v) && v > 0 ? v : null;
  }

  const work = mkdtempSync(join(tmpdir(), 'narration-'));
  info(`开始合成：${shots.length} 镜 / ${size} / ${fps}fps / preset=${args.preset}`);

  try {
    const segments = [];
    for (let i = 0; i < shots.length; i += 1) {
      const shot = shots[i];
      const seg = join(work, `seg${String(i).padStart(3, '0')}.mp4`);
      // 每镜都**用同一套参数**编码：拼接阶段走 `-c copy`（不重编码），
      // 参数不一致会在拼接时报 "Stream ... parameters do not match"。
      const vf = `scale=${width}:${height}:force_original_aspect_ratio=decrease,`
        + `pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=${fps}`;
      const cmdArgs = ['-y', '-hide_banner', '-loglevel', 'error', '-loop', '1', '-i', shot.image];
      if (shot.audio) cmdArgs.push('-i', shot.audio);
      cmdArgs.push('-vf', vf, '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
        '-preset', args.preset, '-crf', String(args.crf));
      if (shot.audio) {
        cmdArgs.push('-c:a', 'aac', '-b:a', '128k');
        // ⚠️ 见文件顶部第 3 条：只靠 -shortest 会多出一大截卡住的画面。
        //    先探真实时长，显式 -t；探不到才退回 -shortest（并如实说）。
        const dur = await probeSeconds(shot.audio);
        if (dur !== null) {
          cmdArgs.push('-t', dur.toFixed(3));
        } else {
          info(`第 ${i + 1} 镜：探不到配音时长，退回 -shortest（成片末尾可能多出一小段静帧）`);
          cmdArgs.push('-shortest');
        }
      } else {
        // 没有配音的镜：用 spec.seconds 或默认 3 秒（否则 -loop 1 会无限长）
        const secs = Number(shot.seconds) > 0 ? Number(shot.seconds) : 3;
        cmdArgs.push('-t', String(secs), '-an');
      }
      cmdArgs.push(seg);
      info(`第 ${i + 1}/${shots.length} 镜：${shot.audio ? '图+配音' : `静音 ${shot.seconds || 3}s`}`);
      const r = await run(ffmpeg, cmdArgs, 30 * 60 * 1000);
      if (r.code !== 0) {
        fail(`第 ${i + 1} 镜编码失败（ffmpeg 退出码 ${r.code}）${r.killed ? '（超时被杀）' : ''}：${tail(r.stderr)}`, 1);
      }
      if (!existsSync(seg) || statSync(seg).size === 0) {
        fail(`第 ${i + 1} 镜没产出文件`, 1);
      }
      segments.push(seg);
    }

    // 拼接：concat demuxer + `-c copy`（同参数编码，所以能直接复用流，很快）
    const listFile = join(work, 'list.txt');
    writeFileSync(
      listFile,
      segments.map((p) => `file '${p.replace(/'/g, "'\\''")}'`).join('\n') + '\n',
      'utf8',
    );
    info('拼接中（不重编码）…');
    const cat = await run(ffmpeg, [
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'concat', '-safe', '0', '-i', listFile,
      '-c', 'copy', dest,
    ], 30 * 60 * 1000);
    if (cat.code !== 0) {
      fail(`拼接失败（ffmpeg 退出码 ${cat.code}）：${tail(cat.stderr)}`, 1);
    }
    if (!existsSync(dest) || statSync(dest).size === 0) fail('拼接后没有产出文件', 1);

    const bytes = statSync(dest).size;
    info(`完成：${dest}（${(bytes / 1048576).toFixed(2)} MB，${shots.length} 镜）`);
    // ⚠ 这一行是 Dart 侧识别的成功标记，格式不要改
    process.stdout.write(`[narration] ok file=${dest} bytes=${bytes} shots=${shots.length}\n`);
  } finally {
    if (args.keep) info(`中间文件保留在 ${work}`);
    else { try { rmSync(work, { recursive: true, force: true }); } catch { /* 清不掉就算了 */ } }
  }
}

main().catch((e) => fail(`未预期的错误：${(e && e.stack) || e}`, 1));
