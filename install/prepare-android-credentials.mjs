/**
 * 把本机的模型凭据转换成 Android 侧可用的 .env 文件。
 *
 * 安全约定：**不打印任何密钥内容**，只报告是否找到、长度与写入位置。
 *
 * 本机凭据来源：$DSH_HOME/.credentials.yaml 的 refs（COM_API_KEY）
 * 目标：D:/dev/android-node/android-home/.env  —— 随后 push 到 Android 的 DSH_HOME
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const CRED = 'C:/Users/25894/AppData/Roaming/PaopaocatDSH/.credentials.yaml';
const OUT_DIR = 'D:/dev/android-node/android-home';
const OUT = path.join(OUT_DIR, '.env');

if (!existsSync(CRED)) {
  console.error(`找不到凭据文件: ${CRED}`);
  process.exit(1);
}

const text = readFileSync(CRED, 'utf8');

/** 从 refs 段里取一个键的值（YAML 流式映射 / 块式映射都能应付）。 */
function extractRef(key) {
  // 形如：  COM_API_KEY: "sk-xxx"   或   COM_API_KEY: sk-xxx
  const re = new RegExp(`${key}\\s*:\\s*"?([^"\\n,}]+)"?`);
  const m = re.exec(text);
  return m ? m[1].trim() : null;
}

const comKey = extractRef('COM_API_KEY');
const dsKey = extractRef('DEEPSEEK_API_KEY');

const lines = [];
if (comKey) lines.push(`COM_API_KEY=${comKey}`);
if (dsKey) lines.push(`DEEPSEEK_API_KEY=${dsKey}`);

if (lines.length === 0) {
  console.error('凭据文件里没找到 COM_API_KEY / DEEPSEEK_API_KEY');
  process.exit(1);
}

mkdirSync(OUT_DIR, { recursive: true });
writeFileSync(OUT, lines.join('\n') + '\n', 'utf8');

// 只报告事实，不泄露内容
console.log('已生成 .env（内容不回显）：');
console.log(`  写入位置: ${OUT}`);
for (const name of ['COM_API_KEY', 'DEEPSEEK_API_KEY']) {
  const v = name === 'COM_API_KEY' ? comKey : dsKey;
  console.log(`  ${name.padEnd(18)} ${v ? `已找到（长度 ${v.length}，前缀 ${v.slice(0, 3)}…）` : '未找到'}`);
}
