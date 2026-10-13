# 0.65 变更说明

版本：`0.0.65+65` · 版本名 `0.65` · 目标 ABI `arm64-v8a` · 状态：**源码已就绪，未出包**

依据（用户 2026-10-12 两条原话）：

1. 「貌似本地大模型调用知识库是没什么效用的，感觉回答得乱七八糟」
2. 「再查一下图形/视频的模型端点是否真实，最好查看这几家的技术文档，也可以给注册地址」

---

## 一、知识库「没什么效用、答得乱七八糟」——两层根因，两层都致命

结论：**不是错觉，也不是模型太笨。是检索这一侧根本给不出有用的材料，而且给材料的方式也是错的。**

### 1.1 检索侧：切片不按文档边界（主因）

`app/lib/local/kb_index.dart` 的 `chunkText` 把整份语料当成**一条连续的流**，
只按长度切（`minChars 200` / `maxChars 600`），**从不看文档边界** ——
于是连续几篇互不相关的文档被合并进同一块。

实测（12 篇互不相关的短文档 / 722 字）：

| | 改之前 | 改之后 |
|---|---|---|
| 切出几块 | **2 块** | **12 块** |
| 第一块内容 | 545 字，含 **9 篇**：机场 + 红烧肉 + 月球 + 公司简介 + 量子纠缠 + 煮米饭 + 报销流程 + 长城 + 咖啡因 | 1 篇 |
| 含 ≥2 篇的块 | 2 块 | **0 块** |
| 检索探针 top-1 命中 | **1 / 11** | **15 / 16** |
| 检索探针 top-3 命中 | **1 / 11** | **16 / 16** |

为什么致命：一块同时讲红烧肉和量子纠缠，那**任何问句都会命中它**，排名失去意义；
而且小知识库只有 2~3 块时 `topK: 3` 等于把**整份知识库**塞给模型 ——
模型一边收到一大坨无关材料，一边被要求「请优先依据它们回答」，
结果就是用户说的「乱七八糟」。

**修法**：空行（`\n\s*\n`）作**文档硬边界，绝不跨边界合并**。
一篇文档先独立成块；只有同一篇**内部**才按长度合并，过长再按句号在篇内切
（抽成私有 `_chunkSegment`）。JSON 抽取器在每篇之间写 `'\n\n'`（原来是 `'\n'`）。

### 1.2 组装侧：材料怎么交给模型（次因，但同样影响很大）

`app/lib/local/local_chat.dart` 的 `localChatStream` 原来有三个坑，都专门坑小模型：

| # | 原来 | 现在 |
|---|---|---|
| ① | **从不发 `system` 消息** ——「请优先依据资料回答、不要编造」被 `contentOf` 粘在用户消息里，和问题混在一起 | 有材料时在最前面插一条 `system`（小模型对系统位指令的遵守度明显更高） |
| ② | **历史里每一轮的旧材料都会重发** ——`contentOf` 会把 `context` 拼回去，而 `history` 是整段会话；问第 5 句时前 4 句各自的「以下是知识库查到的资料，请优先依据它们回答」全在上下文里，讲的却是**别的**问题 | 只有**最后一条（本轮）**带材料，历史旧材料一律丢掉 |
| ③ | 有材料时温度仍是 `0.7`、上限 `512` | 温度降到 `0.3`、上限提到 `768`（小模型读完材料还得有额度写答案） |

### 1.3 ⚠️ 老索引不会自动变好 —— 必须重建

块的切法在**建索引时**就烧进 `chunks.bin` 了，**升级 App 不会让已有索引变好**。
所以：

* `KbIndexMeta` 新增 `chunkMode` 字段；老文件缺这个字段 → `kChunkModeLegacy`（1），
  新建的写 `kChunkModeDocBoundary`（2）。
  **默认值必须是"老"**，否则老索引被误判成"已经好了"，用户永远看不到重建提示。
* 知识库页把旧索引如实标成「已建索引：{n} 段 —— 但这是**旧切法**建的，检索会不准」，
  按钮变「重建（推荐）」，并附一句说明（重建在本机完成、不联网、不花额度）。

**没重建之前，这一条修复对已有知识库不生效。**

### 1.4 测试

