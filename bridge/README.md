# dsh-mobile-bridge

把电脑上运行的 DSH（`dsh --profile acp`）变成手机可连的 WebSocket 服务。
手机侧只实现 [桥协议 v1](bridge-protocol.md)，**不接触任何 ACP/DSH 内部概念**。

```
原生 App (Flutter)  ←— 桥协议 v1 · WebSocket —→  dsh-mobile-bridge (PC, Node)
                                                      └─ stdio JSON-RPC 2.0 → dsh --profile acp
                                                      └─ data/devices.json（设备凭据）
```

## 为什么必须有桥

DSH 官方面向程序化客户端的两个协议（SDK、ACP）**都是 stdio**，手机无法直接持有一条电脑上的管道。桥因此是架构必需品，不是可选项。

选 ACP 而不是 SDK 的原因：ACP 有 `session/cancel`、`session/list`、`session/resume`，以及**唯一能做「手机上批准命令」的 `session/request_permission`**；SDK 协议只有 3 个方法、没有取消、没有审批。

## 前置条件

| 项 | 要求 |
|---|---|
| Node | ≥ 20（本机 v22.23.2 已验证） |
| DSH | 已安装，`lib/bin.js` 可执行（本机 `0.1.7-rc.2`） |
| 模型凭据 | `acp` profile 默认模板用 `DEEPSEEK_API_KEY`；若你的可用路由是自定义 provider，需通过 `--patch` overlay 注入（见下） |
| 工作目录 | **必须 ACL 可改**。放在 `C:\Users\<you>\…` 没问题；深层中文路径可能触发 `SetNamedSecurityInfoW Win32 5` 导致工具全部失败 |

## 快速开始

```powershell
cd bridge
npm install                # 只有 ws 一个依赖

# 1. 启动桥（常驻）
node src/bridge.mjs serve

# 2. 另开一个终端，生成一次性配对码
node src/bridge.mjs pair
#    → 打印 6 位配对码 + 一行 dsh-mobile://pair?... URI，在 App 里扫码或手输
```

健康检查与设备管理（都只允许本机访问）：

```powershell
node src/bridge.mjs health
node src/bridge.mjs devices
node src/bridge.mjs revoke <deviceId>     # 手机丢了用这个止损
node src/bridge.mjs revoke-all
```

## 配置

复制 `config.example.json` 为 `config.json`（可选；环境变量优先）。也可只用环境变量：

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `DSH_BIN` | `D:/Programs/PaopaocatDSH/app/lib/bin.js` | dsh 入口 |
| `DSH_MOBILE_CWD` | 当前目录 | Agent 工作目录，**必须 ACL 可改** |
| `DSH_MOBILE_HOST` | `127.0.0.1` | 监听地址。Tailscale 场景用 `0.0.0.0`（管理端点仍受 loopback 检查保护） |
| `DSH_MOBILE_PORT` | `8788` | 监听端口 |
| `DSH_PERMISSION_MODE` | `workspace-write` | 见下 |

### `DSH_PERMISSION_MODE` 是本项目最关键的一个开关

DSH 用**同一个旋钮**捆绑沙箱与审批策略（`$DSH_HOME/profiles/acp` 的组合默认值）：

| 值 | 沙箱 | 审批 | 后果 |
|---|---|---|---|
| `workspace-write`（默认） | workspace-write | **`ask`** | ✅ 手机上能审批命令；沙箱根 = 桥 spawn 时的 cwd，**该目录必须 ACL 可改** |
| `danger-full-access` | danger-full-access | `never` | 工具永不失败，但**审批彻底失效**——手机上不会收到任何审批请求 |
| `read-only` | read-only | `ask` | Agent 不能改文件 |

> **二者不可兼得**，这是 DSH 的设计而不是 bug。要"手机上批准命令"，就必须 `workspace-write`。

### TLS / wss（默认启用）

`install/gen-tls-cert.ps1` 生成自签证书到 `bridge/tls/`：

| 文件 | 用途 |
|---|---|
| `bridge.pfx` | 桥的私钥+证书（PFX，密码 `dsh-mobile-bridge`） |
| `bridge-cert.pem` | 公开证书（测试客户端当 `ca:` 用、或浏览器调试） |
| `fingerprint.txt` | 证书 SHA-256 指纹 —— **App 配对时要 pin 这个值** |

桥启动时只要发现 `tls/bridge.pfx` 就用 **wss**，并把指纹打印到控制台、写进 `/health` 与 `/pair`。

```powershell
install\gen-tls-cert.ps1          # 生成（或重新生成）证书
$env:DSH_MOBILE_TLS = '0'         # 强制回退明文 ws（仅限 Tailscale 这类已加密私有网络）
```

> **App 侧必须 pin 指纹**，不允许 `badCertificateCallback = (…) => true` 这种盲信任写法。
> 证书是否由"受信任 CA"签发并不重要，重要的是**指纹与你配对时看到的一致**。

验证：`node bridge/test-wss.mjs`（会连一次、比一次指纹，并确认**未受信任的客户端被拒绝**）。

### 模型路由 overlay

`acp-model.overlay.yml` 通过 `--patch` 叠加注入模型路由，**不改动 `$DSH_HOME/profiles/acp`**：

```powershell
node <dsh>/lib/bin.js --profile acp --patch bridge/acp-model.overlay.yml
```

