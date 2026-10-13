#!/usr/bin/env node
'use strict';
/**
 * edit-image.mjs —— 本机**修图**：一键美化（调色/锐化/磨皮/暗角）+ 去水印（盖住）。
 *
 * ## 先说清楚"修图"能做到什么、做不到什么（界面上也必须这么说）
 *
 * 这一版用的是**随包的 ffmpeg 滤镜**，全都跑在本机、不联网、不花额度：
 *   * **一键美化**：`eq`（亮度/对比/饱和/伽马）、`unsharp`（锐化）、`smartblur`（磨皮近似）、
 *     `colorbalance`（暖/冷调）、`vignette`（暗角）。
 *   * **去水印 / 去杂物**：`delogo` —— 用**周围像素插值把框内盖住**。
 *     ⚠️ 它是"盖住/糊掉"，**不是恢复**：纯色或平滑背景效果不错，**复杂纹理背景会看出痕迹**。
 *   * ❌ **做不到**：真·恢复被水印盖住的内容（那需要图像修复模型）、瘦脸大眼换脸（需要人脸关键点）、
 *     商业级磨皮（保留五官纹理）。**不要**在任何地方暗示能做这些。
 *   * ⚠️ 法律提醒（只提示，判断在用户）：去掉**别人版权作品**上的水印有侵权风险，尤其发布/商用时。
 *
 * ## 为什么不用 Agnes 的图生图去水印
 *
 * 那条路是"让模型重画一版"：它会**连别处一起改**，而且它根本不知道水印下面原本是什么
 * —— 结果是"水印没了、但整张图也变了"。要"只动那一小块"，只能靠本机滤镜。
 * 反过来说：要"重画/换风格/多图合成"，用 `make-image.mjs --ref`（图生图），不要用这个脚本。
 *
 * ## 用法
 *
 *   node edit-image.mjs <源图> <输出图> [选项]
 *   node edit-image.mjs --help
 *
 *   --preset <none|fresh|cinema|skin|warm|cool>  美化档位，默认 fresh
 *   --strength <1-100>        强度，默认 60（档位与强度共同决定滤镜参数）
 *   --delogo <x:y:w:h>        去水印框（**像素**坐标；App 侧按预览框算好再传，见下）
 *   --box <br|bl|tr|tl|bottom>   去水印框的快捷位置（命令行方便用；与 --box-width/--box-height 配合）
 *   --box-width <5-40>        框宽占画面宽度的百分比，默认 18
 *   --box-height <3-40>       框高占画面高度的百分比，默认 8
 *   --ffmpeg <path> / --ffprobe <path>
 *
 * ⚠️ **框的位置/大小只有一套算法**：App 的预览框与这里必须一致 ——
 *    所以 App 用 `--delogo x:y:w:h`（自己算好，见 media_page.dart 的 `_editBox()`）；
 *    `--box` 只是给命令行/测试用的便捷写法，两份算法在测试里对照。
 *
 * 环境变量（与 make-narration.mjs 同一套）：
 *   DSH_ANDROID_FFMPEG / AGNES_FFMPEG    随包的 ffmpeg（App 里由运行时注入）
 *   DSH_ANDROID_FFPROBE / AGNES_FFPROBE  随包的 ffprobe（用来读画面尺寸）
 *   都没有时用 PATH 里的 ffmpeg/ffprobe（电脑上调试/测试走这条）。
 *
 * 输出约定（Dart 侧按这一行判断成功，**格式不要改**）：
 *   `[edit-image] ok file=<绝对路径> bytes=<字节数> ops=<做了什么>`
 *
 * 诚实约束：
 *   * 滤镜缺失（自定义构建可能被裁）时**直接报错**，不偷偷降级成"看着差不多"的图；
 *   * ffmpeg 的报错原样带出来（最后几行），不吞。
 *
 * 退出码：0 成功；1 处理失败；2 参数/环境错误。
 */

import { spawn } from 'node:child_process';
import { existsSync, statSync } from 'node:fs';
import { resolve } from 'node:path';

const DEFAULT_PRESET = 'fresh';
const DEFAULT_STRENGTH = 60;
const DEFAULT_BOX_WIDTH = 18;
const DEFAULT_BOX_HEIGHT = 8;
const PRESETS = ['none', 'fresh', 'cinema', 'skin', 'warm', 'cool'];
const POSITIONS = ['br', 'bl', 'tr', 'tl', 'bottom'];

// ─────────────────────────────────────────────────────────── 输出与退出

