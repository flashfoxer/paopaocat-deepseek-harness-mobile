package com.dshmobile.dsh_mobile

import android.util.Base64
import android.util.Log
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Conversation
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.MessageCallback
import com.google.ai.edge.litertlm.SamplerConfig
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * ⚠️ **本文件一律 catch `Throwable`，不要改回 `Exception`**（审计 P0-10）。
 *
 * 原因：native 层抛出来的东西**大多不是** `Exception`。
 * `UnsatisfiedLinkError`、`OutOfMemoryError`、`NoClassDefFoundError`、
 * `StackOverflowError` 全都属于 **`Error`**，而 `Error` 不继承 `Exception` ——
 * 只 catch `Exception` 时它们会直接**穿过去**。
 *
 * 穿过去之后有一条很难查的后果链：
 *    native 抛 Error → 穿透 → 这个请求的 socket 被关掉 →
 *    Dart 侧 `await for` 看到"流正常结束" → **半截回复被当成完整回答**
 *    存进会话与落盘（`local_chat.dart` 只有连接超时，没有读超时）。
 *
 * 本仓库历史上已经踩过 `UnsatisfiedLinkError` 这个坑；`MainActivity.kt` 当时
 * 被系统性改成了 `Throwable`（34 处），**这个文件被漏掉了**（原来是 18 处
 * `Exception` / 2 处 `Throwable`）。2026-10-09 已统一成 20 处 `Throwable`。
 *
 * 另外：本文件**不用协程**（没有 `suspend` / `launch`），所以放宽到 `Throwable`
 * 不会吞掉 `CancellationException` 这类必须向外传播的异常。
 *
 * 同时把报告失败的几行从 `Log.w` 改成 [say] —— `Log.w` 只进 logcat，
 * 用户在 App 的「运行日志」里**一行都看不到**，这与本文件 [say] 上面写的
 * 设计前提（"`Log.i` 只进 logcat，用户在 App 里根本看不到"）直接冲突。
 */

/**
 * 把 **LiteRT-LM**（Google 官方的端侧推理运行时）包成一个"本机 OpenAI 兼容服务"。
 *
 * ## 为什么需要这一层
 *
 * llama.cpp 自带 `llama-server`（一个现成的 HTTP 服务），所以 App 侧只要"起进程 +
 * 注册成 DSH 的 `local` 厂家"就够了。而 LiteRT-LM 是**进程内 API**
 * （`Engine` / `Conversation`），**没有现成的 HTTP 服务** —— 所以这里手写一个极小的
 * HTTP/1.1 服务，把它的流式输出转成 `/v1/chat/completions` 的 SSE。
 *
 * 这样做的意义：**App 侧（overlay / 会话 / 模型选择 / 用量）一行都不用改** ——
 * 对 DSH 来说它和 llama.cpp 那台一模一样，只是"端口后面换了个引擎"。
 *
 * ## 为什么值得做（用户 2026-10-07 的对比）
 *
 * 用户拿 Google 的 AI Edge Gallery 对比，发现"本地模型快得多"。原因之一就是它走
 * LiteRT-LM + GPU/NPU delegate，而我们的 llama.cpp 路径没有 NPU。这条桥就是
 * 把那条路接进 App。
 */
class LiteRtLmBridge {
    companion object {
        private const val TAG = "dsh-litertlm"
    }

    private var engine: Engine? = null
    private var server: ServerSocket? = null
    private var running = false

    /** 当前正在跑的模型路径（给状态查询用）。 */
    private var modelPath: String = ""

    /** 后端名（cpu / gpu / npu）。 */
    private var backendName: String = "cpu"

    /** 每次请求最多产出多少 token。 */
    private var maxOutputTokens: Int = 2048

    /** 采样温度。 */
    private var temperature: Double = 0.8

    /**
     * 上下文上限（LiteRT-LM 的 `maxNumTokens`）。
     *
     * ⚠️ 默认 **16384**，不是 4096 —— 这是有教训的：llama.cpp 那条路最开始默认 2048，
     * 而 **DSH 每轮光固定开销就约 7000 tokens**（AGENTS.md + 技能清单 + 运行时快照），
     * 于是每一句话都被引擎拒绝（`exceeds the available context size`）。
     * 这里必须给够，否则会重演同一个问题。
     */
    private var maxNumTokens: Int = 16384

    // ── 会话复用（本轮性能改造的核心）────────────────────────────────────
    //
    // 用户 2026-10-07 的反馈是「本地大模型还是慢」。量下来最大的一笔浪费在这儿：
    // **每问一句都把整段历史重新预填充一遍**。DSH 一轮的固定开销就约 7000 token
    // （AGENTS.md + 技能目录 + 运行时快照），聊到二十来轮时光历史就上万 token ——
    // 每说一句新话，这上万 token 都要在手机上重算一次，首字自然要等很久。
    //
    // 做法：**把 Conversation 留着不关**（它内部就是 KV cache），下一轮如果只是
    // "同一会话又往后加了一轮"，就只把新的那句 user 发给它 —— 引擎只需算新增的
    // 几十个 token，首字几乎立刻出来。判定条件全在 [reuseBlockReason] 里，
    // 任何一条不满足就老实重建：**最坏 = 和以前一样慢，不会更慢，也不会答错**。
    private var conv: Conversation? = null
    private var sessSystem: String = ""
    private var sessModelPath: String = ""
    private var sessBackend: String = ""
    private var sessMaxNumTokens: Int = 0
    private var sessMaxOutputTokens: Int = 0
    private var sessSamplerKey: String = ""