为什么需要它：`acp` profile 的默认模板把路由写死为 `provider: deepseek-official` + `model: deepseek-v4-flash`，并依赖 `DEEPSEEK_API_KEY`。如果你的可用路由是自定义 provider（本机是 `commandcode.ai` + `COM_API_KEY`），不换就会得到：

```
Internal error: turn failed: Authentication Fails, Your api key: ****xxxx is invalid
```

overlay 里必须同时覆盖**两处**——`agent-default-model` 和 `acp`（ACP 服务器用自己的 config 决定每个新会话的路由，会盖掉默认模型）：

```yaml
- id: acp
  name: "@deepseek-ai/dsh-acp"
  config:
    provider: com
    model: deepseek/deepseek-v4.1-flash
```

## 验证

桥在运行时执行。带 mock 的脚本需要 `DSH_BIN` 指向 `probes/mock-acp-server.mjs`，并以 `DSH_MOBILE_TLS=0` 启动（mock 不做 TLS）。

| 脚本 | 验证内容 |
|---|---|
| `probes/bridge-smoke.mjs` | 主链路：配对 → 握手 → 建会话 → 订阅 → 发消息 → 收 update → 关闭 |
| `probes/permission-test.mjs` | 审批四条路径：批准 / 拒绝 / 会话级允许 / 记忆放行（确定性） |
| `probes/cancel-test.mjs` | 取消链路：`running → cancelling → idle`，且取消后仍可继续 |
| `probes/reconnect-test.mjs` | 断线恢复：seq 补拉连续无重复、未决审批被补发且可应答 |
| `probes/crash-test.mjs` | DSH 崩溃：桥通知 App → 指数退避重启 → 恢复可用 |
| `bridge/test-wss.mjs` | wss：指纹一致、**未受信任的客户端被拒绝** |

```powershell
node probes/bridge-smoke.mjs       # 需要真实 DSH
node probes/permission-test.mjs    # 需要 mock ACP
node bridge/test-wss.mjs           # 需要 wss 模式
```

期望输出（本机已实测通过）：

```
[smoke] 配对成功 deviceId = dev_…
[smoke] 握手成功 host = {...} 会话数 = 1
[smoke] 新会话 s_3 配置项 = model
[smoke] 订阅成功 fromSeq = 0 toSeq = 0
[smoke] 已入队 clientMsgId = smoke-1
[smoke] 轮次结束状态 = idle
[smoke] 本轮收到 2 条 update：
   seq=1 kind=message text="收到"
   seq=2 kind=usage
[smoke] 会话已关闭 s_3
[smoke] 全部通过 ✓
```

## 安全

桥以你的用户身份运行、能拉起 `dsh`（而 dsh 能执行 shell 命令）。**桥被攻破 = 整机沦陷**。因此：

1. 默认只绑 `127.0.0.1`；开网络请优先用 **Tailscale**，桥只绑 tailnet 地址。
2. **绝不**做公网端口转发 + 明文 `ws://`。
3. 配对码 TTL 120 s、一次性、连错 5 次锁 15 分钟；桥只存 `sha256(deviceToken)`。
4. 吊销路径必须可用：`revoke <deviceId>` / `revoke-all`。
5. 管理端点（`/pair`、`/devices`、`/health`）**只允许 loopback**，其它来源一律 403。
6. 高风险命令（`rm -rf`、`curl|sh`、`Invoke-Expression`、`.ssh`/`.env`、`git push --force`、写系统目录）在 `permission_request.riskFlags` 里高亮，App 必须显式展示，**永不自动允许**。
7. v1 **未做**设备私钥签名挑战（计划 v1.1）。当前安全依赖 Tailscale 的设备身份 + 可吊销 token。

## 故障排查

| 现象 | 原因与处理 |
|---|---|
| 工具报 `SetNamedSecurityInfoW failed (Win32 5): grantWrite(<cwd>)` | 工作目录 ACL 不可改。把 `DSH_MOBILE_CWD` 换到 `C:\Users\<you>\…` 下的目录 |
| `Authentication Fails, Your api key: ****xxxx is invalid` | overlay 没生效，或只改了 `agent-default-model` 没改 `acp` 行 |
| 手机上收不到审批请求 | `DSH_PERMISSION_MODE` 是 `danger-full-access`（审批策略被设为 `never`）。改成 `workspace-write` |
| 桥起来但 `pair` 连不上管理端点 | `DSH_MOBILE_HOST` 设成了某个非 loopback 地址。用 `0.0.0.0` 或 `127.0.0.1` |
| 会话发消息回 `busy` | 上一轮未结束，先发 `cancel` 并等 `session_status: idle` |
| `session/list` 看不到刚建的会话 | ACP 的 `session/list` **只返回非活跃（可恢复）的会话**，当前活跃会话不在其中——这是实测行为，不是 bug |

## 文件

| 文件 | 作用 |
|---|---|
| `src/acp-client.mjs` | 拉起 `dsh --profile acp`，换行分帧 JSON-RPC 2.0 传输 |
| `src/sessions.mjs` | 会话注册表、`session/update` → 桥协议归一化、seq 事件日志 |
| `src/server.mjs` | WebSocket 服务 + 桥协议分发 + 权限流转 + 管理端点 |
| `src/store.mjs` | 设备凭据（只存 hash）与配对码 |
| `src/bridge.mjs` | CLI 入口 |
| `acp-model.overlay.yml` | 模型路由 overlay（`--patch`） |
| `bridge-protocol.md` | **App 要实现的契约** |
| `../docs/W1-acp-findings.md` | ACP 实测报告（所有结论的证据） |
