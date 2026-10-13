// `bridge/src/store.mjs` 的测试 —— 配对与设备表（审计 P0-9 的同型问题 + P2 两条）。
//
// 为什么这几条非有不可：这个文件的调用者是 `verifyToken()`，而它
// **每个 hello 都调**。所以"读坏 → 当成空 → 把空写回"这条链在这里的后果是：
// 用户已配对的手机**一次性全部掉线**，且日志里什么都不说。
//
// 跑法：node install/test-bridge-store.mjs      （不需要设备/网络）

import assert from 'node:assert/strict';
import {
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = resolve(fileURLToPath(new URL('.', import.meta.url)), '..');
const { Store } = await import(join(REPO, 'bridge/src/store.mjs'));

let passed = 0;
const failures = [];
function test(name, fn) {
  try {
    fn();
    passed += 1;
    console.log(`  ok   ${name}`);
  } catch (e) {
    failures.push(name);
    console.log(`  FAIL ${name}\n       ${e && e.message ? e.message : e}`);
  }
}

const dir = mkdtempSync(join(tmpdir(), 'bridge-store-test-'));
const file = join(dir, 'devices.json');

// ── 正常路径 ───────────────────────────────────────────────────────────────
console.log('== 正常配对 ==');
test('配对成功后 verifyToken 认这个 token', () => {
  const s = new Store(dir);
  const { code } = s.createPairCode();
  const paired = s.pair(code, '我的手机');
  assert.ok(s.verifyToken(paired.deviceToken), '刚配对的 token 必须认出来');
  assert.equal(s.verifyToken('not-a-token'), null);
});

test('配对码是 6 位数字（P2：不再用 Math.random）', () => {
  for (let i = 0; i < 50; i += 1) {
    const c = new Store(dir).createPairCode().code;
    assert.match(c, /^\d{6}$/, `配对码格式不对：${c}`);
  }
});

test('配对码是一次性的（同码第二次必须失败）', () => {
  const s = new Store(dir);
  const { code } = s.createPairCode();
  s.pair(code, 'a');
  assert.throws(() => s.pair(code, 'b'), /无效或已过期/);
});

// ── 坏文件：隔离 + 保住字节 + 不静默（P0-9 同型）─────────────────────────────
console.log('\n== 坏 devices.json ==');
test('解析失败 → 隔离成 .corrupt，原始字节一个不少', () => {
  const broken = '{"devices":[{"deviceId":"d1"';
  writeFileSync(file, broken, 'utf8');
  // eslint-disable-next-line no-new
  new Store(dir);
  assert.ok(!existsSync(file), '坏文件不该还留在原处');
  assert.ok(existsSync(`${file}.corrupt`), '应该被隔离到 .corrupt');
  assert.equal(readFileSync(`${file}.corrupt`, 'utf8'), broken, '字节必须原样保留');
});

test('隔离之后 verifyToken 无论如何都不会毁掉原始字节', () => {
  const s = new Store(dir);
  s.verifyToken('whatever'); // 每个 hello 都会调它 —— 老代码在这里把空表写回
  assert.ok(existsSync(`${file}.corrupt`), '.corrupt 不该消失');
  assert.equal(
    readFileSync(`${file}.corrupt`, 'utf8'),
    '{"devices":[{"deviceId":"d1"',
    '用户的原始字节被覆盖了 —— 这正是要堵的那个洞',
  );
});

test('不堆积 .corrupt（只留最近一次）', () => {
  const cs = readdirSync(dir).filter((n) => n.endsWith('.corrupt'));
  assert.equal(cs.length, 1, `应该有 1 个 .corrupt，实际 ${cs.length}`);
});

test('形状不对（合法 JSON 但缺 devices）不会抛 TypeError，且被隔离', () => {
  rmSync(`${file}.corrupt`, { force: true });
  writeFileSync(file, '{"version":1}', 'utf8');
  const s = new Store(dir);
  // 老代码：this.devices.devices 是 undefined → 每个 hello 抛 TypeError
  assert.doesNotThrow(() => s.verifyToken('x'));
  assert.ok(existsSync(`${file}.corrupt`), '形状不对的文件也该被隔离');
});

test('0 字节文件按"还没配过"处理，不隔离', () => {
  rmSync(`${file}.corrupt`, { force: true });
  writeFileSync(file, '', 'utf8');
  // eslint-disable-next-line no-new
  new Store(dir);
  assert.ok(existsSync(file), '空文件不该被当成损坏挪走');
  assert.ok(!existsSync(`${file}.corrupt`));
});

// ── 原子写 ─────────────────────────────────────────────────────────────────
console.log('\n== 原子写 ==');
test('写完之后没有 .part 残留，且文件是合法 JSON', () => {
  const s = new Store(dir);
  const { code } = s.createPairCode();
  s.pair(code, 'x');
  const stray = readdirSync(dir).filter((n) => n.endsWith('.part'));
  assert.deepEqual(stray, [], `.part 残留：${stray.join(',')}`);
  assert.doesNotThrow(() => JSON.parse(readFileSync(file, 'utf8')));
});

test('配对后设备表里存的是 token 的 sha256，不是明文', () => {
  const s = new Store(dir);
  const { code } = s.createPairCode();
  const paired = s.pair(code, '明文检查');
  const raw = readFileSync(file, 'utf8');
  assert.ok(!raw.includes(paired.deviceToken), '明文 token 落盘了');
  assert.match(raw, /"tokenHash"/);
});

rmSync(dir, { recursive: true, force: true });

console.log(`\n${'='.repeat(64)}`);
if (failures.length) {
  console.log(`失败 ${failures.length} 项 / 通过 ${passed} 项`);
  for (const n of failures) console.log(`  · ${n}`);
  process.exit(1);
}
console.log(`全部通过（${passed} 项）`);