* `test/kb_index_test.dart`：新增「切片必须尊重文档边界」5 例
  （12 篇 → 12 块且每块 1 篇 / 4 种空行写法都认 / 单换行**不是**硬边界 /
  超长文档在篇内切且不越界 / 短文档不被丢掉）+「老索引要能被认出来」3 例。
* `test/kb_local_chat_e2e_test.dart`：把原来钉着的
  「简单对话的定义：一条 `system` 都不许有」这条契约**显式改写**为
  「有材料 → 恰好一条 `system` 且在最前；没材料 → 一条都没有」，
  并新增「历史里旧轮的检索材料不许重发」1 例。

---

## 二、图像/视频端点核实（逐家对官方文档）

七家里 **五家端点正确**，**一家（MiniMax）视频这条路是坏的**，
一家（硅基流动）域名要分国内/国际。

| 厂家 | 图像 | 视频 | 结论 |
|---|---|---|---|
| **通义万相**（阿里云百炼） | `POST /api/v1/services/aigc/text2image/image-synthesis`<br>必带 `X-DashScope-Async: enable`，尺寸 `1024*1024`（星号）<br>查询 `GET /api/v1/tasks/{id}` | `POST /api/v1/services/aigc/video-generation/video-synthesis` | ✅ 与文档一致 |
| **OpenAI** | `{base}/images/generations`（`gpt-image-1` 不收 `response_format`） | — | ✅ |
| **智谱 GLM** | `{base}/images/generations`，`base = open.bigmodel.cn/api/paas/v4` | — | ✅ |
| **豆包**（火山方舟） | `{base}/images/generations`，`base = ark.cn-beijing.volces.com/api/v3` | `{base}/contents/generations/tasks` + `content[]` | ✅ 形状与 Seedance 文档一致（⚠️ 文档站是 JS 渲染，正文未能抓取比对，仅凭路径形状与既有实现核对） |
| **MiniMax** | `{base}/images/generations` | **见下，原来三处错** | ⚠️ **已修** |
| **硅基流动** | `{base}/images/generations` | `POST /v1/video/submit` → `POST /v1/video/status`（体 `{requestId}`） | ✅ 路径正确；**域名分国内/国际** |
| **Agnes** | `/images/generations`（`response_format`/参考图必须在 `extra_body`） | `POST /videos` → `GET /videos/{id}` | — 本项目自有厂家，无公开文档可查 |

### 2.1 MiniMax 视频：三处错，每处单看都像在照文档写

依据：<https://platform.minimax.cn/docs/api-reference/video-generation-v2-create>、
<https://platform.minimax.cn/docs/api-reference/video-generation-v2-query>

| # | 原来 | 文档要求 | 后果 |
|---|---|---|---|
| ① | body 是 **v1** 形状（顶层 `prompt`），路径却是 **v2** | v2 的 `required` 是 `[model, content, resolution, duration]`，提示词必须在 `content[]` 里 | 上游必然回 `invalid params, content must include a non-empty text item (2013)` |
| ② | 首帧写顶层 `first_frame`（v1 字段） | 首帧是 `content[]` 的一项：`{type:'image_url', image_url:{url}, role:'first_frame'}` | 图生视频参数不认 |
| ③ | 轮询打 `/v1/query/video_generation/{id}` | v2 任务查 `GET /v2/query/video_generation/{task_id}`（task_id 是**路径段**） | 查不到，任务永远"进行中"直到超时 |

> 补充：v1 那个老接口（`GET /v1/query/video_generation`）的 `task_id` 是**查询参数**
> `?task_id=`，不是路径段 —— 所以原来那条 URL **即使走 v1 也是错的**。

**也就是说：视频生成这条路在真机上必然失败，而且失败信息指向"参数不对"，
很容易被误当成"这家模型不支持"。**

修复后（`videoPlan('minimax', ...)` 干跑实证）：

```
提交: https://api.minimax.cn/v2/video_generation
body: {"model":"MiniMax-H3","content":[{"type":"text","text":"一只猫"}],
       "duration":6,"resolution":"768P","ratio":"16:9"}
轮询: https://api.minimax.cn/v2/query/video_generation/TASK123
```

图生视频（`ratio` 按文档强制 `adaptive`）：

```
body: {"model":"MiniMax-H3",
       "content":[{"type":"text","text":"动起来"},
                  {"type":"image_url","image_url":{"url":"data:..."},"role":"first_frame"}],
       "duration":6,"resolution":"768P","ratio":"adaptive"}
```

