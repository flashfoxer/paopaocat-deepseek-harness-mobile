/**
 * office-zip.mjs —— 造/读 **OOXML（docx / xlsx / pptx）** 的最小 zip 工具。
 *
 * ## 为什么单独一个文件
 *
 * 这三类"Office 文件"的本质都是 **ZIP + 一堆 XML**。手机上**没有 python**，
 * 所以这条路只能自己走：用 `node:zlib` 的 `deflateRawSync` / `inflateRawSync`
 * 加一个手写的 zip 头。
 *
 * 为什么要共享：造 xlsx、造 docx、读 xlsx 三件事都要它 —— 抄三遍迟早抄歪。
 * 工具箱里已有同样的先例（`agnes-retry.mjs` 被 make-image / make-video
 * 用 `import './agnes-retry.mjs'` 引）。**落盘时必须落在同一个目录**
 * （见 `lib/local/android_toolbox.dart`）。
 *
 * ## 能力边界（写清楚，免得被当成通用 zip 库）
 *
 *   * 写：deflate(8) 与 store(0)，不加密、不写 zip64（Office 文件不会到 4GB）；
 *     时间戳写成固定值（**可复现**：同样输入产出同样字节，方便对 sha256）。
 *   * 读：只认"中央目录 + 本地头"的标准结构，支持 deflate/store；
 *     不认加密、不认 zip64、不认多卷。
 *   * **只做字节层面的事**：XML 怎么拼、字段叫什么，由调用方负责。
 */

import { deflateRawSync, inflateRawSync } from 'node:zlib';

// ─────────────────────────────────────────────────────────── CRC32

const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) {
      c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    }
    t[n] = c;
  }
  return t;
})();

/** 标准 zip 用的 CRC-32（IEEE 802.3，反射多项式 0xEDB88320）。 */
export function crc32(buf) {
  let c = -1;
  for (let i = 0; i < buf.length; i += 1) {
    c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ -1) >>> 0;
}

// ─────────────────────────────────────────────────────────── 写

/** 固定的 MS-DOS 时间/日期（1980-01-01 00:00）—— 让产物可复现。 */
const DOS_TIME = 0;
const DOS_DATE = 0x0021;

/**
 * 把 `[[名字, 内容], …]`（或 Map）打成一个 zip Buffer。
 *
 * @param {Iterable<[string, (string|Buffer|Uint8Array)]>} entries
 * @param {{level?: number}} [opts] level=0 表示全部 store（不压缩，排查用）
 */
export function zipWrite(entries, opts = {}) {
  const list = entries instanceof Map ? [...entries.entries()] : [...entries];
  const level = opts.level === undefined ? 9 : opts.level;

  const parts = [];
  const central = [];
  let offset = 0;

  for (const [name, content] of list) {
    const raw = Buffer.isBuffer(content) ? content : Buffer.from(String(content), 'utf8');
    const nameBuf = Buffer.from(name, 'utf8');
    const deflated = level > 0 ? deflateRawSync(raw, { level }) : raw;
    // 压不小的就不压（目录项/很小的 XML 常见），跟标准 zip 工具一样
    const useDeflate = deflated.length < raw.length;
    const data = useDeflate ? deflated : raw;
    const method = useDeflate ? 8 : 0;
    const crc = crc32(raw);

    const lh = Buffer.alloc(30);
    lh.writeUInt32LE(0x04034b50, 0);   // 本地文件头签名
    lh.writeUInt16LE(20, 4);           // 需要版本 2.0
    lh.writeUInt16LE(0x0800, 6);       // 通用位：bit 11 = 文件名是 UTF-8
    lh.writeUInt16LE(method, 8);
    lh.writeUInt16LE(DOS_TIME, 10);
    lh.writeUInt16LE(DOS_DATE, 12);
    lh.writeUInt32LE(crc, 14);
    lh.writeUInt32LE(data.length, 18);
    lh.writeUInt32LE(raw.length, 22);
    lh.writeUInt16LE(nameBuf.length, 26);
    lh.writeUInt16LE(0, 28);
    parts.push(lh, nameBuf, data);

    const cd = Buffer.alloc(46);
    cd.writeUInt32LE(0x02014b50, 0);   // 中央目录签名
    cd.writeUInt16LE(20, 4);           // 创建版本
    cd.writeUInt16LE(20, 6);           // 需要版本
    cd.writeUInt16LE(0x0800, 8);
    cd.writeUInt16LE(method, 10);
    cd.writeUInt16LE(DOS_TIME, 12);
    cd.writeUInt16LE(DOS_DATE, 14);
    cd.writeUInt32LE(crc, 16);
    cd.writeUInt32LE(data.length, 20);
    cd.writeUInt32LE(raw.length, 24);
    cd.writeUInt16LE(nameBuf.length, 28);
    cd.writeUInt16LE(0, 30);           // extra
    cd.writeUInt16LE(0, 32);           // comment
    cd.writeUInt16LE(0, 34);           // 起始磁盘
    cd.writeUInt16LE(0, 36);           // 内部属性
    cd.writeUInt32LE(0, 38);           // 外部属性
    cd.writeUInt32LE(offset, 42);      // 本地头偏移
    central.push(cd, nameBuf);

    offset += lh.length + nameBuf.length + data.length;
  }

  const centralBuf = Buffer.concat(central);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(0, 4);
  eocd.writeUInt16LE(0, 6);
  eocd.writeUInt16LE(list.length, 8);
  eocd.writeUInt16LE(list.length, 10);
  eocd.writeUInt32LE(centralBuf.length, 12);
  eocd.writeUInt32LE(offset, 16);
  eocd.writeUInt16LE(0, 20);           // 注释长度

  return Buffer.concat([...parts, centralBuf, eocd]);
}

