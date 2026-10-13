/**
 * 桥的本地持久化：设备（配对凭据）与配置。
 *
 * 安全约定：
 *  - 只存 deviceToken 的 sha256，明文只在配对响应里出现一次。
 *  - 配对码只存在于内存，TTL 120s，一次性，连错 5 次锁 15 分钟。
 *  - 目录默认在 bridge/data/（不要写进 DSH 的 workspace）。
 */

import { createHash, randomBytes, randomInt, randomUUID } from 'node:crypto';
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';

const PAIR_TTL_MS = 120_000;
const PAIR_MAX_ATTEMPTS = 5;
const PAIR_LOCK_MS = 15 * 60_000;

function sha256(s) {
  return createHash('sha256').update(s).digest('hex');
}

/** 一行诊断日志。走 stderr：stdout 留给协议帧。 */
function warn(message) {
  try {
    process.stderr.write(`[bridge/store] ${message}\n`);
  } catch {
    /* 日志写不出去不该影响认证 */
  }
}

export class Store {
  constructor(dir) {
    this.dir = dir;
    mkdirSync(dir, { recursive: true });
    this.devicesFile = path.join(dir, 'devices.json');
    this.devices = this.#load(this.devicesFile, { version: 1, devices: [] });
    this.pairCodes = new Map(); // code -> { expiresAt }
    this.pairFailures = 0;
    this.pairLockedUntil = 0;
  }

  /**
   * 读设备表。
   *
   * ⚠️ 这里曾经是 `catch { return fallback; }` —— 而它的调用者
   * `verifyToken()`（**每个 hello 都调**）在查不到设备之后会 `#save()`，
   * 把这份"空表"**写回磁盘**。于是 devices.json 一旦半截损坏：
   * 用户已配对的手机**一次性全部掉线**，而且日志里连 err 都没接。
   * 与 App 侧 P0-9 是同型问题（读坏 → 当成空 → 写回，原始数据永久消失）。
   *
   * 现在：解析失败先**把坏文件挪到 `.corrupt`**（保住原始字节，可人工恢复），
   * 再返回 fallback，并**明确打日志**。挪走之后再写空表也不会毁掉任何东西。
   */
  #load(file, fallback) {
    if (!existsSync(file)) return fallback;
    let raw;
    try {
      raw = readFileSync(file, 'utf8');
    } catch (err) {
      warn(`读不了 ${file}（${err && err.message}）—— 本次按空设备表处理，**不会**覆盖它`);
      return fallback;
    }
    // 0 字节 / 全空白：没有内容可丢，当作"还没配过"，不报损坏。
    if (raw.trim() === '') return fallback;

    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch (err) {
      const dest = `${file}.corrupt`;
      let moved = false;
      try {
        // POSIX rename 会直接覆盖已存在的 dest —— 只保留最近一次坏文件，不堆积。
        renameSync(file, dest);
        moved = true;
      } catch (moveErr) {
        warn(`隔离坏文件失败（${moveErr && moveErr.message}）`);
      }
      warn(
        `⚠️ ${file} 解析失败（${err && err.message}）—— ` +
          (moved ? `已另存为 ${dest}，` : '原文件保留，') +
          '本次按空设备表处理。用户的配对记录可能都失效了，请检查这个文件。',
      );
      return fallback;
    }

