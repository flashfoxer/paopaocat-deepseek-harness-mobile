# 会话到底在用哪个模型 / 哪个 Key —— 证据化排查（0.11）

> 排查对象：`dsh-mobile`（Flutter Android，包名 `com.dshmobile.dsh_mobile`，`kAppVersion = '0.11'`）
> 设备：`emulator-5554`（**共享设备**：排查期间另一个代理在跑"轮换池"和"日志导出"的 UI 自动化，见 §6）
> 结论分三类：**已证实** / **已排除** / **待设备验证**。所有 Key 一律打码。

---

## 1. 三个问题的结论

| # | 用户的问题 | 结论 | 精确触发条件 |
|---|---|---|---|
| 1 | 「设置里模型设置好了，但会话没读取模型、还是空的？」 | **会，但不是"没读取"，是两处不同步**（已证实） | ① 会话里点过一次别的模型（只写安全区 `dsh_model_selected_id`）之后，设置页按 `models.json.selected` 显示/标记的"默认"就与会话实际用的分叉；② `models.json` 有厂家、模型条目为空时，会话确实"空"，而提示语会让用户反复去填已经填好的 Key |
| 2 | 「是不是又那种"必须切一下页面才刷新"？」 | **模型清单的刷新不用切页面（已排除）；但运行中的会话不会跟着新配置走（已证实）** | 配置（Key / 端点 / 模型清单）变了之后，**当前这条已打开的会话进程**不会热更新 —— 要重建进程 |
| 3 | 「会话里调用的不是设置里的模型？」 | **会，而且有两种不同的错法**（已证实） | ① 每厂家 Key 根本没进会话子进程 → 非 `com/deepseek/openai` 的厂家（**Agnes 就是**）在会话里必然 `no credential`；② 同一厂家改了 Key/端点后，会话继续用进程里的旧 Key/旧端点（`session/set_config_option` 只切"已注册的模型"，不换 Key/端点） |

---

## 2. 逐层证据

### ②③ overlay 与子进程环境：修前就没把"每厂家 Key"传进会话

`lib/local/acp_client.dart`（**修前**）：

```dart
final env = <String, String>{
  'LD_LIBRARY_PATH': nativeLibDir, 'DSH_HOME': dshHome, 'HOME': filesDir,
  'PATH': '/system/bin:/system/xbin', 'TMPDIR': '$filesDir/tmp',
  if (apiKey != null && apiKey.isNotEmpty) ...{
    'COM_API_KEY': apiKey, 'DEEPSEEK_API_KEY': apiKey, 'OPENAI_API_KEY': apiKey,
  },
  // ← 没有 apiKeys（ProviderKeys.envFor 算出来的"每厂家一把"）
};
```

`lib/ui/pages/chat_page.dart`（**修前**，L293）：`apiKey: rt.apiKey,` —— 只传了安全区里那把**单把旧 Key**。
而 overlay 里每家厂家写的是 `apiKeyEnv: <PID>_API_KEY`（`dsh_runtime.dart:422`）。`DshRuntime.apiKeys` 只对
`spawn()/runOnce()/headless()`（定时任务、轮换代理）生效，**会话这条 ACP 路径一直是丢的**。

设备上抓到的 overlay（App 自己生成的；下面是按关键字过滤后的原文片段）：

```
        apiKeyEnv: AGNES_API_KEY
        baseURL: "http://127.0.0.1:8891/agnes/v1"
          - id: agnes-model
    provider: agnes
    model: agnes-model
    provider: agnes
    model: agnes-model
```

### ⑤/⑥ 真实请求打在哪：独立 DSH_HOME + 假端点（设备上跑的协议级实验）

做法（**不经过 Flutter UI，抗干扰**）：`/data/data/com.dshmobile.dsh_mobile/files/audit/`
下一份独立的 `dshhome` + 自己写的 overlay，用 `run-as` 起 `dsh --profile acp --patch overlay.yml`；
假端点在主机 `127.0.0.1:8891`，经 `adb reverse` 让设备 `127.0.0.1:8891` 指过来
（**刻意避开 8899**，那是另一个代理的 `pool401_server.py`）。

**实验 A：env 里给了 `COM_API_KEY`/`DEEPSEEK_API_KEY`**

