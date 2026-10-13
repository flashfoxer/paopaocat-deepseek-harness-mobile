# W1 · DSH ACP 服务端行为实测报告

- 实测日期：2026-10-02
- DSH 版本：`0.1.7-rc.2`（`D:/Programs/PaopaocatDSH/app/lib/bin.js`）
- ACP 客户端实现：`probes/acp-probe.mjs`（手写换行分帧 JSON-RPC 2.0，无 SDK 依赖）
- 夹具：`fixtures/acp-probe-*.jsonl`（全量原始帧）、`fixtures/acp-probe-*.summary.json`
- 协议契约来源：`@agentclientprotocol/sdk@1.4.0` 的 `schema/schema.json`（ACP v1）

> 本报告只写**实测到的**行为。凡是推断，都显式标注「推断」。

---

## 0. 结论摘要

1. **握手可用**：`initialize` 请求 `protocolVersion: 1`，服务端回 `1`，无需 `authenticate`（`authMethods: []`）。
2. **能力比宣传的更窄**：`sessionCapabilities` 只有 `close` / `list` / `resume`；**没有** `delete` / `fork` / `additionalDirectories` / `loadSession`；**`promptCapabilities.image = false`**（当前配置下不能发图）。
3. **流式是「消息级」不是「token 级」**：300+ 字的中文回答仍只产生 **1 个** `agent_message_chunk`。这对 App 渲染是重大利好——不需要增量渲染骨架。
4. **权限审批真的会触发**，且是唯一的 agent→client 请求（无 fs / terminal / elicitation 请求）——说明 **DSH 用自己的工具，不依赖客户端环境能力**。
5. **审批选项只有 `allow_once` / `reject_once`**，没有 `allow_always`。"本次会话允许"必须由桥自己记忆实现。
6. **会话跨进程持久化**：新进程 `session/list` 能看到并恢复之前进程创建的会话。
7. **沙箱与审批由一个旋钮捆绑控制**（`DSH_PERMISSION_MODE`），且沙箱工作区根 = 子进程的 `process.cwd()`。**工作目录 ACL 不可改会让工具直接失败**（详见 §6）——这是桥必须处理的部署前置。

---

## 1. initialize（握手）

请求：

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
  "protocolVersion":1,
  "clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false},
  "clientInfo":{"name":"dsh-mobile-probe","version":"0.1.0"}}}
```

实测响应：

| 字段 | 实测值 |
|---|---|
| `protocolVersion` | `1`（请求 1 → 协商 1） |
| `agentInfo` | `{ "name": "deepseek-harness-acp", "version": "0.0.1" }` |
| `authMethods` | `[]`（无认证方法；ACP 的 `authenticate` 是空操作） |
| `agentCapabilities.mcpCapabilities` | `{ "http": true }`（无 sse / acp） |
| `agentCapabilities.promptCapabilities` | `{ "image": false, "audio": false, "embeddedContext": false }` |
| `agentCapabilities.sessionCapabilities` | `{ "close": {}, "list": {}, "resume": {} }` |
| `agentCapabilities.loadSession` | 未出现（= 不支持） |

**必须记住的三条**：

- `loadSession` / `delete` / `fork` / `additionalDirectories` 都**不可用**，桥不能设计依赖它们的 UI。
- `image: false` 意味着**不能通过 ACP 内容块发图**。图片方案见 §7。
- ACP TS SDK 1.4.0 的 schema 里有 `delete`/`fork`/`plan`/`elicitation`/`terminal` 等一大堆定义，**但 DSH 一个都没公布**——不要照着 SDK schema 写功能。

### 图片内容块：实测印证（`probes/image-probe.mjs`）

只看到能力声明"不支持"还不足以定方案，所以实际发了一张 1×1 PNG（`text` + `image` 两个 block）：

```json
{"jsonrpc":"2.0","id":3,"error":{"code":-32602,
 "message":"Invalid params: inline image prompts were not advertised by this connection"}}
