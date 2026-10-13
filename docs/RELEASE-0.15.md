# 0.15 交付记录 · 用户 10 条改进全量实施

> 写给出接手的会话：这一版不是"修补"，是用户一次性提的 **10 条改进逐条落地**。
> 每条都实施过、每批都跑过 `flutter analyze` + `flutter test`。
> 上一版见 [`RELEASE-0.14.md`](RELEASE-0.14.md)。
>
> 版本：`kAppVersion = '0.15'`、`pubspec version: 0.0.15+15`（versionCode 15）
> 日期：2026-10-05
> 累计改动：**21 文件 / +2316 行 / -79 行**
> 验证终态：`analyze → No issues found!` ｜ `test → 83 passed / 3 skipped / 0 failed`

---

## 0. 先说一个前提：你手上的 0.14 包落后源码约 26 小时

迁移包里导出的源码最后改动到 2026-10-05 02:46（+08），而 0.14 的 APK 打于 2026-10-04 00:17。
中间那一批改动**没打版、版本号也没升**（`app_version.dart` 仍写 0.14、changelog 没加条目）。
其中就包括语音的 `RECORD_AUDIO` 运行时申请 —— 所以"语音用不了"这条，一部分是**包旧**，一部分是**真 bug**（见 §2）。

---

## 1. 十条改进逐条

### 1.1 语音输入（用户第 8 条）—— 真因不是权限

**真因**：`chat_page.dart` 的 `_onVoiceState` 原本写的是

```dart
if (held) return;              // 按住：什么都不做
unawaited(_speakToText());     // 松手：才开始识别
```

也就是**松手之后才开始录音** —— 用户对着手机说话的整段时间里录音根本没开，
必然采到静音 → `onError(6/7)` → 回退系统 Intent。这解释了"开了麦克风权限也没用"。

**改法**（三处）：
* `MainActivity.kt`：新增 `"stopSpeech"` 分发 + `stopSpeechRecognizer()`（调 `stopListening()`，
  一律 `success` 返回 `ok`/`noop`/`failed`，不抛错）。
* `local/dsh_runtime.dart`：新增 `DshHost.stopSpeech()`。
* `ui/pages/chat_page.dart`：`_onVoiceState` 改为按下 `_startSpeech()`（**不 await**，让它一直听）、
  松手 `_stopSpeech()`；新增 `_speechRunning` 单飞字段防重入。

### 1.2 对话可复制（第 10 条）

**真因**：消息正文全是普通 `Text`（用户消息 / 助手回复 / 思考块），只有工具命令与输出用了
`SelectableText`，全库没有 `SelectionArea` → 长按没有选择菜单。

**改法**：给这三处正文包 `SelectionArea`。
**刻意不用 `SelectableText`** —— 它不支持 `overflow: ellipsis`，会让"展开/收起"的折叠逻辑失效。

### 1.3 背景网格（第 3 条）—— 不是没做，是看不见

网格**早就实现了并且已启用**（`DshGridPainter`，挂在 `main.dart` 的 `MaterialApp.builder` 底层）。
问题是 `alpha = 0.035` + `1px`：手机 DPR 是 3，1 逻辑像素 = 3 物理像素，3.5% 透明等于不存在。

**改法**：alpha 深色 `0.075` / 浅色 `0.055`；格距深色 22 / 浅色 24；**每 4 格一条更亮的主格线**做层次。
同时修掉一个隐患：`DshGridBackground` 改为**由调用方传入 `bgColor`**，
否则 painter 在 `paint` 里现读 `DshColors.bg`，新旧值永远相同、`shouldRepaint` 恒为 false，
**换肤后背景层不重绘**（`main.dart` 那处 `const` 必须去掉，理由写在该行注释里）。

> α 上限经验值约 0.08，再高会把正文衬脏（正文对比度需保持 ≥ 4.5:1）。

### 1.4 左右滑动切页（第 9 条）

