// edit-image.mjs 的**真功能测试**（本机修图：美化 + 去水印）。
//
// ## 为什么这一条能"真跑"
//
// 这个脚本调的是 **ffmpeg CLI**，而电脑上本来就有 `/usr/bin/ffmpeg` ——
// 所以把 `DSH_ANDROID_FFMPEG` 指向它，就能在本机**真的改一张图**，再用 ffprobe /
// signalstats 量出来"到底改了没有"。这比"断言滤镜串拼得对不对"强得多。
//
// ⚠️ 它**证明不了**的：手机上用的是我们自己编的 Android arm64 ffmpeg，
// 滤镜集合可能与 Debian 版不同 —— 脚本因此在运行时会用 `ffmpeg -filters`
// **自检必需滤镜**，缺了就当场报错（不降级糊弄）。本机这条链路验的是脚本逻辑本身。
//
// 用法：node install/test-edit-image.mjs
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = fileURLToPath(new URL('.', import.meta.url));
const REPO = join(HERE, '..');
const SCRIPT = join(REPO, 'app', 'assets', 'toolbox', 'edit-image.mjs');

let passed = 0;
const failures = [];

function test(name, fn) {
  try {
    fn();
    passed += 1;
    console.log(`  ✓ ${name}`);
  } catch (e) {
    failures.push([name, e]);
    console.log(`  ✗ ${name}\n      ${e.message}`);
  }
}
function section(t) { console.log(`\n== ${t} ==`); }

function tool(name) {
  for (const p of [`/usr/bin/${name}`, `/usr/local/bin/${name}`]) {
    if (existsSync(p)) return p;
  }
  const which = spawnSync('sh', ['-c', `command -v ${name}`], { encoding: 'utf8' });
  const out = (which.stdout || '').trim();
  return out && existsSync(out) ? out : null;
}

const FFMPEG = tool('ffmpeg');
const FFPROBE = tool('ffprobe');
if (!FFMPEG || !FFPROBE) {
  console.log('本机没有 ffmpeg/ffprobe —— 跳过（这些用例需要一个真 ffmpeg CLI）');
  process.exit(0);
}

const work = mkdtempSync(join(tmpdir(), 'edit-image-test-'));
process.on('exit', () => { try { rmSync(work, { recursive: true, force: true }); } catch {} });

/** 造素材：320x240 的中灰底；可选在右下角画一个白块（当作"水印"）。 */
function makeSource(path, withMark) {
  const draw = withMark
    ? ',drawbox=x=251:y=211:w=64:h=24:color=white@1.0:t=fill'
    : '';
  const r = spawnSync(FFMPEG, [
    '-v', 'error', '-f', 'lavfi',
    '-i', `color=c=0x404040:s=320x240:d=1${draw}`,
    '-frames:v', '1', path, '-y',
  ], { encoding: 'utf8' });
  assert.equal(r.status, 0, `造图失败：${r.stderr}`);
}

function runScript(args, env = {}) {
  const r = spawnSync(process.execPath, [SCRIPT, ...args], {
    encoding: 'utf8',
    env: { ...process.env, DSH_ANDROID_FFMPEG: FFMPEG, DSH_ANDROID_FFPROBE: FFPROBE, ...env },
    timeout: 300_000,
  });
  return { code: r.status, out: r.stdout || '', err: r.stderr || '' };
}

/** 一块区域的**亮度均值**（signalstats 的 YAVG）—— 用它量"到底改没改"。 */
function yavg(file, crop) {
  const vf = `${crop ? `crop=${crop.w}:${crop.h}:${crop.x}:${crop.y},` : ''}` +
    'signalstats,metadata=print:file=-';
  const r = spawnSync(FFMPEG, ['-v', 'error', '-i', file, '-vf', vf, '-f', 'null', '-'],
    { encoding: 'utf8' });
  const m = /lavfi\.signalstats\.YAVG=([\d.]+)/.exec(`${r.stdout}${r.stderr}`);
  assert.ok(m, `读不到 YAVG：${r.stdout} ${r.stderr}`);
  return Number(m[1]);
}

function size(file) {
  const r = spawnSync(FFPROBE, ['-v', 'error', '-select_streams', 'v:0',
    '-show_entries', 'stream=width,height', '-of', 'csv=p=0:s=x', file], { encoding: 'utf8' });
  return (r.stdout || '').trim();
}

/** 两块图的 PSNR（average）。**完全一样时返回 Infinity** —— 用它量"到底改没改"。 */
function psnr(a, b) {
  const r = spawnSync(FFMPEG, ['-hide_banner', '-i', a, '-i', b, '-lavfi', 'psnr', '-f', 'null', '-'],
    { encoding: 'utf8' });
  const m = /average:([\d.]+|inf)/.exec(`${r.stdout}${r.stderr}`);
  assert.ok(m, `读不到 PSNR：${r.stdout} ${r.stderr}`);
  return m[1] === 'inf' ? Infinity : Number(m[1]);
}

