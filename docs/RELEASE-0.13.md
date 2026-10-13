# 0.13 —— 会话里到底能不能跑命令 / 切模型为什么要选两次

> 版本：`kAppVersion = '0.13'`、`pubspec 0.0.13+13`、`versionCode 13`
> 交付包：`dist/paopaocat-preview-0.13-arm64-v8a.apk`（187.6 MB，
> sha256 `7E445C22754074DA1814B6C34CB465AC95BE713E688A6CF4AC37BF7AB6F906BF`，
> 签名与 0.12 **同一把**（`7aaf4448…cc17`）→ 直接覆盖安装，不用卸载）
> 用户反馈（真机截图原文）：
> ① 「画图好像不能用」—— App 里的会话回了
> `node "$DSH_ANDROID_TOOLBOX/make-image.mjs"` 这条命令**一条都发不出去**，
> 报错就是 `spawn bash ENOENT`；
> ② 「切换模型的时候选一次，不行，需要选第二次才可以切换模型」。
> 另外用户要求：**「分享运行日志」弹窗里加上开发者邮箱**。

环境：`emulator-5554`（x86_64 Android 14，adb root）+ 本机假模型端点
（`install/fix13_fake_model.py`，`adb reverse tcp:8891`）。修前/修后都在**同一台设备**上跑。

---

## 1. 结论（先看这段）

| # | 用户看到的现象 | 根因 | 状态 |
|---|---|---|---|
| ① | 画图 / 生成 PPT / 任何要跑命令的事都失败（`spawn bash ENOENT`） | **会话进程（ACP）自己拼了一份精简环境**：既没挂执行环境 shim，也没有 `DSH_ANDROID_*` 四件套 / `DSH_ANDROID_TOOLBOX` / `AGNES_*`。shim 的设计是"四个变量齐全才生效"，缺一个就**完全不改写**；于是 DSH 的 bash 工具照旧去 spawn 一个 Android 上根本不存在的 `bash` | ✅ 已修 + **设备端到端验证**（§3.1） |
| ② | 切模型选一次不生效，要选第二次 | 两个独立成因叠加：**(a)** `ModelStore.selectModel` 先 `notifyListeners()` 再落盘 → 会话页收到通知时去重读 `models.json`，读到的还是**旧** selected，overlay 也就按旧的对账；**(b)** `_applyModelChange` **只在"配置变了"时**才同步 overlay，而"这个模型当场切不过去 → 重建会话"这条路上没有同步 → 新进程读到的还是**旧默认路由** | ✅ 已修 + **设备端一次点击验证**（§3.2） |
| ③ | （新要求）弹窗里要有开发者邮箱 | —— | ✅ 已加 + 设备上截图核验（§3.3） |

顺带查出来但**这版没动**的一个问题：ACP 启动时 stderr 有
`permission (@deepseek-ai/dsh-permission-presets): Error: composed sandbox and approval
defaults match no preset; configure defaultPreset explicitly`（`dsh: warning: 1 entry did
not activate`）。见 §5「没修的」。

---

## 2. 根因与证据

### 2.1 ① 会话里为什么一条命令都跑不了

**修前** `lib/local/acp_client.dart` 的 `AcpClient.start()` 是**自己拼一份 env**：

```dart
final args = <String>['--expose-internals', '--require', fsShim, dshBin, '--profile', 'acp', …];
final env = <String, String>{
  'LD_LIBRARY_PATH': nativeLibDir, 'DSH_HOME': dshHome, 'HOME': filesDir,
  'PATH': '/system/bin:/system/xbin', 'TMPDIR': '$filesDir/tmp',
  …apiKey / apiKeys…
};
```

而 `DshRuntime.spawn()`（headless / 定时任务 / 轮换代理那条路）是**另一套**：

```dart
'--require', fsShim, '--require', execShimPath,        // ← 会话这边没有 execShim
'DSH_ANDROID_NODE_BIN', 'DSH_ANDROID_FS_SHIM',
'DSH_ANDROID_EXEC_SHIM', 'DSH_ANDROID_TMPDIR',        // ← 会话这边一个都没有
'DSH_ANDROID_TOOLBOX', 'AGNES_BASE_URL', …
```

`assets/toolbox/android-exec-shim.cjs` 顶部写死了行为：**「4 个变量齐全才启用改写；否则完全透传」**
（`const ACTIVE = MISSING.length === 0`，见该文件 100~102 行）。所以会话进程里
`child_process.spawn('bash', …)` 原样发出 → Android 上没有 `bash` → `ENOENT`。

