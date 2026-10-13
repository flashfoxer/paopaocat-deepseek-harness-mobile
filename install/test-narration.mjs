// make-narration.mjs 的**真功能测试**（口播/短剧的合成器）。
//
// ## 为什么这一条能"真跑"
//
// 这个脚本调的是 **ffmpeg CLI**，而电脑上本来就有 `/usr/bin/ffmpeg` ——
// 所以把 `DSH_ANDROID_FFMPEG` 指向它，就能在本机**真的合成一条 mp4**，
// 再用 `ffprobe` 校验产物。这比"断言命令行拼得对不对"强得多：
// 它证明的是"这条链路真的能产出合法视频"。
//
// ⚠️ 有一点它**证明不了**：手机上的是我们自己编的 Android arm64 版，
// 而且那个构建里**没有** subtitles/drawtext/ass 滤镜（见 make-narration.mjs 顶部）。
// 所以字幕是 **App 侧画在图上**的，这个脚本只负责"图+音频→段→拼接"。
// 本机验证覆盖的正是它负责的那部分。
//
// 用法：node install/test-narration.mjs
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, mkdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = fileURLToPath(new URL('.', import.meta.url));
const REPO = join(HERE, '..');
const SCRIPT = join(REPO, 'app', 'assets', 'toolbox', 'make-narration.mjs');

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

/** 找本机 ffmpeg / ffprobe（找不到就整体跳过：这些用例需要一个真 ffmpeg）。 */
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

const work = mkdtempSync(join(tmpdir(), 'narration-test-'));
process.on('exit', () => { try { rmSync(work, { recursive: true, force: true }); } catch {} });

/** 用本机 ffmpeg 造素材：一张纯色图 / 一段正弦音。 */
function makeImage(path, color) {
  const r = spawnSync(FFMPEG, ['-v', 'error', '-f', 'lavfi', '-i', `color=c=${color}:s=320x240:d=1`,
    '-frames:v', '1', path, '-y'], { encoding: 'utf8' });
  assert.equal(r.status, 0, `造图失败：${r.stderr}`);
}
function makeAudio(path, freq, secs) {
  const r = spawnSync(FFMPEG, ['-v', 'error', '-f', 'lavfi', '-i', `sine=frequency=${freq}:duration=${secs}`,
    '-c:a', 'aac', path, '-y'], { encoding: 'utf8' });
  assert.equal(r.status, 0, `造音频失败：${r.stderr}`);
}

function runScript(args, env = {}) {
  const r = spawnSync(process.execPath, [SCRIPT, ...args], {
    encoding: 'utf8',
    env: { ...process.env, DSH_ANDROID_FFMPEG: FFMPEG, ...env },
    timeout: 300_000,
  });
  return { code: r.status, out: r.stdout || '', err: r.stderr || '' };
}

function probe(path) {
  const r = spawnSync(FFPROBE, ['-v', 'error', '-show_entries',
    'stream=codec_name,codec_type,width,height', '-show_entries', 'format=duration',
    '-of', 'default=nw=1', path], { encoding: 'utf8' });
  assert.equal(r.status, 0, `ffprobe 失败：${r.stderr}`);
  return r.stdout;
}

// ─────────────────────────────────────────────────────────────────── 用例

