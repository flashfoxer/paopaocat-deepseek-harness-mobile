# 构建环境与踩坑记录

本文档记录本机（Windows 11 / 25H2）搭建 Flutter + Android 构建链时**实际遇到**的问题与解法。
目的是让你（或任何接手的人）不必再踩一遍。

## 一、已安装的工具链

| 组件 | 版本 | 位置 |
|---|---|---|
| Flutter SDK | 3.47.6 stable（Dart 3.13.5） | `D:\dev\flutter` |
| JDK | Microsoft OpenJDK 17.0.20.1 LTS | `D:\dev\jdk\jdk-17.0.20.1+1` |
| Android SDK | platforms 35/36、build-tools 35.0.0/36.0.0、platform-tools、cmdline-tools latest | `D:\dev\android-sdk` |
| Gradle 用户缓存 | — | `D:\dev\gradle-home` |
| 下载缓存（安装包） | Flutter 1.84 GB / JDK 178 MB / cmdline-tools 146 MB | `D:\dev\downloads` |

已持久化的**用户级**环境变量：

```
JAVA_HOME            = D:\dev\jdk\jdk-17.0.20.1+1
ANDROID_HOME         = D:\dev\android-sdk
ANDROID_SDK_ROOT     = D:\dev\android-sdk
PUB_HOSTED_URL       = https://pub.flutter-io.cn
FLUTTER_STORAGE_BASE_URL = https://storage.flutter-io.cn
PATH += D:\dev\flutter\bin; %JAVA_HOME%\bin; %ANDROID_HOME%\platform-tools; %ANDROID_HOME%\cmdline-tools\latest\bin
```

## 二、构建与测试

```powershell
# 构建 debug APK（产物回传到 dsh-mobile\dist）
install\build-apk.ps1 -Mode debug

# 构建 release APK
install\build-apk.ps1 -Mode release

# 运行 App 协议层的端到端集成测试（需先启动桥）
node bridge\src\bridge.mjs serve        # 另开终端
install\run-integration-test.ps1
```

## 三、踩到的坑（每一个都真的卡住过）

### 1. 中文项目路径 —— 构建与分析器都会崩

**现象 A**（Gradle 构建）：

```
Your project path contains non-ASCII characters. This will most likely cause
the build to fail on Windows. Please move your project to a different directory.
See http://b.android.com/95744
```

**现象 B**（`flutter analyze`）：

```
FormatException: Unterminated string (at character 610)
...%E6%96%B0%E5%BB%BA%E6%96%87%E4%BB%B6%E5%A4%B9/dsh-mobile/app/"}],"capabilities
#0 _ChunkedJsonParser.fail ...
```

原因是 analysis server 的 LSP 通道按字节长度分帧，而路径被百分号编码后字节数错位。

**解法（本项目采用）**：源码留在工作区，**构建与测试在 ASCII 副本里进行**，产物回传 `dist/`。
`install/build-apk.ps1` 与 `install/run-integration-test.ps1` 都内置了这一步（robocopy 同步到 `D:\dev\build\app`）。

> 另一种写法是在 `android/gradle.properties` 加 `android.overridePathCheck=true`，
> 但 AGP 原文说的是 "will most likely cause the build to fail"——只是关掉检查，并不解决问题。本项目没有采用。

> ⚠️ **同类坑（第二轮新踩，比上面两个更隐蔽）**：**不要用 PowerShell 批量改 Dart 源码**。
> 本机 PowerShell 是 5.1，`Get-Content -Raw` 按 ANSI 读无 BOM 的 UTF-8 文件 →
> 读出来就是乱码，`Set-Content` 写回就**永久损坏**。
> 本次一次性损坏了 `expert_page.dart` / `library_page.dart` / `project_page.dart` 三个文件
> （表现为注释里出现 `锛` `鈥` 之类字符），靠 `D:\dev\build\app-local` 的镜像副本才救回来。
> → 改源码一律用编辑工具；批量改完跑一次 `python docs\check_encoding.py <lib 目录>` 自查。

### 2. Gradle 官方源不可达 —— 必须换镜像

`gradle-wrapper.properties` 默认指向 `https://services.gradle.org/distributions/gradle-9.3.1-all.zip`。
本机实测：

