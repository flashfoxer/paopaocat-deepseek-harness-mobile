# 泡泡猫的 DSH · 0.09 版本说明（对照用户反馈逐条）

> **0.10（进行中）**：0.09 交付后用户又提了一批，见文末「附录：0.10 改动」。版本号已改为
> `kAppVersion = '0.10'` / `pubspec version: 0.0.10+10`；**按用户要求暂不打包**。

## 交付包（0.09）

| 项 | 值 |
|---|---|
| 文件 | `dist/paopaocat-preview-0.09-arm64-v8a.apk` |
| 大小 | 196,628,425 字节（187.5 MB） |
| sha256 | `42E1442E5936146654CA8B4DA9FA5B0326F277AE9A02FF764C198B03F05D871B` |
| versionCode / versionName | **9** / 0.0.9（首页显示 `v0.09`） |
| 签名 | Android Debug 证书 `7aaf444815ac78e3396ed5e95bd4e8f483745254559615d1bfd5f20180d3cc17` |
| **覆盖安装** | ✅ 与上一版交付包（0.08 arm64）**同一签名**、versionCode 更大 → 可直接覆盖安装，**不需要先卸载**（卸载会清掉 App 私有目录里的会话与配置） |
| 包内容核查 | 15 个 arm64 原生库（含 `libnode.so` / `libz1.so` / `libssl3.so`）、**0 个 x86_64 库**、12 个 `SKILL.md`、5 个工具箱脚本、`dsh-runtime.zip`、AOT `libapp.so`；清单含 `enableOnBackInvokedCallback=true` + `FileProvider` + 保活前台服务权限 |
| release 变体风险 | 签名走 debug keystore（项目既有做法）、**未开 R8/minify** → release 与 debug 的差异只有 Dart AOT 优化，无混淆裁剪风险 |

验证脚本：`install/verify_009_headless.py`（非 UI）、`install/verify_009_ui.py`（UI+logcat）、
`install/verify_009_firstrun.py`（首启）、`install/verify_009_model_sheet.py`（模型列表里的轮换组）。

---

> 版本：**0.09**（`app/lib/app_version.dart` 的 `kAppVersion`，与 `app/pubspec.yaml` 的 `version: 0.0.9+9` 同步）
> 打包名约定（用户 2026-10-04 要求）：**`paopaocat-preview-<版本>-<abi>[-debug].apk`**
> 例：`paopaocat-preview-0.09-arm64-v8a.apk`（真机）、`paopaocat-preview-0.09-x86_64-debug.apk`（模拟器）
> 由 `install/build-local-apk.ps1` 从 `kAppVersion` 推导并自动清掉旧命名的历史包。

---

## 用户反馈 → 实现位置 → 验证状态

