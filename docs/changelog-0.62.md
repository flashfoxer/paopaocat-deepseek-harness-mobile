# 泡泡猫 DSH 手机版 v0.62 · 更新说明

> 本版做两件事：
> 1. **影视工具真的能用多个厂家了**（图像 + 视频）—— 你 2026-10-11 纠正我：
>    「只认 Agnes 那套形状」是我写死的限制，不是能力限制；
> 2. **本地大模型「启动不了」的根因找到并修好** —— 靠你发回的那份真机日志
>    （`dsh-report-20261011-232851.txt`，nubia NX809J / v0.60 / Android 16）。

---

## 1. 影视工具按厂家换请求形状（图像 + 视频）

### 你纠正得对，那是我的限制

以前手机版「换厂家」只换了**网址和 Key**，请求本身还是 Agnes 那一套：
端点路径、参数名（`size` 是 `1K/2K` 档位）、返回结构（`/agnesapi?video_id=`）
全是写死的。所以换成别家必然失败 —— 而失败的样子看起来像「别家不支持」。

桌面版影视工具是按**模型名 + 厂家**路由到不同端点、用各自的形状发请求的。
手机版现在也一样。

### 做法：一份形状表，脚本和界面都读它

新增 `app/assets/toolbox/media-vendors.mjs` —— **形状的唯一来源**（纯计算、不碰网络、
可干跑）。它导出 `imagePlan(vendorId, req)` / `videoPlan(vendorId, req)`，
每个 plan 自带 `submit` / `taskIdOf` / `poll` / `pick`。

| 厂家 | 图像形状 | 视频形状 |
|---|---|---|
| Agnes | `/v1/images/generations`，`size` 是档位，`extra_body` 放 `response_format` / 参考图 | `POST /v1/videos` → 轮询 `/agnesapi?video_id=…` → `metadata.url` |
| OpenAI | `/v1/images/generations`（带参考图改走 `/v1/images/edits` multipart） | **不支持** |
| 智谱 GLM | `open.bigmodel.cn/api/paas/v4/images/generations` | 不支持 |
| 豆包 Seedance（火山方舟） | `ark.cn-beijing.volces.com/api/v3/images/generations` | `POST …/contents/generations/tasks`（`content[]` + `duration`）→ 轮询 tasks |
| MiniMax | `api.minimax.cn/v1/image_generation`（吃 `aspect_ratio`） | 提交在 `/v2`、查询在 `/v1` |
| 通义万相（百炼） | `…/api/v1/services/aigc/text2image/image-synthesis`（异步） | `…/video-generation/video-synthesis`（异步）→ 轮询 `/api/v1/tasks/{id}` |
| 硅基流动 | `api.siliconflow.cn/v1/images/generations` | `POST /video/submit` → `POST /video/status` |
| 认不出的厂家 | 按 OpenAI 兼容形状试 | 不支持 |

### 界面按厂家换档位（不再拿一套参数硬套所有人）

- Agnes 的尺寸是 **1K / 2K / 3K / 4K 档位**，别家要 **1024x1024 这类像素值**；
  像素厂家那一栏的标签是「尺寸」，Agnes 是「清晰度」。
- **万相没有比例参数**（比例由尺寸表达）→ 比例那一行**不显示**，并写明原因。
- **MiniMax 的图像吃 `aspect_ratio`、不吃尺寸、也不吃参考图** → 参考图那一行不显示。
- **硅基流动的视频没有时长参数**（时长由模型决定）→ 时长不显示。
- **豆包 Seedance 不发分辨率档位**（由模型与比例决定）→ 分辨率不显示。
- 切换模型时，如果当前选的值这家没有，会**自动拉回这家第一项**并提示
  「已按这家支持的档位改成 X」—— 不静默改。
- 厂家在本 App 里没接视频（OpenAI / 自定义）时，**不给生成按钮**，
  而是说清「点上面的『换一个』选一家支持视频的厂家」。

### 设置里内置了端点（图像 6 家 / 视频 4 家）