// ─────────────────────────────────────────────────────────────────── 用例

section('edit-image：美化（真跑滤镜）');
{
  const src = join(work, 'gray.png');
  makeSource(src, false);
  const out60 = join(work, 'fresh60.png');
  const warm20 = join(work, 'warm20.png');
  const warm100 = join(work, 'warm100.png');

  test('美化真的改了像素（不是复制一份）：与源图的 PSNR 有限', () => {
    const r = runScript([src, out60, '--preset', 'fresh', '--strength', '60']);
    assert.equal(r.code, 0, `脚本失败：${r.err}`);
    assert.match(r.out, /\[edit-image\] ok file=.* bytes=\d+ ops=美化:fresh\(60\)/,
      `缺成功标记。stdout=${r.out}`);
    assert.ok(existsSync(out60), '应产出结果图');
    assert.ok(statSync(out60).size > 0, '结果图不该是空文件');
    assert.equal(size(out60), '320x240', '尺寸应保持不变');
    const p = psnr(src, out60);
    assert.ok(Number.isFinite(p), `应与源图不同（PSNR 有限），实际 ${p}`);
  });

  test('强度是有意义的：同档位不同强度 → 输出不同（不是摆设滑杆）', () => {
    for (const s of [20, 100]) {
      const out = s === 20 ? warm20 : warm100;
      const r = runScript([src, out, '--preset', 'warm', '--strength', String(s)]);
      assert.equal(r.code, 0, `warm@${s} 失败：${r.err}`);
    }
    const p = psnr(warm20, warm100);
    assert.ok(Number.isFinite(p), `强度不同就该产出不同，实际 PSNR=${p}（一样）`);
    assert.ok(p < 55, `强度差 5 倍时差异应明显（PSNR < 55），实际 ${p}`);
  });

  test('每个档位都能出图，且都真的改动了像素', () => {
    for (const preset of ['fresh', 'skin', 'cinema', 'warm', 'cool']) {
      const out = join(work, `${preset}.png`);
      const r = runScript([src, out, '--preset', preset, '--strength', '70']);
      assert.equal(r.code, 0, `${preset} 失败：${r.err}`);
      assert.ok(existsSync(out) && statSync(out).size > 0, `${preset} 没出图`);
      assert.equal(size(out), '320x240', `${preset} 改了尺寸？`);
      assert.ok(Number.isFinite(psnr(src, out)), `${preset} 等于没改（PSNR=inf）`);
    }
  });

  test('--preset none + 没去水印 → 退出码 2（没有要做的事，不许假装修了）', () => {
    const r = runScript([src, join(work, 'nope.png'), '--preset', 'none']);
    assert.equal(r.code, 2);
    assert.match(r.err, /错误：既没美化/);
  });
}

section('edit-image：去水印（delogo）');
{
  const marked = join(work, 'marked.png');
  makeSource(marked, true);
  const box = { x: 251, y: 211, w: 64, h: 24 };
  const markBefore = yavg(marked, box);
  const bg = yavg(marked, { x: 10, y: 10, w: 64, h: 24 });

  test('框内原本是白的（前提成立：白块 251,211 64x24）', () => {
    assert.ok(markBefore > 200, `白块亮度应很高，实际 ${markBefore}`);
    assert.ok(bg < 80, `背景应较暗，实际 ${bg}`);
  });

  test('delogo 之后那一块被"盖住"（亮度掉到背景附近）', () => {
    const out = join(work, 'delogo.png');
    const r = runScript([marked, out, '--preset', 'none', '--delogo', '251:211:64:24']);
    assert.equal(r.code, 0, `脚本失败：${r.err}`);
    assert.match(r.out, /\[edit-image\] 说明：去水印是/,
      '必须把"盖住≠恢复"说给用户（stdout 里要有这句）');
    assert.match(r.out, /\[edit-image\] ok .*ops=不美化\+去水印:251,211,64x24/,
      `缺成功标记。stdout=${r.out}`);
    const after = yavg(out, box);
    assert.ok(after < 120, `白块应被盖掉（<120），实际 ${after}（原 ${markBefore}）`);
    // 其余区域基本不动（只动那一小块 —— 这是本脚本与"用模型重画"的关键区别）
    assert.ok(Math.abs(yavg(out, { x: 10, y: 10, w: 64, h: 24 }) - bg) < 3,
      '框外区域不该被动到');
  });

  test('--box br 的框位置/尺寸与约定一致（App 预览框按同一套算法画）', () => {
    const out = join(work, 'box-br.png');
    const r = runScript([marked, out, '--preset', 'none',
      '--box', 'br', '--box-width', '20', '--box-height', '10']);
    assert.equal(r.code, 0, `脚本失败：${r.err}`);
    // 320x240：w=round(320*20%)=64，h=round(240*10%)=24，边距 m=round(240*2%)=5 →
    //   x=320-64-5=251，y=240-24-5=211
    assert.match(r.out, /去水印:251,211,64x24/,
      `框应与 App 预算的一致。stdout=${r.out}`);
  });

  test('框碰到画面边缘 → 收进画面内并给提示，而不是报错', () => {
    const out = join(work, 'edge.png');
    const r = runScript([marked, out, '--preset', 'none', '--delogo', '318:238:40:40']);
    assert.equal(r.code, 0, `贴边的框应被纠正后继续：${r.err}`);
    assert.match(r.out, /提示：/, '纠正过就要说出来（用户得知道框被挪了）');
    assert.ok(existsSync(out), '应产出结果图');
  });

  test('框大到离谱 → 也能出图，但会提示"效果会很糊"', () => {
    const out = join(work, 'huge.png');
    const r = runScript([marked, out, '--preset', 'none', '--delogo', '20:20:250:200']);
    assert.equal(r.code, 0, `应出图：${r.err}`);
    assert.match(r.out, /盖住了半张图以上/, `应有提示。stdout=${r.out}`);
  });
}