function out(line) {
  process.stdout.write(line.endsWith('\n') ? line : line + '\n');
}
function err(line) {
  process.stderr.write(line.endsWith('\n') ? line : line + '\n');
}
/** 参数/环境错误：退出码 2，文案以「错误：」开头（Dart 侧按这个前缀取给用户看的原因）。 */
function fail(msg, code = 1) {
  err(`错误：${msg}`);
  process.exit(code);
}

function usage() {
  out(`用法：node edit-image.mjs <源图> <输出图> [选项]

选项：
  --preset <${PRESETS.join('|')}>   美化档位，默认 ${DEFAULT_PRESET}
  --strength <1-100>                强度，默认 ${DEFAULT_STRENGTH}
  --delogo <x:y:w:h>                去水印框（像素坐标）
  --box <${POSITIONS.join('|')}>    去水印框快捷位置（配 --box-width/--box-height）
  --box-width <5-40>                框宽占画面宽度百分比，默认 ${DEFAULT_BOX_WIDTH}
  --box-height <3-40>               框高占画面高度百分比，默认 ${DEFAULT_BOX_HEIGHT}
  --ffmpeg <path>  --ffprobe <path>
  --help

说明：美化靠本机滤镜（eq/unsharp/smartblur/colorbalance/vignette）；
      去水印靠 delogo **用周围像素盖住**，不是恢复原内容（复杂背景会留痕）。`);
  process.exit(0);
}

// ─────────────────────────────────────────────────────────── 参数

function parseArgs(argv) {
  const o = {
    source: null, output: null,
    preset: DEFAULT_PRESET, strength: DEFAULT_STRENGTH,
    delogo: null, box: null,
    boxWidth: DEFAULT_BOX_WIDTH, boxHeight: DEFAULT_BOX_HEIGHT,
    ffmpeg: '', ffprobe: '',
  };
  const rest = [];
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    const need = () => {
      const v = argv[++i];
      if (v === undefined) fail(`${a} 后面需要跟一个值`, 2);
      return v;
    };
    if (a === '--help' || a === '-h') usage();
    else if (a === '--preset') o.preset = need();
    else if (a === '--strength') o.strength = Number(need());
    else if (a === '--delogo') o.delogo = need();
    else if (a === '--box') o.box = need();
    else if (a === '--box-width') o.boxWidth = Number(need());
    else if (a === '--box-height') o.boxHeight = Number(need());
    else if (a === '--ffmpeg') o.ffmpeg = need();
    else if (a === '--ffprobe') o.ffprobe = need();
    else if (a.startsWith('--')) fail(`不认识的选项 ${a}（用 --help 看用法）`, 2);
    else rest.push(a);
  }
  [o.source, o.output] = rest;
  if (!o.source) fail('缺少源图路径（第一个参数）', 2);
  if (!o.output) fail('缺少输出图路径（第二个参数）', 2);
  o.source = resolve(o.source);
  o.output = resolve(o.output);
  if (!existsSync(o.source)) fail(`找不到源图：${o.source}`, 2);
  if (resolve(o.source) === resolve(o.output)) {
    fail('输出不能覆盖源图（修图要保留原图，免得改坏了没法回头）', 2);
  }
  if (!PRESETS.includes(o.preset)) {
    fail(`--preset 只能是 ${PRESETS.join(' / ')}，收到 ${JSON.stringify(o.preset)}`, 2);
  }
  if (!Number.isInteger(o.strength) || o.strength < 1 || o.strength > 100) {
    fail(`--strength 需要 1–100 的整数，收到 ${JSON.stringify(o.strength)}`, 2);
  }
  if (o.box && !POSITIONS.includes(o.box)) {
    fail(`--box 只能是 ${POSITIONS.join(' / ')}，收到 ${JSON.stringify(o.box)}`, 2);
  }
  for (const [k, v] of [['--box-width', o.boxWidth], ['--box-height', o.boxHeight]]) {
    if (!Number.isFinite(v) || v < 1 || v > 60) {
      fail(`${k} 需要 1–60（百分比），收到 ${JSON.stringify(v)}`, 2);
    }
  }
  if (o.delogo) parseDelogo(o.delogo); // 形状错误立刻报，别等到 ffmpeg
  if (o.preset === 'none' && !o.delogo && !o.box) {
    fail('既没美化（--preset none）也没去水印（--delogo/--box）—— 没有要做的事', 2);
  }
  return o;
}