| # | 用户原话（要点） | 实现位置 | 验证状态 |
|---|---|---|---|
| 1 | 产物无法分享出去 | `MainActivity.kt` 新增 `shareFile`（ACTION_SEND + FileProvider + chooser）；`DshHost.shareFile`；`artifact_opener.dart` 的 `ArtifactOpener.share`；产物卡片/消息产物行/预览页加了分享入口 | 代码 + analyze；**真机分享面板未验证** |
| 2 | 生成的是 HTML，打开却是代码 | `library_page.dart`：`.html/.htm` 主路径改走 **App 内 WebView** 渲染（`webview_flutter`），工具栏给「查看源码」「浏览器打开」两条备用路径 | 代码 + analyze；**真机渲染未验证** |
| 3 | 明确要求 PPT，却生成不了 | ① `assets/toolbox/make-pptx.mjs`（纯 node 自写 ZIP+OOXML，真 .pptx）；② `assets/toolbox/android-exec-shim.cjs`（Android 没有 bash，DSH 的 bash 工具写死 spawn `"bash"` → 改写为 `/system/bin/sh`，并让 shell 能直接调 `node`）；③ 12 个内置技能随包装入 `<DSH_HOME>/skills`（`data/builtin_skills.dart`）；④ `AGENTS.md` 里写明"要 PPT 就用 make-pptx.mjs，不许拿 HTML 顶替" | ✅ **本机三重验证**：python-pptx 断言 + **真实 PowerPoint 打开并导出 PNG/PDF** + PDF 抽文字（中文/项目符号/备注都对）。**真机 shim 未验证** |
| 4 | 首次安装必须配模型，否则「开始准备」点不动 | `task_home_view.dart`：没有模型时不再静默进对话页，而是**明确说明 + 只给一条出口（去设置）**；首页加常驻提示 | 代码 + analyze；**真机点击未验证** |
| 5 | 配好一个模型后，无法再选其他厂家 | `settings_tab.dart` 重做模型区：按厂家分组的「我的模型」、`+ 添加厂家/模型`、编辑厂家、删除；`_upsertProvider()` **只动本厂家，其它厂家与轮换组原样保留**；Key 按厂家存安全区（`state/provider_keys.dart`）；overlay 一次写全部厂家（`DshRuntime.writeOverlayFromConfig`） | 代码 + analyze + upsert 代码证据；**真机未验证** |
| 6 | 设立「模型轮换组」（如 cat：429 时自动换下一个，显示在模型列表） | `assets/toolbox/rotate-proxy.mjs`（OpenAI 兼容本地代理，按顺序故障转移 + 粘性）；`local/rotation_proxy.dart`（起代理、挑端口、等就绪）；overlay 里把组注册成 `rotate/<组名>`；`ConfiguredConfig.choices` 让组**和普通模型一样出现在模型列表**；设置页组管理界面 | ✅ 代理**本会话独立复跑**：429 → 自动切第二个成员 → 客户端只看到 200；日志 `[rotate] cat: a/fake-down 失败(429)，改用 b/fake-up`；全失败 → 沿用上游 429。**真机未验证** |
| 7 | 内置 Agnes：注明免费 + 注册地址 + 生图/生视频端点，用户要图/视频时自动调用 | `data/agnes_builtin.dart`（端点/注册地址/模型名/免费口径）；`assets/toolbox/make-image.mjs`、`make-video.mjs`；环境变量注入（`DshRuntime._environment` + `ProviderKeys.envFor`）；`AGENTS.md` 里写"要图/视频直接跑脚本，不许只给提示词"；技能 `make-image`/`make-video` | 脚本请求形状/轮询/下载/失败路径全过（本地假上游 60 项断言）；无 Key 时**如实报错并给出注册地址**（本会话复跑）。**真实 Key 未验证** |
| 8 | 首页 4 条内置会话"只填了几个字"、换一换只是换顺序；改 12 条 | `data/builtin_starters.dart`（12 条池子，每条绑一个技能 + 点名技能的提示词）；`data/builtin_skills.dart`（12 个技能装到设备）；首页一次显示 6 条、「换一换」换**一批不同的**；`assets/skills/<name>/SKILL.md` × 12 | 代码 + analyze；**真机未验证** |
| 9 | 打包名称统一为 `paopaocat preview + 版本号` | `install/build-local-apk.ps1`：从 `kAppVersion` 读版本 → 产出 `paopaocat-preview-<版本>-<abi>[-debug].apk`，并清理 `dsh-local-*.apk` / `app-*.apk` 历史命名；顺带核 pubspec 版本与 versionCode 是否同步（只警告） | 命名推导与语法检查已实测（`paopaocat-preview-0.09-arm64-v8a.apk`）；**未真正打包**（用户要求先不打包） |
| 10 | 边缘侧滑一下就把 App 退到后台；要改成「再滑一次才退」 | `MainActivity.kt`：注册 `OnBackInvokedCallback`（API 33+，`onPostResume` 里注册以压过引擎自己的回调）+ 覆写 `onBackPressed`（旧系统）；收到返回就通过方法通道问 Dart `shouldExitOnBack`，Dart 回 true 才 `moveTaskToBack(true)`（=退到后台）。Dart：`DshHost.onSystemBack` + `app_shell.dart` 的 `_shouldExitOnBack()`（先关 push 进来的页面 → 不在首页先回首页 → 首页上两次才退，第一次弹提示）。`AndroidManifest.xml` 加 `android:enableOnBackInvokedCallback="true"` | ✅ 设备实测三例：首页按一次 → 弹「再滑动（或按返回）一次就退出 App（会退到后台）」且**留在 App**；2 秒内再按一次 → **退到后台**（前台窗口变成 launcher）；在「资料库」按返回 → 日志 `返回：先切回首页（当前 2）`，不退出 |

---

## 新增/改动的文件