`app_shell.dart` 的 body 原本是裸的 `IndexedStack`。**改法**：外包 `GestureDetector`
（`onHorizontalDragEnd` → `_handleSwipe`），速度阈值 300px/s，**屏幕左右各 24dp 死区** ——
Android 10+ 的边缘返回手势从屏幕边缘起划，不设死区会把"想返回"误判成"想切页"。

### 1.5 会话入口（第 1 条）

**真因**：会话页是 `Navigator.push` 的全屏路由，点底部其它 Tab 走 `Navigator.pop` →
`dispose` → `AcpClient.close` 在 300ms 后**杀掉 node 子进程**。所以切走不只是"找不到入口"，
**正在生成的回答会被打断**；而壳层只持有 `_index`，从不记 `sessionId`。

**本次做的**：壳层记 `_activeSessionId/_Cwd/_Label`（在 `onSessionUsed` 回调里同步），
首页底部出现「继续上次会话」条（`_ResumeSessionBar`），走的是与工作区页**完全相同**的
`resumeSessionId` 路径。

**后续已补上**（同一版内）：把 `AcpClient` 的所有权从会话页上移到壳层持有的
`SessionRegistry`，于是**多会话并发 + 切页不打断**都成立了。详见 §6。

### 1.6 会话重命名（第 6 条）

**改法**：`WorkspaceStore` 新增 `_sessionTitles` 映射 + `renameSession()` / `customTitleOf()` /
`_withCustomTitle()`；落盘在 `workspaces.json` 的 `sessionTitles` 字段，`load()` 读回；
`sessionsOf()` 与 `noteSession()` 优先用自定义名（**返回副本**，不污染磁盘索引那份真实数据）。
UI：`workspace_page.dart` 的 `_SessionTile` 长按 → `_RenameSessionDialog`
（StatefulWidget，控制器生命周期与路由对齐 —— 沿用项目既有做法，别改成调用方 new+dispose）。

**如实说明**：ACP 协议**没有** rename，DSH 那边的会话不受影响；留空保存 = 清除自定义名。

### 1.7 手机权限板块（第 7 条）

`AndroidManifest.xml` 权限 7 → 12 条（新增 `ACCESS_FINE/COARSE_LOCATION`、`READ_MEDIA_IMAGES/VIDEO`、
`READ_EXTERNAL_STORAGE` maxSdk=32）。`MainActivity.kt` 新增
`permissionStatus` / `requestPermissions` / `openAppSettings` / `openSpecialSettings` 四个方法
（`REQ_PERMS = 4716`，`pendingPermsResult/Keys` 字段，`onRequestPermissionsResult` 加分支）。

设置页新增「手机权限」分区：**独立 `_PermissionsSection` StatefulWidget**（设置页本身是
StatelessWidget，这样零侵入）。

**两条必须守住的表述纪律**：
1. **不承诺"一键全开"** —— Android 没有这种 API；`MANAGE_EXTERNAL_STORAGE` 这类特殊权限
   必须用户去系统页面手动开，而且它**看不到其它 App 的 `/Android/data`**；
   `signature|privileged` 级权限根本拿不到。
2. **与 DSH 沙箱模式分开写** —— `DSH_PERMISSION_MODE`（移动端 overlay 硬编码
   `danger-full-access`，见 `dsh_runtime.dart`，因为 Android 内核没有 landlock 无法下调）
   是"Agent 能用哪些工具"，跟手机给不给权限毫无关系。**不要把后者译成"超级权限"。**

### 1.8 产物留存 + 来源（第 5 条）

**真因**：会话页其实**已经有**产物列表，但数据是 `ChatPage._artifacts` 这份**纯内存**列表，
`_loadTranscript` 恢复会话时**不重建** → 退出再进就空，只能去资料库翻；
而且 `Artifact` 结构里**没有 sessionId**，回答不了"哪个会话产生的"。

**改法**：
* `Artifact` 增 `sessionId` / `sessionCwd` + `toJson()` / `fromJson()`。
* 新增 `data/artifact_store.dart`：按会话存 `<DSH_HOME>/artifacts/<sid>.json`
  （一会话一文件、写失败不抛错、`loadAll()` 供资料库「按会话」视图用）。