这解释了两个看起来矛盾的现象：
* 同一个 App 的**定时任务 / 轮换代理**那条路一直是好的（它走 `DshRuntime.spawn`）；
* 而"12 个内置技能"全都写着 `node "$DSH_ANDROID_TOOLBOX/make-image.mjs"` —— 在会话里必然发不出去。

**修法**：`AcpClient.start()` 改成接**整个 `DshRuntime`**，把 `runtime.environment`
（含 DSH_ANDROID 四件套 + 工具箱 + Agnes + 每厂家 Key）**照搬**，并挂上 `execShimPath`；
调用前先 `AndroidToolbox.ensureInstalled()`（否则 `--require` 的路径还不存在，node 会以
`Cannot find module … (internal/preload)` 退出）。这样"会话进程和别的进程环境不一致"这类
bug **从结构上**不可能再出现 —— 而不是再往那份手拼的 env 里补一行。

### 2.2 ② 一次点击为什么会引来两次通知

```
点模型行 → ModelStore.selectModel(e)
             ├─ _selected = e
             ├─ notifyListeners()          ← 通知 1（旧代码在这里就发了）
             ├─ 写安全区
             └─ 写 models.json.selected
         → Navigator.pop(e)
       → ChatPage._openModelSheet 拿到返回值
             └─ onModelChanged()           ← 通知 2（main 里 load() 又会 notify 一次）
```

旧代码里 `_openModelSheet` 里那句守卫是 `if (picked.id != widget.models.selected?.id) return;`
—— `picked` 就是刚选中的那个，**这个比较永远为假**，等于没有守卫。

而 `main._onModelChanged()` 的顺序是 `models.load()`（内部 `notifyListeners()`）**先**、
`applyModelSelection()` 写 overlay **后**。于是通知 1/通知 2 都可能落在
"内存里已切、盘上还没写 / overlay 还没重写"的窗口里。
`docs/model-routing-audit-0.11.md` §7 第 3 条已经把这条竞态写下来了，只是当时没改。

**修法（三处，缺一不可）**：
1. `ModelStore.selectModel()` 改成**先落盘、再 `notifyListeners()`**，并暴露
   `selectionSettled`（`Future`）—— 会话页在重写 overlay 之前 `await` 它；
2. `ModelStore` 新增 `reloadQuiet()` / `publish()`，`main._onModelChanged()` 改成
   **先写 overlay、再 publish**（顺序反过来就是 §2.3 那个"切了没生效"）；
3. `ChatPage._applyModelChange()`：**单飞 + 合流**（一次点击两次通知只跑一次，
   期间的请求合并成"再跑一次"）；并且**任何**重建之前都先同步 overlay
   （旧代码 `if (configChanged && …)` 才同步 —— "切不过去 → 重建"这条路上没有同步，
   新进程读的还是旧默认路由）。

### 2.3 还要"别再把假成功当成功"

`session/set_config_option` **返回成功 ≠ 切到了目标模型**：DSH 只认**进程启动时已注册**的
模型（`dsh-acp` 的 `AcpModelControl.set()`：`choices.get(value)` 取不到就抛
`unknown model option`）。而界面上的模型名来自本地 store，点一下就变了。

所以 `AcpClient.setSessionModel()` 现在**用运行时回的 `currentValue` 校验**：

```dart
final want = modelOptionValue(provider, model);      // '["provider","model"]'
final options = await setConfigOption(sessionId, 'model', want);
… for (o in options) if (o['id'] == 'model') return '${o['currentValue']}' == want;
```

对不上就如实返回 false → 走"重建会话"那条**一定生效**的路。
另外 `session/new` / `session/resume` 的返回里也带 `configOptions`，App 顺手记下
`acp.liveModelRoute`，logcat 里能看到 `运行时报=agnes/agnes-model` —— 这才是"在跑哪个模型"的证据，
界面上的选中项不是。

---

## 3. 验证（都是设备上跑出来的原文）

### 3.1 机制层：那份 shim 在 Android 上真的能改写

用**App 真正用的那个 libnode + 那两份 shim + 那套环境变量**（`run-as` 跑，
`install/fix13_shim_probe.js`）直接调 `child_process`：