```

- 拒绝发生在**参数校验阶段**（`-32602`），**没有触发模型调用**；
- 报错文案明确指向"本连接未公布 inline 图片能力"；
- 与 `published capability: image=false` 完全一致。

→ **结论**：手机上发图必须走「桥把文件落到工作区 + prompt 里给路径」，不能走 ACP image block。
桥在收到 App 的图片时应主动拒绝并给出可读提示，而不是把原始 `-32602` 透给用户。

---

## 2. session/new（建会话）

请求：`{ "cwd": "<绝对路径>", "mcpServers": [] }`（两个参数都必填。）

实测响应：`{ sessionId: "<uuid>", configOptions: [...] }`，**没有 `modes` 字段**。

`configOptions` 实测（本机 `com` provider 下）：

| id | name | category | type | 说明 |
|---|---|---|---|---|
| `model` | Model | `model` | `select` | 分组 options（`deepseek-official`、`com` 两组），value 形如 `["com","deepseek/deepseek-v4.1-flash"]` |
| `reasoning_effort` | Reasoning effort | `thought_level` | `select` | **仅当所选模型声明了推理选项时出现**：官方 deepseek 路由下有 `off/low/high/max`；切到 `com` 路由后该项消失 |

**实测结论**：`sessionId` 是 UUID；模型与推理强度都是**会话级**配置项，通过 `session/set_config_option` 串行修改（本次未实测该方法的参数形态，列为待验证项）。

---

## 3. session/prompt 与 session/update（核心）

`session/prompt` 返回 `{ stopReason: "end_turn" }`；流式内容全部走 `session/update` 通知。

### 3.1 实测到的 update 类型与真实结构

| `sessionUpdate` | 实测结构 | 频度 |
|---|---|---|
| `agent_message_chunk` | `{ messageId, content: { type: "text", text } }` | **整条消息 1 次** |
| `agent_thought_chunk` | `{ messageId, content: { type: "text", text } }` | 1–4 次 |
| `tool_call` | `{ toolCallId, title, kind, status: "in_progress", rawInput: { command, description } }` | 每个工具 1 次 |
| `tool_call_update` | `{ toolCallId, status: "completed"｜"failed", content: [{ type: "content", content: { type: "text", text } }] }` | 每个工具 1 次 |
| `usage_update` | `{ used, size }` | 1–5 次（较频繁） |

真实样本（节选）：

```json
{"sessionUpdate":"agent_message_chunk","messageId":"3a90f4da-…","content":{"type":"text","text":"我是运行在 DSH 终端环境里的编码智能体…"}}
{"sessionUpdate":"agent_thought_chunk","messageId":"3a90f4da-…","content":{"type":"text","text":"The user asks me to introduce myself…"}}
{"sessionUpdate":"tool_call","toolCallId":"call_00_t2imc8…","title":"pwsh","kind":"other","status":"in_progress","rawInput":{"command":"echo dsh-acp-probe-ok","description":"Echo probe string to stdout"}}
{"sessionUpdate":"tool_call_update","toolCallId":"call_00_t2imc8…","status":"completed","content":[{"type":"content","content":{"type":"text","text":"dsh-acp-probe-ok\r\n"}}]}
{"sessionUpdate":"usage_update","used":6283,"size":1000000}
```

### 3.2 三条对实现有直接影响的结论

1. **消息是整块提交的**。用「用约 300 字介绍你自己」提示词实测，`agent_message_chunk` 仍然只有 **1 次**，一次性给出全部 300+ 字。→ App 不需要为增量 token 做特殊渲染；按 `messageId` 追加/替换即可。
2. **`messageId` 不能区分 thought 和 message**：同一次回答里，`agent_thought_chunk` 与 `agent_message_chunk` 的 `messageId` **完全相同**。分流必须靠 `sessionUpdate` 字段。
3. **工具详情只在 `tool_call` 里，权限请求里没有**：`session/request_permission` 的 `toolCall` 只带 `toolCallId`。App 必须先缓存 `tool_call` 的 `rawInput`，用 `toolCallId` 回查，才能在审批弹窗里显示"要执行的命令"。

粒度统计（一次含工具的对话）：17 个 update，字节数 min 59 / max 3137 / **avg 399**。
→ **不需要 token 级节流**；`usage_update` 可合并或降频即可。

---

## 4. 权限审批（agent → client）

实测请求：

```json
{"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{
  "sessionId":"252fa4e3-…",
  "toolCall":{"toolCallId":"call_00_w6xmhparmt3xo2z1e65ue5ck"},
  "options":[
    {"optionId":"allow-once","name":"Allow once","kind":"allow_once"},
    {"optionId":"reject-once","name":"Reject","kind":"reject_once"}]}}