**新增（App 侧）**
- `lib/data/configured_models.dart` 重写为 **v2**：多厂家 + 轮换组 + v1 自动迁移（Read 保留兼容视图）
- `lib/state/provider_keys.dart`：每个厂家各自的 Key（安全区），带老 Key 迁移
- `lib/local/android_toolbox.dart`：把 `assets/toolbox/**` 落到 `<filesDir>`（幂等）
- `lib/local/rotation_proxy.dart`：轮换代理的进程生命周期
- `lib/data/agnes_builtin.dart`：Agnes 内置常量与免费口径原文
- `lib/data/builtin_skills.dart`：内置技能安装（带哈希清单，**用户改过的不覆盖**）
- `lib/data/builtin_starters.dart`：首页 12 条内置会话池

**新增（随包资源 `assets/toolbox/`，纯 node 内置模块、零 npm 依赖）**
- `android-exec-shim.cjs`：`bash`→`/system/bin/sh`、`node`→随包 libnode.so（补 `--expose-internals --require fs-shim`），并把父进程环境合并给子进程（DSH 会剥掉 `DSH_*` 与敏感变量）
- `make-pptx.mjs`：JSON 大纲 → 真 .pptx
- `rotate-proxy.mjs`：模型轮换代理
- `make-image.mjs` / `make-video.mjs`：Agnes 生图 / 生视频

**新增（`assets/skills/`：12 个内置技能）**
`make-slides` / `make-image` / `make-video` / `data-analysis` / `doc-processing` / `doc-digest` / `sheet-cleanup` / `code-tool` / `file-organize` / `translate-polish` / `study-cards` / `weekly-report`

**新增（验证脚本）**
- `install/verify_009_headless.py`：设备侧非 UI 验证（工具箱/技能/overlay/shim/pptx/Agnes 无 Key 报错）
- `install/verify_009_ui.py`：界面侧验证（首页 12 条与会换一批、设置页多厂家与轮换组、logcat 自证日志）

---

## 关键技术事实（别再踩）

1. **Android 上没有 bash**：`@deepseek-ai/dsh-bash-local` 写死 `spawn("bash", ["-c", cmd])`；设备只有 `/system/bin/sh`（mksh）。**POSIX 语法**，mksh 里**函数名不能带横线**。
2. **Android 禁止执行 App 数据目录里的文件**（SELinux `app_data_file` 无 execute），所以 shim 只能在 `node --require` 里改 `child_process`，不能往 `filesDir` 放一个 `bash`。
3. **`node --require` 的改写对 DSH 有效**：DSH 用 ESM 具名导入 `import { spawn } from "node:child_process"`，实测拿到的是改写后的函数。
4. **DSH 会剥环境变量**：`@deepseek-ai/dsh-subprocess` 的 `scrubbedParentEnv()` 去掉所有 `DSH_*` 与敏感变量 → 所以 shim 里显式合并 `process.env`，否则 `AGNES_API_KEY` 到不了 shell。开关：`DSH_ANDROID_ENV_PASSTHROUGH=none|前缀白名单`。
5. **overlay 里不能出现空的 `models:`**（YAML null 会让整份配置校验失败 → 对话全废）。`writeOverlayFromConfig` 只写"真的有模型"的厂家，全空时拒绝写入。
6. **Agnes 的两处官方口径**（`https://agnes-ai.cn/zh-Hans/docs/*.md`）：参考图与 `response_format` 都必须在 `extra_body` 里（顶层是官方点名的错误写法）；视频 `size` 只能是 `"720P"`、`seconds` 是字符串、三种 mode 互斥、完成时读**顶层 `url`**。
7. **免费口径照抄官方**：图像"所有支持的输出分辨率档位和输入参考图片当前均免费"；视频"原价 ¥0.15/秒，现价 ¥0/秒"，并注明"免费政策如有调整，以 Agnes AI 平台最新公告为准"。**界面与提示里不许写"永久免费"。**
8. **`.ps1` 必须纯 ASCII**：PowerShell 5.1 读 BOM-less UTF-8 且含中文会崩（`build-local-apk.ps1` 已核对 non-ASCII = 0，且通过 parser 语法检查）。

---

## 怎么验证 / 怎么打包