* `chat_page.dart`：`_adoptProducedArtifacts` 给产物补来源并落盘；
  新增 `_restoreArtifacts()` 在 `_loadTranscript` 之后读回 ——
  **读回来的条目仍是候选**，照样过 `verifyProducedArtifacts` 复核文件是否还在，
  核实不过如实丢掉（`since` 传 1970 以绕过"本次会话之后"的时间窗，否则旧产物会被全滤掉）。

### 1.9 图片能看懂（第 2 条）

**真因**：ACP 实测 `promptCapabilities.image = false`，图片**从不作为图片发出**；
App 只把绝对路径插进输入框并注明"能否理解取决于模型视觉能力"。
而用户那句话（"必须用视觉模型"）**是模型自己回复的** —— App 代码里 grep 该文案 0 命中。

**改法（复刻 `dsh-vision-router` 的思路：视觉模型只是眼睛，文本模型是大脑）**：
* 新增 `assets/toolbox/vision-proxy.mjs`（865 行，零第三方依赖）：一条**免费视觉链**
  智谱 `glm-4.6v-flash` → `glm-4.1v-thinking-flash` → `glm-4v-flash` → OVH 匿名
  `Qwen2.5-VL-72B` → dashscope `qwen3-vl-flash` → intern `internvl-latest`；
  链式尝试、只有一条 JSON 出 stdout、日志走 stderr、Key 只打前缀+长度。
* `chat_page.dart` 新增 `_describeImage()`：`runOnce([visionProxyScriptPath, path, '--text'])`，
  超时 200s，**失败一律返回 null**（退回原来的"只给路径 + 如实说明"，不编假描述）。

**已知限制（必须写进用户可见文案）**：
* OVH 匿名限 2 次/分/IP，共享出口极易 429；
* **幻觉实测**：1×1 纯色 PNG 被描述成"登录/注册表单"—— 极小/空白图的描述不可信；
* 图片会上传第三方云（隐私边界）。

### 1.10 长会话助手（第 4 条）—— 为什么是 App 侧实现

`dsh-smart-compact` 的机制是接管宿主的**压缩单槽**、把 `summarize()` 覆盖成固定模板（零模型调用）。
但它的 `inject` 里硬要 `webServer`（只有 web profile 提供）→ **手机上的 acp profile 根本挂载不了**
（不是降级，是整插件不 apply）；就算绕开，压缩槽也被 `compaction-basic` 占着，
而且它还要给宿主 `dsh-token-meter` **打补丁** —— 手机的 DSH 是版本化 zip 解包树，一升级补丁就没了。

**用户已确认走 App 侧等价实现**：新增 `local/context_budget.dart`
（`estimateContextBudget()` 按 2 字符 ≈ 1 token 估算并**标明是估算**；
`buildHandoffNote()` 把已知事实填好、把判断项留给新窗口的模型自己写），
附件菜单加「长会话助手」→ `_openContextHelper()` 弹层显示估算 + 生成交接笔记插进输入框。
**全程不调模型**，与 smart-compact 的省钱思路一致。

> 同一个原因：`dsh-vision-router` 也依赖 web 包的 `webServer`，在手机上同样装不上 ——
> 所以 §1.9 也是"App 侧复刻"而不是"装插件"。

---

## 2. 验证（可复跑）

```bash
# 唯一写入源是 /root/办公/dsh-mobile/app；中文路径会让 dart analyzer 崩，
# 所以构建/测试都在 ASCII 镜像里做（见 HANDOFF.md §3.1）。
bash /root/办公/sync-dsh-app.sh
export PATH=/opt/flutter/bin:$PATH
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export PUB_HOSTED_URL=https://pub.flutter-io.cn
cd /tmp/dsh-app
flutter analyze --no-pub      # → No issues found!
flutter test --no-pub         # → 83 passed / 3 skipped / 0 failed
```