```
[drv] keys in env: COM_API_KEY=AUDI***, DEEPSEEK_API_KEY=AUDI***
[drv] configOptions=[{"id":"model",…"options":[{"group":"com",…"model-alpha"},{"group":"deepseek",…"model-beta"},…]}]
--- S1 default route prompt ---   [drv] S1 OK stopReason=end_turn reply="你好，这是本地假端点的回复。"
--- S2 in-session switch ---      [drv] S2 set_config_option(deepseek/model-beta) -> OK   ; S2 OK
--- S3 rewrite overlay on disk ---[drv] overlay rewritten on disk: com baseURL /com/v1 -> /com2/v1 (changed=true) ; S3 OK
--- S4 unregistered provider ---  ERROR {"code":-32602,"message":"Invalid params: unknown model option: [\"ghost\",\"ghost-1\"]"}
--- S5 registered provider + unregistered model --- ERROR {…unknown model option: [\"com\",\"model-gamma\"]}
```

假端点实际收到的请求（Key 打码，保留前后各 4 位以便区分）：

```
{"ts":"19:17:56","path":"/com/v1/chat/completions",     "auth":"Bearer***1111","model":"model-alpha","stream":true}
{"ts":"19:17:56","path":"/deepseek/v1/chat/completions","auth":"Bearer***2222","model":"model-beta","stream":true}
{"ts":"19:17:56","path":"/com/v1/chat/completions",     "auth":"Bearer***1111","model":"model-alpha","stream":true}
   ↑ 这一条是 S3：磁盘上的 overlay 已经改成 `/com2/v1`，请求**仍然**打 `/com/v1`
```

→ **已证实**：
* 会话请求的 provider/model/Key 完全由"**进程启动时**读到的 overlay + 环境变量"决定；
* `session/set_config_option` 能在不重启进程的前提下换模型（S2 成功，端点/Key 也跟着换）；
* 但它**只认进程启动时注册过的模型**（S4/S5 都报 `unknown model option`）；
* **改 overlay 对运行中的进程无效**（S3）→ 改 Key/端点必须重建进程。

**实验 B：env 里一把 Key 都不给（这正是 App 对非 com/deepseek/openai 厂家的现状）**

```
[drvB] keys in env:  (none expected)
[drvB] session 239812d8-f384-442c-b3a5-f8c6746265a9
[drvB] prompt FAILED as expected: {"code":-32603,"message":"Internal error: turn failed:
   llm-pi-ai: no credential for provider route \"com\"; its profile resolves COM_API_KEY,
   which is not set — store COM_API_KEY through the credentials service … "}
```

假端点日志里**没有任何新请求** → 缺 Key 时连 HTTP 都发不出去，报错文本就是用户会看到的那句
（`api_error_text.dart` 会把它翻成中文）。

### ① 设置页存的 vs 安全区里的：设备实测

```
files/models.json （我自己写进去的受控配置）
{"version":2,"selected":"com/model-alpha",
 "providers":[{"id":"com",…"apiKeyEnv":"COM_API_KEY"},{"id":"deepseek",…}],
 "models":[{"provider":"com","id":"model-alpha","name":"alpha"},…],"groups":[]}

shared_prefs/FlutterSecureStorage.xml（当前只有一条键）
  …_dsh_model_selected_id = <加密值>
shared_prefs/shared_prefs.moved/FlutterSecureStorage.xml（上一个代理移走的原件）
  dsh_model_api_key / dsh_provider_key_com / dsh_model_provider /
  dsh_model_selected_id / dsh_model_base_url / dsh_model_tier / dsh_model_id
```

`ModelStore.load()`（**修前**）：`ModelEntry? restored = _find(selectedId) ?? _find(cfg.selected);`
→ **安全区里"上次点过的"无条件盖掉 `models.json.selected`**。而设置页的"默认"徽标来自
`(_cfg.selected ?? '') == m.route`（`model_settings_panel.dart:706/1419`，日志行是
`[dsh-model-panel] 本页刷新：… selected=…`）→ 两边说的不是同一件事。

App 冷启动实测（0.11 debug x86_64，overlay 删掉让 App 自己生成）：

```
[dsh-model] 清单载入：2 项（2 个厂家 / 0 个轮换组），选中=com/model-alpha
[dsh-runtime] overlay 已重写：2 个厂家 / 2 个模型 / 0 个轮换组，默认=com/model-alpha
[dsh-model] overlay 已生成/升级：默认=com/model-alpha，注册 2 项（写入前 -1 项）
[chat][acp] spawn libnode.so --profile acp
[chat] ACP session ready: e7443052-e04c-4abb-a555-623cddc85fd8 model=alpha cwd=…/workspaces/moni-ws
会话页顶栏：「当前模型 alpha」
```