```powershell
# 1) 静态检查（必须在 ASCII 镜像里跑，中文路径会让 analyze 挂）
robocopy "<repo>\app" D:\dev\build\app-main /MIR /XD build .dart_tool .idea .gradle
& D:\dev\flutter\bin\flutter.bat analyze      # 期望：No issues found!

# 2) 模拟器包（验证用；用户要求"先不要急着打包"，所以这步只在需要验证时做）
install\build-local-apk.ps1 -Abi x86_64 -Mode debug
#   → dist\paopaocat-preview-0.09-x86_64-debug.apk

# 3) 设备侧验证（非 UI + UI）
python install\verify_009_headless.py            # 工具箱/技能/overlay/shim/pptx/Agnes
python install\verify_009_ui.py                  # 首页 12 条 / 设置页多厂家与轮换组 / logcat

# 4) 真机包（等用户说可以打包）
install\build-local-apk.ps1 -Abi arm64-v8a -Mode release
#   → dist\paopaocat-preview-0.09-arm64-v8a.apk
```

---

## 真机（模拟器 x86_64）实测结果 — 2026-10-04

包：`dist/paopaocat-preview-0.09-x86_64-debug.apk`（249.9 MB，覆盖安装保留数据）
脚本：`install/verify_009_headless.py`（非 UI）、`install/verify_009_ui.py`（UI + logcat）

**已实测通过**

| 项 | 证据 |
|---|---|
| ① 产物分享 | 预览页点「分享」→ 原生日志 `shareFile -> …/demo.html (text/html)`、Dart 日志 `[dsh-library] 分享 demo.html -> ok`、前台窗口变成 `com.android.intentresolver/.ChooserActivity`（系统分享面板真的弹出） |
| ② HTML 预览渲染 | 工作区放入自包含 `demo.html` → 资料库点开 → 预览页标题 `App 内网页预览 · 304 B`，含「查看源码」「浏览器打开」「分享」→ **走的是渲染路径，不是源码视图** |
| ③ 真 PPT | 模型自己在设备上跑 `bash` → `node v26.4.0` → `make-pptx.mjs`，产出 **9103 字节真 .pptx**（ZIP 魔数 `PK`），并自己解包验证了内部中文内容 |
| ④ 首启引导 | 把 `models.json` / 模型 overlay / `shared_prefs` 一起挪走（等效全新安装）→ 首页出现常驻提示「还没有可用模型 · 去设置」；点「开始新会话」弹出说明层（「还没有配置模型 / 现在一个模型都没有，开始会话也没法回话。/ 去「设置 → 模型」：选一家服务商，填上 API Key，点测试并保存」+ 按钮「去设置」「知道了」）；点「去设置」**真的切到设置页**。验完已原样恢复 |
| ⑤ 多厂家并存 | 设置页可见「+ 添加厂家/模型」「编辑」「删除厂家」「来自本机安全存储（这家厂家自己的那把）」，两家厂家卡片并存 |
| ⑥ 轮换组 | ① 代理就绪 + 真实请求 fallback：`[rotate] cat: bogus/nope-model 失败(ECONNREFUSED)，改用 com/…` → `成功（第 2 个成员顶上）`；② **模型列表里显示为「轮换组 cat · 轮换组 · 2 个模型」**，点选后弹「已切换到 cat，正在重建会话…」、无 flutter 异常、日志 `overlay 已重写：默认=rotate/cat … 轮换代理端口=39321` |
| ⑦ Agnes 预设 | 设置页可见「一键添加 Agnes（免费）」「复制地址」「https://platform.agnes-ai.cn」；设备上无 Key 时脚本如实报错并给出注册地址 |
| ⑧ 12 条内置会话 | 首页一次显示 **6 条** + 小字「点一条 → 带着对应技能的指令开新会话」；点「换一换」后 6 条里**换掉 4 条**；12 个技能设备上「新增 12 / 失败 0」 |
| ⑨ 打包名 | 产出 `paopaocat-preview-0.09-x86_64-debug.apk`，旧命名包被移到 `dist/_old-names/`（**移动，不删除**） |

