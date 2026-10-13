# LiteRT-LM 桥的「不靠真机」验证程序

这里放的是 **2026-10-08 把端侧大模型切到 LiteRT-LM（Gemma 4）时挖出的坑**对应的小验证程序。

为什么要留它们：那几个坑有个共同特点 —— **现象和真因隔了三层，肉眼看不出来**。

- 真机日志里只有一句 `ClassNotFoundException: LiteRtLmJniException`，而它其实是
  **R8 把那个类当死代码裁了**（0.36）；
- 修完 R8 又发现 GPU 要的厂商库**必须先在 AndroidManifest 里声明**（0.37）；
- 再往下才看到桥的 HTTP 服务把 `Content-Length`（字节）**当字符数**读，中文请求
  永远读不满 → 卡死（0.38）；
- 最后是 SSE 收尾少发 `finish_reason`，DSH 客户端**直接抛错**，把成功的生成判成失败（0.39）。

这三个程序就是当时把「猜」变成「证据」用的：

| 文件 | 验证什么 | 依赖 |
|---|---|---|
| `HttpBodyTest.java` | 桥读 HTTP 正文的方式：旧写法（按字符读）在中文请求上**卡死**，新写法（按字节读）正确 | JDK（本机 17） |
| `verify-sse.mjs` | 收尾分片少发 `finish_reason` 时，**逐行复刻** DSH 客户端（`pi-ai/openai-completions.js`）的判定 → 会抛 `Stream ended without finish_reason` | 只要有 node |
| `verify-wire.mjs` | 用 **DSH 手机运行时里真正那份 `openai` SDK** 解析桥的**逐字节**响应（含「只有 `Connection: close`、没有 Content-Length」这种分帧） | node + 下面那条解包命令 |

## 怎么跑

```bash
# ⚠️ 先把文件复制到**纯 ASCII 路径**（如 /tmp）再跑。
#    仓库在 /root/办公（中文路径），而本机 JVM 在中文路径下连源文件都找不到：
#    直接在仓库目录跑 javac 会报 `error: file not found: HttpBodyTest.java`
#    （与 docs/BUILD-LINUX.md 记的是同一个坑）。node 不受影响。
mkdir -p /tmp/vtest && cp ./*.java ./*.mjs /tmp/vtest/ && cd /tmp/vtest

# ① HTTP 正文读取（旧卡死 / 新正确）
javac -encoding UTF-8 -d . HttpBodyTest.java && java -Dfile.encoding=UTF-8 -cp . HttpBodyTest

# ② SSE 收尾的 finish_reason（复刻客户端判定）
node verify-sse.mjs

# ③ 用真 openai SDK 解析桥的响应字节
#    先把 SDK 从手机运行时里解出来（158MB 的 zip 里那份，版本 6.40.0，零运行时依赖）
python3 - <<'PY'
import zipfile, os
Z = '/tmp/dshbuild/android-node/app-assets/dsh-runtime.zip'
z = zipfile.ZipFile(Z)
base = '/tmp/sdkcheck'
for n in z.namelist():
    if 'node_modules/openai/' in n.replace('\\', '/'):
        out = os.path.join(base, n.replace('\\', '/'))
        os.makedirs(os.path.dirname(out), exist_ok=True)
        open(out, 'wb').write(z.read(n))
print('已解到', base)
PY
mkdir -p /tmp/sdkcheck/app && cp verify-wire.mjs /tmp/sdkcheck/app/ && cd /tmp/sdkcheck/app && node verify-wire.mjs
```

三个程序都会打印自己的结论并以退出码 0/1 表示通过与否。

## 已知结论（2026-10-08 实测）

- ① 旧写法：**2001ms 后线程仍在阻塞**（真卡死，不是抛错）；新写法：**1ms** 拿到完整中文正文。
- ② 旧收尾（`choices: []`）→ `ok=false 报错="Stream ended without finish_reason"`；新收尾 → `ok=true stopReason=stop` 正文完整。
- ③ 真 SDK 对两种收尾**都能解析**、正文都完整；差别只在 `finish_reason` 收得到收不到
  —— 而这正是 pi-ai 判流合法与否的依据。

## 还有两条是「查符号/查源码」而不是跑程序得到的（一并记在这里）

- **加速器 ABI 兼容**：`litert-gpu:2.3.0` 的 `libLiteRtClGlAccelerator.so` 只导出
  `LiteRtAcceleratorImpl@@VERS_1.0`，而 `liblitertlm_jni.so` 里要 dlsym 的入口名正是
  `LiteRtAcceleratorImpl` → 两边一致。
  ```bash
  NM=/opt/android-sdk/ndk/*/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-nm
  $NM -D --defined-only libLiteRtClGlAccelerator.so | grep LiteRt
  strings liblitertlm_jni.so | grep LiteRtAcceleratorImpl
  ```
- **生成上限字段名**：DSH 发的是 `max_completion_tokens`（不是 `max_tokens`）——
  依据是 `pi-ai/openai-completions.js:1266` 的 `useMaxTokens` 白名单与 `:601` 的写入分支。
  桥以前只读 `max_tokens`，会**永远落到默认 2048**、把 DSH 要的上限丢掉（0.41 修）。