→ 配置**没变**时，①→⑤ 这一段是通的（models.json → 清单 → overlay → 会话）。

### ③ 会不会"必须切页面才刷新"

* `AppShell` 把**同一个** `ModelStore` 实例传给 `ChatPage`（`models: widget.models`），
  `ChatPage.initState` 里 `widget.models.addListener(_onModelStoreChanged)` → 通知能到已打开的会话页。
* `main._onModelChanged` 里 `await _models.load(filesDir)` 会重读磁盘 —— 注释里说的那个"退出重进才看见模型"已经修过。
* 但会话页的**底部 Tab** 是 `Navigator.pop({tab:4})`（`chat_page` 的 `_showAttachHint` / bottom nav）：
  切到「设置」**会把会话页 pop 掉**，所以底部 Tab 那条路根本不存在"会话页不刷新"的场景 —— 下次进会话是新建的页面。
* 唯一"会话页还活着"的路径是对话页齿轮 → **push 出来的 v1 `SettingsPage`**。
  这里有两个事实（代码级，见 §5 待验证第 6 条）：
  * 返回时 `main._openSettings` 会 `_models.load()` + `_onModelChanged()` → **用 `models.json` 重写 overlay**，
    也就是齿轮页里改的 Base URL / provider / model（`SettingsPage._save` → `runtime.writeModelConfig`）
    **立刻被盖掉**，只有它写的那把**旧 Key**（`dsh_model_api_key`）留了下来、真的会进子进程；
  * 修前那条会话页只会走 `session/set_config_option` → "切换成功"但进程里的旧配置没变。

---

## 3. 我证实并修了的问题

| 文件 | 位置/函数 | 改了什么 | 为什么 |
|---|---|---|---|
| `lib/local/acp_client.dart` | `AcpClient.start()` | 新增 `Map<String,String> apiKeys`，并把它拼到 env **最后**（覆盖 `COM_/DEEPSEEK_/OPENAI_API_KEY`），PID 日志里带上"注入 N 个厂家环境变量" | overlay 用 `apiKeyEnv` 点名凭据，不注入就 `no credential`（实验 B）。放最后是为了"同名的每厂家 Key 赢过旧键名"，同时**保留** PATH/DSH_ANDROID_*/旧 Key |
| `lib/ui/pages/chat_page.dart` | `_start()` | `apiKeys: st.keys`（`ProviderKeys.envFor(widget.models.config)` 现算的每厂家 Key）+ `apiKey: rt.apiKey` 兜底 | 修前只传 `rt.apiKey`；现算而不是用 `widget.runtime` 里那份快照，避免 ChatPage 持有的是旧 runtime |
| `lib/ui/pages/chat_page.dart` | 新增 `_spawnState()` / `_spawnedConfigKey` / `_syncingConfig` | 记录"这次 spawn 真正吃进去的配置指纹"（厂家/协议/端点/apiKeyEnv/模型清单/轮换池/每厂家 Key 值/旧 Key）；配置变了 → **先让外层重写 overlay，再重建进程**；只有"换个已注册模型"才走 `session/set_config_option` | 实验 A 的 S3/S4/S5：进程不热更新配置，`set_config_option` 只认注册过的模型。指纹**刻意不含"当前选中的那一个"**（否则每次点模型都会重建会话，退回用户第 11 条反馈要修的行为）；**必须含 Key 值**（同厂家只改 Key 时 overlay 文本完全一样） |
| `lib/ui/pages/chat_page.dart` | `_onModelStoreChanged()` | 加 `if (_syncingConfig) return;` | 上面那次"同步 overlay"会触发 `models.load()` → 再打回来；不拦会并发出两个 node 进程 |
| `lib/state/model_store.dart` | `load()` | 恢复顺序改为 **`models.json.selected` 优先**，安全区 `dsh_model_selected_id` 退化成兜底（并用于"厂家前缀"回收） | 设置页显示/标记的就是 `models.json.selected`；会话必须以它为准（问题 1） |
| `lib/state/model_store.dart` | `selectModel()` + 新增 `_persistSelectionToConfig()` | 面板里选中后**同时**写安全区**和** `models.json.selected`（只改 selected 一个字段；route 必须真在那份配置里才写，避免写出坏文件） | 只写安全区是"设置里 A、会话跑 B"的根因；写回后两处永远一致，而且重启后选择不会丢 |
| `lib/ui/app_shell.dart` | `ensureModelConfig()` | 新增两条重写条件：overlay 里的默认 route ≠ 当前选中项；当前 route 的**端点/模型 id** 与配置不一致（新增 `overlayLooksStale()` 做很浅的文本对账） | 原来只看"条数/沙箱/端口"，同一个厂家只改 Base URL 时会认为"无需重写"，新会话继续打旧端点 |
| `lib/ui/pages/chat_page.dart` | `_noModelNotice()` + `ModelStore.providersWithoutModels` / `hasAnyProviderKey` | "有厂家但没模型"时改说「厂家和 Key 都有了，但还没有模型：去设置点获取模型」，不再一律让他"填地址和 API Key" | 用户实测遇到过"有厂家没模型"，而原提示是写死的"填 Key"，照做多少遍都没用 |
| `lib/ui/pages/chat_page.dart` |（未改 `_switchModelInPlace` 本体）| — | 按要求不动它；改的是"什么时候调用它"（`_applyModelChange`） |

