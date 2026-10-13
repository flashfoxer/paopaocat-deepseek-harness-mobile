# 手机安装与测试指南

目标：把 `dist/app-release.apk` 装到你的 Android 手机上，连上电脑端的桥，跑通一次真实对话。

## 0 · 路径速查（先看这个）

本项目**不在** `C:\Users\25894` 下，而是在一个深层中文目录里。所以：

```
项目根目录：D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile
```

**本文档里凡是 `cd` 开头的命令，都已经写成绝对路径**——不要用 `cd dsh-mobile\bridge` 这种相对路径，会直接报"路径不存在"。

更省事的办法：项目根目录下有三个双击即可运行的脚本，它们用 `%~dp0` 自动定位，不需要 cd：

| 脚本 | 作用 |
|---|---|
| `start-bridge.cmd` | 启动桥（自动设好监听地址与 Agent 工作目录） |
| `pair-phone.cmd` | 生成 6 位配对码 |
| `share-apk.cmd` | 起 APK 下载页 |

**本机已探明的环境事实**（下面步骤据此写成）：

| 项 | 实测值 |
|---|---|
| 电脑局域网地址 | **192.168.1.100**（WLAN） |
| 桥默认端口 | 8788 |
| Windows 防火墙 | 8788 与 8000 的入站规则**已添加**（Private profile） |
| 当前终端权限 | 非管理员（加防火墙规则需管理员终端） |

---

## 第 1 步 · 把 APK 传到手机

两个办法，选一个：

**A. 用电脑起下载页（推荐，不用数据线）**

```powershell
# 推荐：双击项目根目录的 share-apk.cmd
# 或：
cd "D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile"
node install\serve-apk.mjs
```

它会打印 `http://192.168.1.100:8000/` —— 手机浏览器打开这个地址，点 `app-release.apk` 下载。
> 如果打不开，先做第 2 步（防火墙），因为 8000 端口同样会被拦。

**B. 数据线拷贝**：把 `dsh-mobile\dist\app-release.apk` 复制到手机存储，用文件管理器点开安装。

安装时系统可能提示「未知来源应用」，在设置里允许该浏览器/文件管理器安装应用即可。

---

## 第 2 步 · 放行防火墙（**必须做，否则手机连不上**）

手机连不上桥，90% 是这里。用一个**管理员** PowerShell（右键 → 以管理员身份运行）执行：

```powershell
New-NetFirewallRule -DisplayName "DSH Mobile Bridge (8788)" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8788 -Profile Private

New-NetFirewallRule -DisplayName "DSH Mobile APK Server (8000)" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8000 -Profile Private
```

只放行 `Private`（家庭/办公网络），不放 `Public`——这是有意的：**公网环境下不该开这个口**。

> 如果放行后仍然连不上，检查当前 Wi-Fi 是不是被 Windows 标记成了「公用网络」：
> `Get-NetConnectionProfile`，若 `NetworkCategory` 是 `Public`，可以在设置 → 网络里把它改成「专用网络」，
> 或者临时把上面命令的 `-Profile Private` 换成 `-Profile Any`（用完记得删规则）。

用完之后想撤掉规则：

```powershell
Remove-NetFirewallRule -DisplayName "DSH Mobile Bridge (8788)"
Remove-NetFirewallRule -DisplayName "DSH Mobile APK Server (8000)"
```

---

## 第 3 步 · 启动桥

```powershell
# 推荐：双击项目根目录的 start-bridge.cmd（下面三项它都设好了）
# 或：
cd "D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile\bridge"
$env:DSH_MOBILE_HOST = '0.0.0.0'                              # 关键：默认只绑 127.0.0.1，手机永远连不上
$env:DSH_MOBILE_CWD  = 'C:\Users\25894\dsh-mobile-workspace'  # 关键：工作目录必须 ACL 可改
node src\bridge.mjs serve
```

看到这段就算成功：

```
[bridge] dsh 就绪 agent=deepseek-harness-acp@0.0.1 caps={"close":{},"list":{},"resume":{}}
[bridge] WebSocket 已监听 ws://0.0.0.0:8788
```

然后**另开一个终端**生成配对码：

```powershell
# 推荐：双击项目根目录的 pair-phone.cmd
# 或：
cd "D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile\bridge"
node src\bridge.mjs pair
```

会打印 6 位配对码（**120 秒内有效，且只能用一次**）。

---

## 第 4 步 · 在 App 里配对

打开手机上的 **DSH Mobile**，填入：

| 字段 | 值 |
|---|---|
| 配对码 | 上一步打印的 6 位数字 |
| 电脑地址 | `192.168.1.100`（若用 Tailscale，填 tailnet IP） |
| 端口 | `8788` |
| 这台设备的名字 | 随便，例如「我的手机」 |
| **使用 TLS（wss）** | 用 `start-bridge.cmd` 启动 → **打开**；用 `start-bridge-ws.cmd` → 关闭 |
| **证书指纹** | 仅 wss 需要：把桥窗口打印的那串 `AA:BB:…` 复制进去 |