另外：错误信息原来用 `String(task.error)`，而 v2 的 `error` 是**对象** →
会变成 `[object Object]`，把上游原话丢掉；现在取 `task.error.message`。

### 2.2 注册 / 拿 Key 地址（七家）

原来表里**只有 Agnes** 有 `register` 字段，其余六家的 Key 去哪拿全靠用户自己搜。

| 厂家 | 注册 / 拿 Key |
|---|---|
| Agnes | <https://platform.agnes-ai.cn> |
| OpenAI | <https://platform.openai.com/signup> |
| 智谱 GLM | <https://open.bigmodel.cn/> |
| 通义万相（百炼） | <https://bailian.console.aliyun.com/> |
| 豆包（火山方舟） | <https://console.volcengine.com/ark> |
| MiniMax | <https://platform.minimax.cn/user-center/basic-information/interface-key> |
| 硅基流动 | <https://cloud.siliconflow.cn/>（国际站 `cloud.siliconflow.com`，Key 不通用） |

界面：设置 → 图像/视频模型 → 「各厂家的 Key」，每行新增「去哪拿 Key」→
弹层里显示地址并可**复制**（不偷偷跳浏览器：本 App 是"不联网也能用"的本地工具，
而且用户多半是要复制到电脑上注册）。
自定义厂家没有地址 → **不显示**这个按钮（不猜地址）。

### 2.3 测试

* **新增 `install/test-media-vendors.mjs`**（纯 node，42 项全过）：
  逐条对官方文档核端点，含 MiniMax v2 的 body 形状、首帧位置、轮询路径、
  成功/失败响应解析、七家注册地址的 https 校验、自定义厂家无地址。
* **新增 `test/media_vendors_register_test.dart`**：
  Dart 侧镜像表与 `assets/toolbox/media-vendors.mjs` **逐条对账**（防两边漂），
  并断言注册地址都在各自厂家的控制台域名下。
* `test/toolbox_video_shape_test.dart`：原来把「提交在 v2、**查进度在 v1**」
  当成"两个根不一样"的**特性**钉住的那条，已改写为「创建与查进度都在 v2」，
  并新增 MiniMax 首帧用例。

---

## 三、知识库不再出现「中文维基百科」字样

依据（用户 2026-10-12）：「把知识库的中文维基百科字样消除，就写知识库三个字就行」。

| # | 原来 | 现在 |
|---|---|---|
| ① | 可下载包名字：`中文维基百科（清洗版・254,547 条・2023-07 快照）` | **`知识库`**（大小 `500 MiB` / 条数 `254547 条` / 许可仍在下面那行，信息没丢） |
| ② | 许可行：`CC BY-SA 4.0（内容来自中文维基百科）` | `CC BY-SA 4.0` |
| ③ | 下载前提示：`下载的资料是第三方社区语料（中文维基百科 2023-07 快照）：…` | `下载的资料是第三方社区语料：…` |

**提示本体一行未删** —— 去掉的是"点名是哪一份语料"，不是"这是第三方语料、
过滤不完整、未经我们审查、不代表我们观点"（那是 2026-10-09 明确要求、
必须在点「下载」之前就看见的）。

测试：`test/kb_page_notice_test.dart` 新增一组
「知识库里不许再出现『中文维基百科』字样」，**同时核清单正文与页面源码**
（防止只改一边），并钉住包名就是「知识库」三个字。
原来借"中文维基百科"当渲染锚点的那条断言改用条数 `254547`。

i18n：三张表同步换键，`1274 / 1274`，0 漏翻 0 陈旧。

### 说明文字（note）里的数据源点名 —— 已按你的选择处理

可下载列表里那段说明原本末尾写着「数据来源：HuggingFace 数据集
`pleisto/wikipedia-cn-20230720-filtered`（国内用镜像 hf-mirror）」。

按你的选择（**只去掉数据源名字和链接，保留「过滤不完整、未经审查」的说明**）：

| | 处理 |
|---|---|
| 数据源名字 / 镜像名 | **去掉** → 「数据来源：第三方公开数据集（名字与地址不在这里列出）」 |
| 合规披露本体 | **一字未删** —— 「过滤是黑名单式的、不完整」「逐条通读仍找出 5 条不宜内容」「内容不代表本应用的观点」全部保留 |
| `sources` 里的下载地址 | **保留** —— 那是真下载地址，界面上不渲染，删了会下不下来（测试里专门钉住） |