    /** 已经喂进引擎的历史（不含当前这一轮），元素是 (归一化角色, 文本)。 */
    private var sessFed: List<Pair<String, String>> = emptyList()

    /** 上一轮我们发出去的 user 原文。 */
    private var sessLastUser: String = ""

    /** 上一轮引擎产出的完整回复。 */
    private var sessLastReply: String = ""

    // 复用 / 重建计数 —— 给界面"有据可查"用（用户要求：快没快要有数字，不靠体感）。
    private var reuseCount: Int = 0
    private var rebuildCount: Int = 0
    private var lastRebuildReason: String = ""
    private var lastReused: Boolean = false

    /** 推理串行化：本地引擎一次只能跑一个请求，而且会话状态不允许被打乱。 */
    private val inferenceLock = Any()

    /**
     * 日志出口：把关键行**同时**送到 App 的「运行日志」。
     *
     * 为什么必须有：`Log.i` 只进 logcat，用户在 App 里根本看不到 —— 上一轮我
     * 说"失败了看运行日志里的 litert-lm 行"，那其实是一张**空头支票**（这条链路
     * 的日志一行都不会出现在 App 里）。现在由 MainActivity 注入一个回调，
     * 关键行会同时进 `DiagnosticsLog`，用户能一键导出。
     */
    var logger: ((String) -> Unit)? = null

    /** 记一行日志（logcat + App 运行日志）。 */
    private fun say(msg: String) {
        Log.i(TAG, msg)
        try {
            logger?.invoke(msg)
        } catch (_: Throwable) {
        }
    }

    val port: Int get() = server?.localPort ?: 0

    /** 启动：加载模型（这步慢，几秒到几十秒）+ 开始监听。 */
    @Synchronized
    fun start(
        modelPath: String,
        requestedPort: Int,
        backend: String,
        maxOutputTokens: Int,
        temperature: Double,
        maxNumTokens: Int,
    ): Int {
        stop()
        this.modelPath = modelPath
        this.backendName = backend.lowercase()
        this.maxOutputTokens = maxOutputTokens
        this.temperature = temperature
        this.maxNumTokens = maxNumTokens

        val backendObj = when (this.backendName) {
            "gpu" -> Backend.GPU()
            else -> Backend.CPU()
        }
        say("加载模型：$modelPath（backend=$backendName, maxNumTokens=$maxNumTokens）")
        val eng = Engine(
            EngineConfig(
                modelPath = modelPath,
                backend = backendObj,
                maxNumTokens = maxNumTokens,
            ),
        )
        try {
            eng.initialize()
        } catch (e: Throwable) {
            // 初始化失败（缺库 / 显存不够 / 模型文件不对 / OOM）→ 先把已建的引擎关掉，
            // 别留着占内存（一个几 GB 的模型不释放，用户再点一次就会 OOM），再原样抛上去。
            // 注意接的是 **Throwable**：原生层失败会抛 UnsatisfiedLinkError 之类的 **Error**。
            say("引擎初始化失败：${e.javaClass.name}: ${e.message}")
            try {
                eng.close()
            } catch (_: Throwable) {
            }
            throw e
        }
        engine = eng

        // 端口：优先用请求的那个，被占用就往上试 10 个。
        //
        // ⚠️ 类型必须是 **Throwable?**，不能是 Exception?：下面那个 catch 收的是
        // Throwable（见本文件头部"为什么必须 catch Throwable"）。写成 Exception?
        // 会**编译不过** —— Kotlin 不像 Java 那样容忍这种宽窄不匹配。
        // 这一条是 2026-10-10 出 0.58 时被 Kotlin 编译器抓出来的：当时放宽 catch 的
        // 那次改动只做了静态检查（本机没编译器），漏了这一行。
        var lastError: Throwable? = null
        for (p in requestedPort until requestedPort + 10) {
            try {
                val s = ServerSocket(p, 8, InetAddress.getByName("127.0.0.1"))
                server = s
                running = true
                thread(name = "litertlm-accept", isDaemon = true) { acceptLoop(s) }
                say("已就绪：127.0.0.1:$p（$backendName）")
                return p
            } catch (e: Throwable) {
                lastError = e
            }
        }
        // 一个端口都没起来 → 把引擎关掉，别留着占内存。
        eng.close()
        engine = null
        throw IllegalStateException("端口 $requestedPort 起 10 个都没成功：${lastError?.message}")
    }

    /** 停止：关服务与引擎。 */
    @Synchronized
    fun stop() {
        running = false
        try {
            server?.close()
        } catch (_: Throwable) {
        }
        server = null
        // ⚠️ 顺序：**先关会话，再关引擎**（会话是引擎的资源）。
        try {
            conv?.close()
        } catch (e: Throwable) {
            say("关闭会话时出错：${e.message}")
        }
        conv = null
        resetSession()
        try {
            engine?.close()
        } catch (e: Throwable) {
            say("关闭引擎时出错：${e.message}")
        }
        engine = null
        say("已停止")
    }

    /** 清空会话状态（换模型 / 换后端 / 停止时都必须清，否则会拿旧状态去答新模型）。 */
    private fun resetSession() {
        sessSystem = ""
        sessModelPath = ""
        sessBackend = ""
        sessMaxNumTokens = 0
        sessMaxOutputTokens = 0
        sessSamplerKey = ""
        sessFed = emptyList()
        sessLastUser = ""
        sessLastReply = ""
    }