```
[android-exec-shim] 已接管 child_process：spawn, spawnSync, execFile, execFileSync, exec, execSync
[android-exec-shim] spawnSync: "bash" → "/system/bin/sh"
[android-exec-shim] spawnSync: "node" → "…/lib/x86_64/libnode.so"
[bash-echo]   error=none status=0  stdout=DSH_SHIM_OK / TOOLBOX=…/files/toolbox / SH=/system/bin/sh / Linux
[bash-node]   error=none status=0  stdout=2
[node-direct] error=none status=0  stdout=NODE_DIRECT_OK
```

### 3.2 端到端：会话里真的跑起来了（这是"画图能用"的同一条链路）

假模型第一轮直接发 3 个 `bash` 工具调用（`echo` 自检 / `node -e` / `ls -l $DSH_ANDROID_TOOLBOX`），
第二轮把结果念回来。服务器侧打印的**工具结果原文**：

```
[fix13] POST /agnes/v1/chat/completions … tools=['bash', …] tool_results=0
[fix13] POST /agnes/v1/chat/completions … tool_results=3
[fix13] ---- 工具结果原文 ----
DSH_SHIM_OK
TOOLBOX=/data/user/0/com.dshmobile.dsh_mobile/files/toolbox
EXEC_SHIM=/data/user/0/com.dshmobile.dsh_mobile/files/shims/android-exec-shim.cjs
TMPDIR=/data/user/0/com.dshmobile.dsh_mobile/files/tmp
Linux localhost 6.1.23-android14-4… x86_64 Toybox
[fix13] ---- 工具结果原文 ----
NODE_OK v26.4.0
[fix13] ---- 工具结果原文 ----
-rw------- 1 u0_a192 u0_a192 17376 … make-image.mjs
-rw------- 1 u0_a192 u0_a192 40074 … make-pptx.mjs
-rw------- 1 u0_a192 u0_a192 23563 … make-video.mjs
-rw------- 1 u0_a192 u0_a192 29826 … rotate-proxy.mjs
```

同一进程的环境（`/proc/<pid>/environ`，即修复后的 ACP 进程）：

```
DSH_ANDROID_NODE_BIN  /data/app/~~…/lib/x86_64/libnode.so
DSH_ANDROID_FS_SHIM   /data/user/0/…/files/shims/android-fs-shim.cjs
DSH_ANDROID_EXEC_SHIM /data/user/0/…/files/shims/android-exec-shim.cjs
DSH_ANDROID_TMPDIR    /data/user/0/…/files/tmp
DSH_ANDROID_TOOLBOX   /data/user/0/…/files/toolbox
AGNES_API_KEY         audi***   ← Agnes 那把 Key 也在（make-image.mjs 就认它）
```

App 侧 logcat：
```
[chat][acp] spawn libnode.so --profile acp（已挂执行环境 shim，注入 5 个厂家环境变量）
[chat][acp] session created: … model=agnes/agnes-model
```

### 3.3 切模型：点**一次**就生效（`install/fix13_e2e.py`）

```
[chat] model changed -> agnes-m2                                   ← 两次通知（单飞后只跑一次）
[chat] 会话内切换模型成功：agnes/agnes-model2（会话未重建，已由运行时确认）
界面：「当前模型 agnes-m2」；**没有**出现新的「ACP session ready」→ 会话没重建、聊天记录留着
```

### 3.4 开发者邮箱（`install/fix13_verify_email.py`）

设置 → 关于 → 分享运行日志，弹窗 dump 出来的文本：

```
- 点下面按钮后会打开系统的分享面板：发给微信 / QQ / 文件传输助手 / 邮件都行，发给谁由你决定。
- 开发者邮箱：
- 25894126@qq.com          ← 可长按复制（SelectableText）
- 取消 / 生成并分享
```

### 3.5 回归

```
flutter analyze（镜像 D:\dev\build\app-fix13） → No issues found!
flutter test                                  → +66 All tests passed!
   （含新增 test/acp_model_route_test.dart 5 条：configOptions 解析 + modelValue 逐字一致）
   注：真跑全绿需要两个桥进程（8788 明文 + 8790 TLS），见 install/run-integration-test.ps1
包内容核查：仅 arm64-v8a、15 个原生库（含 libnode.so）、0 个 x86_64、
           12 个 SKILL.md、5 个工具箱脚本（含 android-exec-shim.cjs）、dsh-runtime.zip、
           versionCode=13/versionName=0.0.13、含 RECORD_AUDIO 权限
```

---

## 4. 改了哪些文件