```
[ERR] gradle 官方        11554ms  fetch failed
[206] gradle 腾讯镜像      320ms  (224.0MB)
```

**解法**：改成

```
distributionUrl=https\://mirrors.cloud.tencent.com/gradle/gradle-9.3.1-all.zip
```

另外 `mavenCentral()` 与 `google()` 实测可达，无需改仓库。

### 3. Kotlin 增量编译在本机必坏 —— 关掉它

**现象**：

```
Caused by: java.lang.AssertionError: java.lang.Exception: Could not close
incremental caches in ...\build\shared_preferences_android\kotlin\
compileDebugKotlin\cacheable\caches-jvm\jvm\kotlin:
class-fq-name-to-source.tab, source-to-classes.tab, internal-name-to-source.tab
> Execution failed for task ':shared_preferences_android:compileDebugKotlin'
```

`flutter clean` 之后**仍然复现**，所以不是缓存脏，而是增量编译在该环境下无法工作。

**解法**：在 `android/gradle.properties` 中

```properties
kotlin.incremental=false
kotlin.compiler.execution.strategy=in-process
```

代价是 Kotlin 部分每次全量编译（本项目约多花 1–2 分钟），换取构建可靠。

### 4. PowerShell 把 Flutter 的正常警告当成致命错误

Flutter 每次都会往 stderr 写：

```
Flutter assets will be downloaded from https://storage.flutter-io.cn. Make sure you trust this source!
```

如果脚本里写了 `$ErrorActionPreference = 'Stop'`，这会以 `NativeCommandError` 中止整个脚本
——构建根本没开始就"失败"了。脚本里已显式去掉该设置，改为检查 `$LASTEXITCODE`。

### 5. 代码级：`Clipboard` 不在 material 里

```
lib/ui/pair_page.dart:135:40: Error: The getter 'Clipboard' isn't defined for the type '_PairPageState'.
```

`Clipboard` 来自 `package:flutter/services.dart`，需要显式 import。

## 四、验证结果

| 验证项 | 结果 |
|---|---|
| `flutter build apk --debug` | ✅ 成功，产物 152.9 MB |
| `flutter build apk --release` | 见 `dist/` |
| APK 结构 | ✅ `classes.dex`、三个 ABI 的 `libflutter.so`、`AssetManifest.bin`、`AndroidManifest.xml` |
| 桥 ↔ App 协议层集成测试 | ✅ `All tests passed!`（配对→握手→建会话→订阅→发消息→收 update→关闭） |

**尚未验证**：真机 / 模拟器上的 UI 渲染与交互（本机没有连接 Android 设备）。
协议层已被集成测试覆盖，但界面布局、软键盘行为、后台切换等需要在真机上确认。

## 四·补 · 本地运行时 APK 的构建与界面验证（第二轮补充）

### 构建（本地版，内嵌 node，**不是**上面那个远程桥版本）

```powershell
# 真机包（arm64）
install\build-local-apk.ps1 -Abi arm64-v8a -Mode release
# 模拟器包（x86_64，调试用）
install\build-local-apk.ps1 -Abi x86_64 -Mode debug
```