**真机验证抓出来、已修的真 bug（这些不修会直接发版翻车）**
1. **Flutter 不打包子目录资源**：pubspec 写 `- assets/skills/` 时 12 个技能一个都没进 APK（`Unable to load asset`）。改成逐个目录列出。
2. **脚本入口守卫在 App 里失效**：`rotate-proxy.mjs` 用 `import.meta.url` 对比 `argv[1]`；App 用 `Process.start` 直接 spawn 时不相等 → node **启动、不打印、exit 0**（代理"起不来但没报错"）。加按文件名的兜底判断。
3. **`runOnce` 丢"秒退进程"的输出**：退出事件先于 stdout 数据，旧代码立刻 cancel 订阅 → 读回空串。改成等管道排空（`asFuture`）。
4. **代理被未捕获异常打死**：DSH 请求触发某个未捕获 `error` 时 node 直接 `exit=1`，会话侧只看到 `TRANSPORT: Connection error`。代理加了 `uncaughtException` / `unhandledRejection` 兜底（只记日志、进程不死），并让 Dart 侧**持续订阅**代理 stderr（原来就绪后 cancel 掉，崩溃时什么都看不到）。
5. **`readRotatePort` 抓错端口**：全文匹配第一个 `127.0.0.1` 会把"用户自己配的本地端点"当代理端口，导致每次启动都白重写 overlay。改成只在 `rotate:` 段落里读。
6. **App 重写配置会抹掉代理的 `lastGood`**（代理学到的"哪个成员能用"被清空）。改成读-改-写，保留该字段。
7. 验证脚本自身的坑：`adb push/pull` 不认中文路径（要经 ASCII 临时目录）、`LD_LIBRARY_PATH` 要指到 `lib/<abi>/`、toybox 的 `grep -E` 在复杂 ERE 上会 segfault、冷启动时 `uiautomator dump` 返回空树（要按"真的有文字"重试）。

**仍未实测**
- 模型面板里"组"那一项的小角标 —— **已实测**（见上表 ⑥ 第 ② 条）。
- 真机 arm64（本轮机器上没有连 arm64 设备）。
- Agnes 真实出图/出视频（没有真实 Key）。
- `lastGood` 保留那一项：代码 + analyze 已过，但设备上"强制 App 重跑配置写入"没跑成（前台服务保活），留到打包后复验。
- ⑩ 的**侧滑手势**本身：设备上用 `input keyevent 4`（同一个返回通道）验的；真实手指在屏幕边缘侧滑没有自动化手段，逻辑走的是同一条回调。

---

**仍未实测**

- **真机**：分享面板、WebView 渲染、mksh 实际行为、Android 上的 node 版本、SIGTERM 优雅关闭。
- **Agnes 真实生成**：没有真实 API Key；只验证了请求形状/轮询/下载/失败路径（本地假上游）。视频接口是否接受 Data URI 素材，官方只对图片明确支持，脚本会打一行 stderr 警告。
- **gradle 集成**：`webview_flutter` 在本项目的 AGP/Kotlin 组合下未构建验证。
- **UI 交互的真机效果**（多厂家保存后第一家是否仍在、换一换是否真换一批）依赖设备实测。

---

# 附录：0.10 改动（用户 2026-10-04 在 0.09 基础上继续提的）

`kAppVersion = '0.10'`、`pubspec version: 0.0.10+10`。

## 0.10 交付包（已出，用户 2026-10-04 说「打包」后产出）

| 项 | 值 |
|---|---|
| 文件 | `dist/paopaocat-preview-0.10-arm64-v8a.apk` |
| 大小 | 196,674,397 字节（187.6 MB） |
| sha256 | `357744A73731E7ED55B1EDAB04ACAE0DF1AE300C35C0B581CF4F3D52C84DCBD7` |
| versionCode / versionName | **10** / 0.0.10（首页显示 `v0.10`） |
| 签名 | `7aaf444815ac78e3396ed5e95bd4e8f483745254559615d1bfd5f20180d3cc17` —— 与 0.08/0.09 **同一把**，可直接覆盖安装（不用卸载，卸载会清掉会话与配置） |
| 包内容核查 | 15 个 arm64 原生库（含 `libnode.so` / `libz1.so`）+ AOT `libapp.so`、**0 个 x86_64 库**、12 个 `SKILL.md`、5 个工具箱脚本、`dsh-runtime.zip`；清单含 `enableOnBackInvokedCallback=true` + `FileProvider` |
| 打包前状态 | `flutter analyze` 0 error/warning/info、17 个单测全过、x86_64 debug 构建通过（同时验证了 Kotlin 侧 `openUrl`） |


