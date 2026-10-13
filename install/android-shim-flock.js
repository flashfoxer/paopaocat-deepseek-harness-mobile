/**
 * Android shim for @deepseek-ai/node-addon-system's flock entry.
 *
 * 原实现在 loadBinding() 里显式拒绝非 linux/darwin 平台：
 *     if (platform !== 'linux' && platform !== 'darwin') throw ERR_FLOCK_UNSUPPORTED_PLATFORM
 * Android 的 process.platform 是 'android'（不是 'linux'），而且 bionic libc
 * 本身也不导出 flock()，所以这条路在 Android 上走不通。
 *
 * 退化理由：文件锁在这里用于防止**多个进程**同时写同一份会话文件。
 * 单 App 进程内不存在这种竞争者，因此保留接口语义（调用方认为已获得独占锁）
 * 而不再真正加锁。
 *
 * 如果将来出现多进程写入场景（例如后台服务与前台 App 同时跑），
 * 需要换成基于文件创建/重命名的纯 JS 锁，而不是继续用 no-op。
 */

export async function tryLockExclusive(fd) {
  // no-op：单进程内没有竞争者
  void fd;
}