脚本会自己 robocopy 到 `D:\dev\build\app-local`、改写 `gradle.properties` 的
`dshAbi=`、`gradlew --stop`，产物回传 `dsh-mobile\dist\`。

### 两条闸 + 一次瘦身（2026-10-09 加，审计 P0-1 / P0-5）

**① 出包后核对**（`install\check-release.py`）：`build-local-apk.ps1` 把包放回
`dist\` 之后**立刻**核对，不过就 `throw`。它只认**包里的字节**：
`versionName` / `AndroidToolbox.assets` 每个 key 都在 `libapp.so` 里 /
`app/assets/**` 与包内逐名 **size + sha256** 一致。
（0.57 就是在这儿失守的：`libapp.so` 里少 `open-app.mjs` 一个字符串，
273 条测试全绿，真机上"打开本机应用"是死的。`-SkipVerify` 可跳过，默认不跳。
注：`open-app.mjs` 与「打开本机应用」已于 2026-10-10 按要求取消，但**这个检查保留** ——
  它抓的是"表里有、so 里没有"的形状，换任何一条资产都成立。）

**② 凭据边界的 node 测试**（`install\test-toolbox-node.mjs`）：`flutter test`
看不到 node 脚本，而 exec shim 的环境白名单与轮换代理的客户端令牌都住在那里。
`rebuild-and-verify.ps1` 会在**打包之前**跑它，不过就 `exit 1`。

**②-b 其它两个 node 侧测试**（同样是「`flutter test` 看不到」的脚本，手工跑）：

```sh
node install/test-make-pptx.mjs     # 25 项：PPT 排版引擎（容器/排版/设计/容错四层）
node install/test-zen-proxy.mjs     # 19 项：免密通道的形状（四工具、msg_ 请求 id、真流式、两种 403）
```

`test-make-pptx.mjs` 里那个 XML 良构校验器是**自写无依赖**的 —— 生成器最容易犯的错
（少一个闭合标签、属性漏引号、没转义的 `&`）都会让人**打不开文件**，而这在 `flutter test`
里看不出来。`test-zen-proxy.mjs` **只用本地假上游**，不许拿真上游当测试靶子。

**③ 运行时包瘦身**：`build-app-assets.ps1` 打完包会自动调用
`install\slim-runtime-zip.py`，把 Android 永远用不到的东西剔掉
（Windows 的 `.exe/.dll/.pdb`、source map、`.d.ts`、文档、测试目录…）。
实测 **157.9 MB → 33.7 MB（-78.7%）**，投影 APK **226.6 MB → 约 113.4 MB**。

```powershell
# 已经有一个 dsh-runtime.zip：只瘦身、不重新打包（几秒，不用等几分钟）
install\build-app-assets.ps1 -SlimOnly
# 想打原始（未瘦身）的包来 A/B 对比
install\build-app-assets.ps1 -Force -SkipSlim
```

排除规则**只存在于那份 python 里**（配 `install\test_slim_rules.py` 17 项 +
三重自检：包入口 / 静态引用 / 许可证）。**不要**在 ps1 里再写一份规则 ——
两份删除规则必然漂移，而漂移的那份会删掉承重的东西
（开发时就差一点删掉被 DSH 核心静态 import 的 `dsh-win32-process`）。

⚠️ 瘦身后**必须真机冒烟**（至少 `dsh --version` 与 `make-pptx`）——
脚本能证明"没有入口指向被删文件"，不能证明每条运行时代码路径都还走得通。
前置条件：`D:\dev\android-node\app-assets\dsh-runtime.zip` + `jnilibs\<abi>\libnode.so`。

### 界面验证工具（第二轮新增，都是纯 ASCII 的 .ps1 / .py）

| 脚本 | 用途 |
|---|---|
| `install\uitap.ps1 -Dump` | dump Flutter 语义树（带 bounds），确认"页面上到底有什么" |
| `install\uitap.ps1 -Label 专家 [-Long 6000]` | 按 label 点击 / 长按 |
| `install\shot.ps1 -Name page08_task -DestDir ...\docs\screenshots` | 截屏（先 pull 到 ASCII 目录再复制） |
| `docs\check_layout.py <截图> [设计稿]` | 逐行扫色带，输出每页横向色带分界线 |
| `docs\find_accent.py <截图...>` | 按品牌青色定位 logo / 选中态 / 主按钮 |
| `docs\check_encoding.py <lib 目录>` | 扫 dart 源码乱码标记（见 §三.1 的警告） |

**三个 UI 自动化的坑**（都踩过）：
1. Flutter 是自绘引擎，默认 `uiautomator` 读不到文字 —— `main.dart` 里已 `ensureSemantics()`。
2. 软键盘弹出会让整页上移约 **820px**（输入行 y=2025 → y=1207）→ 每次点击前重新 dump。
3. `adb shell input keyevent KEYCODE_BACK` **连按两次会直接退出 App** → 截图会变成桌面。
   退页面一律用语义树里的 `返回`。



## 五、Android 侧的关键配置（已写入源码）

`android/app/src/main/AndroidManifest.xml`：

- `INTERNET`、`ACCESS_NETWORK_STATE` 权限；
- `android:usesCleartextTraffic="true"` —— 桥在局域网/Tailscale 内用明文 `ws://`，
  Android 9+ 默认禁止明文，不放行就连不上；
- `android:allowBackup="false"` + `fullBackupContent="false"` ——
  防止设备凭据被云备份还原到新机（会导致签名/凭据错位的"神秘 401"）。