section('edit-image：参数与环境错误（要能看懂、退出码要对）');
{
  const src = join(work, 'gray.png');

  test('缺源图路径 → 退出码 2', () => {
    const r = runScript([]);
    assert.equal(r.code, 2);
    assert.match(r.err, /错误：缺少源图路径/);
  });

  test('源图不存在 → 退出码 2，并给出路径', () => {
    const r = runScript([join(work, 'nope.png'), join(work, 'o.png')]);
    assert.equal(r.code, 2);
    assert.match(r.err, /错误：找不到源图/);
  });

  test('输出不能覆盖源图（免得改坏没得回头）', () => {
    const r = runScript([src, src, '--preset', 'fresh']);
    assert.equal(r.code, 2);
    assert.match(r.err, /错误：输出不能覆盖源图/);
  });

  test('档位写错 → 退出码 2 且列出可选值', () => {
    const r = runScript([src, join(work, 'o.png'), '--preset', 'x']);
    assert.equal(r.code, 2);
    assert.match(r.err, /--preset 只能是/);
  });

  test('强度越界 → 退出码 2', () => {
    const r = runScript([src, join(work, 'o.png'), '--strength', '0']);
    assert.equal(r.code, 2);
    assert.match(r.err, /--strength 需要 1–100/);
  });

  test('--delogo 形状不对 → 退出码 2', () => {
    const r = runScript([src, join(work, 'o.png'), '--preset', 'none', '--delogo', '1:2:3']);
    assert.equal(r.code, 2);
    assert.match(r.err, /--delogo 形状应为 x:y:w:h/);
  });

  test('注入的 ffprobe 路径不存在 → 明确说是哪个变量/哪条路径，而不是崩栈', () => {
    // 手机上 DSH_ANDROID_FFPROBE 指向 nativeLibraryDir/libffprobe.so；
    // 那个文件没了（打包漏了/被清理工具删了）必须当场说清，而不是"找不到 ffprobe"。
    const r = runScript([src, join(work, 'o.png'), '--preset', 'fresh'],
      { DSH_ANDROID_FFPROBE: '/nonexistent/ffprobe' });
    assert.equal(r.code, 1);
    assert.match(r.err, /错误：环境变量 DSH_ANDROID_FFPROBE 指的 ffprobe 不存在/);
  });

  test('--ffprobe 显式给错路径 → 退出码 2（参数错，不是环境坏）', () => {
    const r = runScript([src, join(work, 'o.png'), '--preset', 'fresh',
      '--ffprobe', '/nonexistent/ffprobe']);
    assert.equal(r.code, 2);
    assert.match(r.err, /错误：--ffprobe 指的文件不存在/);
  });

  test('--help 退出码 0', () => {
    const r = runScript(['--help']);
    assert.equal(r.code, 0);
    assert.match(r.out, /用法：node edit-image\.mjs/);
    assert.match(r.out, /不是恢复原内容/);
  });
}

// ─────────────────────────────────────────────────────────────────── 汇总

console.log(`\n${'='.repeat(60)}`);
if (failures.length === 0) {
  console.log(`全部通过（${passed} 项）—— 用本机真 ffmpeg 改的图，不是断言命令行`);
  process.exit(0);
}
console.log(`失败 ${failures.length} 项 / 通过 ${passed} 项`);
for (const [name] of failures) console.log(`  · ${name}`);
process.exit(1);