// ─────────────────────────────────────────────────────────── 读

/**
 * 读一个 zip Buffer，返回 `Map<名字, Buffer>`（内容已解压）。
 *
 * 之所以自己解析而不用现成库：**手机上不能 npm install**（见 AGENTS.md），
 * 而这个解析只有几十行 —— 比引一个依赖可控。
 */
export function zipRead(buf) {
  // EOCD 在文件尾，最多再带 64KB 注释
  let eocd = -1;
  const minPos = Math.max(0, buf.length - 22 - 0xffff);
  for (let i = buf.length - 22; i >= minPos; i -= 1) {
    if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error('不是合法的 zip：找不到 EOCD（文件是否损坏？）');

  const count = buf.readUInt16LE(eocd + 10);
  let p = buf.readUInt32LE(eocd + 16);
  const out = new Map();

  for (let i = 0; i < count; i += 1) {
    if (buf.readUInt32LE(p) !== 0x02014b50) {
      throw new Error(`中央目录第 ${i + 1} 项签名不对（zip 可能被截断）`);
    }
    const method = buf.readUInt16LE(p + 10);
    const compSize = buf.readUInt32LE(p + 20);
    const nameLen = buf.readUInt16LE(p + 28);
    const extraLen = buf.readUInt16LE(p + 30);
    const commentLen = buf.readUInt16LE(p + 32);
    const localOff = buf.readUInt32LE(p + 42);
    const name = buf.toString('utf8', p + 46, p + 46 + nameLen);

    // 本地头的 extra 长度**可能与中央目录不同**，必须重读
    const lhNameLen = buf.readUInt16LE(localOff + 26);
    const lhExtraLen = buf.readUInt16LE(localOff + 28);
    const dataStart = localOff + 30 + lhNameLen + lhExtraLen;
    const raw = buf.subarray(dataStart, dataStart + compSize);

    if (method === 8) out.set(name, inflateRawSync(raw));
    else if (method === 0) out.set(name, Buffer.from(raw));
    else throw new Error(`不支持的压缩方式 ${method}（只认 store / deflate）`);

    p += 46 + nameLen + extraLen + commentLen;
  }
  return out;
}

// ─────────────────────────────────────────────────────────── XML 小工具

/** XML 文本转义（`&` 必须第一个换，否则会把后面生成的实体再转一遍）。 */
export function xmlEscape(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

/** XML 文本反转义（解析别人写的 xlsx 时用）。 */
export function xmlUnescape(s) {
  return String(s)
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&');
}

/** 列号（0 起）→ 列名（A、B…AA）。 */
export function colName(index) {
  let n = index + 1;
  let s = '';
  while (n > 0) {
    const r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = Math.floor((n - 1) / 26);
  }
  return s;
}

/** 列名（A、AA）→ 列号（0 起）。认不出来返回 -1。 */
export function colIndex(name) {
  const s = String(name || '').toUpperCase().replace(/[^A-Z]/g, '');
  if (!s) return -1;
  let n = 0;
  for (const ch of s) n = n * 26 + (ch.charCodeAt(0) - 64);
  return n - 1;
}
