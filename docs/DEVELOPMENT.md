# DSH Mobile

用原生手机 App 远程使用电脑上运行的 [DSH](https://github.com/deepseek-ai/deepseek-harness) Agent：
浏览会话、发消息、看工具执行、**在手机上批准命令**。

```
┌──────────────┐   桥协议 v1     ┌──────────────────┐   stdio JSON-RPC   ┌────────────────────┐
│ Flutter App  │ ───WebSocket──▶ │ dsh-mobile-bridge │ ─────────────────▶ │ dsh --profile acp  │
│ iOS / Android│ ◀────────────── │  (PC, Node)       │ ◀───────────────── │  Agent 循环/工具    │
└──────────────┘                 └──────────────────┘                    └────────────────────┘
```

## 为什么是"桥 + ACP"而不是直连

DSH 官方面向程序化客户端的两个协议（SDK、ACP）**都是 stdio**，手机无法直接持有一条电脑上的管道，
所以中间必须有一个桥进程。选 ACP 而不是 SDK 的原因：

| | SDK profile | **ACP profile（本项目采用）** |
|---|---|---|
| 方法数 | 3 个 | 完整会话生命周期 |
| 取消任务 | ❌ 只能关进程 | ✅ `session/cancel` |
| 会话列表/恢复 | ❌ | ✅ `session/list` / `session/resume` |
| **权限审批** | ❌（明确未实现） | ✅ `session/request_permission` |

**手机端批准命令只有 ACP 这一条路。**

## 目录结构

```
dsh-mobile/
├── docs/W1-acp-findings.md      ACP 服务端行为实测报告（所有结论的证据）
├── probes/
│   ├── acp-probe.mjs            可复跑的 ACP 探针（输出原始帧夹具）
│   ├── bridge-smoke.mjs         桥的端到端冒烟测试
│   └── extract-update-samples.mjs
├── fixtures/                    实测夹具（JSONL 原始帧 + 配置 dump）
├── bridge/                      ★ 电脑端桥（Node，仅依赖 ws）
│   ├── bridge-protocol.md        App 要实现的契约
│   ├── README.md                 部署、配置、安全、故障排查
│   └── src/*.mjs
├── app/                         ★ Flutter App
│   └── lib/
│       ├── protocol/            桥协议客户端与模型
│       ├── state/               全局状态与协议编排
│       ├── storage/             设备凭据（Keychain / Keystore）
│       └── ui/                  配对页 / 会话列表 / 会话页
└── install/                     工具链安装与探测脚本
```

## 快速开始

### 1. 电脑端：启动桥

📁 项目根目录是 `D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile`
（**不在**用户目录下，所以下面是绝对路径；也可以直接双击根目录的 `start-bridge.cmd`）

```powershell
cd "D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile\bridge"
npm install                                                   # 只有 ws 一个依赖
$env:DSH_MOBILE_HOST = '0.0.0.0'                              # 允许手机访问
$env:DSH_MOBILE_CWD  = 'C:\Users\25894\dsh-mobile-workspace'  # 必须在 ACL 可改的目录
node src\bridge.mjs serve     # 拉起 dsh --profile acp 并监听
node src\bridge.mjs pair      # 另开终端（或双击 pair-phone.cmd）：生成一次性配对码
```

安装期间需注意的两件事（详见 `bridge/README.md`）：

1. `acp` profile 默认把模型路由写死为官方 DeepSeek + `DEEPSEEK_API_KEY`。
   如果你的可用路由是自定义 provider，必须用 `--patch bridge/acp-model.overlay.yml` 覆盖
   ——而且要**同时**覆盖 `agent-default-model` 和 `acp` 两行，否则会话仍走无效 key。
2. 桥的工作目录必须 **ACL 可改**（放在 `C:\Users\<you>\…` 下没问题）。
   否则 Agent 的工具会报 `SetNamedSecurityInfoW failed (Win32 5): grantWrite(...)`。

桥默认以 **wss（TLS）** 监听：启动时会打印证书 SHA-256 指纹，App 配对时要 pin 它
（`install/gen-tls-cert.ps1` 生成证书；`DSH_MOBILE_TLS=0` 可回退明文 ws，仅限私有网络）。

### 2. 手机端：构建 App

```powershell
cd dsh-mobile/app
flutter pub get
flutter build apk --debug          # 或 flutter run
```

App 里输入电脑地址（Tailscale IP 或局域网 IP）、端口 8788、6 位配对码即可。

## 已实测确认的关键事实

> 完整证据见 `docs/W1-acp-findings.md`。

- **流式是消息级，不是 token 级**：300+ 字回答仍只产生 1 个 `agent_message_chunk`。
  App 不需要增量渲染骨架。
- **`promptCapabilities.image = false`**：图片不能走 ACP 内容块，
  必须改为"桥把文件落到工作区 + prompt 里用路径引用"。
- **审批只有 `allow_once` / `reject_once`**，没有"始终允许"：
  "本次会话始终允许"由桥自己记忆实现。
- **沙箱与审批由同一个旋钮捆绑**（`DSH_PERMISSION_MODE`）：
  `workspace-write` → 有审批但目录必须 ACL 可改；`danger-full-access` → 工具永不失败但审批彻底失效。
  **二者不可兼得。**
- **无 `load` / `delete` / `fork`，`close` 即销毁**：
  UI 必须严格区分"取消订阅"与"销毁会话"。
- **没有 agent→client 的 fs / terminal 请求**：DSH 用自己的工具，不依赖客户端环境能力。

## 安全

桥以你的用户身份运行，能拉起 `dsh`（而 dsh 能执行 shell 命令）。**桥被攻破 = 整机沦陷。**

- 默认只绑 `127.0.0.1`；开网络优先用 **Tailscale**，桥只绑 tailnet 地址。
- **绝不**做公网端口转发 + 明文 `ws://`。
- 高风险命令（`rm -rf`、`curl|sh`、`Invoke-Expression`、`.ssh`/`.env`、`git push --force`）
  在审批卡片上高亮，**永不自动允许**。
- 手机丢了立刻 `node src/bridge.mjs revoke <deviceId>`。

## 改完就写：文件一个、说明一个（2026-10-14 起）

**每改一个功能、每修一个 bug，留下两份 —— 分开写，不混在一份里。**

| | **文件**（技术侧） | **说明**（面向使用者） |
|---|---|---|
| 给谁看 | 我们自己 / 后来接手的人 | **使用者** |
| 形态 | `docs/CHANGES-<日期>.md`（先例：`CHANGES-2026-10-04.md`） | `docs/更新说明-<版本>.md`（先例：`更新说明-0.15-0.17.md`） |
| 写什么 | 具体动了什么、依据是什么、**怎么验证** | **「之前的问题 / 现在」**，一条一个问题 |
| 口径 | 可以有类名、路径、命令、日志证据 | 面向使用者，不出现内部实现，用户看得懂 |
| 去向 | 留在仓库 | 发版时逐条搬进 App 内更新说明（`app/lib/data/changelog.dart`）、GitHub Release 说明、公众号稿 |

两条纪律：
* **说明的来源是 `changelog.dart`，逐条对应、没有额外发挥** —— 发版前把两边核一遍；
* 两份**都不进包**（进包的是 `changelog.dart`）；所以「说明」的价值在于**发版时有东西可搬**，
  「文件」的价值在于**过一阵子还查得出为什么这么改**。

还没做完的条目先标「（进行中）」，做完改成正式措辞。

## 进度

| 阶段 | 状态 |
|---|---|
| W1 · ACP 行为实测 | ✅ 完成（含原始帧夹具） |
| W1 · 桥协议 v1 + 桥骨架 | ✅ 完成，端到端冒烟通过 |
| W2 · Flutter App（配对 / 会话 / 流式 / 审批） | ✅ 代码完成、编译通过，协议层集成测试通过 |
| W2 · 出包 | ✅ 早期那两个包（`dist/app-debug.apk` / `dist/app-release.apk`）已由下面的版本化包取代 |
| W3 · 健壮性（断线补拉 / 故障演练） | ⏳ 未做 |
| W4 · 真机验证（UI 渲染 / 软键盘 / 切后台） | ⏳ **需要一台 Android 设备**；0.71 的逐项清单见 [`docs/使用说明.md`](docs/使用说明.md) §13 |
| **版本化出包（0.62 → 0.73）** | ✅ **最新 `dist/paopaocat-preview-0.73-arm64-v8a.apk`**（`versionCode 73`，签名与 0.70/0.71/0.72 一致可直接覆盖安装）。0.73 增加了**本机离线配音**（sherpa-onnx + 中文 VITS，零 Key、离线）与**「没有配音也照样出片」**；0.72 是真机反馈后的修复版。内容见 App 内「设置 → 关于 → 更新说明」，逐条依据见 [`docs/需求台账.md`](docs/需求台账.md) |

每个功能块的界面截图（20 张，一个文档看全部）见 [`docs/界面截图-0.73.md`](docs/界面截图-0.73.md)。

构建环境、镜像配置与踩过的坑见 [`docs/BUILD.md`](docs/BUILD.md)；
本机 Linux 打包流程见 [`docs/BUILD-LINUX.md`](docs/BUILD-LINUX.md)。
装到手机测试的完整步骤、防火墙配置与排错表见 [`docs/PHONE-TEST.md`](docs/PHONE-TEST.md)。
集成测试报告见 `flutter test`（`app/test/bridge_integration_test.dart`）。
