# Android 单 APK 内嵌 DSH · 实现与踩坑记录

- 验证日期：2026-10-02
- 状态：**已跑通**。APK 内的 `node --version`、`dsh --version`、`dsh --profile headless --dump-default-config` 全部成功
- 产物：`dist/dsh-local-x86_64-app-debug.apk`（227.3 MB，模拟器版）

---

## 1. 架构

```
APK
├── lib/x86_64/libnode.so            ← node 26.4.0（原 bin/node，改名以符合 jniLibs 规则）
├── lib/x86_64/lib*.so               ← Termux 侧的依赖库（ICU/OpenSSL/sqlite/c-ares/ffi/zlib）
├── assets/dsh-runtime.zip           ← DSH 依赖树 + 三个 shim（484 MB → 150.6 MB）
└── classes.dex / libflutter.so / …  ← Flutter 与 App 代码

首次启动：
  MainActivity 解压 zip → files/dsh/（26495 个条目）+ files/shims/
                     → 覆盖两个 shim 到 DSH 树内的目标位置

运行时：
  Dart 用 Process.start 拉起 nativeLibraryDir/libnode.so
    --expose-internals                        （替代缺失的原生 addon）
    --require files/shims/android-fs-shim.cjs （绕开 SELinux 的硬链接限制）
    files/dsh/lib/bin.js --profile headless "任务"
  环境：LD_LIBRARY_PATH=nativeLibraryDir, DSH_HOME=files/dshhome
```

**为什么 node 必须以 `libnode.so` 的名义放在 jniLibs**：Android 只允许从 `nativeLibraryDir`
执行原生程序；App 私有目录里的可执行文件会被 SELinux 拒绝执行。

---

## 2. 体积

| 项 | 大小 |
|---|---|
| node 二进制 | 46.9 MB |
| 依赖库（按 DT_NEEDED 闭包精确挑选，11 个文件） | 45.6 MB |
| DSH 依赖树 zip（26495 条目） | 150.6 MB |
| **APK（x86_64 debug）** | **227.3 MB** |

首启解压耗时约 **75 秒**（模拟器，26495 个文件）。

---

## 3. 本轮解决的关键问题

### 3.1 jniLibs 命名与依赖改写

Termux 的库叫 `libcrypto.so.3` / `libicui18n.so.78` / `libz.so.1`，**不以 `.so` 结尾**，
无法作为 jniLibs 打包。`install/prepare-jnilibs.mjs` 做两件事：

1. 解析 ELF 的 `.dynamic` / `.dynstr`，从 `libnode.so` 出发算**依赖闭包**，只输出真正需要的库
   （避免把整棵目录塞进去，多出 40+ MB）；
2. 把库名改成合规形式（`libcrypto3.so`、`libicui18n78.so`…），并在**所有 ELF** 里
   做同长度/更短加 `\0` 的字符串替换，让 `DT_NEEDED` 指向新名字。

### 3.2 解压：ZipInputStream 会提前结束

从 `AssetManager` 直接流式解压时，zip 有 26495 个条目却只解出 **3 个**就结束。
改用 **`ZipFile`**（读 central directory）后正常。

### 3.3 .NET 在 Windows 上写出的 zip 用反斜杠

`ZipFile.CreateFromDirectory`（.NET Framework）生成的条目名是 `app\xxx`（反斜杠），
不符合 zip 规范，于是 `startsWith("app/")` 全部不匹配。
Kotlin 侧统一 `name.replace('\\', '/')` 解决。

### 3.4 Kotlin 的嵌套块注释

注释里写 `app/**` 会开启**嵌套注释**，导致外层 `/** */` 永不闭合，报
`Unclosed comment` + `Missing '}'`。涉及路径的注释不要用 KDoc。

### 3.5 Flutter 不转发 `-P` 给 Gradle