section('make-narration：真跑本机 ffmpeg 合成成片');
{
  const imgA = join(work, 'a.png');
  const imgB = join(work, 'b.png');
  const audA = join(work, 'a.aac');
  const audB = join(work, 'b.aac');
  makeImage(imgA, 'orange');
  makeImage(imgB, 'blue');
  makeAudio(audA, 440, 1);
  makeAudio(audB, 660, 1.5);

  test('两镜（各图+配音）→ 一条合法 mp4，时长≈两段之和', () => {
    const spec = join(work, 'spec2.json');
    writeFileSync(spec, JSON.stringify({
      size: '320x240',
      shots: [{ image: imgA, audio: audA }, { image: imgB, audio: audB }],
    }), 'utf8');
    const out = join(work, 'out2.mp4');
    const r = runScript([spec, out]);
    assert.equal(r.code, 0, `脚本失败：${r.err}`);
    // 成功标记是 Dart 侧认结果的约定
    assert.match(r.out, /\[narration\] ok file=.* bytes=\d+ shots=2/,
      `缺成功标记。stdout=${r.out}`);
    assert.ok(existsSync(out), '应该产出成片');
    assert.ok(statSync(out).size > 1000, '成片不该是空文件');

    const info = probe(out);
    assert.match(info, /codec_name=h264/, `视频流应为 h264：\n${info}`);
    assert.match(info, /codec_name=aac/, `音频流应为 aac：\n${info}`);
    assert.match(info, /width=320/, `画幅应为 320x240：\n${info}`);
    const dur = Number((/duration=([\d.]+)/.exec(info) || [])[1]);
    assert.ok(dur > 2.0 && dur < 3.2,
      `两段 1s + 1.5s 拼起来应约 2.5s，实际 ${dur}s`);
  });

  test('有的镜没配音 → 用 --seconds（或默认 3s）并且仍然拼得起来', () => {
    const spec = join(work, 'spec3.json');
    writeFileSync(spec, JSON.stringify({
      size: '320x240',
      shots: [
        { image: imgA, audio: audA },
        { image: imgB, seconds: 0.5 }, // 静音镜
      ],
    }), 'utf8');
    const out = join(work, 'out3.mp4');
    const r = runScript([spec, out]);
    assert.equal(r.code, 0, `脚本失败：${r.err}`);
    assert.ok(existsSync(out));
    const info = probe(out);
    assert.match(info, /codec_name=h264/);
    const dur = Number((/duration=([\d.]+)/.exec(info) || [])[1]);
    assert.ok(dur > 1.2 && dur < 2.2, `1s + 0.5s 应约 1.5s，实际 ${dur}s`);
  });

  test('画幅与 args 覆盖：--size 会覆盖 spec 里的值', () => {
    const spec = join(work, 'spec4.json');
    writeFileSync(spec, JSON.stringify({
      size: '320x240',
      shots: [{ image: imgA, audio: audA }],
    }), 'utf8');
    const out = join(work, 'out4.mp4');
    const r = runScript([spec, out, '--size', '160x120', '--fps', '15']);
    assert.equal(r.code, 0, `脚本失败：${r.err}`);
    const info = probe(out);
    assert.match(info, /width=160/, `应该用命令行给的画幅：\n${info}`);
  });
}

section('make-narration：错误路径（要说人话，且退出码可辨）');
{
  const img = join(work, 'a.png');
  const aud = join(work, 'a.aac');
  makeImage(img, 'orange');
  makeAudio(aud, 440, 0.5);

  test('shots 为空 → 退出码 2，说明"没有内容可合成"', () => {
    const spec = join(work, 'empty.json');
    writeFileSync(spec, JSON.stringify({ shots: [] }), 'utf8');
    const r = runScript([spec, join(work, 'x.mp4')]);
    assert.equal(r.code, 2);
    assert.match(r.err, /错误：.*没有内容可合成/);
  });

  test('图不存在 → 退出码 2，并指出是第几镜', () => {
    const spec = join(work, 'missing.json');
    writeFileSync(spec, JSON.stringify({
      shots: [{ image: img, audio: aud }, { image: join(work, 'nope.png'), audio: aud }],
    }), 'utf8');
    const r = runScript([spec, join(work, 'y.mp4')]);
    assert.equal(r.code, 2);
    assert.match(r.err, /错误：第 2 镜的图不存在/);
  });

  test('spec 不是合法 JSON → 退出码 2，说明读不了', () => {
    const spec = join(work, 'broken.json');
    writeFileSync(spec, '{ not json', 'utf8');
    const r = runScript([spec, join(work, 'z.mp4')]);
    assert.equal(r.code, 2);
    assert.match(r.err, /错误：读不了 spec\.json/);
  });

  test('缺参数 → 退出码 2，并给出用法', () => {
    const r = runScript([]);
    assert.equal(r.code, 2);
    assert.match(r.err, /错误：缺少 spec\.json/);
  });

  test('--help 退出码 0（不报错）', () => {
    const r = runScript(['--help']);
    assert.equal(r.code, 0);
    assert.match(r.out, /用法: node make-narration\.mjs/);
  });
}

// ─────────────────────────────────────────────────────────────────── 汇总

console.log(`\n${'='.repeat(60)}`);
if (failures.length === 0) {
  console.log(`全部通过（${passed} 项）—— 用本机 ffmpeg 真合成了 ${passed} 条链路`);
  process.exit(0);
}
console.log(`失败 ${failures.length} 项 / 通过 ${passed} 项`);
for (const [name] of failures) console.log(`  · ${name}`);
process.exit(1);