    // 形状守卫：合法 JSON 但结构不对（例如 `{}`）时，后面
    // `this.devices.devices.find(...)` 会**每个 hello 都抛 TypeError**。
    if (!parsed || typeof parsed !== 'object' || !Array.isArray(parsed.devices)) {
      const dest = `${file}.corrupt`;
      let moved = false;
      try {
        renameSync(file, dest);
        moved = true;
      } catch (moveErr) {
        warn(`隔离结构异常文件失败（${moveErr && moveErr.message}）`);
      }
      warn(
        `⚠️ ${file} 形状不对（缺少 devices 数组）—— ` +
          (moved ? `已另存为 ${dest}，` : '原文件保留，') +
          '本次按空设备表处理。',
      );
      return fallback;
    }
    return parsed;
  }

  /**
   * 原子写：先写 `.part`，再 `rename` 覆盖。
   *
   * 直接 `writeFileSync` 是先截断再写；进程在中间被杀（或磁盘满）就会留下
   * **半份 JSON** —— 而上面那个"读坏 → 当成空"的坑正是从半份 JSON 开始的。
   * 同目录 rename 在 POSIX 上是原子的。
   */
  #save() {
    const part = `${this.devicesFile}.part`;
    writeFileSync(part, JSON.stringify(this.devices, null, 2), 'utf8');
    renameSync(part, this.devicesFile);
  }

  // ---------- 配对 ----------

  /**
   * 生成一次性配对码（6 位数字）。
   *
   * ⚠️ 原来用 `Math.random()` —— 配对码是**认证要素**，不该用可预测的伪随机
   * （同文件上面已经 import 了 `randomBytes`，`randomInt` 也是内置的）。
   * 用 `randomInt` 取 [100000, 1000000) 上的均匀整数。
   */
  createPairCode() {
    const code = String(randomInt(100000, 1000000));
    this.pairCodes.clear();
    this.pairCodes.set(code, { expiresAt: Date.now() + PAIR_TTL_MS });
    return { code, expiresAt: Date.now() + PAIR_TTL_MS, ttlSeconds: PAIR_TTL_MS / 1000 };
  }

  get pairLocked() {
    return Date.now() < this.pairLockedUntil;
  }

  /** 用配对码换取设备凭据。返回 {deviceId, deviceToken, deviceName} 或抛错。 */
  pair(code, deviceName) {
    if (this.pairLocked) {
      const err = new Error(`配对已锁定，请 ${Math.ceil((this.pairLockedUntil - Date.now()) / 60000)} 分钟后再试`);
      err.code = 'pair_locked';
      throw err;
    }
    const entry = this.pairCodes.get(String(code ?? ''));
    if (!entry || entry.expiresAt < Date.now()) {
      this.pairFailures += 1;
      if (this.pairFailures >= PAIR_MAX_ATTEMPTS) {
        this.pairLockedUntil = Date.now() + PAIR_LOCK_MS;
        this.pairFailures = 0;
      }
      const err = new Error('配对码无效或已过期');
      err.code = 'pair_code_invalid';
      throw err;
    }
    this.pairCodes.delete(String(code)); // 一次性
    this.pairFailures = 0;

    const deviceToken = randomBytes(32).toString('base64url');
    const device = {
      deviceId: 'dev_' + randomUUID().slice(0, 8),
      name: deviceName || '未命名设备',
      tokenHash: sha256(deviceToken),
      createdAt: new Date().toISOString(),
      revoked: false,
      lastSeenAt: null,
    };
    this.devices.devices.push(device);
    this.#save();
    return { deviceId: device.deviceId, deviceToken, deviceName: device.name };
  }

  // ---------- 认证 ----------

  verifyToken(token) {
    if (!token) return null;
    const hash = sha256(String(token));
    const device = this.devices.devices.find((d) => d.tokenHash === hash && !d.revoked);
    if (!device) return null;
    device.lastSeenAt = new Date().toISOString();
    this.#save();
    return device;
  }

  listDevices() {
    return this.devices.devices.map((d) => ({
      deviceId: d.deviceId,
      name: d.name,
      createdAt: d.createdAt,
      lastSeenAt: d.lastSeenAt,
      revoked: d.revoked,
    }));
  }

  revokeDevice(deviceId) {
    const device = this.devices.devices.find((d) => d.deviceId === deviceId);
    if (!device) return false;
    device.revoked = true;
    this.#save();
    return true;
  }

  revokeAll() {
    for (const d of this.devices.devices) d.revoked = true;
    this.#save();
  }
}