「设置 → 图像 / 视频模型 → 添加模型」里，点一下厂家 chip 就自动填好
**端点 + 建议模型名 + 厂家 id**。模型名可以改（豆包要照控制台里的接入点 id 填）。

**顺带修掉两个"填了就必然 404"的预设**（照着形状表逐条核对时发现的）：

- **万相**原来填的是 `…/compatible-mode/v1`（OpenAI 兼容入口）——
  万相的生图/生视频**没有**兼容入口，走的是异步协议。填错的后果是拼出
  `…/compatible-mode/v1/api/v1/services/…` → 404，看起来像"万相接不通"。
- **MiniMax** 原来填的是 `api.minimax.chat`（**国际站**），国内站是 `api.minimax.cn`。
- 另外**万相的尺寸写法是 `1024*1024`（星号）**：以前界面给的是 `1024x1024`，
  会原样发出去。现在形状表会把 `x` / `×` 统一换成该厂家要的分隔符。

### ⚠️ 边界（如实说）

本机**没有这些厂家的 Key，也没有安卓真机**。所以我能保证的是：
**发出去的形状按各家文档与桌面版已投产的实现写对了**，
并且失败时**把上游原话显示出来**（不吞错、不假装成功）。
我不能保证的是「上游一定收」—— 那要你用自己的 Key 试。

**Agnes 那条路一个字节都没动**（`make-video.mjs` 的 Agnes 分支有测试逐字钉住）。

---

## 2. 本地大模型「启动不了」：根因与修复

### 你那份真机日志把根因钉死了

日志里 23:28:18 → 23:28:38 连续 8 次：

```
引擎不存在：/data/app/…/lib/arm64/libllamaserver.so
```

**不是我原先猜的「启动失败」**。真正发生的是：

1. 你盘上留着一个**旧版本下载的 `.gguf` 模型**（llama.cpp 格式）；
2. llama.cpp 引擎**自 0.47 起就有意不随包**（它在骁龙 8 Elite 这类机型上处理长请求
   必然崩溃，所以下线了）→ 这个模型**永远起不来**；
3. 而「本地大模型」页判定"能不能跑"的写法是
   `entry == null || _engineAvailable(entry)` ——
   把**「清单里没有这个模型」当成了「那它肯定是能跑的（比如用户自己导入的）」**。
   旧 `.gguf` 正好不在新清单里 → 被判成能跑 → 界面给出「启动」按钮 → 一点就去找
   `libllamaserver.so` → 必然失败；
4. 更糟的是错误文案还写着「App 安装不完整，重装一次」—— **重装一百次也没用**。

### 四处修复

| # | 改哪 | 改成什么 |
|---|---|---|
| 1 | `ondevice_models_page.dart` 的 `_installedRow` | 判据改成**登记表里记的 engine**（老条目的默认值正好是 `llama.cpp`），不再拿"清单里有没有"当能跑的证明 |
| 2 | 同一行的小字 | 跑不了时**直接写明为什么**（以前只把「启动」按钮藏起来，一个字都不解释 —— 你看到的就是"点了没反应"） |
| 3 | `local_model_server.dart` | 引擎缺失时按引擎区分：`litert-lm` → 「引擎文件不在…（App 安装不完整，重装一次）」；其它 → 「这个模型要的是 llama.cpp 引擎，而它从 0.47 起就不随包了…请改用 Gemma 4 这类 .litertlm 模型」 |
| 4 | `local_chat_page.dart` | 「本地对话」的切换列表**不再列出跑不了的模型**，并如实说明「有 N 个模型本版跑不了，已从上面隐藏：…，可在『本地大模型』页删掉」 |
| 5 | `ondevice_models_page.dart` 下载按钮 | 加同一道闸：**引擎不在包里的模型不给下**（不再让你下一个必然跑不了的模型、白下几百 MB） |

### 你要做的

把那个旧 `.gguf` 删掉（「本地大模型」页有「删除」），改用 **Gemma 4 这类
`.litertlm` 模型**（同一页可以下载）。

---

## 3. 顺带补掉的两条「永远翻不了」的 i18n 缺口

