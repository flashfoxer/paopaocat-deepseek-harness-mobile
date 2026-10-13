# DSH Mobile · 桥协议 v1

> 状态：v1 草案 · 基于 W1 实测（见 `../docs/W1-acp-findings.md`）
> 消费者：原生 App（Flutter）。**App 只实现本协议，不接触任何 ACP/DSH 内部概念。**

---

## 1. 传输与分帧

- **载体**：WebSocket。
  - 桥存在 `tls/bridge.pfx` 时监听 **`wss://`（默认）**，App 必须提供证书 SHA-256 指纹用于 pin；
  - `DSH_MOBILE_TLS=0` 时回退明文 `ws://`，**仅限 Tailscale 这类已加密的私有网络**。
- **指纹校验是强制的**：wss 下 App 若拿不到指纹或指纹不匹配，必须拒绝连接。
  禁止使用 `badCertificateCallback = (…) => true` 这种盲信任写法。
- **分帧**：一个 WebSocket text frame = 一个 UTF-8 JSON 对象。**不换行分帧**（与 ACP 不同，别混）。
- **上行限制**：单帧 ≤ 64 KiB；超出请分片或改走 `POST /upload`。
- **心跳**：App 每 **15 s** 发 `ping`；桥 **45 s** 未收到任何帧即判死链并关闭。不要用 ACP 侧的 2 s 心跳参数。
- **重连**：指数退避 1/2/4/8…上限 30 s，带抖动；网络路径变化时立即重连，不等超时。

## 2. 认证与配对

三条消息，全部是 App→桥请求 + 桥→App 响应式回执。

### 2.1 配对（一次性）

```json
→ {"v":1,"type":"pair","id":"c1","code":"482915","deviceName":"iPhone 15 · Bob"}
← {"v":1,"type":"pair_ok","id":"c1","deviceId":"dev_7f3a…","deviceToken":"<32字节随机，仅此一次下发>"}
```

- `code`：电脑端执行 `dsh-mobile-bridge pair` 生成，**6 位数字、TTL 120 s、一次性、连错 5 次锁 15 分钟**。
- 桥侧只存 `sha256(deviceToken)`；明文只在本次响应里出现。
- 配对成功时电脑端必须打印/提示"已与 <deviceName> 配对"并写审计日志。
- **v1 不做设备私钥签名挑战**（v1.1 加入）。风险由 Tailscale 的设备身份 + 可吊销 token 承担。

### 2.2 握手

```json
→ {"v":1,"type":"hello","id":"h1","deviceToken":"…","client":{"platform":"ios","appVersion":"0.1.0"}}
← {"v":1,"type":"hello_ok","id":"h1",
   "deviceId":"dev_7f3a…","protocolVersion":1,
   "host":{"name":"DESKTOP-XXX","dshVersion":"0.1.7-rc.2","cwd":"C:\\work\\proj","permissionMode":"workspace-write"},
   "sessions":[{"id":"s_1","cwd":"C:\\work\\proj","status":"idle","lastSeq":42,"updatedAt":1699999999}]}
```

握手失败返回 `error`，`code` 为 `auth_required`（没带 token）或 `auth_failed`（token 无效/已吊销）。

### 2.3 吊销

App 内"解除配对"或电脑端 `dsh-mobile-bridge devices revoke <deviceId>` → 该 token 立即失效，下次连接返回 `auth_failed`。

## 3. 会话

```json
→ {"v":1,"type":"list_sessions","id":"l1","cwd":"C:\\work\\proj"}
← {"v":1,"type":"sessions","id":"l1","sessions":[{"id":"s_1","cwd":"…","title":null,"status":"idle","lastSeq":42,"updatedAt":0}]}

→ {"v":1,"type":"new_session","id":"n1","cwd":"C:\\work\\proj"}
← {"v":1,"type":"session","id":"n1","session":{"id":"s_2","cwd":"…","configOptions":[…],"lastSeq":0}}

→ {"v":1,"type":"resume_session","id":"r1","sessionId":"s_1"}
← {"v":1,"type":"session","id":"r1","session":{…}}   # 随后按 §5 补拉历史

→ {"v":1,"type":"close_session","id":"x1","sessionId":"s_2"}
← {"v":1,"type":"closed","id":"x1","sessionId":"s_2"}

→ {"v":1,"type":"set_config","id":"g1","sessionId":"s_1","configId":"reasoning_effort","value":"low"}
← {"v":1,"type":"config","id":"g1","sessionId":"s_1","configOptions":[…]}
```

- `id` 是桥对外稳定的会话标识（桥自己生成，**不是** ACP 的 sessionId）。ACP 侧 id 变化不外泄。
- `status`：`idle` / `running` / `cancelling`。
- **`close_session` 语义 = 销毁**；App 里"返回列表/取消订阅"只能发 `unsubscribe`，绝不能发 `close_session`（ACP 无 `load`，关掉就拿不回上下文）。
- `title`：ACP 不提供标题，v1 恒为 `null`；App 用首条用户消息或时间戳自行生成显示名。

## 4. 消息与更新

```json
→ {"v":1,"type":"prompt","id":"p1","sessionId":"s_1","text":"…","clientMsgId":"m_abc"}
← {"v":1,"type":"accepted","id":"p1","sessionId":"s_1","clientMsgId":"m_abc","queued":true}
```

`accepted` 只代表**已入队**，不代表模型开始回答。真正内容走 `update`：

```json
← {"v":1,"type":"update","sessionId":"s_1","seq":43,
   "update":{"kind":"message","messageId":"…","text":"完整回答文本","complete":true}}
```

### 4.1 `update` 归一化类型（v1 全集）