`flutter build apk -PdshAbi=x86_64` 不会传到 Gradle，`build.gradle.kts` 退回默认值，
于是打到模拟器上的 APK 里是 arm64 的 `libnode.so`。
改用环境变量 `ORG_GRADLE_PROJECT_dshAbi` —— **但 Gradle daemon 会缓存进程环境**，
daemon 复用时仍读不到，最终改为写进 `android/gradle.properties`（并 `gradlew --stop`）。

### 3.6 abiFilters 被 Flutter 插件覆盖

`defaultConfig.ndk.abiFilters` 在这个组合下无效，APK 里同时出现 arm64-v8a 与 x86_64
两套原生库。改用 `packaging.jniLibs.excludes` 显式排除非目标 ABI。

### 3.7 `extractNativeLibs` → `useLegacyPackaging`

Android 默认不把 `.so` 解压到文件系统（`extractNativeLibs=false`），
于是 `nativeLibraryDir` 是空的，`libnode.so` 无法执行。
AGP 明确拒绝在 manifest 里写 `extractNativeLibs="true"`，要求改用
`packaging.jniLibs.useLegacyPackaging = true`。

顺带效果：**APK 从 420 MB 降到 227.3 MB**（`.so` 在 APK 内以压缩形式存储）。

### 3.8 PowerShell 5.1 + 中文注释 = 静默错误（踩得最深）

`build-local-apk.ps1` 里有一行 `$GradleProps = "$Target\android\gradle.properties"`，
运行时 `$Target` 明明是 `D:\dev\build\app-local`，这个插值结果却是**空串**。
原因：脚本是 UTF-8 无 BOM，PowerShell 5.1 按 ANSI 读取，**中文注释乱码后产生了引号**，
破坏了后续行的解析。

**结论：这个环境下的 `.ps1` 必须纯 ASCII**（或在文件头写 BOM）。
所有 `install/*.ps1` 现已遵守。

---

## 4. 验证证据（全部在 Android 14 x86_64 模拟器上实测）

| 步骤 | 结果 |
|---|---|
| APK 安装 + 启动 | ✅ |
| 解压运行时 | ✅ `entries=26495 files=26495`，`files/dsh/lib/bin.js` 就位 |
| shim 覆盖 | ✅ 两个 shim 已落到 DSH 树内目标位置 |
| nativeLibraryDir | ✅ `libnode.so` 49 MB 落盘且可执行 |
| `node --version` | ✅ `exit=0`，stdout = `v26.4.0` |
| `dsh --version` | ✅ `exit=0`，stdout = `0.1.7-rc.2` |
| `dsh --profile headless --dump-default-config` | ✅ `exit=0`，完整配置树 |
| **`dsh --profile headless "<任务>"`（真实模型对话）** | ✅ **`exit=0`，stdout = `收到`，耗时 21 秒** |

### 模型凭据如何进入 App

- App 内「模型设置」接受 Base URL / provider id / model id / API Key；
- API Key 存 `flutter_secure_storage`，并以**环境变量**注入 node 进程
  （overlay 用 `apiKeyEnv` 引用同名变量）——Key 不进入命令行；
- 保存时在 `files/dshhome/model.overlay.yml` 生成 overlay，运行 headless 时用 `--patch` 加载；
- 开发/自动化场景可从 `files/dev-api-key.txt` 读取（便于用
  `adb shell run-as ... 'cat > ...'` 经 stdin 注入，避免 Key 出现在命令行里）。

> 观测手段说明：Flutter 是自绘引擎，`uiautomator` 读不到界面文本，
> 所以关键状态都通过 `debugPrint` 打到 logcat（`adb logcat -s flutter`），
> 按钮用 `adb shell input tap` 触发。

---

## 5. 真机包（arm64-v8a）

```powershell
# 构建（约 5-10 分钟）
install\build-local-apk.ps1 -Abi arm64-v8a -Mode release
# 产物
dist\dsh-local-arm64-v8a-app-release.apk   186.0 MB
```

交付前做过的静态自检（全部通过在案的构建产物上）：