/** `x:y:w:h` → {x,y,w,h}（四个都要是整数）。 */
function parseDelogo(spec) {
  const parts = String(spec).split(':').map((p) => p.trim());
  if (parts.length !== 4) fail(`--delogo 形状应为 x:y:w:h，收到 ${JSON.stringify(spec)}`, 2);
  const nums = parts.map((p) => Number(p));
  if (nums.some((n) => !Number.isFinite(n) || n < 0)) {
    fail(`--delogo 的四个值都要是非负数字，收到 ${JSON.stringify(spec)}`, 2);
  }
  return { x: nums[0], y: nums[1], w: nums[2], h: nums[3] };
}

// ─────────────────────────────────────────────────────────── 找 ffmpeg

function resolveBinary(explicit, envKeys, fallback, what) {
  // ⚠️ 与 make-narration.mjs 有一点**故意不同**：显式给的路径 / 环境变量指的路径
  //    **必须真的存在**，不存在就报错（而不是安静地回落到 PATH）。
  //    理由：手机上这两个值由 App 注入（`DSH_ANDROID_FFMPEG/FFPROBE` 指向
  //    `nativeLibraryDir/libffmpeg.so|libffprobe.so`）。一旦那个文件没了（打包漏了、
  //    被清理工具删了），"安静回落 PATH"在 Android 上**必然**失败，而且报的是
  //    "找不到 ffmpeg"这种看不出根因的话 —— 不如当场说清是哪个变量、哪个路径没了。
  if (explicit) {
    if (!existsSync(explicit)) fail(`--${what} 指的文件不存在：${explicit}`, 2);
    return explicit;
  }
  for (const k of envKeys) {
    const v = (process.env[k] || '').trim();
    if (!v) continue;
    if (!existsSync(v)) {
      fail(`环境变量 ${k} 指的 ${what} 不存在：${v} —— 随包的工具损坏或被删了`, 1);
    }
    return v;
  }
  return fallback; // 交给 PATH 解析（电脑上调试/测试走这条）
}

// ─────────────────────────────────────────────────────────── 跑子进程

function run(cmd, args, timeoutMs = 10 * 60 * 1000) {
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
      resolvePromise({ code: -1, stdout, stderr: `${stderr}\n${e.message}`, killed });
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      resolvePromise({ code, stdout, stderr, killed });
    });
  });
}

/** 把 ffmpeg 的报错压成一句人话（最后几行通常最有信息）。 */
function tail(text, lines = 4) {
  const all = String(text || '').split('\n').map((l) => l.trim()).filter((l) => l !== '');
  return all.slice(-lines).join(' / ').slice(0, 400);
}

// ─────────────────────────────────────────────────────────── 画面尺寸

async function probeSize(ffprobe, file) {
  const r = await run(ffprobe, [
    '-v', 'error',
    '-select_streams', 'v:0',
    '-show_entries', 'stream=width,height',
    '-of', 'csv=p=0:s=x',
    file,
  ], 60 * 1000);
  const m = /^(\d{2,5})x(\d{2,5})/.exec(String(r.stdout).trim());
  if (!m) {
    fail(`读不出画面尺寸（ffprobe 退出码 ${r.code}）：${tail(r.stderr) || '没有输出'}`, 1);
  }
  return { width: Number(m[1]), height: Number(m[2]) };
}

// ─────────────────────────────────────────────────────────── 滤镜

/** 数字进滤镜串：去掉多余的 0，避免出现 1.0000000000000002 这种噪声。 */
function f(n) {
  const v = Math.round(n * 1000) / 1000;
  return String(v);
}

/**
 * 档位 + 强度 → 滤镜串数组。
 * 强度 t = 0..1（strength/100），**每个档位的参数都随 t 线性变化** —— 所以滑杆是有意义的，
 * 不是"画着好看"。
 */