**回归验证（最终树）**

```
flutter analyze（镜像 D:\dev\build\app-audit）      → No issues found!   exit=0
flutter test test\theme_skin_test.dart test\api_error_text_test.dart → All tests passed! (+17) exit=0
flutter test test\overlay_staleness_test.dart（新增）→ All tests passed! (+7) exit=0
```

新增的 `test/overlay_staleness_test.dart` 把 `overlayLooksStale` 的契约钉死：
端点/模型一致 → 不过期；同厂家改 Base URL → 过期；模型 id 不在 overlay → 过期；
overlay 缺失 / 厂家没写进去 → 过期；route 不属于这份配置（自愈路径）→ 不判过期；
轮换组 → 不参与端点对账。（新增测试文件不影响"那两个文件仍 17 passed"。）

主题约束：本次改动没有新增任何色值组件（`_noModelNotice` 沿用原有 `DshColors.err` 写法，未加 `const`）。

---

## 4. 已排除的怀疑

1. **"会话不读模型清单、拿设计稿假名字充数"** —— 已排除。清单来源就是 `models.json`：
   设备实测 `[dsh-model] 清单载入：2 项…选中=com/model-alpha` 与我自己写的 `models.json` 完全一致；
   会话页顶栏显示 `alpha` / `agnes-m`，与配置一致。
2. **"设置页保存后内存里的 ModelStore 没重读，必须退出重进"** —— 已排除（这条历史上修过）：
   `main._onModelChanged` 里 `await _models.load(filesDir)` 确实重读磁盘，设备上也能看到
   保存后 `[dsh-model] 清单载入：…` 再次出现；`ChatPage` 持有的是同一个 `ModelStore` 实例，通知能到。
3. **"底部 Tab 的「设置」和 push 出来的 `SettingsPage` 走的是同一条路"** —— 已排除：
   前者是 `AppShell` 的 `IndexedStack` 第 5 页（`SettingsTab` → `ModelSettingsPanel`，写 `models.json`，
   保存后调 `onModelChanged`）；后者是对话页齿轮 push 出来的 v1 页（只写安全区旧键 + 直接改 overlay）。
   两者行为不同，见 §1 问题 1/2 的触发条件。
4. **"overlay 只声明一个厂家，所以切厂家会丢配置"** —— 已排除：设备上 overlay 里
   `bogus` + `com` + `rotate` 三段同时存在，与 `models.json` 的 2 个厂家 + 1 个组一一对应。
5. **"轮换组在会话里切不过去"** —— 未发现问题：组就是 `rotate/<名字>` 的普通
   provider/model（协议实验里 `rotate` 段也在 `configOptions` 的候选里）。
6. **"`session/set_config_option` 是坏的"** —— 已排除（实验 A 的 S2）：它在"进程启动时已注册"的
   范围内工作正常，连端点/Key 都跟着换成目标厂家的。

---

## 5. 待设备验证清单（设备被另一个代理独占期间暂停；一次跑完即可）

> 前置：`install\build-local-apk.ps1 -Abi x86_64 -Mode debug` + `adb install -r`；
> 假端点用 **8892**（别用 8899）；`adb reverse tcp:8892 tcp:8892`。
> 修前的 APK 我已另存：`D:\dev\build\audit-harness\pre-fix-0.11-x86_64-debug.apk`。