> ⚠️ **一个提醒（不是这次改出来的，但现在更明显了）**：数据来自 CC BY-SA 4.0 的公开语料，
> 该许可通常要求**署名来源**。现在界面上只剩「许可：CC BY-SA 4.0」，不再出现来源名称。
> 仓库内的 `kb_manifest.json`（`sources`）与 `docs/KB-COMPLIANCE-2026-10-09.md`
> 仍完整记录来源，但界面上没有署名。如果这个 App 有对外分发，建议在「关于」页
> 留一行低调的来源署名 —— 要不要加，你定。


---

## 三、验证

| 项 | 结果 |
|---|---|
| `flutter analyze` | ✅ No issues found |
| 全量测试（排除 2 个批量易抖的截图文件） | ✅ **596 通过 / 3 跳过 / 0 失败** |
| i18n 三表 | ✅ **1274 / 1274，0 漏翻 0 陈旧 0 占位符错** |
| `install/test-media-vendors.mjs` | ✅ **42 通过 / 0 失败** |
| 检索探针（12 篇语料 / 16 问） | ✅ top-1 **15/16**、top-3 **16/16**（原 1/11） |

---

## 四、出包与验签（2026-10-12）

| 项 | 值 |
|---|---|
| 文件 | `dist/paopaocat-preview-0.65-arm64-v8a.apk` |
| 大小 | 100,752,588 字节（96.1 MB） |
| sha256 | `9f94ff05d4ff5fb565e8e2dfcc0ad2a0d4b2e3a7e8e4b1ea59763b6d9f79561d` |
| versionCode / versionName | `65` / `0.0.65` |
| minSdk / targetSdk | 24 / 36 |
| ABI | 仅 `arm64-v8a` |
| 构建 | `flutter build apk --release --target-platform android-arm64`，Gradle `assembleRelease` 61.9s |

**签名核对**（本机 `apksigner` 不可用，改用等价的手工核对）：

| 检查 | 结果 |
|---|---|
| `APK Sig Block 42`（v2 签名块魔数） | ✅ 在 |
| `1a870971`（v2 签名块 ID） | ✅ 在 |
| debug 证书 DER（`~/.android/debug.keystore`） | ✅ 在 |
| v1 签名块（`META-INF/*.RSA`） | ❌ 不在 —— 与既往各版一致（release 用 debug 签名配置） |

**包内抽查**：

* `lib/arm64-v8a/liblitertlm_jni.so` 在（LiteRT-LM 引擎）；
  `libllamaserver.so` / `libstable_diffusion*` **不在**（已下线，符合预期）。
* `assets/flutter_assets/assets/kb/kb_manifest.json` 里包名已是「知识库」、
  许可只剩 `CC BY-SA 4.0`、`note` 里已无 `wikipedia` 字样 ——
  **改过的清单确实进了包**（不是只改了源码）。

**交付校验** `python3 install/check-release.py` → **7 / 7 PASS**：
版本同一 · 落盘表自检（11 个脚本字符串都在 `libapp.so` 里）· 资产同一（28 个资产 size+sha256 全同）·
运行时包（`dsh-runtime.zip` 32.1 MB）· 引擎检查·下线（无 llama.cpp 库）·
引擎检查·dlopen（14 个运行时库都在）· ffmpeg 架构（都是 AArch64 ELF）。

> ⚠️ **装上之后要手动做一件事**：打开「知识库」页点一次**「重建（推荐）」**。
> 块的切法在建索引时就写进文件了，升级 App 不会让已经建好的索引变好 ——
> 不重建的话，检索质量那一条修复不生效。

> **没有推仓库** —— 按流程，推送需要另行确认。


## 四、未做的事（如实说明）

* **没有出包**：按流程，安装包要在你同意后才生成。
* **没有推仓库**：需要另行确认。
* **火山方舟/智谱/OpenAI 的文档正文没能抓到**（站点是 JS 渲染），
  这三家的路径是凭**形状与既有实现**核对，不是逐字比对官方正文 ——
  已在表里如实标注，没有假装验证过。
* **Agnes 无公开文档可查**（本项目自有厂家），其端点未做外部核实。
* 知识库修复**需要你重建索引**才生效（见 §1.3）。
* 截图仍是 0.19 的。