    /** 一句话状态（App 侧会把它写进运行日志 / 界面）。 */
    fun status(): String =
        if (running && server != null) {
            val cache = if (reuseCount + rebuildCount == 0) {
                "尚未对话"
            } else {
                "复用 $reuseCount / 重建 $rebuildCount"
            }
            "运行中 127.0.0.1:$port ($backendName，$cache)"
        } else {
            "未运行"
        }

    /** 会话复用的统计（JSON 字符串，给 App 显示"到底快在哪"）。 */
    fun statsJson(): String = JSONObject()
        .put("reused", lastReused)
        .put("reuseCount", reuseCount)
        .put("rebuildCount", rebuildCount)
        .put("reason", lastRebuildReason)
        .toString()

    // ------------------------------------------------------------------ HTTP

    private fun acceptLoop(s: ServerSocket) {
        while (running) {
            val client = try {
                s.accept()
            } catch (_: Throwable) {
                break
            }
            thread(isDaemon = true) { handle(client) }
        }
    }

    private fun handle(client: Socket) {
        try {
            client.use { c ->
                // ⚠️ 必须**按字节**读请求 —— 绝不能用 BufferedReader 去读正文。
                // 原因见 readRequest 的注释：Content-Length 是字节数，中文一字 3 字节，
                // 混用会让请求永远读不满 → read() 阻塞 → DSH 侧报「ACP 请求超时」。
                val raw = BufferedInputStream(c.getInputStream())
                val req = readRequest(raw) ?: return
                val requestLine = req.first
                val bodyText = req.second
                val parts = requestLine.split(" ")
                val method = parts.getOrNull(0) ?: return
                val path = parts.getOrNull(1) ?: "/"

                when {
                    method == "GET" && (path == "/health" || path == "/") ->
                        writePlain(c.getOutputStream(), 200, "ok")

                    method == "POST" && path.startsWith("/v1/chat/completions") ->
                        handleChat(c.getOutputStream(), bodyText)

                    else -> writePlain(c.getOutputStream(), 404, "not found")
                }
            }
        } catch (e: Throwable) {
            say("处理请求出错：${e.message}")
        }
    }

    /**
     * 读一个 HTTP/1.1 请求：返回 (请求行, 正文文本)；连接直接断了则返回 null。
     *
     * ⚠️ **为什么整段都按字节读**（2026-10-08 踩坑，已在 JVM 上复现并修好）：
     *
     * 旧代码用 `BufferedReader.read(CharArray)` 读正文，长度用的是 HTTP 的
     * `Content-Length` —— 但那个头是**字节数**，而 `read(char[])` 读的是**字符数**。
     * 中文在 UTF-8 下一个字符占 3 字节，于是正文的字符数只有字节数的约 1/3，
     * `while (read < contentLength)` **永远凑不满**，线程就阻塞在 `read()` 上；
     * DSH 那边发完请求在等响应、连接不会关，于是表现为
     * `TimeoutException: ACP 请求超时`（DSH 的固定开销里全是中文，必然踩到）。
     *
     * 现在：请求行与头（纯 ASCII）逐字节读到空行；正文按 `Content-Length` 读**字节**，
     * 读完再整体 UTF-8 解码 —— 中英文、emoji 都正确。
     * 本机 JVM 复现结论：旧写法 2001ms 仍在阻塞、新写法 1ms 拿到完整中文正文。
     */
    private fun readRequest(raw: BufferedInputStream): Pair<String, String>? {
        val headerLines = ArrayList<String>()
        val sb = StringBuilder()
        while (true) {
            val b = raw.read()
            if (b < 0) return null // 连接在头读完之前就断了
            if (b == '\n'.code) {
                var s = sb.toString()
                sb.setLength(0)
                if (s.endsWith("\r")) s = s.dropLast(1)
                if (s.isEmpty()) break // 空行 = 头结束
                headerLines.add(s)
            } else {
                sb.append(b.toChar())
            }
        }
        val requestLine = headerLines.firstOrNull() ?: return null
        var contentLength = 0
        var chunked = false
        for (h in headerLines) {
            val idx = h.indexOf(':')
            if (idx <= 0) continue
            val name = h.substring(0, idx).trim()
            val value = h.substring(idx + 1).trim()
            if (name.equals("Content-Length", true)) {
                contentLength = value.toIntOrNull() ?: 0
            } else if (name.equals("Transfer-Encoding", true)) {
                if (value.contains("chunked", true)) chunked = true
            }
        }
        if (chunked) {
            return requestLine to String(readChunkedBody(raw), Charsets.UTF_8)
        }
        val bodyBytes = ByteArray(contentLength)
        var read = 0
        while (read < contentLength) {
            val n = raw.read(bodyBytes, read, contentLength - read)
            if (n <= 0) break
            read += n
        }
        return requestLine to String(bodyBytes, 0, read, Charsets.UTF_8)
    }