```

客户端应答（实测可用）：

```json
{"jsonrpc":"2.0","id":0,"result":{"outcome":{"outcome":"selected","optionId":"allow-once"}}}
```

要点：

- **服务端请求 id 从 `0` 开始**，与客户端的 id 空间独立——桥必须用独立计数器处理双向请求。
- **只有 `allow_once` 与 `reject_once`**，没有 `allow_always` / `reject_always`。"本次会话允许"要在桥侧自己记住并自动应答，不能指望协议。
- 拒绝的另一种合法应答是 `{"outcome":{"outcome":"cancelled"}}`（规范要求：收到 `session/cancel` 时必须用它结算所有待决权限请求）。
- **不是每条命令都会问**：沙箱内允许的操作直接执行（实测 `echo` 未触发审批）。审批只在需要更高权限时出现。→ 手机端的审批 UI 是"提权请求"，不是"每条命令确认"。

---

## 5. session/list / session/close / session/resume

| 调用 | 实测结果 |
|---|---|
| `session/list` | 返回 `{ sessions: [{ sessionId, cwd }] }`。**只列非活跃（已关闭、可恢复）的会话**；当前活跃会话不在其中。条目只有 `sessionId` 与 `cwd`，**没有标题/时间戳** |
| `session/close` | 返回 `{}`；关闭后会话仍出现在 `session/list` 里（可恢复） |
| 跨进程 | 新起的 ACP 进程能列出并恢复**上一个进程**创建的会话 ✓ |

`session/resume` 未实测（契约存在、`sessionCapabilities.resume` 已公布），列为待验证项。

---

## 6. 权限模式与沙箱（部署关键）

配置树实测（`--dump-config`）：

```yaml
- id: sandbox-policy
  config:
    mode: !!js process.env.DSH_PERMISSION_MODE ?? 'workspace-write'
    workspaceRoot: !!js process.cwd()        # ← 沙箱工作区根 = 子进程 cwd
- id: approval
  config:
    policy: !!js >-
      (process.env.DSH_PERMISSION_MODE ?? 'workspace-write') ===
      'danger-full-access' ? 'never' : 'ask'
- id: permission
  config:
    presets:
      read-only:          { sandbox: read-only,          approval: ask  }
      workspace-write:    { sandbox: workspace-write,    approval: ask  }
      danger-full-access: { sandbox: danger-full-access, approval: never }