| # | 用户原话（要点） | 实现 | 状态 |
|---|---|---|---|
| 11 | 「会话页面切换模型就会重建会话，修复这个问题」 | 改用 **ACP 会话内配置项**：`session/set_config_option`（`configId=model`，值 `["provider","model"]`）——`acp_client.dart` 新增 `setConfigOption/setSessionModel`；`chat_page.dart` 的 `_onModelStoreChanged` → 先 `_switchModelInPlace()`，**成功则会话与历史全保留**（提示「已切换到 X（会话保留）」），失败才回退重建并如实说明 | ✅ 代码 + analyze；**设备未验** |
| 12 | 「首页的内置对话改为 4 个一组」 | `builtin_starters.dart`：`visibleCount = 4`、`shuffleStep = 4` → 12 条切成 3 组互不重复；`task_home_view.dart` 的「换一换」改回 `nextStart + windowFrom`（一次换一整组，点 3 次看全） | ✅ 代码 + analyze；**设备未验** |
| 13 | 「语音识别无法使用，是否可以内置」 | 查证：DSH 自带本地 SenseVoice（sherpa-onnx）**Android 不可用**（原生包只面向 macOS / Linux glibc / Windows；int8 模型 239MB）。按用户选定方案 ① 实现：`MainActivity.recognizeSpeech` **优先 Android 12+ 设备端离线识别**（`isOnDeviceRecognitionAvailable` + `createOnDeviceSpeechRecognizer`），失败回退原系统 Intent；语言改为跟随设备语言；识别器用完即 `destroy()` | ⏳ **代码已改，Kotlin 编译未验**（见下"树为什么暂时是红的"） |
| 14 | 「看 soft.zmm168.top 的风格，按那个风格改界面；设置分三个按钮：浅色、深色、自定义（占位）」 | 已扒到该站真实令牌（浅底 `#eef3fb`、半透明白面板 `rgba(255,255,255,.72)`、细边 `rgba(32,74,150,.15)`、主色青 `#0891b2` + 紫 `#7c3aed` + 粉 `#db2777`、圆角 16/10/24、代码块深蓝 `#0f1729`）；交给子代理落地两套皮肤 + 三档切换 | 🔄 子代理进行中 |
| 15 | 「模型设置页面过于凌乱，规范化一下，一目了然」 | 分节重排（当前模型 → 我的模型 → 轮换组 → 添加模型（默认收起）→ 内置 Agnes）、提示框统一三态、功能一个不丢 | 🔄 排队给同一个子代理（同一个文件，避免撞车） |
| 16 | 「插件栏目表述有问题（把"按你的要求先留占位"取掉）」 | 改成面向用户的诚实表述（"插件安装暂未开放（需要对插件做安全校验与回滚，做完再放出入口）"），入口继续置灰 | 🔄 同上 |

## ⚠️ 当前工程为什么暂时编不过（接手别再猜）

第 14 条的主题改造要把"全局静态配色"变成**可运行时切换**，于是 `DshColors.x` 不能再是 `const`，
而它散在二十来个 UI 文件里（大量 `const TextStyle(color: DshColors.x)`）。子代理清理的过程中，
`flutter build` 会报一串 `Constant evaluation error` **属预期中间态**，不是谁的改动坏了。
判断方法：`flutter analyze` 会指出每一处待去掉的 `const`。

**接线核对（等它交付后按这个顺序验）**：
1. `flutter analyze` 必须 0 error / 0 warning / 0 info；
2. `flutter test test/api_error_text_test.dart`（已有的 6 条错误翻译测试，别改它）；
3. `install\build-local-apk.ps1 -Abi x86_64 -Mode debug` → **这一步同时验证第 13 条的 Kotlin**（Kotlin 只能靠构建验）；
4. 装模拟器 + `install\verify_009_ui.py` 看首页「4 个一组」；会话内切模型要人工点一次（看是否还有"正在重建会话"）；
5. 语音：模拟器大概率没有离线识别模型，**要真机才能验**（没有 arm64 设备时应如实说明）。

## 0.10 已经跑过的验证（在有主题改动之前）

- `flutter analyze`：**No issues found!**（第 11/12 条落地后、主题开工前）
- `flutter test test/api_error_text_test.dart`：6/6 通过（含用户真机那条 `no credential for provider route "agnes"` 的**原文**断言）

