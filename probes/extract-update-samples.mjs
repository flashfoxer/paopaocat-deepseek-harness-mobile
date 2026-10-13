// 从最新夹具中提取每种 session/update 的真实结构样本（写桥协议的依据）。
import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';

const DIR = 'D:/新建文件夹/新建文件夹/新建文件夹/新建文件夹/dsh-mobile/fixtures';
const latest = readdirSync(DIR)
  .filter((f) => f.endsWith('.jsonl'))
  .sort()
  .pop();

console.log('f夹具文件:', latest, '\n');

const frames = readFileSync(path.join(DIR, latest), 'utf8')
  .split('\n')
  .filter(Boolean)
  .map((l) => JSON.parse(l));

const updateSamples = new Map();
const outbound = [];

for (const f of frames) {
  const msg = f.msg;
  if (!msg) continue;
  if (f.dir === 'out') outbound.push(msg);
  if (f.dir === 'in' && msg.method === 'session/update') {
    const kind = msg.params?.update?.sessionUpdate;
    if (!updateSamples.has(kind)) updateSamples.set(kind, msg.params);
  }
}

for (const [kind, sample] of updateSamples) {
  console.log('======== session/update :: ' + kind + ' ========');
  console.log(JSON.stringify(sample, null, 2).slice(0, 2200));
  console.log();
}

console.log('======== 客户端发出的方法序列 ========');
console.log(
  outbound
    .map((m) => (m.method ? `${m.method}${m.id !== undefined ? ` (id ${m.id})` : ''}` : `result for id ${m.id}`))
    .join('  ->  '),
);
