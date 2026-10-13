# Android 本地运行 DSH · 可行性验证报告

- 验证日期：2026-10-02
- 环境：Android 14（API 34）x86_64 模拟器，SELinux **Enforcing**，宿主 Windows 11
- 结论：**可行**。DSH 已在 Android 上完成一次真实模型对话（`只回答两个字：收到` → `收到`，退出码 0）
- 项目目标形态：单 APK，除模型 API 外不依赖任何服务器

---

## 0. 结论摘要

把 DSH 原封不动搬到 Android 上跑，会依次撞上 **4 个平台障碍**。每一个都有确定解法，
且解法都不需要修改 DSH 主体逻辑（除一处 `link` 降级）：

| # | 障碍 | 现象 | 解法 |
|---|---|---|---|
| 1 | Node 二进制的 shell 路径被硬编码为 Termux 路径 | `spawnSync /data/data/com.termux/files/usr/bin/sh ENOENT` | 二进制内**同长度替换**为 `/system/bin/sh` |
| 2 | 缺平台原生 addon：`node-addon-require-builtin` | boot 阶段 fatal：`No usable native binding found for node-addon-require-builtin-android-x64` | 纯 JS shim（`requireBuiltin` = 标准 `require`）+ `--expose-internals` |
| 3 | 缺平台原生 addon：`node-addon-system` 的 flock | `flock is not supported on android-x64` | 纯 JS shim：单进程场景退化为 no-op |
| 4 | SELinux 禁止硬链接，而会话持久化用 `link()` 做原子写 | `EACCES: permission denied, link '...zstd.<hash>.tmp' -> '...zstd'` | `--require` shim：link 被拒时降级为 `copyFile(COPYFILE_EXCL)` |

全部解决后：

```
[android-fs-shim] fs.link / fs.promises.link 已接管
收到
EXIT=0
```

---

## 1. 运行时从哪来

`nodejs-mobile` 停在 **Node 18.20.4**，而 DSH 用了 `node:sqlite`（Node 22.5+ 才有，23+ 默认启用），
因此**必须放弃 nodejs-mobile**。

改用 **Termux 的 nodejs 包**（官方 Node 交叉编译到 Android，当前 26.4.0）：

```
https://packages.termux.dev/apt/termux-main/pool/main/n/nodejs/nodejs_26.4.0-1_{aarch64,x86_64}.deb
```

其 `control` 声明的依赖：`libc++, openssl, c-ares, libicu, libsqlite, zlib, libffi`
（Termux pool 里 `lib*` 包位于 `pool/main/lib<x>/`，不是首字母目录）

node 二进制的实际 `DT_NEEDED`：`libc.so, libcares.so, libcrypto.so.3, libdl.so, libffi.so,
libicui18n.so.78, libicuuc.so.78, libm.so, libsqlite3.so, libssl.so.3, libz.so.1`

### 一个必须处理的细节：库名

Termux 用**符号链接**把一个 `.so` 暴露成多个名字（`libicui18n.so.78 -> libicui18n.so.78.3`），
而 Windows 解包无法创建符号链接（需要管理员/开发者模式），于是只拿到实体文件，名字对不上。

`install/normalize-runtime-libs.mjs` 迭代补齐：扫描所有 ELF 里出现的 `lib*.so*` 字符串，
对每个缺失的名字找"以它开头"的实体文件复制。最终 24 个库全部就位。

### 体积（x86_64 实测）

| 项 | 大小 |
|---|---|
| node 二进制 | 46.9 MB |
| 依赖库（含 ICU data 31.6 MB） | 47.4 MB |
| 运行时小计 | **94.3 MB** |
| DSH 安装树（node_modules 等，26492 个文件） | **484 MB** |
| 合计（未压缩） | **~578 MB** |

---

## 2. 四个障碍的细节

### 障碍 1：Node 硬编码了 Termux 的 shell

`process.platform` 是 `android`，但 node 二进制里把默认 shell 固定成
`/data/data/com.termux/files/usr/bin/sh`（共 1 处），而 Android 只有 `/system/bin/sh`。
`SHELL` 环境变量**无效**（不参与该决策）。

解法：`install/patch-node-shell.mjs` 在二进制里做**同长度替换**（新路径更短，用 `\0` 补齐）。
该字符串位于 `.rodata`，不改变任何 ELF 结构。

修补后 `child_process` 立刻可用。

> 二进制里还残留 8 种 Termux 路径（`.../usr/bin/bash`、`.../usr/tmp`、`.../files/usr/lib` 等），
> 实测**不影响**本次对话流程；是否影响其它工具能力需要后续逐项验证。

### 障碍 2：`node-addon-require-builtin` 没有 android 构建

它只发布了 `win32-x64-msvc`。`dsh-app-boot` 在 boot 阶段用它加载 Node 内部模块：

```
internal/modules/esm/loader, internal/modules/cjs/loader,
internal/modules/helpers, internal/modules/esm/utils, internal/modules/esm/resolve
```

它的公开接口只有三个：`requireBuiltin(id)`、`isAllowedInternalId(id)`、`getBindingInfo()`。

解法：`install/android-shim-require-builtin.js` 用标准 `require()` 实现
（配合启动参数 `--expose-internals`，这正是 `cordis-plugin-loader` 自己留的旁路）。

### 障碍 3：`node-addon-system` 的 flock