```

三种模式的实测对照：

| `DSH_PERMISSION_MODE` | 沙箱 | 审批 | 实测结果 |
|---|---|---|---|
| 未设（默认 `workspace-write`） | workspace-write | `ask` | 触发权限请求；**在 ACL 不可改的目录下工具失败** |
| `workspace-write`（cwd = `C:\Users\25894\…`） | workspace-write | `ask` | 工具 `completed`，未触发审批（沙箱内操作） |
| `danger-full-access` | danger-full-access | `never` | 工具 `completed`，**永不触发审批** |

**踩到的坑（必读）**：当 `cwd` 位于权限异常的目录（本次是 `D:\新建文件夹\…`）时，工具执行报：

```
Error: SetNamedSecurityInfoW failed (Win32 5): grantWrite(<cwd>)
```

原因是 workspace-write 沙箱需要对 `process.cwd()` 授予写权限，而该目录的 ACL 改不动。**换到 `C:\Users\<用户>\…` 后立刻正常**。

对桥的三条硬要求：

1. 桥 `spawn` dsh 时**必须显式指定 `cwd`**，且该目录必须 ACL 可改（用户正常的工作目录没问题；深层中文路径 / 受控目录可能不行）。
2. 桥必须把 `DSH_PERMISSION_MODE` 做成**显式配置项**，并在启动时自检：跑一次无害工具，把沙箱失败作为**启动期诊断**暴露到 App（而不是等用户踩到）。
3. **要"手机上能审批"，就必须用 `workspace-write`（`approval: ask`）**；`danger-full-access` 会让审批彻底失效。二者不可兼得——这是产品取舍，不是 bug。

---

## 7. 对原架构假设的修正

| 原假设 | 实测结论 |
|---|---|
| "ACP 增量粒度太细（每 token 一条），桥必须做节流" | **不成立**。是消息级提交，avg 399 字节。桥只需对 `usage_update` 合并 |
| "图片走 ACP image 内容块" | **不可用**（`image: false`）。图片应改为：桥把文件落到会话工作区，prompt 里用文本给出**相对路径**，让 Agent 用自己的文件工具读 |
| "审批可提供 允许一次 / 本次会话允许" | 协议只给 `allow_once` / `reject_once`。"本次会话允许"要么桥自己记忆，要么不做 |
| "桥必须防止 DSH 向客户端要 fs/terminal 能力" | 无需。实测 DSH **从不**发这类请求，只用自己 PC 上的工具 |
| "会话 id 跨重启稳定性未知，桥需要别名映射" | 仍然**需要**（`session/list` 返回的条目信息极少，且桥需要稳定的对外 id），但风险比预期低——恢复确实跨进程可用 |
| "需要自定义预设才能同时拿到沙箱与审批" | **不必要**。默认就是 `workspace-write + ask`，正是想要的组合；难的是目录 ACL，不是预设 |

---

## 8. 待验证项（下一轮）

1. `session/set_config_option` 的确切参数形态与返回（切模型 / 切推理强度）。
2. `session/resume` 的参数与语义：能否续上下文、恢复后历史是否可见。
3. `session/cancel` 的实际行为：`stopReason` 是否为 `cancelled`，待决权限请求是否被自动结算。
4. 多会话并发：一个 ACP 进程能同时跑几个会话、是否串行。
5. 长回答是否**真的**永远是单 chunk（需要一次明确的超长输出，例如要求输出 2000 字或一大段代码）。
6. ACP 子进程重启后，`session/list` 中会话的 `cwd` 是否仍可 `resume`（跨进程恢复的完整链路）。
7. `web_search` 工具在 ACP 下的行为——配置树里 `searchProvider: deepseek-official` + `apiKeyEnv: DEEPSEEK_API_KEY`，而该 key 在本机无效，**工具级搜索会 401**（桥需要一并覆盖这个行，或明确禁用搜索工具）。

---

## 9. 复现方式

```powershell
# 默认（workspace-write + ask）
node dsh-mobile/probes/acp-probe.mjs

# 指定权限模式与沙箱目录
$env:PROBE_PERMISSION_MODE = 'workspace-write'
$env:PROBE_SANDBOX = 'C:\Users\<you>\dsh-mobile-sandbox'
node dsh-mobile/probes/acp-probe.mjs
```

模型路由通过 `bridge/acp-model.overlay.yml` 以 `--patch` 叠加注入（**不改动 `$DSH_HOME/profiles/acp`**）：

```
node <dsh>/lib/bin.js --profile acp --patch <overlay.yml>
```
