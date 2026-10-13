#!/usr/bin/env node
/**
 * 给「已经下载好的模型文件」算 sha256，并回填进随包清单。
 *
 * 为什么需要这一步：清单里的 bytes 是从源站 API 取的精确值，但 **sha256 必须由真实文件算出来**
 * （不能凭猜，也不能只信源站）。回填之后，手机端导入/下载就会**逐字节校验**，
 * 而不是只比大小 —— 那是"文件完整"与"文件没被掉包"的区别。
 *
 * 用法（在下载目录里跑）：
 *   node install/models/hash-models.mjs .            # 只算并打印，不改清单（先看对不对）
 *   node install/models/hash-models.mjs . --write    # 算完直接回填 app/assets/models/model_manifest.json
 *   node install/models/hash-models.mjs . --write --require-hash
 *                                                    # 同时把清单里的 requireHash 打开
 *                                                    # （发布版才打开：缺哈希的条目会拒绝下载）
 *
 * 匹配规则：**按文件名匹配**；大小与清单不符的会标 ⚠️ 并跳过（说明下到了别的版本）。
 */
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');
const MANIFEST = path.join(REPO, 'app/assets/models/model_manifest.json');

const args = process.argv.slice(2);
const dir = args.find((a) => !a.startsWith('--'));
const write = args.includes('--write');
const requireHash = args.includes('--require-hash');

if (!dir) {
  console.error('用法：node install/models/hash-models.mjs <模型文件所在目录> [--write] [--require-hash]');
  process.exit(1);
}
if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) {
  console.error(`目录不存在：${dir}`);
  process.exit(1);
}

const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));

/** 流式计算 sha256：1–3 GB 的文件不能一次读进内存。 */
function sha256(file) {
  return new Promise((resolve, reject) => {
    const h = crypto.createHash('sha256');
    const s = fs.createReadStream(file, { highWaterMark: 1 << 20 });
    s.on('data', (c) => h.update(c));
    s.on('end', () => resolve(h.digest('hex')));
    s.on('error', reject);
  });
}

const mb = (n) => `${(n / 1048576).toFixed(1)} MB`;
const found = [];
const missing = [];
const mismatch = [];

for (const m of manifest.models) {
  const p = path.join(dir, m.fileName);
  if (!fs.existsSync(p)) {
    missing.push(m.fileName);
    continue;
  }
  const size = fs.statSync(p).size;
  if (size !== m.bytes) {
    mismatch.push({ id: m.id, file: m.fileName, got: size, want: m.bytes });
    continue;
  }
  process.stdout.write(`  ⏳ ${m.fileName}（${mb(size)}）… `);
  const h = await sha256(p);
  const same = m.sha256 && m.sha256.toLowerCase() === h;
  console.log(same ? '✅ 与清单一致' : m.sha256 ? '🔄 与清单不同（已更新）' : '✅ 首次回填');
  found.push({ id: m.id, file: m.fileName, size, sha256: h, changed: m.sha256 !== h });
  if (write) m.sha256 = h;
}

console.log('');
console.log(`找到并校验：${found.length} 个　缺失：${missing.length} 个　大小不符：${mismatch.length} 个`);
if (missing.length) console.log(`  缺失：${missing.join(', ')}`);
for (const x of mismatch) {
  console.log(`  ⚠️ ${x.file}：实际 ${x.got} 字节，清单 ${x.want} 字节（下到的可能是另一个版本，已跳过）`);
}

if (write && found.length) {
  if (requireHash) manifest.requireHash = true;
  manifest.updatedAt = new Date().toISOString().slice(0, 10);
  fs.writeFileSync(MANIFEST, JSON.stringify(manifest, null, 2) + '\n');
  console.log('');
  console.log(`✅ 已回填 ${found.length} 个 sha256 → ${path.relative(REPO, MANIFEST)}`);
  console.log(`   requireHash = ${manifest.requireHash}`);
  console.log('   接下来：跑一遍 App 的测试（清单自检会读这个文件），再重新打包。');
} else if (found.length) {
  console.log('');
  console.log('（未修改清单。确认无误后加 --write 回填，并在发版时加 --require-hash。）');
}
