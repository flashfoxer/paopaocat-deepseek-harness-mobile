'use strict';
/**
 * Android filesystem shim —— 通过 `node --require` 预加载。
 *
 * 问题（实测）：
 *   Android 的 SELinux（Enforcing）禁止在该环境创建硬链接：
 *     ln: cannot create hard link from 'a.txt' to 'b.txt': Permission denied
 *   而 DSH 的会话持久化用 `link()` 实现"原子写"（先写临时文件，再 link 到目标
 *   以保证不会被覆盖），于是整个写入路径直接 EACCES 失败。
 *
 * 处理：
 *   仅在 link 被权限/不支持类错误拒绝时，降级为带 COPYFILE_EXCL 的复制 ——
 *   语义等价（目标已存在则失败，不会覆盖），只是不再与源共享 inode。
 *   其它错误照常抛出，不掩盖真实故障。
 *
 * 说明：如果运行环境允许硬链接（例如 App 私有目录），这里会自动走原生路径，
 * 不产生任何额外开销。
 */

const fs = require('node:fs');
const fsp = require('node:fs/promises');

const FALLBACK_CODES = new Set(['EPERM', 'EACCES', 'ENOSYS', 'EOPNOTSUPP', 'ENOTSUP']);

const originalLinkSync = fs.linkSync;
fs.linkSync = function linkSyncShim(existingPath, newPath) {
  try {
    return originalLinkSync.call(fs, existingPath, newPath);
  } catch (err) {
    if (!err || !FALLBACK_CODES.has(err.code)) throw err;
    fs.copyFileSync(existingPath, newPath, fs.constants.COPYFILE_EXCL);
  }
};

const originalLink = fsp.link;
fsp.link = async function linkShim(existingPath, newPath) {
  try {
    return await originalLink.call(fsp, existingPath, newPath);
  } catch (err) {
    if (!err || !FALLBACK_CODES.has(err.code)) throw err;
    await fsp.copyFile(existingPath, newPath, fs.constants.COPYFILE_EXCL);
  }
};

// 便于排查：确认 shim 已加载（只在显式设置 DEBUG 时输出）
if (process.env.DSH_ANDROID_SHIM_DEBUG === '1') {
  process.stderr.write('[android-fs-shim] fs.link / fs.promises.link 已接管\n');
}