| 文件 | 改了什么 |
|---|---|
| `lib/local/dsh_runtime.dart` | `_environment` → **公开** `environment`（含注释说明为什么公开），`spawn` 跟着改名 |
| `lib/local/acp_client.dart` | `start()` 改接 `DshRuntime`（整份 env + `--require execShim` + 先 `ensureInstalled`）；`setConfigOption` 返回 `configOptions`；新增 `modelOptionValue` / `modelRouteFromConfigOptions` / `liveModelRoute`；`setSessionModel` 变成**校验型**（返回 bool） |
| `lib/local/session_index.dart` | 跟着新签名传 `runtime:` |
| `lib/ui/pages/chat_page.dart` | `_start` 用整份 runtime；`_applyModelChange` 单飞+合流、任何重建前都同步 overlay；`_switchModelInPlace` 认运行时的确认；`_liveRoute` 记运行时实际在跑的模型；`_openModelSheet` 先 `await selectionSettled` 再 `onModelChanged`（顺手删掉那句恒假的守卫） |
| `lib/state/model_store.dart` | `selectModel` 先落盘再通知；新增 `selectionSettled` / `reloadQuiet` / `publish`；`load` 拆出 `_loadInto` |
| `lib/main.dart` | `_onModelChanged` 改成"先写 overlay 再 publish"；`_openSettings` 用 `reloadQuiet` |
| `lib/data/developer_contact.dart` | **新增**：`kDeveloperEmail = '25894126@qq.com'` |
| `lib/ui/widgets/send_log_button.dart` | 分享/导出弹窗末尾加一行「开发者邮箱：25894126@qq.com」（可选中复制） |
| `lib/app_version.dart` / `pubspec.yaml` / `lib/data/changelog.dart` | 版本 0.13 / versionCode 13 / 0.13 更新说明 5 条 |
| `app/test/acp_model_route_test.dart` | **新增** 5 条单测（钉死 configOptions 解析与 `modelValue` 的逐字一致） |
| `install/fix13_*.py`、`fix13_shim_probe.js`、`fix13_fake_model.py` | 本轮验证用的假模型 / E2E / 探针 / 邮箱核验脚本（可复跑） |

---

## 5. 这版**没**修 / 没验的（如实列出）

1. **`permission-presets` 那个 warning**（ACP stderr）：
   `composed sandbox and approval defaults match no preset; configure defaultPreset explicitly`
   → `dsh: warning: 1 entry did not activate`。也就是说 overlay 里只写了
   `sandbox-policy: danger-full-access`，没写审批预设，这个插件条目**没激活**。
   实测**不影响**本轮功能（bash 工具照常执行、没弹审批），所以**没有动它**；
   但"审批/权限预设到底生效了没有"这件事现在是**没配置**状态，值得下一轮确认后再改
   （要改就在 overlay 里补 `permission` 那一段，需要先确认合法的 preset 名）。
2. **真机（用户手上的 arm64 手机）未验**：本机只有 x86_64 模拟器。
   本轮所有设备证据都来自 `emulator-5554`。**"画图能不能出图"这条最终验收仍在用户手机上**
   —— 模拟器这边证明的是"命令能发出去、node 与工具箱脚本能跑起来"，
   真机上还多一层"Agnes 接口能不能连上"（模拟器无外网，用的是假端点）。
3. **`make-image.mjs` 的真实出图没验**：假端点只走到"工具执行成功"，没有真的调 Agnes 生图
   （模拟器没外网、也没有有效 Key）。脚本本身的行为（没 Key 就如实报错 + 给注册地址）
   没动过。
4. **语言/语音（0.12 的麦克风权限）没复验**：权限在包里、代码没动。
5. **用户真机日志（2026-10-04 22:44 导出，v0.12）里又暴露两个 0.13 没修的问题** ——
   见 §7。

---

## 6. 现场状态（可复跑）

* 设备上留的东西**已还原**：`files/models.json` 与 `files/dshhome/model.overlay.yml`
  从 `.fix13-bak` 拷回并删掉了备份；`/data/local/tmp/fix13_*` 已删。
  （还原后的 `models.json` 只剩 `agnes/agnes-model` 一个模型，指向 `127.0.0.1:8891`。）
* 复跑命令：
  * 假模型：`python install/fix13_fake_model.py 8891`（+ `adb reverse tcp:8891 tcp:8891`）
  * 端到端：`python -X utf8 install/fix13_e2e.py`
  * 邮箱：`python -X utf8 install/fix13_verify_email.py`
  * shim 机制：`install/fix13_shim_probe.js` + 用 `run-as` 带上那套环境跑（见 §3.1）