function presetFilters(preset, strength) {
  const t = Math.max(0.01, Math.min(1, strength / 100));
  switch (preset) {
    case 'none':
      return [];
    case 'fresh': // 通透：微提亮 + 提对比 + 提饱和 + 轻锐化（手机上最常见的"看着更清楚"）
      return [
        `eq=brightness=${f(0.02 * t)}:contrast=${f(1 + 0.14 * t)}:saturation=${f(1 + 0.16 * t)}`,
        `unsharp=5:5:${f(0.2 + 0.5 * t)}:5:5:0`,
      ];
    case 'cinema': // 电影感：提对比、降饱和、略降伽马、加暗角
      return [
        `eq=contrast=${f(1 + 0.22 * t)}:saturation=${f(1 - 0.14 * t)}:gamma=${f(1 - 0.05 * t)}`,
        `colorbalance=rs=${f(-0.03 * t)}:bs=${f(0.04 * t)}`,
        `vignette=a=${f((Math.PI / 5) * t)}`,
      ];
    case 'skin': // 人像：磨皮（smartblur 近似）+ 极轻锐化，不做"塑料脸"
      // ⚠️ smartblur 的参数范围是硬的：luma_radius 0.1–5、luma/chroma_strength 都是
      //    **[-1, 1]**（超了 ffmpeg 直接 "out of range" 报错）。所以这里全部夹在范围内。
      return [
        `smartblur=luma_radius=${f(0.6 + 2.6 * t)}:luma_strength=${f(0.4 + 0.6 * t)}:luma_threshold=0` +
          `:chroma_radius=0.6:chroma_strength=${f(0.2 + 0.4 * t)}:chroma_threshold=0`,
        `eq=brightness=${f(0.012 * t)}:contrast=${f(1 + 0.04 * t)}`,
        `unsharp=3:3:${f(0.15 * t)}:3:3:0`,
      ];
    case 'warm': // 暖调
      return [
        `colorbalance=rs=${f(0.16 * t)}:gs=${f(0.05 * t)}:bs=${f(-0.13 * t)}`,
        `eq=saturation=${f(1 + 0.06 * t)}:contrast=${f(1 + 0.04 * t)}`,
      ];
    case 'cool': // 冷调
      return [
        `colorbalance=rs=${f(-0.12 * t)}:bs=${f(0.16 * t)}`,
        `eq=saturation=${f(1 + 0.03 * t)}:contrast=${f(1 + 0.05 * t)}`,
      ];
    default:
      fail(`不认识的档位 ${JSON.stringify(preset)}`, 2);
      return [];
  }
}

/** 这些滤镜**必须**存在：自定义构建被裁过滤镜，缺了就要当场报错，不许偷偷降级。 */
function requiredFilters(preset, hasDelogo) {
  const need = new Set();
  if (hasDelogo) need.add('delogo');
  switch (preset) {
    case 'fresh': need.add('eq'); need.add('unsharp'); break;
    case 'cinema': need.add('eq'); need.add('colorbalance'); need.add('vignette'); break;
    case 'skin': need.add('smartblur'); need.add('eq'); need.add('unsharp'); break;
    case 'warm':
    case 'cool': need.add('colorbalance'); need.add('eq'); break;
    default: break;
  }
  return [...need];
}

async function assertFilters(ffmpeg, names) {
  if (names.length === 0) return;
  const r = await run(ffmpeg, ['-hide_banner', '-filters'], 60 * 1000);
  if (r.code !== 0) {
    fail(`读不到 ffmpeg 的滤镜表（退出码 ${r.code}）：${tail(r.stderr)}`, 2);
  }
  const text = String(r.stdout);
  const missing = names.filter((n) => !new RegExp(`^\\s*[A-Z.]+\\s+${n}\\s`, 'm').test(text));
  if (missing.length > 0) {
    fail(`随包的 ffmpeg 里没有这些滤镜：${missing.join(' / ')}` +
      ` —— 这个构建被裁过滤镜，这一档做不了（如实报出来，不降级糊弄）。`, 2);
  }
}

// ─────────────────────────────────────────────────────────── 去水印框

/**
 * 位置 + 尺寸（占画面百分比）→ 像素框。
 * ⚠️ 这套算法与 App 侧预览框**必须一致**（改了一边就要改另一边）：
 *    边距取短边的 2%，右下角对齐时留边距。
 */
function boxFromPosition(pos, W, H, wPct, hPct) {
  const w = Math.max(8, Math.round((W * wPct) / 100));
  const h = Math.max(6, Math.round((H * hPct) / 100));
  const m = Math.max(2, Math.round(Math.min(W, H) * 0.02));
  switch (pos) {
    case 'br': return { x: W - w - m, y: H - h - m, w, h };
    case 'bl': return { x: m, y: H - h - m, w, h };
    case 'tr': return { x: W - w - m, y: m, w, h };
    case 'tl': return { x: m, y: m, w, h };
    case 'bottom': return { x: m, y: H - h - m, w: W - 2 * m, h };
    default: fail(`不认识的 --box 位置 ${JSON.stringify(pos)}`, 2); return null;
  }
}

/**
 * 把框收进画面内（delogo 要求框完整落在画面里，碰边会直接报错）。
 * 返回 {x,y,w,h,warns}。
 */