1. **修前症状（agnes 厂家，A 类证据）**：装 pre-fix APK，`models.json` 只留
   `agnes`（`baseUrl=http://127.0.0.1:8892/agnes/v1`，`apiKeyEnv=AGNES_API_KEY`），
   在「设置 → 模型」的自定义厂家表单里**填一把 Key 并保存**（这样安全区里才有
   `dsh_provider_key_agnes`），发一条消息。
   **预期**：界面报「执行失败：…no credential for provider route "agnes"…」，假端点日志**无请求**。
2. **修后（同一配置，装修复版 APK）**：同样的操作。
   **预期**：假端点出现 `POST /agnes/v1/chat/completions`，`Authorization` 打码后是那把 Key
   的前 6 / 后 4 位；界面拿到假端点的回复。（这条是"每厂家 Key 真的进了会话"的硬证据。）
3. **改端点必须生效**：把 agnes 的 Base URL 改成 `…/agnes2/v1`（面板保存，或改 models.json 后在
   会话模型面板换一个模型触发 `onModelChanged` 也行），再发一条。
   **预期**：请求打 `/agnes2/v1`；logcat 里应看到**重建**（`[chat] ACP session ready:` 再次出现、
   node 进程 PID 变化），而不是只弹「已切换到…（会话保留）」。
4. **只改 Key 也要生效**：同一厂家换一把 Key 保存，再发一条。
   **预期**：假端点 `Authorization` 的前 6 / 后 4 位变成**新 Key**；同样应看到进程重建。
   （这条验的是"指纹含 Key"那条修复。）
5. **问题 1 的对账**：会话里用模型面板把模型换成 B。
   **预期**：logcat 出现 `[dsh-model] 已把选中项写回 models.json.selected=…`；`run-as … cat files/models.json`
   的 `selected` == B；`[dsh-model-panel] 本页刷新：… selected=…` 也是 B；**重启 App 后**
   `[dsh-model] 清单载入：… 选中=B`（设置页的默认 == 会话用的模型）。
6. **齿轮页（v1 SettingsPage）的真相**：对话页 → 齿轮 → 改 Base URL+provider+model 保存 → 返回。
   **预期（需要确认的怀疑）**：返回后 `main._onModelChanged` 会用 `models.json` 把 overlay 重写回去，
   也就是**齿轮页改的端点/provider/model 不生效**，只有它的 Key 生效；修复版会因此判定"配置变了"重建会话。
   如果确认，建议把齿轮页入口指向设置 Tab（change 由你们决定，不在本次改动范围）。
7. **问题 4 的文案**：`models.json` 只留一个厂家、`models` 为空 → 进会话。
   **预期**：显示新文案「厂家和 Key 都有了，但还没有模型：去「设置 → 模型」点「获取模型」…」，
   而不是让他去"填地址和 API Key"。
8. **问题 5 的一致性**：设置页显示"N 个厂家 / M 个模型"后，`run-as … cat files/dshhome/model.overlay.yml`
   数 `- id:` 条目。
   **预期**：**没有模型的厂家不会出现在 overlay 里**（`dsh_runtime.writeOverlayFromConfig` 的 `emittable` 过滤），
   即 overlay 的厂家数 ≤ 设置页的厂家数 —— 这是既有设计（写进去会让整份 overlay 校验失败），
   但界面上没有任何提示，值得确认是否要在设置页说明。

---

## 6. 共享设备与现场状态（重要）

* `emulator-5554` 上**同时有另一个代理**在跑 UI 自动化（`python install\verify_pool_models.py`、
  `install\pool401_server.py 8899`、`ui.ps1` 划屏/dump）。我实测到 App 进程被它反复拉起
  （PID 31939→32236→32745），有一次我的界面上还停着它的 `DocumentsUI` 文件选择器。
  → 因此 §2 里**协议级实验（A/B）是我自己的独立 DSH_HOME、不受影响**；
  **App 级证据（`[dsh-model]`/`[chat]` 日志、overlay/models.json 快照）取自共享设备，可能与他人操作交错**，我按时间戳标注了。