* 中文路径的老坑又踩了一次：`aapt` **不认**中文路径（`Illegal byte sequence`），
  要先把 APK 拷到 `D:\dev\build\...` 再 dump badging。

---

## 7. 用户真机日志复核（v0.12，nubia NX809J / Android 16 / arm64）

用户导出了 **0.12** 的运行日志（`dsh-report-20261004-224430.txt`，348 行）。
它把 §2 的两条根因**在真机上逐行复现**了，另外暴露两个 0.13 **没修**的问题。

### 7.1 真机确认：会话进程没有执行环境（= 画图/PPT 跑不了）

```
22:17:32 [print:dsh-runtime] overlay 已重写：2 个厂家 / 7 个模型 / 1 个轮换组，默认=agnes/agnes-3.0-flash
22:27:39 [print:chat] [acp] spawn libnode.so --profile acp （注入 5 个厂家环境变量）   ← 0.12 的文案，没提 shim
…随后模型 12 分钟里反复撞同一堵墙…
22:33:01 [print:chat] thought: The bash tool is consistently failing with ENOENT …
22:33:21 [print:chat] message: `bash` 工具在当前环境不可用（找不到 `bash` 二进制），
                     没法直接执行 `node` 生成 .pptx …你自己跑一下…
```

同一个会话里 `read` / `write` / `web_fetch` / `web_search` **都能用**，
只有 `bash` 是死的 —— 与"只有会话进程少了那套环境"这个诊断完全吻合。
（用户在 0.12 上还没有本次修复，所以这是**修前**证据。

### 7.2 真机确认：切模型"要点两次"的现场

```
22:29:05.428 [chat] model changed -> cat
22:29:05.450 [dsh-models] models.json 已写入 … selected=rotate/cat
22:29:05.450 [dsh-model] 已把选中项写回 models.json.selected=rotate/cat
22:29:05.451 [dsh-model] 清单载入：8 项…选中=agnes/agnes-3.0-flash   ← 读到的还是旧值
22:29:05.451 [chat] model changed -> agnes-3.0-flash                ← 界面被弹回 agnes
22:29:05.475 [chat] 会话内切换模型成功：agnes/agnes-3.0-flash（会话未重建）   ← 而且打印了两遍
22:29:10.361 [chat] model changed -> cat                            ← 用户只好又点一次
22:29:10.375 [dsh-model] 清单载入：…选中=rotate/cat                 ← 这次才读到
22:29:10.388 [chat] 会话内切换模型成功：rotate/cat
```

**这就是"选一次不行、要选第二次"的真机现场**：通知先到、落盘后到，
会话页在窗口里重读 `models.json` 拿到旧 `selected`，于是把模型**切回旧的那个**。
0.13 的两处修法（`selectModel` 先落盘再通知 + `_openModelSheet` await `selectionSettled`）
正是卡在这个窗口上；日志里那句"成功"打印两遍也说明当时是并发进来两次。

### 7.3 0.13 **没修**的问题（新发现）

| # | 日志证据 | 诊断 | 能不能修 |
|---|---|---|---|
| G | `22:32:20 [chat] thought: The glob tool also failed (ripgrep launch failed)` | `glob` / `grep` 走的是**随包的 ripgrep 可执行文件**（`@vscode/ripgrep`）。设备上只有 `@vscode/ripgrep` 和 **`@vscode/ripgrep-win32-x64`**（运行时树是在 Windows 上打包的），而且 Android 10+ **不允许执行 App 数据目录里的文件**（libnode 正是因此改名 `libnode.so` 放进 nativeLibraryDir 才能跑）。两个原因各占一半 | **能**，而且有现成套路：Termux 的 aarch64 `ripgrep` 包是给 Android/bionic 编的 → 取出 `bin/rg` 改名 `librg.so` 放进 `jnilibs/<abi>/`，再在 `android-exec-shim.cjs` 加一条规则把 `rg` 改写到它（和 `node` 那条一模一样）。取包可以直接扩展 `install/fetch-termux-deps.mjs` |
| S | `22:30:06 [chat] thought: The web search failed due to an API authentication error` | `web_search` 要的是 **DeepSeek 官方凭据**；用户只配了 `com`（commandcode.ai 聚合）+ `agnes`，所以必然认证失败。手机**本身有网**（模型随后用 `web_fetch` 抓百度/新浪都成功了） | 两条路：给一把 DeepSeek Key；或者**在 AGENTS.md 里如实写明"联网搜索不可用，要查资料就用 web_fetch 直抓"**，别让模型白撞两轮 |
| R | `22:28:52 [chat] prompt failed: … 429 … 您已达到免费用户的 API 速率限制（AgnesAI_error）` | Agnes 免费额度**会限流**。当时选的是单个 `agnes-3.0-flash`（不是轮换池），所以没人接手；用户后来手动切到 `rotate/cat` 就继续跑了 | 不用改代码；提示用户**选中「轮换池」**（他有 `cat`，4 个成员）就会自动降级到下一个 |