| 检查 | 结果 |
|---|---|
| APK 内 ABI | 仅 `arm64-v8a` |
| native 库 | 15 个（11 个 DSH 运行时库 + libapp/libflutter/libdartjni/libdatastore） |
| `libnode.so` ELF | AArch64 64-bit，interpreter = `/system/bin/linker64` |
| shell 路径补丁 | 已应用（`/system/bin/sh`，旧 Termux 路径 0 残留） |
| 依赖引用闭包 | ✓ 全部能在 jniLibs 内解析（含 `libz1.so`） |
| assets | `assets/dsh-runtime.zip`（26495 条目，含 3 个 shim） |
| 签名 | debug key（可直接安装；上架需换正式 keystore） |

### 一个只在 arm64 上暴露的缺陷（已修）

`install/normalize-runtime-libs.mjs` 里用来识别库名的正则是
`lib[A-Za-z0-9_+\-.]{2,40}?\.so` —— **要求库名至少 2 个字符**，
于是 `libz.so.1`（`libz` 只有 1 个字符）**从未被补齐**。
而 `libnode.so` 与 `libsqlite3.so` 都依赖 `libz.so.1`。

x86_64 之所以没暴露出这个问题，是因为早期手工推送测试时复制过 `libz.so.1`，
而 arm64 是全新跑流程，于是缺了 `libz1.so`，真机上会以
`library "libz.so.1" not found` 启动失败。

修复：正则改为 `{1,40}`；重跑 normalize + prepare 后 arm64 jniLibs 变为 11 个文件。

### 另一个交付陷阱（已修）

构建脚本原先把所有 `*.apk` 从 Gradle 输出目录复制到 `dist/` 并按当前 ABI 重命名，
于是**旧的 x86_64 debug 包被命名为 `dsh-local-arm64-v8a-app-debug.apk`**——
名字写 arm64，内容是 x86_64。现已改为：构建前清空输出目录，且只复制
`app-<mode>.apk`。

### 真机首次使用暴露的引导缺陷（已修）

用户在真机上第一次运行就报：

```
[headless 对话] exit=1
Error: Cannot find module '.../files/shims/android-fs-shim.cjs'
  requireStack: [ 'internal/preload' ]
```

原因：`DshRuntime.spawn` **无条件**加了 `--require <fsShim>`，而该文件要等
「准备运行时」解压之后才存在。用户没解压就点了执行 → node 死在预加载阶段，
而且报错是一串 Node 内部堆栈，**完全没提示"要先解压"**。

修复三点：

1. `spawn` 前置检查 `isUnpacked`，未就绪时抛可读中文错误；
2. `_guard` 统一拦截未就绪的操作，提示「请先点准备运行时」；
3. 页面顶部在未解压时显示醒目标注。

教训：**"底层能跑通"和"首次使用能走通"是两件事**。
在模拟器上我按"先解压→再执行"的顺序操作，因此从未触发这条路径；
真实用户第一步就撞上了，且只拿到一句无法理解的 Node 错误。

---

## 6. 尚未完成 / 下一步

1. **模型对话验证**：需要在 App 内提供 API Key 输入并生成模型 overlay
   （目前 overlay 还是手工 push 到设备的形式）。
2. **Dart 侧的 stdio 客户端**：现在只有测试按钮；正式形态要让 Flutter 用
   `Process.start` 的 stdio 说 ACP 协议（换行分帧 JSON-RPC），
   并复用已有的会话/流式/审批 UI 与状态层。
3. **输出解码**：`local_test_page` 收集 stdout 时未做 UTF-8 解码，日志里显示为字节数组
   （不影响功能，需要修）。
4. **arm64-v8a 真机包**：`jnilibs/arm64-v8a` 已就绪，但尚未在真机验证
   （模拟器是 x86_64，ABI 相关的结论需要真机复测）。
5. **`node-pty` / `sharp`**：Android 无对应构建。它们都是 `createLazyRequire`
   懒加载，不使用终端/图像工具时不会触发；降级行为仍需逐工具确认。
6. **首启体验**：75 秒解压需要进度反馈与"可跳过"设计（当前进度回调是限频上报）。