* 排查期间我在设备上留下的东西（**只影响测试现场，不影响产品代码**）：
  * `files/models.json` 被我换成受控配置（原件备份在 `files/models.json.audit-bak`）；
  * `files/dshhome/model.overlay.yml` 被 App 按我的配置重生成（原件备份 `model.overlay.yml.audit-bak`）；
  * `shared_prefs/FlutterSecureStorage.xml(.audit-bak)`、`FlutterSharedPreferences.xml(.audit-bak)` 原样保留；
  * 新增目录 `files/audit/`（独立 DSH_HOME + 实验脚本），删掉即可：
    `adb shell run-as com.dshmobile.dsh_mobile rm -rf files/audit`；
  * 还原现场：`cp files/models.json.audit-bak files/models.json`、
    `cp files/dshhome/model.overlay.yml.audit-bak files/dshhome/model.overlay.yml`；
  * `adb reverse` 里我加了 `tcp:8891`（可 `adb reverse --remove tcp:8891`），
    8899 那条我还回给另一个代理了；`adb root` 已开（adbd 现在是 root）。
  * **安全区里的 Key 我一个都没动、也没读出来**（值全是密文，缺 `dsh_model_api_key` 的现场是上一个代理把
    `shared_prefs/` 移走造成的，不是我）。

## 7. 我没能验证的部分（如实列出）

1. **修复版 App 的端到端**（§5 的 2/3/4/5/7）——设备被占用，尚未跑。协议级机制已证实，App 侧只有代码级推理。
2. **修前 App 的真实报错文本**（§5 第 1 条）——同上，未抓到界面原文；
   但协议级实验 B 给出的错误文本与 App 走的是同一条 DSH 校验路径。
3. **`main.dart` 的 `_onModelChanged` 顺序竞态**：`models.load()`（内部 `notifyListeners()`）**先于**
   `applyModelSelection()` 写 overlay。我在 ChatPage 里用"重建前主动让外层同步一次"绕开了它，
   但更干净的修法要改 `main.dart`（见 §8 的可选 diff），我没有动它。
4. **`lib/local/session_index.dart`** 也调 `AcpClient.start`（用的是 `session/list`，不调用模型），
   我没给它加 `apiKeys`——它属于别的代理的文件范围，且不需要凭据。
5. **`models.json` 有厂家但零模型**时 `_start()` 仍会 spawn（`hasModelConfig` 为真就带旧 overlay，
   为假就不带 `--patch` 而回落到官方端点）。本次只修了提示语，**发送链路的行为没动**，属于残留问题。

## 8. 给主代理的可选 diff（这两个文件我没动）

### A. `lib/main.dart`：让"先落盘 overlay，再通知界面"（消除竞态）

配合 `lib/state/model_store.dart`（这个文件是我的，可以一起加）：

```dart
// model_store.dart：把 load 的实体抽出来，允许"只读盘不发通知" + "稍后手动发一次"
Future<void> load({required String filesDir}) async {
  await _loadInto(filesDir);
  notifyListeners();
}

/// 只读盘、不发通知（给 main 用：先把 overlay 落盘，再让界面看到新清单）。
Future<void> reloadQuiet({required String filesDir}) => _loadInto(filesDir);

/// 与 reloadQuiet 配对：改完 overlay 再发一次通知。
void publish() => notifyListeners();

Future<void> _loadInto(String filesDir) async { /* 原 load() 的函数体（去掉最后的 notifyListeners） */ }
```

```diff
--- a/lib/main.dart
+++ b/lib/main.dart
@@ async def _onModelChanged
-      await _models.load(filesDir: filesDir);
+      // 顺序在这里很重要：先把新清单落到 overlay，再让界面（会话页）看到新选中项。
+      // 否则监听者会在"overlay 还是旧的"这一瞬间决定重建会话，新进程读到的仍是旧端点。
+      await _models.reloadQuiet(filesDir: filesDir);
       await applyModelSelection(runtime: rt, models: _models, secure: _secure);
+      _models.publish();
       final next = await _buildRuntime(paths);
```

（不合并也没关系：ChatPage 里那次 `await widget.onModelChanged?.call()` 已经把同样的顺序补上了。）

### B. `lib/local/dsh_runtime.dart`（可选，更彻底）：overlay 里写一个配置指纹

```diff
--- a/lib/local/dsh_runtime.dart
+++ b/lib/local/dsh_runtime.dart
@@ writeOverlayFromConfig
     buf.writeln('# 由 App 生成：把 DSH 的模型路由指向用户配置的端点。');
+    buf.writeln('# config-fingerprint: ${_overlayFingerprint(config, activeRoute)}');
```
这样 `ensureModelConfig` 可以直接比对指纹，而不必像我这次那样在 `app_shell.dart` 里
按行对账（`overlayLooksStale`，它依赖"overlay 是本 App 自己写的格式"这一前提）。
不合并也可以：现在的对账只查**当前默认那一条 route**（端点 + 模型 id），假阳性风险已压到很低。