### 7.4 真机侧的环境事实（从这份日志读出来的）

* 厂家：`agnes`（1 个模型，有 Key）、`com`（6 个模型，有 Key）；轮换组 `cat` 4 个成员。
* 当前选中 `rotate/cat`；`models.json` 里 7 个模型 / 8 项清单。
* 内置技能 12 条；专家库 321 名 / 22 分区（`@michengai/dsh-agency-agents@1.0.5`）。
* 定时任务能跑：`执行任务「五分钟后帮我发一封邮件」` → headless 进程 exit=0，
  模型回了 QQ 邮箱 SMTP 的结论（**注意：headless 那条路一直是好的**，与 §2.1 一致）。
* 主题已切 `light`（`dsh_theme_skin` 落盘）。

---

## 8. 「轮换池到底有没有起作用」—— 实测（可复跑）

用户怀疑轮换池没生效。用 `install/fix13_fake_rot.py`（**同一个端口两个前缀**：
`/aaa` 永远 429、`/bbb` 正常）+ 一份两成员的组配置
（`cat = [aaa/aaa-model, bbb/bbb-model]`，选中 `rotate/cat`），让池子当默认路由，发一条消息：

假上游侧（服务器日志）：
```
[rot-fake] POST /aaa/v1/chat/completions model=aaa-model -> 429
[rot-fake] POST /bbb/v1/chat/completions model=bbb-model -> 200
```

App 侧（logcat + 落盘的诊断日志，`install/fix13_rot_e2e.py` 采的）：
```
14:56:42 [chat] ACP session ready: … model=cat 运行时报=rotate/cat
14:56:48 [dsh-rotate] [rotate] cat: aaa/aaa-model 失败(429)，改用 bbb/bbb-model
14:56:48 [dsh-rotate] [rotate] cat: bbb/bbb-model 成功（第 2 个成员顶上）
14:56:48 [chat] message: 轮换池第二个成员（bbb/bbb-model）答的：我顶上了。
界面：「已完成 · 轮换池第二个成员（bbb/bbb-model）答的：我顶上了。」
```

→ **池子是好的**：429 真的触发换人，界面拿到的是第二个成员的回答；
代理还把 `lastGood` 写成了 `{"cat":1}`（下次从"上次成功那个"开始）。

### 8.1 用户那份真机日志里能推出什么

* 22:28:52 的 429 发生时，选中路由是**单个** `agnes/agnes-3.0-flash`
  （`[acp] session created: … model=agnes-3.0-flash`），**不是池子** ——
  **限流那一刻池子不在场上**，这才是"感觉它没起作用"的真实原因。
* 22:29:10 切到 `rotate/cat` 之后 4 轮都成功，而且整份日志里**没有一条**
  `失败(…)，改用 …` / `第 N 个成员顶上`（这两条是**无条件**打的）→
  说明池子在跑，且**没有一个成员失败过**（顺利时反而看不到痕迹）。

### 8.2 为什么"看不着"（建议下一版改）

1. **粘性**：代理把"每组上次成功的成员下标"写在 `rotate-config.json` 的 `lastGood`，
   下次**从它开始**（`rotation_proxy.dart:139` 是**故意保留**的）。
   实测踩到：第一遍跑时 `lastGood={"cat":1}` → **直接用第二个成员**、一次 429 都没碰，
   看起来像"第一个成员从来没被用过"。要复现"换人"，必须先清掉这个粘性
   （`run-as … rm -f files/toolbox/rotate-config.json`）。
2. **过程默认不打日志**：每次请求那一行（`→ 组: model=… 起始成员=…`）是
   `--verbose` 才输出（`rotate-proxy.mjs:637`），而 App 起代理时没带 `--verbose`。
   → 最小改动：起代理时加 `--verbose`（脚本已支持 `--verbose` / `--log <文件>`），
   下次导出运行日志就能直接看到「起始成员 + 有没有降级」。**这条建议还没实现**。