**顺带修的测试健壮性问题**：原先 `wss_integration_test` 写死了 `D:\` 下的指纹文件路径、
`bridge_integration_test` 要求桥正在运行 —— 在 Linux 上会**稳定报 2 条假失败**，把真回归淹掉。
现在两者前置不满足时**显式 skip 并说明怎么补前置**。

**⚠️ 未能验证的部分（诚实清单）**：
1. **Kotlin 改动没有编译过** —— 本机没有 JDK / Android SDK / Gradle，
   只做了"括号配对 + 与基线 diff 比对"。**首次真机编译时重点复核 `MainActivity.kt`。**
2. 真机行为（语音起录时机、滑动与系统返回手势、权限弹窗、看图链路）全部需要真机复测。
3. `vision-proxy.mjs` 只在本机 Node 22 上验证过，目标 Termux Node 26.4.0 **未实测**。

---

## 3. 未完成 / 下一步

| 项 | 状态 |
|---|---|
| 打 0.15 的 APK | 需先装 **JDK 17 + Android SDK + Gradle**；装好后 `install/build-local-apk.ps1`（Windows 脚本，Linux 需改用 `flutter build apk --release --target-platform android-arm64`） |
| 资料库「按会话」视图 | `ArtifactStore.loadAll()` 已备好，`library_page.dart` 的 UI 还未接 |
| ~~多会话并发 + 切页不打断~~ | ✅ **已完成**，见 §6 |
| 附件落在会话 cwd 之外 | 现能读通只因默认 `danger-full-access`；一旦切 `workspace-write` 则 `read` 必失败（隐雷） |
| 技术文档归档 | 按用户铁律归入「技术问题知识库」kb-cat4 |

---

## 6. 附：多会话并发 + 切页不打断（同版补做）

用户对第 1 条追问"是不是不能同时开多个会话"之后补的架构调整。

### 根因

`AcpClient` 由 `ChatPage` 的 State 持有，`dispose()` 里直接 `close()`；
而会话页是 `Navigator.push` 出来的全屏路由 —— 用户点底部别的 Tab 就会 pop → dispose
→ 进程在 300ms 后被杀，**正在生成的回答被当场打断**。
所以问题不只是"找不到入口"，是"切走就把活干断了"。

### 改法

新增 `lib/state/session_registry.dart`：

* `LiveSession`：一个会话的**进程 + 消息 + 产物 + 运行状态 + 待答权限**。
  它才是"会话还活着"的真相，会话页只是借用它渲染。
* `SessionRegistry`（`ChangeNotifier`）：**壳层持有**，负责所有进程的生老病死。

三个关键机制：

1. **detach 不杀进程** —— 页面 pop 时只解除绑定，进程继续跑。只有用户显式关闭、
   或 App 退出（`closeAll`）才收尸。
2. **backlog 回放** —— 人不在时收到的 `session/update` 攒进句柄（上限 4000 条），
   回来 `attach` 时先回放再接实时。权限请求同理：不然 DSH 侧等不到决定，
   120s 超时自动拒绝。
3. **状态共享** —— `ChatPage` 的 `_messages` / `_artifacts` 改成 getter，
   指向句柄持有的那一份：切页不丢内容，离屏收到的更新也进得来。

壳层的 `_start()` 会先问注册表"这个会话是不是已经在跑"，命中就
`_adoptLive()` 接上，**绝不新起进程** —— 这是"回答不中断"的另一半。
真正的多会话并发由此自然成立：前一个还在跑，用户可以回首页开新的。

### 验证

`test/session_registry_test.dart`（4 条，**用真实 `sleep` 进程而不是 mock** ——
`AcpClient` 需要 dart:io 的 `Process`）：

* detach 之后进程**必须还活着**（"切页不打断"的底层保证）
* 只有显式 close 才收尸
* 注册表复用语义：同工作区 + 同 sessionId 才复用，别的不复用
* `runningOnes` 只报正在跑的（首页「正在回答」提示的数据源）

> **踩坑**：`Process.exitCode` 是 `Future<int>`，**不是同步字段**。
> 判断"进程还活着"必须用 `exitCode.timeout(...)` 竞速 ——
> 超时前拿到退出码才算已经死了；直接跟 `null` 比较会被分析器判为
> `unnecessary_null_comparison`，而且逻辑是错的。