不是新功能，是**机制上翻不了**的补齐（切英/日/韩会静默露中文，且现有检查发现不了）：

1. 设置里 6 家**图像预设的说明**是数据表里的字面量，界面原来用 `Text(presetNote)`
   原文显示 → 改成 `context.tr(presetNote)` + 加扫描器锚点；
2. 「本地对话」里那句带参数的提示原来走 `_toast('中文', args)` ——
   字面量不在 `tr(...)` 里，i18n 扫描器**看不见**它 → 表里没有 → 静默不翻。
   改成 `_toastMsg(context.tr('…', args))`。

新增 `media_models_test.dart` 的一条测试，钉住「以后再加预设也必须登记 + 有锚点」。

---

## 4. 本版验证（实际输出）

| 验证 | 结果 |
|---|---|
| `flutter analyze --no-pub` | `No issues found!` |
| `flutter test`（全量，排除两个批次性抖动的截图测试） | **564 passed / 3 skipped / 0 failed** |
| `node install/i18n/check-tables.mjs` | 源码 key **1258** 条 · 三张表各 1258 条 · 漏翻 0 · 陈旧 0 · 占位符错 0 · 换行错 0 · **完全一致 ✓** |
| `node assets/toolbox/media-vendors.mjs --selftest` | 13 个形状全过（exit 0） |
| 生图形状测试（新增 9 条） | 与 HEAD 版脚本对本地假服务器**逐字比对**：URL 相同、body 逐字相同 |
| 生视频形状测试（新增 11 条） | Agnes 那条逐字不变（`size:"720P"`、`seconds` 是字符串、`/agnesapi?video_id=`） |

**没做到的（如实列出）**：

- 没有这些厂家的真 Key、没有安卓真机 → 只证明「形状对」，不证明「上游收」；
- 多厂家这条路**没有在真机上跑过**（本机没有设备）；
- 本地模型那条修复也**没有在真机上验证**（同样没有设备）——
  但这次的判据是"包里有哪个 `.so`"，而真机日志已经证明 llama.cpp 的 `.so` 确实不在包里，
  所以那条 `.gguf` 会被正确判成"跑不了"，这一点是**由日志本身证明的**，不靠推测。

---

## 5. 出包与验签（2026-10-11）

| 项 | 值 |
|---|---|
| 文件 | `dist/paopaocat-preview-0.62-arm64-v8a.apk` |
| 大小 | 100,733,328 B（96.1 MB） |
| sha256 | `551b4c3ec35bb90074c17c70168bacfb0e458370076e4c4bb650793342233143` |
| versionCode / versionName | **62** / `0.0.62` |
| minSdk / targetSdk / compileSdk | 24 / 36 / 36 |
| 签名 | APK Signing Block + **v2 签名块**（id `0x7109871a`）；签名证书 = 调试证书（`~/.android/debug.keystore` 的 DER 在包内），与预览包口径一致；无 v1（JAR）签名，minSdk 24 下不需要 |
| ABI | 只有 `arm64-v8a`（`dshAbi=arm64-v8a`） |

`python3 install/check-release.py` → **7/7 全 PASS**：

```
[PASS] 版本同一       versionName = 0.0.62（与 pubspec 一致）
[PASS] 落盘表自检     11 个脚本的字符串都在包内 lib/arm64-v8a/libapp.so 里
[PASS] 资产同一       28 个资产在包里逐名一致，size + sha256 全部相同
[PASS] 运行时包       assets/dsh-runtime.zip  32.1 MB
[PASS] 引擎检查       没有任何 llama.cpp 相关库（已按 0.47 下线）
[PASS] 引擎检查       14 个运行时 dlopen 的库都在
[PASS] ffmpeg 架构    libffmpeg.so / libffprobe.so 都是 AArch64 ELF ✓
结论：全部通过 —— 这个包里的字节和当前源码树一致，可以发
```

**这个包只出了本地 APK，没有推仓库**（按用户定的规矩：推仓库必须另行确认）。
真机验证仍未做 —— 本机没有安卓设备，需要你把包装上后反馈。