    /**
     * 读 `Transfer-Encoding: chunked` 的正文（2026-10-08 真机第 2 个坑）。
     *
     * ⚠️ **为什么必须支持**：Flutter/Dart 的 `HttpClient` 用 `req.add(bytes)` 且
     * **不设 `contentLength`** 时，发出去的是 **chunked**，而不是 Content-Length。
     * 旧代码只认 Content-Length → 找不到就把正文当空串 → `jsonDecode("")` 抛
     * `bad json: End of input at character 0 of` → **测速与启动自检一律 HTTP 400**
     * （真机 0.50 日志：`测速失败：HTTP 400 bad json: End of input at character 0 of`）。
     *
     * 为什么以前没暴露：旧 llama.cpp 路径连的是 `llama-server`（真 HTTP 服务器，认 chunked），
     * 而 LiteRT-LM 这条路是我们**手写**的 HTTP 服务端。
     * 本机 JVM 复现：同一份 chunked 请求，旧解析得到 0 字节、新解析得到完整正文。
     *
     * 格式：`<十六进制长度>[;扩展]\r\n<该长度的字节>\r\n` 重复，以 `0\r\n` 结束
     * （后面可能跟若干 trailer 头，最后是一个空行）。
     */
    private fun readChunkedBody(raw: BufferedInputStream): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        while (true) {
            val line = readAsciiLine(raw) ?: break
            val hex = line.trim().substringBefore(';').trim()
            val size = hex.toIntOrNull(16) ?: break
            if (size == 0) {
                // 结束块：吃掉 trailer，直到空行
                while (true) {
                    val t = readAsciiLine(raw) ?: break
                    if (t.isEmpty()) break
                }
                break
            }
            val buf = ByteArray(size)
            var got = 0
            while (got < size) {
                val n = raw.read(buf, got, size - got)
                if (n <= 0) break
                got += n
            }
            out.write(buf, 0, got)
            readAsciiLine(raw) // 每个 chunk 结尾的 \r\n（可能带扩展，忽略）
        }
        return out.toByteArray()
    }

    /** 逐字节读到 `\n`，去掉尾部 `\r`；流在行首就断开时返回 null。 */
    private fun readAsciiLine(raw: BufferedInputStream): String? {
        val sb = StringBuilder()
        while (true) {
            val b = raw.read()
            if (b < 0) return if (sb.isEmpty()) null else sb.toString()
            if (b == '\n'.code) {
                var s = sb.toString()
                if (s.endsWith("\r")) s = s.dropLast(1)
                return s
            }
            sb.append(b.toChar())
        }
    }

    private fun writePlain(out: OutputStream, code: Int, text: String) {
        val bytes = text.toByteArray(Charsets.UTF_8)
        val head = "HTTP/1.1 $code ${if (code == 200) "OK" else "ERR"}\r\n" +
            "Content-Type: text/plain; charset=utf-8\r\n" +
            "Content-Length: ${bytes.size}\r\n" +
            "Connection: close\r\n\r\n"
        out.write(head.toByteArray(Charsets.UTF_8))
        out.write(bytes)
        out.flush()
    }

    /**
     * `/v1/chat/completions`：把 OpenAI 形状的请求翻成 LiteRT-LM 的一次对话。
     *
     * 做法（v1，先保证正确）：
     *   * `messages` 里 role=system 的合成 systemInstruction；
     *   * 其余除最后一条外的消息当作 `initialMessages`（历史）；
     *   * 最后一条作为本轮消息发出去，**流式**回收 → 转成 SSE。
     *
     * 这样不用自己维护会话状态：DSH 每轮都会把完整历史发过来，我们照着重建即可
     * （代价是每轮要重新预填充；后续可以按"历史长度 + 内容指纹"缓存会话来省掉）。
     */
    private fun handleChat(out: OutputStream, bodyText: String) {
        val eng = engine
        if (eng == null) {
            writePlain(out, 503, "no engine")
            return
        }
        val streamRequested: Boolean
        val systemText: String
        val items = mutableListOf<Pair<String, String>>()
        // 本轮的图片（原始字节）。默认空 = 纯文本，走跑通过的老路。
        var turnImages: List<ByteArray> = emptyList()
        var reqMaxOut = maxOutputTokens
        var stateless = false
        try {
            val req = JSONObject(bodyText)
            streamRequested = req.optBoolean("stream", true)
            // ⚠️ 生成上限要读**两个**字段名（2026-10-08 从 DSH 客户端源码查出来的）：
            // OpenAI 的新字段名是 `max_completion_tokens`，旧的才是 `max_tokens`；DSH
            // 走的是**新**的（它的判定在 pi-ai/openai-completions.js:1266 的 `useMaxTokens`：
            // 只有 chutes.ai / DeepSeek / Moonshot / Together 等白名单才发 `max_tokens`，
            // 我们的 baseURL 是 127.0.0.1 → 不在白名单 → 发 `max_completion_tokens`）。
            // 只读 `max_tokens` 的后果：**永远落到默认 2048，把 DSH 要的上限丢掉**，
            // 长回答会被硬截断。两个都认，优先新的。
            reqMaxOut = if (req.has("max_completion_tokens")) {
                req.optInt("max_completion_tokens", maxOutputTokens)
            } else {
                req.optInt("max_tokens", maxOutputTokens)
            }
            // 测速请求会带 `stateless: true`：**不碰会话状态**。
            // 否则用户点一次【测速】，正在进行的对话缓存就被冲掉，下一句又得整段重算 ——
            // 那等于"测速让你变慢"，很荒唐。
            stateless = req.optBoolean("stateless", false)
            val msgs = req.optJSONArray("messages") ?: JSONArray()
            var sys = ""
            for (i in 0 until msgs.length()) {
                val m = msgs.getJSONObject(i)
                val role = m.optString("role", "user")
                val text = textOfRequestMessage(m)
                if (role == "system") {
                    sys = if (sys.isEmpty()) text else "$sys\n$text"
                } else {
                    items.add(normRole(role) to text)
                    // 图片只认**最后一条消息**的（"这条消息"就是本轮要问的那句）。
                    // 历史里的图片不进 `items` —— 历史只留文字，这样 KV 复用那套
                    // 判定（只比文字）不用动；而已经发过的图还在会话缓存里，
                    // 模型照样"记得住"（只有会话被重建时那几张图会从上下文里消失）。
                    if (i == msgs.length() - 1) turnImages = imagesOfRequestMessage(m)
                }
            }
            systemText = sys
        } catch (e: Throwable) {
            writePlain(out, 400, "bad json: ${e.message}")
            return
        }
        if (items.isEmpty()) {
            writePlain(out, 400, "no messages")
            return
        }
        // ⚠️ 角色合法化：见 alternating() 的注释。
        // 不做这一步，LiteRT-LM 的模板引擎会在**生成提示词之前**就拒绝整个请求
        // （真机 0.51 日志：`Conversation roles must alternate user/assistant/...`，一次会话 36 次）。
        val norm = alternating(items)
        if (norm.isEmpty()) {
            writePlain(out, 400, "no messages")
            return
        }
        var lastUser = norm.last().second
        var history = norm.subList(0, norm.size - 1).toList()
        if (norm.last().first == "model") {
            // 末条是助手（罕见：DSH 正常都以 user 收尾）：把它并进历史，补一句最小的接续。
            // 不这么做的话，history 会以 user 结尾、后面再发一轮 user —— 又违反交替规则。
            history = norm.toList()
            lastUser = "继续"
        }
        val sampler = SamplerConfig(
            topK = 40,
            topP = 0.95,
            temperature = temperature,
            seed = 0,
        )
        val samplerKey = "40|0.95|$temperature|0"

        // 整个"推理 + 会话状态更新"串行化：本地引擎一次只能跑一个请求，
        // 两个请求并发会把会话状态（KV cache）搅乱。
        synchronized(inferenceLock) {
            // ── 测速请求：另开一个临时会话，不碰主会话状态 ──────────────────
            if (stateless) {
                val tmp = try {
                    eng.createConversation(newConfig(systemText, history, sampler, reqMaxOut))
                } catch (e: Throwable) {
                    say("创建临时会话失败：${e.message}")
                    failRequest(out, streamRequested, e, clearSession = false)
                    return@synchronized
                }
                try {
                    runInference(tmp, out, lastUser, streamRequested, history, trackSession = false)
                } finally {
                    try {
                        tmp.close()
                    } catch (_: Throwable) {
                    }
                }
                return@synchronized
            }

            val reason = reuseBlockReason(systemText, samplerKey, reqMaxOut, history)
            if (reason != null) {
                if (reuseCount + rebuildCount > 0) {
                    rebuildCount++
                    lastRebuildReason = reason
                }
                lastReused = false
                say("重建会话（$reason）：历史 ${history.size} 条")
                try {
                    conv?.close()
                } catch (_: Throwable) {
                }
                conv = null
                val fresh = try {
                    eng.createConversation(newConfig(systemText, history, sampler, reqMaxOut))
                } catch (e: Throwable) {
                    say("创建会话失败：${e.message}")
                    failRequest(out, streamRequested, e)
                    return@synchronized
                }
                conv = fresh
                sessSystem = systemText
                sessModelPath = modelPath
                sessBackend = backendName
                sessMaxNumTokens = maxNumTokens
                sessMaxOutputTokens = reqMaxOut
                sessSamplerKey = samplerKey
                sessFed = history
                sessLastReply = ""
            } else {
                reuseCount++
                lastReused = true
                lastRebuildReason = ""
                say("复用会话：只发新增那一句（已缓存历史 ${history.size} 条）")
            }
            sessLastUser = lastUser
            val c = conv
            if (c != null) {
                runInference(c, out, lastUser, streamRequested, history,
                    images = turnImages)
            }
        }
    }

    /** 角色归一化：`assistant` 与 `model` 是同一边。 */
    private fun normRole(role: String): String =
        if (role == "assistant" || role == "model") "model" else "user"

    /**
     * 把消息列表整理成 LiteRT-LM 能接受的形状：**角色必须严格交替**。
     *
     * ⚠️ 为什么必须（2026-10-08 真机 0.51 日志，同一形态一次会话报了 36 次）：
     *
     *   `推理失败：Failed to start nativeSendMessageAsync: INTERNAL: Failed to apply
     *    template: invalid operation: Conversation roles must alternate
     *    user/assistant/user/assistant...`
     *
     * 这是 LiteRT-LM 的模板引擎在**生成提示词之前**做的校验 —— `initialMessages` 里只要有
     * 「同角色相邻」或「以助手（model）开场」，整次推理就直接失败（不是输出变差，是根本不跑）。
     *
     * 而 DSH 发来的 `messages` **本来就可能不交替**：它会把运行快照/环境当作**额外一条
     * user 消息**塞进来（于是出现 `user, user`），恢复历史时也可能以助手开头。
     *
     * 做法（只做**合法化**，不改语义）：① 丢掉开头连续的助手；② 相邻同角色合并成一条
     * （中间用空行分隔，等于把两段话并作一轮说）；③ 丢掉空内容。
     *
     * 于是调用方再用「最后一条当 prompt、其余当 history」切分时，history 必然为空或以
     * 助手结尾 —— 后面那一轮 user 正好交替得上。
     */
    private fun alternating(
        items: List<Pair<String, String>>,
    ): List<Pair<String, String>> {
        val out = ArrayList<Pair<String, String>>()
        for ((role, text) in items) {
            if (text.isBlank()) continue
            if (out.isEmpty() && role != "user") continue // ① 助手不能开场
            val last = out.lastOrNull()
            if (last != null && last.first == role) {
                out[out.size - 1] = role to (last.second + "\n\n" + text) // ② 合并
            } else {
                out.add(role to text)
            }
        }
        return out
    }

    private fun toMessages(history: List<Pair<String, String>>): List<Message> =
        history.map { (role, text) ->
            // ⚠️ `Message(Role, Contents)` 那个构造函数是 **internal**（javap 看得很清楚），
            // 外部只能用伴生对象上的公开工厂：`Message.user/model/system`。
            if (role == "model") Message.model(text) else Message.user(text)
        }

    /** 会话配置（只此一处构造，免得两处参数不一致）。 */
    private fun newConfig(
        system: String,
        history: List<Pair<String, String>>,
        sampler: SamplerConfig,
        maxOut: Int,
    ): ConversationConfig = ConversationConfig(
        systemInstruction = Contents.of(system),
        initialMessages = toMessages(history),
        samplerConfig = sampler,
        maxOutputToken = maxOut,
    )

    /**
     * 能不能把上一轮那个 Conversation 接着用？
     *
     * 返回 `null` = 可以复用；否则返回**不能复用的原因代码**（会写进日志与界面）——
     * 这样"这次到底省下 prefill 没有"有据可查，而不是靠体感。
     *
     * 代码是稳定的英文词（`system` / `params` / `history` / `partial`），
     * 界面侧再翻成人话（这样不用把中文字符串硬编码进原生层）。
     *
     * 判定必须**严**：任何一条不满足就重建。宁可慢一次，也不能拿错的历史去生成
     * （那会答非所问，比慢严重得多）。
     */
    private fun reuseBlockReason(
        system: String,
        samplerKey: String,
        maxOut: Int,
        history: List<Pair<String, String>>,
    ): String? {
        if (conv == null) return "first"
        if (sessSystem != system) return "system"
        if (sessModelPath != modelPath || sessBackend != backendName) return "params"
        if (sessMaxNumTokens != maxNumTokens) return "params"
        if (sessMaxOutputTokens != maxOut) return "params"
        if (sessSamplerKey != samplerKey) return "params"
        if (sessLastReply.isEmpty()) return "partial"
        // ⚠️ 这里原本写的是「history.size != sessFed.size + 2」+ 按下标逐个比 —— **那是个
        //    永远不可能满足的条件**，导致本函数**恒返回 "history"、会话一次都不复用**，
        //    也就是"同一会话每问一句都把整段历史重算一遍"（这正是用户反馈"慢"的主因之一）。
        //
        //    根因：`sessFed` 在每轮跑完后被更新为 `history + [本轮 user, 本轮 model]`
        //    （见 runInference 末尾），也就是说它**已经包含**了最后一问一答；而上面那个
        //    条件却假设它**不包含**（于是要求进来的 history 比它多 2 条）。两者永远差不上 2。
        //    已用纯逻辑模拟验证：原版 5 轮复用 0 次 / 重建 5 次；改成本行后复用 4 次 / 重建 1 次。
        //
        //    语义上正确的判据就是**精确相等**：引擎的 KV cache 里此刻正好是 sessFed 这些内容，
        //    所以只要"进来的历史 == sessFed"，就说明除了本轮新问的这句之外全都已缓存。
        //    仍然很严：任何一条参数变了、或历史被 DSH 改过（压缩/编辑）都会落到重建，宁可慢一次。
        if (history != sessFed) return "history"
        return null
    }

    /** 请求失败时的统一收尾（并让下一轮重建——坏状态不能接着用）。 */
    private fun failRequest(
        out: OutputStream,
        streamRequested: Boolean,
        e: Throwable,
        clearSession: Boolean = true,
    ) {
        say("推理失败：${e.message}")
        if (streamRequested) {
            try {
                writeSseDone(out)
            } catch (_: Throwable) {
            }
        } else {
            writePlain(out, 500, "inference failed: ${e.message}")
        }
        // 测速请求（临时会话）失败不牵连主会话。
        if (clearSession) sessLastReply = ""
    }

    /**
     * 真正跑一次生成，并把耗时拆开回报（首字延迟 / 解码速度）。
     *
     * 为什么要拆开报：用户的问题是「还是慢」——**慢在哪一段必须能自己看见**。
     * `prompt_ms` = 从发出到第一个片段（含 prefill，这才是"卡住不动"的那段），
     * `predicted_per_second` = 之后吐字的速度。
     *
     * ⚠️ 如实标注 `approx=true`：LiteRT-LM 的 `onMessage` 回调粒度不一定等于 1 token，
     * 所以这里的 tok/s 是**按回调次数估的**，与 llama-server 自己报的精确 token 计数
     * 不是一回事（界面上会分清"实测"与"近似"）。
     */
    private fun runInference(
        c: Conversation,
        out: OutputStream,
        userText: String,
        streamRequested: Boolean,
        history: List<Pair<String, String>>,
        // 本轮随消息一起发出去的图片（原始字节）。**只跟最后一条 user 走**。
        images: List<ByteArray> = emptyList(),
        // 是否把这轮结果写进"主会话"状态（测速的临时会话传 false）。
        trackSession: Boolean = true,
    ) {
        val t0 = System.nanoTime()
        var firstAt = 0L
        var chunks = 0
        val sb = StringBuilder()
        val pending = StringBuilder()
        var firstSent = false
        var lastFlush = 0L

        // ⚠️ 攒批只攒"第一个字之后"的：首字必须立刻发出去 ——
        // 用户最敏感的就是"半天不吐字"，绝不能为了少几次写操作把它推迟。
        fun flush(force: Boolean) {
            if (!streamRequested || pending.isEmpty()) return
            val now = System.nanoTime()
            val big = pending.length >= 24
            val aged = lastFlush != 0L && (now - lastFlush) / 1_000_000L >= 80L
            if (!force && !big && !aged) return
            try {
                writeSseChunk(out, pending.toString())
            } catch (_: Throwable) {
                // 客户端断了就别再写
            }
            pending.setLength(0)
            lastFlush = now
        }

        if (streamRequested) {
            writeSseHeaders(out)
        }
        val done = java.util.concurrent.CountDownLatch(1)
        var failure: Throwable? = null
        try {
            // ── 有图片就发 Contents（图 + 文），没图还是发纯字符串 ──────────────
            //
            // 为什么不是"总是发 Contents"：纯文本那条路是**跑通过的老路**，
            // 引擎对 `sendMessageAsync(String)` 的行为已经验证过（模板、停止符都对）。
            // 只在真的带图时才换成 Contents，出问题时也能一眼分清是哪条路。
            //
            // ⚠️ 图片走的是引擎**内建的视觉编码器**：只有多模态模型（如 Gemma 4 E2B）
            // 才看得见；把图发给纯文本模型，要么被忽略、要么直接报错 ——
            // 所以界面侧按模型能力决定给不给「拍照」入口（见 LocalModelSpec.vision）。
            val send: (MessageCallback) -> Unit = { cb ->
                if (images.isEmpty()) {
                    c.sendMessageAsync(userText, cb)
                } else {
                    val parts = ArrayList<Content>()
                    if (userText.isNotBlank()) parts.add(Content.Text(userText))
                    for (b in images) parts.add(Content.ImageBytes(b))
                    say("本轮带图 ${images.size} 张（共 ${images.sumOf { it.size } / 1024} KB），走 Contents 发送")
                    c.sendMessageAsync(Contents.of(parts), cb)
                }
            }
            send(object : MessageCallback {
                override fun onMessage(message: Message) {
                    val delta = extractText(message)
                    if (delta.isEmpty()) return
                    if (firstAt == 0L) firstAt = System.nanoTime()
                    chunks++
                    sb.append(delta)
                    if (!streamRequested) return
                    pending.append(delta)
                    if (!firstSent) {
                        firstSent = true
                        try {
                            writeSseChunk(out, pending.toString())
                        } catch (_: Throwable) {
                        }
                        pending.setLength(0)
                        lastFlush = System.nanoTime()
                    } else {
                        flush(false)
                    }
                }

                override fun onDone() {
                    done.countDown()
                }

                override fun onError(error: Throwable) {
                    failure = error
                    done.countDown()
                }
            })
            done.await()
        } catch (e: Throwable) {
            failure = e
        }
        flush(true)

        val t1 = System.nanoTime()
        val promptMs = if (firstAt > 0) (firstAt - t0) / 1e6 else (t1 - t0) / 1e6
        val decodeMs = if (firstAt > 0) (t1 - firstAt) / 1e6 else 0.0
        val tps = if (decodeMs > 0) chunks * 1000.0 / decodeMs else 0.0
        val timings = JSONObject()
            .put("prompt_ms", promptMs)
            .put("prompt_n", history.size)
            .put("prompt_per_second", 0)
            .put("predicted_n", chunks)
            .put("predicted_ms", decodeMs)
            .put("predicted_per_second", tps)
            // 如实标注：这是"按回调次数估的"，不是引擎内部的精确 token 计数。
            .put("approx", true)
            .put("reused", lastReused)

        val err = failure
        if (err != null) {
            failRequest(out, streamRequested, err, clearSession = trackSession)
            return
        }

        val reply = sb.toString()
        if (trackSession) {
            sessFed = history + listOf(Pair("user", userText), Pair("model", reply))
            sessLastReply = reply
        }
        say(
            "生成完成：首字 ${promptMs.toInt()}ms · $chunks 段 · " +
                "${"%.1f".format(tps)} 段/s（复用=$lastReused）",
        )

        if (streamRequested) {
            writeTimingsChunk(out, timings)
        } else {
            val resp = JSONObject()
                .put("id", "litertlm")
                .put("object", "chat.completion")
                .put("model", "local")
                .put("timings", timings)
                .put(
                    "choices",
                    JSONArray().put(
                        JSONObject()
                            .put("index", 0)
                            .put("finish_reason", "stop")
                            .put(
                                "message",
                                JSONObject().put("role", "assistant").put("content", reply),
                            ),
                    ),
                )
            val bytes = resp.toString().toByteArray(Charsets.UTF_8)
            val head = "HTTP/1.1 200 OK\r\n" +
                "Content-Type: application/json; charset=utf-8\r\n" +
                "Content-Length: ${bytes.size}\r\n" +
                "Connection: close\r\n\r\n"
            out.write(head.toByteArray(Charsets.UTF_8))
            out.write(bytes)
            out.flush()
        }
    }

    /**
     * 取一条**请求**消息的文字。
     *
     * 兼容两种形状：OpenAI 老式的 `content: "..."`，以及新式的
     * `content: [{"type":"text","text":"..."}, {"type":"image_url",...}]`。
     * 界面带图时发的就是后者 —— 认不出来就会变成"发了图却没有文字"，
     * 模型只能干瞪眼。
     */
    private fun textOfRequestMessage(m: JSONObject): String {
        val c = m.opt("content") ?: return ""
        if (c is String) return c
        if (c is JSONArray) {
            val sb = StringBuilder()
            for (i in 0 until c.length()) {
                val part = c.optJSONObject(i) ?: continue
                if (part.optString("type") != "text") continue
                val t = part.optString("text")
                if (t.isEmpty()) continue
                if (sb.isNotEmpty()) sb.append('\n')
                sb.append(t)
            }
            return sb.toString()
        }
        return ""
    }

    /**
     * 取一条**请求**消息里的图片（原始字节）。
     *
     * 只认 `data:image/...;base64,....` 这种内联形式 —— 本机引擎读不到 http 图片，
     * 让它去联网下图片既慢又不可靠。解不出来的那一张**跳过并记一行日志**，
     * 不因为一张坏图把整轮对话废掉。
     */
    private fun imagesOfRequestMessage(m: JSONObject): List<ByteArray> {
        val c = m.opt("content") ?: return emptyList()
        if (c !is JSONArray) return emptyList()
        val out = ArrayList<ByteArray>()
        for (i in 0 until c.length()) {
            val part = c.optJSONObject(i) ?: continue
            if (part.optString("type") != "image_url") continue
            val url = part.optJSONObject("image_url")?.optString("url") ?: continue
            val comma = url.indexOf(',')
            if (!url.startsWith("data:") || comma < 0) continue
            try {
                out.add(Base64.decode(url.substring(comma + 1), Base64.DEFAULT))
            } catch (e: Throwable) {
                say("图片解码失败（已跳过这张）：${e.message}")
            }
        }
        return out
    }

    /** 从一条流式消息里抠出文本增量。 */
    private fun extractText(message: Message): String {        val contents = message.contents.contents
        val sb = StringBuilder()
        for (item in contents) {
            if (item is Content.Text) sb.append(item.text)
        }
        return sb.toString()
    }

    private fun writeSseHeaders(out: OutputStream) {
        val head = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: text/event-stream; charset=utf-8\r\n" +
            "Cache-Control: no-cache\r\n" +
            "Connection: close\r\n\r\n"
        out.write(head.toByteArray(Charsets.UTF_8))
        out.flush()
    }

    private fun writeSseChunk(out: OutputStream, delta: String) {
        val payload = JSONObject()
            .put("id", "litertlm")
            .put("object", "chat.completion.chunk")
            .put("model", "local")
            .put(
                "choices",
                JSONArray().put(
                    JSONObject()
                        .put("index", 0)
                        .put("delta", JSONObject().put("content", delta)),
                ),
            )
        out.write("data: $payload\n\n".toByteArray(Charsets.UTF_8))
        out.flush()
    }

    private fun writeSseDone(out: OutputStream) {
        out.write("data: [DONE]\n\n".toByteArray(Charsets.UTF_8))
        out.flush()
    }

    /**
     * 流式结束时的**收尾分片**：带上 `finish_reason` 与 timings，再发 `[DONE]`。
     *
     * ⚠️ **`finish_reason` 绝不能省** —— 这是从 DSH 客户端源码里查出来的硬要求
     * （2026-10-08；文件：`@earendil-works/pi-ai/dist/api/openai-completions.js`）。
     * 它逐个分片是这么判的：
     *
     *   const choice = chunk.choices[0];
     *   if (!choice) continue;                    // choices 为空的分片**直接跳过**
     *   if (choice.finish_reason) { ...; hasFinishReason = true; }
     *   ...
     *   if ((compat.supportsFinishReason && !hasFinishReason) || stopReason === "pending")
     *       throw new Error("Stream ended without finish_reason");
     *
     * 而 `supportsFinishReason` 在它的 `detectCompat()` 里**默认是 true**
     * （`openai-completions.js` 里 `supportsFinishReason: true`），我们的 overlay 也没覆盖它。
     * 所以旧写法 `choices: []` 会被跳过 → `hasFinishReason` 永远 false → **DSH 直接抛错**，
     * 把一次成功的生成判成失败（现象：模型明明吐了字，会话里却报错）。
     *
     * 现在把 `finish_reason: "stop"` 放进一个 choice；`delta` 留空对象，
     * 客户端那边 `delta.content` 是 undefined，不会重复追加正文。
     */
    private fun writeTimingsChunk(out: OutputStream, timings: JSONObject) {
        val choice = JSONObject()
            .put("index", 0)
            .put("delta", JSONObject())
            .put("finish_reason", "stop")
        val payload = JSONObject()
            .put("id", "litertlm")
            .put("object", "chat.completion.chunk")
            .put("model", "local")
            .put("choices", JSONArray().put(choice))
            .put("timings", timings)
        try {
            out.write("data: $payload\n\n".toByteArray(Charsets.UTF_8))
            writeSseDone(out)
        } catch (_: Throwable) {
        }
    }
}