该包**显式拒绝**非 linux/darwin 平台（Android 的 `process.platform` 是 `android`），
而且 Android 的 bionic libc 本身也不导出 `flock()`。

解法：`install/android-shim-flock.js` 把 `tryLockExclusive` 退化为 no-op。
文件锁在这里用于防止**多进程**并发写同一份会话文件；单 App 进程内没有竞争者。

### 障碍 4：SELinux 禁止硬链接

```
ln: cannot create hard link from 'a.txt' to 'b.txt': Permission denied
```

`/data` 是 ext4（支持硬链接），但 SELinux（Enforcing）拒绝了该操作。
而 `dsh-session-persistence-jsonl` 的原子写正是：

```js
await internals.fs.link(staged, currentPath);   // 写临时文件后 link 到目标
```

解法：`install/android-fs-shim.cjs`（通过 `node --require` 预加载）在
`EPERM/EACCES/ENOSYS/EOPNOTSUPP` 时降级为 `copyFile(..., COPYFILE_EXCL)` ——
语义等价（**目标已存在则失败，绝不覆盖**），只是不再共享 inode。

> 该 shim 只在原生 link 被拒时才介入；如果 App 私有目录允许硬链接，会自动走原生路径。

---

## 3. 在 Android 上实际执行的验证

每一步都在模拟器里真实执行过：

| 验证 | 结果 |
|---|---|
| `node --version` | `v26.4.0` |
| `require('node:sqlite')` + 建表/插入/查询 | ✅ |
| `child_process.execSync`（修补 shell 后） | ✅ |
| 文件读写 | ✅ |
| HTTPS 出网（HEAD api.deepseek.com） | ✅ HTTP 401（未带认证，链路正常） |
| `dsh --version` | `0.1.7-rc.2` |
| `dsh --help` | 完整输出 |
| `dsh --profile headless --dump-default-config` | ✅ 完整配置树（插件系统正常加载） |
| profile 自动初始化 | ✅（`$DSH_HOME/profiles/headless`） |
| **真实模型对话** | ✅ **输出 `收到`，退出码 0** |

模拟器资源：4 核 / 2.5 GB 内存，`/data` 可用 4.9 GB。

---

## 4. 复现步骤

```powershell
# 1) 运行时（两种架构都支持）
node install\fetch-termux-deps.mjs            # 抓 node 包与 7 个依赖包
install\assemble-android-runtime.ps1 -Arch x86_64
node install\normalize-runtime-libs.mjs x86_64
node install\patch-node-shell.mjs x86_64      # 修补硬编码 shell 路径

# 2) 推送到设备（/data/local/tmp 允许执行，适合验证；正式版要走 jniLibs）
adb push runtime\x86_64 /data/local/tmp/dshrt
adb push <DSH 安装树> /data/local/tmp/dsh

# 3) Android 特有的三个 shim
adb push install\android-shim-require-builtin.js <dsh>/node_modules/node-addon-require-builtin/lib/index.js
adb push install\android-shim-flock.js <dsh>/node_modules/@deepseek-ai/node-addon-system/lib/flock.js
adb push install\android-fs-shim.cjs /data/local/tmp/dshhome/

# 4) 运行
adb shell "LD_LIBRARY_PATH=/data/local/tmp/dshrt/lib DSH_HOME=/data/local/tmp/dshhome \
  /data/local/tmp/dshrt/bin/node --expose-internals \
  --require /data/local/tmp/dshhome/android-fs-shim.cjs \
  /data/local/tmp/dsh/lib/bin.js --profile headless \
  --patch /data/local/tmp/dshhome/android-model.overlay.yml '只回答两个字：收到'"
```

本机可用的模型路由通过 `install/android-model.overlay.yml` 注入
（自定义 provider + `COM_API_KEY`；换成官方 DeepSeek 只需改 provider）。

---

## 5. 尚未验证 / 下一步

**已验证**：核心 Agent、会话、模型调用、持久化、插件加载、子进程、文件系统、HTTPS。

**尚未验证**（打包阶段必须处理）：

1. **App 私有目录里的可执行性**。`/data/local/tmp` 是可执行目录，但正式 APK 不能把 47 MB 二进制放那。
   Android 只允许从 `nativeLibraryDir`（APK 的 `lib/<abi>/`）执行原生程序，
   因此 node 需要以 `libnode.so` 名义进 `jniLibs`，依赖库同样处理（文件名需以 `.so` 结尾，
   可能需要等长改写 ELF 的 `DT_NEEDED`）。
2. **App 私有目录是否允许硬链接**。若允许，障碍 4 的 shim 不会触发；若不允许，shim 是必需的。
3. **`node-pty`**（终端会话）：无 android 预编译。DSH 用 `createLazyRequire` 延迟加载，
   只要不用终端类工具就不受影响；需要确认降级行为。
4. **`sharp`**（图像）：同样无 android 构建，懒加载。
5. **APK 体积与首启解压**。484 MB 的依赖树要随包分发，首次启动需要解压到私有目录，
   这是必须接受的体验代价。
6. **Flutter ↔ Node 的通路**：进程内嵌（nodejs-mobile 风格）还是子进程 + 本地 socket。
   目前验证走的是"外部进程 + stdio"，与既有 `bridge` 的 ACP 客户端逻辑可直接复用。