| kind | 字段 | 说明 |
|---|---|---|
| `message` | `messageId, text, complete` | **整条消息一次到达**（实测：300+ 字仍单次提交）。`complete:true` 表示该 `messageId` 不再追加 |
| `thought` | `messageId, text` | 思考内容，UI 默认折叠。**注意：与 `message` 共用同一 messageId，必须靠 `kind` 区分** |
| `tool_call` | `toolCallId, title, toolKind, status, command?, description?` | `command` 来自 ACP 的 `rawInput.command`，用于展示与审批 |
| `tool_result` | `toolCallId, status, output` | `status`：`completed` / `failed`；`output` 为文本（超长截断后由 `hasMore` 标记） |
| `usage` | `used, size` | 上下文用量；**可合并/降频**，不保证每条都送达 |

> 桥**不**逐 token 推送，也**不**推送 ACP 原始帧。App 永远不会看到 `sessionUpdate` 之类的字段。

### 4.2 取消

```json
→ {"v":1,"type":"cancel","id":"c1","sessionId":"s_1"}
← {"v":1,"type":"session_status","sessionId":"s_1","state":"cancelling"}
```
取消完成后桥推 `session_status: idle`。App 在收到 `idle` 前**不要**发下一条 `prompt`（桥会回 `busy`）。

## 5. 订阅、seq 与断线补拉

- 每次连接后，App 对关心的会话发 `subscribe`：

```json
→ {"v":1,"type":"subscribe","id":"s1","sessionId":"s_1","fromSeq":40}
← {"v":1,"type":"subscribed","id":"s1","sessionId":"s_1","fromSeq":40,"toSeq":43,"needSnapshot":false}
← （随后补发 seq 40…43 的 update，再继续实时推送）
```

- `seq` 在**会话内单调递增**，桥保证同一会话内不跳号、不重复。
- `fromSeq` 超出桥的事件日志窗口（保留每会话最近 2000 条或 2 MB）→ `needSnapshot: true`，桥随后推一条 `update.kind = "snapshot"`：

```json
{"v":1,"type":"update","sessionId":"s_1","seq":1000,
 "update":{"kind":"snapshot","messages":[…],"status":"idle","pendingPermissions":[…]}}
```

- 补拉是**正确性**手段，不是优化：App 永远按 `seq` 去重排序；重复的 `clientMsgId` 视为同一条指令。
- 桥不提供云端历史；历史真相在电脑上，桥的日志是缓存。

## 6. 权限审批（手机端批准命令）

```json
← {"v":1,"type":"permission_request","sessionId":"s_1","requestId":"req_9",
   "toolCallId":"call_00_t2im…","title":"pwsh",
   "command":"rm -rf ./dist","cwd":"C:\\work\\proj",
   "riskFlags":["destructive","outside-sandbox"],
   "options":[{"id":"allow_once","label":"仅本次允许"},{"id":"allow_session","label":"本次会话始终允许"},{"id":"reject_once","label":"拒绝"}],
   "expiresAt":1699999999}

→ {"v":1,"type":"permission_decision","id":"d1","sessionId":"s_1","requestId":"req_9","decision":"allow_once"}
← {"v":1,"type":"permission_ack","id":"d1","requestId":"req_9","applied":true}
```

规则：

- **桥必须先从缓存的 `tool_call` 里取出 `command`/`cwd` 再发**——ACP 的权限请求只给 `toolCallId`，不给详情。
- ACP 只有 `allow_once` / `reject_once`；**`allow_session` 由桥自己记忆**（作用域＝该会话 + 该工具 + 该命令前缀，进程重启即失效）。App 不能假设协议侧支持它。
- 默认超时 **120 s → 自动拒绝**。App 离线/无订阅者时默认**挂起等待**（可配置为自动拒绝）。
- 决定必须回执，否则 DSH 侧会一直挂着。
- 高风险命令（`rm -rf`、`curl|sh`、`Invoke-Expression`、写系统目录、`git push --force`、访问 `.ssh`/`.env`）必须高亮，且**永不自动允许**。

## 7. 桥与 DSH 状态

```json
← {"v":1,"type":"bridge_status","dsh":"restarting","detail":"dsh exited code=1, retry #2 in 4s"}
```

`dsh` 取值：`starting` / `running` / `restarting` / `failed`。
App 必须把它渲染成明确状态（不要永远转圈）：`电脑端未运行` / `DSH 启动失败` / `已连接` / `重连中`。

## 8. 错误

```json
← {"v":1,"type":"error","id":"p1","code":"session_not_found","message":"…"}
```

| code | 含义 | App 处理 |
|---|---|---|
| `auth_required` | 未带 token | 跳配对 |
| `auth_failed` | token 无效/被吊销 | 清除本地凭据，跳配对 |
| `pair_code_invalid` | 配对码错误/过期 | 提示重新获取 |
| `bad_request` | 参数不合法 | 开发期错误，记录 |
| `unknown_type` | 桥不认识该 type | 忽略（协议演进用） |
| `dsh_unavailable` | ACP 子进程不可用 | 显示 `bridge_status` |
| `session_not_found` | 会话不存在或已失效 | 提示"该会话已失效，可新建" |
| `busy` | 该会话有轮次在跑 | 禁用发送按钮，等 `idle` |
| `permission_timeout` | 审批超时 | 提示已自动拒绝 |

## 9. 演进规则

1. 所有帧带 `v`；握手时双方声明 `protocolVersion`。**v1 内只做加法**：新增 `type`/`kind` 时，接收方遇到不认识的必须先忽略而不是断开。
2. 删除或改语义必须升 `protocolVersion`。
3. **DSH 升级的影响面必须被限制在桥内**：App 只依赖本文件。桥若因 DSH 变化而需改写码，App 不发版。
4. 桥不得把 ACP 的 `session/update` 原文、ACP `sessionId`、`usage_update` 等术语泄漏到本协议之外。