**最省事的做法**：别手打。`pair-phone.cmd` 的输出里有一整行 `dsh-mobile://pair?...` URI，
复制它，然后在 App 里点「从剪贴板粘贴配对信息」——地址、端口、协议、指纹会一次填好。

> **指纹必须来自你的电脑**。它证明连上的确实是你的桥，而不是同网段的另一台机器。
> App 会拒绝任何指纹不匹配的证书——**包括系统信任的 CA 签发的证书**。

点「配对并连接」。

**成功的样子**：进入会话列表页，标题栏显示电脑主机名，副标题显示 `workspace-write · N 个会话`。

---

## 第 5 步 · 跑一次真实对话

1. 点右下角 **新会话** → 进入会话页。
2. 输入：`用一句话自我介绍，不要调用工具` → 发送。
3. 应该看到：状态变成「执行中…」，然后出现回答，随后回到「空闲」。

想看工具卡片与审批，输入一个会用到电脑的命令，例如：

```
请执行 pwsh 命令 echo hello-from-phone，并把输出贴出来
```

预期：出现一个 `pwsh` 工具卡片（含完整命令与状态），执行完成后显示输出。

> **关于审批**：桥默认 `DSH_PERMISSION_MODE=workspace-write`，`approval=ask`。但沙箱内允许的操作**不会**弹审批
> ——只有需要提权的操作才会出现审批卡片。这是 DSH 的设计，不是 bug。
> 如果想让审批更容易被触发（也更危险），不要改成 `danger-full-access`：那会让审批彻底失效。

---

## 测试清单（逐条勾）

- [ ] App 能连上、进入会话列表
- [ ] 新会话能创建，消息能发出去
- [ ] 能收到回答（消息级流式，不是逐字）
- [ ] 工具卡片显示完整命令与执行状态、输出
- [ ] 点「取消」能中断正在执行的轮次，之后能继续发消息
- [ ] 锁屏 1 分钟后回来，内容不丢（桥侧有 seq 补拉）
- [ ] 从会话页返回列表，再进入同一会话，历史仍在
- [ ] 设置/菜单里「解除配对」后，重新配对能成功
- [ ] 长命令输出不会让列表卡顿
- [ ] 软键盘弹起时输入框不被遮挡

---

## 排错表

| 现象 | 原因 | 处理 |
|---|---|---|
| App 显示「连接被拒绝」/ 连接超时 | ① 桥没绑 `0.0.0.0`；② 防火墙拦了；③ 地址填错 | 依次检查第 2、3 步；确认手机和电脑在同一 Wi-Fi |
| 一直「连接中…」然后失败 | 手机在 4G/5G，电脑在局域网，二者不通 | 改用 Tailscale，或让手机连同一 Wi-Fi |
| 提示「配对码无效或已过期」 | 超过 120 秒，或已用过一次 | 重新执行 `node src\bridge.mjs pair` |
| 提示「设备凭据已失效，请重新配对」 | 该设备被 `revoke` 过 | 电脑端重新生成配对码，在 App 里重新配对 |
| 发消息后一直转圈 | 电脑端 DSH 出问题 | 看桥那边的终端输出；App 菜单 →「连接日志」 |
| 报 `Authentication Fails, Your api key ... is invalid` | 桥的模型 overlay 没生效 | 检查 `bridge/acp-model.overlay.yml` 是否同时覆盖了 `agent-default-model` **和** `acp` 两行 |
| 工具卡片显示 `SetNamedSecurityInfoW failed` | Agent 工作目录 ACL 不可改 | 启动桥时设 `$env:DSH_MOBILE_CWD='C:\Users\25894\dsh-mobile-workspace'`（换成 ACL 正常的目录） |
| 收不到任何审批请求 | `DSH_PERMISSION_MODE` 被设成了 `danger-full-access` | 改回 `workspace-write` |
| APK 装上但打不开/闪退 | 极少见，可能 ABI 不匹配 | 试着装 `app-debug.apk`（含全部 ABI 与调试符号） |

**排查利器**：App 标题栏右侧菜单 →「连接日志」。
电脑端：`node src\bridge.mjs health` 看 DSH 状态与会话数；桥的终端窗口会实时打印 dsh 的 stderr。

---

## 已知限制（现在就这样，不是 bug）

1. **必须电脑开机且桥在运行**——Agent 循环跑在电脑上，手机只是遥控器。
2. **没有会话标题**：ACP 不提供，列表里用工作目录末段当名字。
3. **换手机看不到历史**：ACP 没有 `session/load`，历史只存在电脑上（桥的 seq 日志能补拉"本次"的断线缺口，但新设备拿不到旧会话内容）。
4. **`release` APK 用的是 debug 签名**：装机测试没问题，上架前要换成你自己的 keystore。
5. **图片暂时不能发**：`promptCapabilities.image = false`，需要走「文件落到工作区 + 路径引用」的方案（尚未实现）。