function normalizeDelogo(box, W, H) {
  const warns = [];
  if (W < 8 || H < 8) {
    fail(`画面太小（${W}x${H}），放不下去水印框`, 2);
  }
  // 顺序很重要：**先定框的大小，再把框推进画面内**。
  // （反过来做会出现"x 顶到最右 → 宽度只剩 1 像素 → 报错"，而那本来是可以救的。）
  const maxW = W - 2; // 左右各留 1 像素：delogo 要求框完整落在画面里
  const maxH = H - 2;
  let w = Math.round(box.w);
  let h = Math.round(box.h);
  if (w < 4) { w = 4; warns.push('框宽至少 4 像素，已放大'); }
  if (h < 4) { h = 4; warns.push('框高至少 4 像素，已放大'); }
  if (w > maxW) { w = maxW; warns.push('框太宽，宽度已收到画面内'); }
  if (h > maxH) { h = maxH; warns.push('框太高，高度已收到画面内'); }
  let x = Math.round(box.x);
  let y = Math.round(box.y);
  if (x < 1) { x = 1; warns.push('框太靠左，已推进画面内'); }
  if (y < 1) { y = 1; warns.push('框太靠上，已推进画面内'); }
  if (x > W - 1 - w) { x = W - 1 - w; warns.push('框太靠右，已往左收回画面内'); }
  if (y > H - 1 - h) { y = H - 1 - h; warns.push('框太靠下，已往上收回画面内'); }
  if (w < 4 || h < 4) {
    fail(`去水印框放不下（画面 ${W}x${H}，算出来的框 ${x},${y} ${w}x${h}）—— 把框调小一点。`, 2);
  }
  if ((w * h) / (W * H) > 0.5) {
    warns.push('这个框盖住了半张图以上，效果会很糊 —— 建议框小一点');
  }
  return { x, y, w, h, warns };
}

// ─────────────────────────────────────────────────────────── 主流程

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const ffmpeg = resolveBinary(args.ffmpeg, ['DSH_ANDROID_FFMPEG', 'AGNES_FFMPEG'], 'ffmpeg', 'ffmpeg');
  const ffprobe = resolveBinary(args.ffprobe, ['DSH_ANDROID_FFPROBE', 'AGNES_FFPROBE'], 'ffprobe', 'ffprobe');

  const { width: W, height: H } = await probeSize(ffprobe, args.source);

  let delogo = null;
  if (args.delogo || args.box) {
    const raw = args.delogo
      ? parseDelogo(args.delogo)
      : boxFromPosition(args.box, W, H, args.boxWidth, args.boxHeight);
    const norm = normalizeDelogo(raw, W, H);
    for (const w of norm.warns) out(`[edit-image] 提示：${w}`);
    delogo = norm;
  }

  const need = requiredFilters(args.preset, delogo != null);
  await assertFilters(ffmpeg, need);

  const chain = presetFilters(args.preset, args.strength);
  if (delogo) chain.push(`delogo=x=${delogo.x}:y=${delogo.y}:w=${delogo.w}:h=${delogo.h}`);
  if (chain.length === 0) fail('没有任何要做的处理', 2);

  const ops = [
    args.preset === 'none' ? '不美化' : `美化:${args.preset}(${args.strength})`,
    delogo ? `去水印:${delogo.x},${delogo.y},${delogo.w}x${delogo.h}` : '',
  ].filter(Boolean).join('+');

  out(`[edit-image] ${W}x${H} → 滤镜链：${chain.join(',')}`);
  if (delogo) {
    out('[edit-image] 说明：去水印是**用周围像素把框内盖住**，不是恢复原内容；' +
      '纯色/平滑背景效果好，复杂纹理背景会看出痕迹。');
  }

  const r = await run(ffmpeg, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-i', args.source,
    '-vf', chain.join(','),
    '-frames:v', '1',
    // 图片输出用 image2 封装：单帧写盘要 -update 1（否则多帧序列会报"文件名要带序号"）。
    '-update', '1',
    args.output,
  ]);
  if (r.code !== 0) {
    fail(`修图失败（ffmpeg 退出码 ${r.code}）${r.killed ? '（超时被杀）' : ''}：${tail(r.stderr)}`, 1);
  }
  if (!existsSync(args.output)) {
    fail('ffmpeg 说成功了，但输出文件不存在 —— 不给你一个假路径', 1);
  }
  const bytes = statSync(args.output).size;
  if (bytes <= 0) fail(`输出文件是空的（${bytes} 字节）`, 1);

  // ⚠ 这一行是 Dart 侧识别的成功标记，格式不要改。
  out(`[edit-image] ok file=${args.output} bytes=${bytes} ops=${ops}`);
}

main().catch((e) => fail(`未预料的异常：${e && e.stack ? e.stack : e}`, 1));
