package com.dshmobile.dsh_mobile

import android.app.Activity
import android.app.ActivityManager
import android.app.NotificationManager
import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodCall
import java.io.File
import java.io.FileOutputStream
import java.util.Locale
import java.security.MessageDigest
import kotlin.math.roundToInt
import java.util.zip.ZipFile

/**
 * Android 侧宿主：把随包的 DSH 运行时解开，并把路径交给 Dart。
 *
 * 设计取舍（都来自实测）：
 *  - DSH 依赖树以一个 **zip** 随包分发：26,492 个文件逐个 AssetManager.open 太慢，
 *    顺序解压一个流要快得多。
 *  - node 二进制放在 jniLibs（nativeLibraryDir）。这是 Android 允许执行原生程序的
 *    唯一位置 —— 私有目录里的可执行文件会被 SELinux 拒绝执行。
 *  - 依赖库同样在 jniLibs 里，通过 LD_LIBRARY_PATH 暴露。
 *  - 三个 Android 专用 shim 在解压末尾覆盖到目标位置（见 install/ 下的说明）。
 *  - 真正的 node 进程由 Dart 侧用 Process.start 拉起；这里只做文件系统准备与路径下发。
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "DshLocal"
        private const val CHANNEL = "dsh/native"

        /** LiteRT-LM（Gemma 4 那批 `.litertlm` 模型）：进程内 API + 本机 HTTP 包装。 */
        private val liteRtLm = LiteRtLmBridge()

        /** 改动此值会让已安装的 App 重新解压一次运行时。 */
        private const val RUNTIME_VERSION = "1"

        // 这里以前有个 `ZIP_ASSET = "dsh-runtime.zip"`（从 asset 里捞随包的运行时）。
        // 0.75 起那个 zip **不再随包**（APK 小 30 MB），改由 App 首次启动时下载到
        // `files/runtime.zip`（见 `lib/local/runtime_bootstrap.dart`），
        // 所以 `assets.open(...)` 那条路连同常量一起删掉了。
        // 要恢复"随包"：把 `build.gradle.kts` 的 assets.srcDirs 加回 `$dshNodeRoot/app-assets`，
        // 再把 `unpack()` 里的抛错换回 `assets.open(...)` 拷贝即可。

        /** 附件/语音用的 requestCode（三者互不相同即可）。 */
        private const val REQ_PICK = 4711
        private const val REQ_PHOTO = 4712
        private const val REQ_SPEECH = 4713

        /** 运行时申请麦克风权限的 requestCode（语音输入要用）。 */
        private const val REQ_MIC = 4714

        /** 「保存文件」选择器（导出运行日志）的 requestCode。 */
        private const val REQ_EXPORT = 4715

        /** 设置页「手机权限」一次性申请多项权限的 requestCode（用户意见⑦）。 */
        private const val REQ_PERMS = 4716

        /** 「从本地文件导入模型」选择器的 requestCode（端侧模型导入）。 */
        private const val REQ_IMPORT_MODEL = 4717
    }

    private var channel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var unpacking = false

    // 系统 Intent 是异步的：先把 Dart 侧的 result 存下来，等 onActivityResult 再回。
    private var pendingResult: MethodChannel.Result? = null
    private var pendingKind: String? = null
    private var pendingPhotoFile: File? = null

    /**
     * 「保存文件」这条路的挂起状态（**故意与 [pendingResult] 分开**）。
     *
     * 为什么分开：附件选择/拍照/语音共用 [pendingResult] 并且有 BUSY 保护；导出日志
     * 完全可能和它们并发（用户先点导出、再从外面选附件），共用一个槽位会互相顶掉。
     */
    private var pendingExportResult: MethodChannel.Result? = null
    private var pendingExportSource: String? = null

    /** 设备端离线识别用的实例（用完立刻 destroy，见 startOnDeviceSpeech）。 */
    private var speechRecognizer: SpeechRecognizer? = null

    /** 等麦克风权限时挂起的语音识别请求（授权结果回来后继续）。 */
    private var pendingSpeechResult: MethodChannel.Result? = null

    /** 等一组权限申请结果时挂起的调用（设置页「手机权限」，用户意见⑦）。 */
    private var pendingPermsResult: MethodChannel.Result? = null

    /** 上面那次申请对应的权限键（用来把结果映射回键名，留作诊断/日志用）。 */
    private var pendingPermsKeys: List<String>? = null

    /**
     * 「导入端侧模型」这条路的挂起状态（**同样与 [pendingResult] 分开**）。
     *
     * 为什么分开：附件/拍照共用 [pendingResult] 且有 BUSY 保护，而导入一个 1–3 GB 的
     * 模型文件要跑几分钟，期间用户完全可能去选附件 —— 共用一个槽位会互相顶掉。
     */
    private var pendingImportResult: MethodChannel.Result? = null
    private var pendingImportDir: String? = null
    private var pendingImportExpect: List<ImportExpect> = emptyList()

    /**
     * 返回手势/返回键的原生入口（用户第 10 条反馈）。
     *
     * 背景：Android 14+ 在 targetSdk ≥ 35 时默认启用 **predictive back**，返回手势由系统
     * 直接处理；我们在清单里开了 `enableOnBackInvokedCallback="true"`，但实测 Flutter
     * 框架那条路在这一版上仍然收不到（在首页按一次返回/边缘侧滑，App 直接被退到后台，
     * Dart 侧一行日志都没有）。所以这里自己注册回调，**把决定权交给 Dart**：
     *   * Dart 说"不能退"（不在首页 / 还有页面可以关）→ 什么都不做；
     *   * Dart 说"可以退"（首页上连续两次返回）→ `moveTaskToBack(true)`，即**退到后台**
     *     （用户原话："实际是退到后台了"）。
     */
    private var backCallback: Any? = null

    /**
     * 每次回到前台都重新注册一次返回回调。
     *
     * 放在 `onPostResume`（而不是 onCreate）的原因：Flutter 引擎自己也会注册一个
     * OnBackInvokedCallback，而系统在**同一优先级**下只调"最后注册的"那个。
     * onPostResume 在引擎注册之后执行，所以我们的回调能稳定胜出；重复注册前先
     * 反注册自己上一次的那个，避免堆积。
     */
    override fun onPostResume() {
        super.onPostResume()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            (backCallback as? OnBackInvokedCallback)?.let {
                onBackInvokedDispatcher.unregisterOnBackInvokedCallback(it)
            }
            val cb = OnBackInvokedCallback { dispatchBackToDart() }
            onBackInvokedDispatcher.registerOnBackInvokedCallback(
                OnBackInvokedDispatcher.PRIORITY_DEFAULT,
                cb,
            )
            backCallback = cb
        }
    }

    /** 旧系统（API < 33，没有 predictive back）走这里。 */
    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        dispatchBackToDart()
    }

    /**
     * 问 Dart："这次返回要不要真的退？"
     *
     *   * Dart 回 true  → `moveTaskToBack(true)`：**退到后台**（用户原话"实际是退到后台了"）
     *   * Dart 回 false → 什么都不做（Dart 侧可能已经关掉了当前页 / 切回首页 / 弹了提示）
     *   * 没有 Dart 处理器或调用失败 → 按"允许退"处理，绝不把用户卡在界面里
     */
    private fun dispatchBackToDart() {
        val c = channel
        if (c == null) {
            moveTaskToBack(true)
            return
        }
        c.invokeMethod("shouldExitOnBack", null, object : MethodChannel.Result {
            override fun success(result: Any?) {
                if (result == true) moveTaskToBack(true)
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                moveTaskToBack(true)
            }

            override fun notImplemented() {
                moveTaskToBack(true)
            }
        })
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // LiteRT-LM 是**进程内**的（不走子进程），所以它的 stdout 不会被 App 收集到 ——
        // 上一轮"失败了看运行日志里的 litert-lm 行"其实是空头支票：一行都不会出现。
        // 这里给它接一条日志通道，关键行直接进 App 的「运行日志」。
        liteRtLm.logger = { msg ->
            runOnUiThread {
                try {
                    channel?.invokeMethod("litertlmLog", msg)
                } catch (_: Exception) {
                }
            }
        }

        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also { c ->
            c.setMethodCallHandler { call, result ->
                when (call.method) {
                    // ---- LiteRT-LM（Gemma 4 那批 `.litertlm` 模型）----
                    //
                    // 它是**进程内 API**（Engine / Conversation），没有现成的 HTTP 服务，
                    // 所以 LiteRtLmBridge 起了一个极小的本机服务把它包成 OpenAI 兼容接口 ——
                    // 这样 App 侧（overlay / 会话 / 选择器）**一行都不用改**。
                    //
                    // ⚠️ 加载模型要几秒到几十秒 → **必须在后台线程**，否则会卡住界面。
                    "litertlmStart" -> {
                        val modelPath = call.argument<String>("modelPath") ?: ""
                        val port = call.argument<Int>("port") ?: 39441
                        val backend = call.argument<String>("backend") ?: "cpu"
                        val maxOut = call.argument<Int>("maxOutputTokens") ?: 2048
                        val temperature =
                            (call.argument<Number>("temperature")?.toDouble()) ?: 0.8
                        val maxNumTokens = call.argument<Int>("maxNumTokens") ?: 4096
                        Thread {
                            try {
                                val p = liteRtLm.start(
                                    modelPath = modelPath,
                                    requestedPort = port,
                                    backend = backend,
                                    maxOutputTokens = maxOut,
                                    temperature = temperature,
                                    maxNumTokens = maxNumTokens,
                                )
                                runOnUiThread { result.success(p) }
                            } catch (e: Throwable) {
                                // ⚠️ 这里必须 catch **Throwable**，不能只 catch Exception。
                                // 原生库加载失败抛的是 `UnsatisfiedLinkError`、模型太大是
                                // `OutOfMemoryError`、类缺失是 `NoClassDefFoundError` —— 全都是
                                // **Error**（不是 Exception）。只 catch Exception 会全部漏掉，
                                // 后果还特别隐蔽：后台线程带异常死掉 → `result` 永远不被回调 →
                                // Dart 那边 `invokeMethod` 的 future 永不返回 →
                                // **界面永远停在「启动中」，运行日志里一个字都没有**。
                                // 那样真机出问题时我们连线索都拿不到，所以必须兜住 Error。
                                //
                                // ⚠️ 只报类名等于没说：真机日志里就是这么一行
                                // `LiteRtLmJniException`，看不出到底是缺库、显存不够、
                                // 还是模型文件不对。这里把 **cause 链 + 栈顶**一起带上。
                                val sb = StringBuilder(e.javaClass.name)
                                e.message?.takeIf { it.isNotBlank() }
                                    ?.let { sb.append(": ").append(it) }
                                var c = e.cause
                                var depth = 0
                                while (c != null && depth < 3) {
                                    sb.append(" ← ").append(c.javaClass.simpleName)
                                        .append(": ").append(c.message ?: "")
                                    c = c.cause
                                    depth++
                                }
                                e.stackTrace.take(3)
                                    .forEach { sb.append("\n  at ").append(it) }
                                runOnUiThread {
                                    result.error("litertlm_start", sb.toString(), null)
                                }
                            }
                        }.start()
                    }
                    "litertlmStop" -> {
                        liteRtLm.stop()
                        result.success(true)
                    }
                    "litertlmStatus" -> result.success(liteRtLm.status())
                    // 会话复用的统计（复用次数 / 重建次数 / 最近重建原因）——
                    // 用户口径：快没快要有数字，不靠体感。
                    "litertlmStats" -> result.success(liteRtLm.statsJson())
                    "getPaths" -> result.success(runtimePaths())
                    "isRuntimeReady" -> result.success(isRuntimeReady())
                    "unpackRuntime" -> unpackRuntimeAsync(result)
                    // 定时任务保活：常驻通知的前台服务（见 DshSchedulerService）。
                    "startSchedulerService" -> {
                        val count = call.argument<Int>("count") ?: 0
                        DshSchedulerService.start(this, count)
                        result.success(true)
                    }
                    "stopSchedulerService" -> {
                        DshSchedulerService.stop(this)
                        result.success(true)
                    }
                    // 通知权限状态：UI 需要如实告诉用户"看不到常驻通知"的原因。
                    "notificationStatus" -> {
                        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                        result.success(nm.areNotificationsEnabled())
                    }
                    // ---- 附件与语音（全部走系统 Intent，零第三方依赖）----
                    // 返回：选中的文件**绝对路径**（拍照返回照片路径）；取消返回 null。
                    "pickFile" -> launchPicker(result, "file")
                    "pickMedia" -> launchPicker(result, "media")
                    "takePhoto" -> launchCamera(result)
                    // 端侧模型：从手机本地文件导入（网盘/微信/数据线拿到的模型）。
                    // 返回 Map{path, bytes, sha256, displayName}；用户取消返回 null。
                    "importModelFiles" -> launchModelImport(call, result)
                    // 返回识别出的文本；取消/失败返回 null（Dart 侧如实提示，不假装成功）。
                    // 优先设备端离线识别，退路是系统 Intent（见 recognizeSpeech）。
                    "recognizeSpeech" -> recognizeSpeech(result)
                    // 语音能力自检：告诉界面"这台机器到底有没有可用的识别服务"。
                    // 用户反馈「语音依然不能使用」时，这一个调用就能分清是
                    // "没有识别服务"还是"识别服务有问题"，不用猜。
                    "speechSupport" -> result.success(speechSupport())
                    // 松手即停（2026-10-05 修正）：让正在进行的设备端识别立刻结束并回结果。
                    // 用户反馈「按住说话没用、开了麦克风也不行」的真正根因是原先
                    // **松手之后才开始识别** —— 用户说话时根本没在录音，必然采到静音。
                    // 现在改成：按下即 startListening，松手调这里 stopListening。
                    "stopSpeech" -> stopSpeechRecognizer(result)
                    // ---- 手机系统权限（设置页「手机权限」分区，用户意见⑦）----
                    // 只读当前状态；点申请时逐项弹系统授权框（Android 没有"一键全开"）。
                    "permissionStatus" -> result.success(permissionStatus())
                    "requestPermissions" -> requestAppPermissions(
                        call.argument<List<String>>("keys") ?: emptyList(),
                        result
                    )
                    // 权限被"永久拒绝"后唯一的出路：跳到本应用的系统设置详情页。
                    "openAppSettings" -> result.success(openAppSettingsPage())
                    // 「特殊权限」入口（全部文件访问 / 悬浮窗 / 写系统设置 / 使用情况 / 安装未知应用）。
                    "openSpecialSettings" -> result.success(
                        openSpecialSettingsPage(call.argument<String>("which") ?: "")
                    )
                    // 用系统"打开方式"打开一个私有目录里的文件（产物 / 资料库）。
                    // 返回 "ok" 或 "no_app"（没有可用应用时交给 Dart 如实提示）。
                    "openFile" -> openFileByPath(call.argument<String>("path"), result)
                    // 用系统"分享"面板把文件发给别的应用（ACTION_SEND + FileProvider）。
                    // 返回 "ok" 或 "no_app"（没有任何可接收分享的应用时交给 Dart 如实提示）。
                    // subject 是可选的（聊天/邮件类接收方会拿它当标题）。
                    "openUrl" -> openUrlInBrowser(call.argument<String>("url"), result)
                    // 用**系统自带的 TTS**把文本合成成 WAV 文件（口播/短剧的配音）。
                    //
                    // 为什么是系统 TTS 而不是某个云厂商：这是给**网友**用的 App，
                    // 不能假设他们注册过某家 TTS。系统 TTS 人人都有、零配置、免费、
                    // 可离线；音色不如云端自然，但"能用"比"好听"重要。
                    // 想要更好音色的人可以在 App 里把配音来源改成 MiMo。
                    //
                    // 返回（机器可读，Dart 侧翻成人话）：
                    //   ok / no_engine / no_lang / no_text / bad_path / error:<msg>
                    "ttsToFile" -> ttsToFile(
                        call.argument<String>("text"),
                        call.argument<String>("path"),
                        call.argument<Double>("rate"),
                        call.argument<Double>("pitch"),
                        result
                    )
                    "shareFile" -> shareFileByPath(
                        call.argument<String>("path"),
                        call.argument<String>("subject"),
                        result
                    )
                    // 运行日志（用户要求：导出/分享给开发者分析）：
                    //   deviceInfo      → 报告头部要的机型/系统/版本信息；
                    //   exportTextFile  → 系统「保存文件」选择器（SAF），返回 ok:uri / cancel / no_app。
                    // ------------------------------------------------ 应用内更新
                    // updateInfo    → 安装相关的全部事实（能否装 / 已装签名 / 版本）
                    // verifyApk     → 这个 APK 的签名是否与当前 App 同一家（**唯一防线**）
                    // installApk    → 交给系统安装器（FileProvider + package-archive）
                    "updateInfo" -> result.success(updateInfo())
                    "verifyApk" -> verifyApkSignature(
                        call.argument<String>("path"),
                        result
                    )
                    "installApk" -> installApk(
                        call.argument<String>("path"),
                        result
                    )
                    "deviceInfo" -> result.success(deviceInfo())
                    "exportTextFile" -> exportTextFile(
                        call.argument<String>("fileName"),
                        call.argument<String>("sourcePath"),
                        call.argument<String>("mime"),
                        result
                    )
                    else -> result.notImplemented()
                }
            }
        }
    }

    // ---------------------------------------------------- 附件与语音（系统 Intent）
    //
    // 为什么不用第三方包：这个 App 已经 187MB，且相机/相册/文件/语音这四件事
    // 系统 Intent 全能做（ACTION_GET_CONTENT / ACTION_IMAGE_CAPTURE /
    // ACTION_RECOGNIZE_SPEECH），没必要为它们再引依赖、再要一堆运行时权限。
    //
    // 为什么不用 resolveActivity 做前置判断：Android 11+ 的包可见性会让它在没声明
    // <queries> 时**错误地返回 null**（明明装了相机也说没有）。所以这里直接启动、
    // 捕获 ActivityNotFoundException，并在 Manifest 里补上 <queries>。

    private fun attachmentsDir(): File {
        val d = File(filesDir, "attachments")
        if (!d.exists()) d.mkdirs()
        return d
    }

    private fun launchPicker(result: MethodChannel.Result, kind: String) {
        if (pendingResult != null) {
            result.error("BUSY", "上一个选择还没结束，请稍候", null)
            return
        }
        val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            if (kind == "media") {
                putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*", "video/*"))
            }
        }
        pendingResult = result
        pendingKind = kind
        try {
            startActivityForResult(
                Intent.createChooser(intent, if (kind == "media") "选择照片或视频" else "选择文件"),
                REQ_PICK
            )
        } catch (e: Throwable) {
            pendingResult = null
            pendingKind = null
            result.error("NO_PICKER", "系统没有可用的选择器：${e.message}", null)
        }
    }

    private fun launchCamera(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("BUSY", "上一个选择还没结束，请稍候", null)
            return
        }
        val target = File(attachmentsDir(), "photo-${System.currentTimeMillis()}.jpg")
        val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE)
        intent.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        try {
            val uri: Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", target)
            intent.putExtra(MediaStore.EXTRA_OUTPUT, uri)
            pendingResult = result
            pendingKind = "photo"
            pendingPhotoFile = target
            startActivityForResult(intent, REQ_PHOTO)
        } catch (e: Throwable) {
            pendingResult = null
            pendingKind = null
            pendingPhotoFile = null
            target.delete()
            result.error("NO_CAMERA", "无法启动相机（设备可能没有相机应用）：${e.message}", null)
        }
    }

    /**
     * 语音识别入口（用户 2026-10-04 反馈「语音识别无法使用，是否可以内置」）。
     *
     * 老实现只有一条路：抛 `RecognizerIntent.ACTION_RECOGNIZE_SPEECH` 给**系统**去处理
     * —— 手机上没有可用的语音识别服务（国产 ROM 没装 Google 语音、厂商服务又不响应）
     * 时直接失败，用户在界面上只看到"没识别到"。
     *
     * 现在**优先走 Android 12+ 的"设备端离线识别"**（`createOnDeviceSpeechRecognizer`，
     * 系统里预置了离线模型的语言可直接离线用），识别不到再回退到老那条 Intent 路。
     * 两条路都失败会**如实分情况报错**（没有离线模型 / 没有识别服务 / 没听清），
     * 不再是一句含糊的提示。
     *
     * 为什么不用 DSH 自带的本地 SenseVoice：它的原生包只面向 macOS / Linux glibc /
     * Windows，**Android（bionic）不在支持列表**，且 int8 模型 239MB —— 见
     * `docs/RELEASE-0.09.md` 里那条评估。
     */
    /**
     * 「从本地文件**批量**导入端侧模型」。
     *
     * 为什么整条链在原生侧做完（多选 → 逐个分块拷贝 → 校验 → 落盘），而不是只把 URI 交给 Dart：
     *  1. `content://` 的流只有原生能直接读（Dart 侧要读就得再引一个插件）；
     *  2. 1–3 GB 的文件**必须分块流式**处理 —— 一次读进内存直接 OOM；
     *  3. 走 SAF（`ACTION_OPEN_DOCUMENT` + `EXTRA_ALLOW_MULTIPLE`）**不需要任何存储权限**，
     *     绕开分区存储（Scoped Storage）下所有权限坑。
     *
     * 批量语义（与下载器同一条纪律）：
     *  - **一个文件失败不影响其余**：坏的那个删掉临时文件、记一条 error，继续下一个；
     *  - sha256 / 字节数**在 rename 之前**校验，不通过绝不允出现正式文件名；
     *  - 清单里没有的文件也照收（`matched=false`）—— 用户以后可能拿来别的模型，
     *    但这时只能证明"文件传完了"，不能证明"是我们要的那个"，UI 要如实区分。
     *
     * 进度通过 `modelImportProgress` 事件回推（宿主 → Dart），与解压进度同一套做法。
     */
    private fun launchModelImport(call: MethodCall, result: MethodChannel.Result) {
        if (pendingImportResult != null) {
            result.error("BUSY", "上一次导入还没结束，请稍候", null)
            return
        }
        val dir = call.argument<String>("targetDir")
        if (dir.isNullOrBlank()) {
            result.error("BAD_ARGS", "缺少目标目录", null)
            return
        }
        // 每个"期望条目"（文件名 → 字节数 / sha256）来自随包清单；没有匹配的也能导。
        val expected = call.argument<List<Map<String, Any>>>("expected") ?: emptyList()
        pendingImportResult = result
        pendingImportDir = dir
        pendingImportExpect = expected.map { e ->
            ImportExpect(
                name = (e["fileName"] as? String)?.lowercase() ?: "",
                bytes = (e["bytes"] as? Number)?.toLong() ?: 0L,
                sha = (e["sha256"] as? String)?.lowercase()?.takeIf { it.isNotBlank() },
            )
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            // 一次可以选多个：模型动辄 1–3 GB，让用户一个个挑太折磨。
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        try {
            startActivityForResult(
                Intent.createChooser(intent, "选择模型文件（可多选）"),
                REQ_IMPORT_MODEL
            )
        } catch (e: Throwable) {
            clearPendingImport()
            result.error("NO_PICKER", "系统没有可用的文件选择器：${e.message}", null)
        }
    }

    /** 清单里的"期望值"：按文件名匹配，用来判断导进来的到底是不是我们要的那个文件。 */
    private data class ImportExpect(val name: String, val bytes: Long, val sha: String?)

    private fun clearPendingImport() {
        pendingImportResult = null
        pendingImportDir = null
        pendingImportExpect = emptyList()
    }

    /** 从选择结果里取出全部 URI（**多选在 clipData，单选在 data**）。 */
    private fun collectUris(data: Intent?): List<Uri> {
        if (data == null) return emptyList()
        val out = mutableListOf<Uri>()
        data.clipData?.let { clip ->
            for (i in 0 until clip.itemCount) {
                clip.getItemAt(i).uri?.let { out.add(it) }
            }
        }
        if (out.isEmpty()) data.data?.let { out.add(it) }
        return out
    }

    private fun importModelsFromUris(uris: List<Uri>) {
        val result = pendingImportResult
        val dir = pendingImportDir
        val expects = pendingImportExpect
        clearPendingImport()
        if (result == null || dir == null) return

        // ⚠️ 必须在后台线程：几 GB 的流在主线程做等于 ANR。
        Thread {
            val targetDir = File(dir)
            if (!targetDir.exists() && !targetDir.mkdirs()) {
                replyImportError(result, "IMPORT_FAILED", "无法创建目录：$dir")
                return@Thread
            }
            val done = mutableListOf<Map<String, Any>>()
            var index = 0
            for (uri in uris) {
                index++
                // content:// 给的名字可能带路径，只取最后一段当文件名。
                val name = File(queryDisplayName(uri) ?: "imported-$index.bin").name
                emitImportProgress(index, uris.size, name)
                val expect = expects.firstOrNull { it.name == name.lowercase() }
                var part: File? = null
                try {
                    part = File(targetDir, "$name.part")
                    val digest = MessageDigest.getInstance("SHA-256")
                    var total = 0L
                    val stream = contentResolver.openInputStream(uri)
                        ?: throw IllegalStateException("系统没有给出可读的数据流")
                    stream.use { i ->
                        FileOutputStream(part).use { o ->
                            val buf = ByteArray(64 * 1024)
                            while (true) {
                                val n = i.read(buf)
                                if (n <= 0) break
                                o.write(buf, 0, n)
                                digest.update(buf, 0, n)
                                total += n
                            }
                            o.flush()
                            o.fd.sync()
                        }
                    }
                    val sha = digest.digest().joinToString("") { "%02x".format(it) }
                    if (expect != null && expect.bytes > 0 && total != expect.bytes) {
                        part.delete()
                        done.add(
                            errorEntry(
                                name, "SIZE_MISMATCH",
                                "文件大小与清单不符（实际 $total 字节，清单 ${expect.bytes} 字节）", total
                            )
                        )
                        continue
                    }
                    if (expect?.sha != null && sha != expect.sha) {
                        part.delete()
                        done.add(errorEntry(name, "HASH_MISMATCH", "sha256 校验失败，已丢弃该文件", total))
                        continue
                    }
                    val dst = File(targetDir, name)
                    if (dst.exists()) dst.delete()
                    if (!part.renameTo(dst)) {
                        // 少数机型上跨挂载点 rename 会失败：退回"拷贝 + 删临时"。
                        part.copyTo(dst, overwrite = true)
                        part.delete()
                    }
                    Log.i(TAG, "import ok -> ${dst.absolutePath} ($total B, matched=${expect != null})")
                    done.add(
                        mapOf(
                            "ok" to true,
                            "file" to name,
                            "path" to dst.absolutePath,
                            "bytes" to total,
                            "sha256" to sha,
                            "matched" to (expect != null),
                            "verified" to (expect != null &&
                                (expect.sha != null || expect.bytes > 0)),
                        )
                    )
                } catch (e: Throwable) {
                    try { part?.delete() } catch (_: Throwable) {}
                    Log.w(TAG, "导入 $name 失败：${e.message}")
                    done.add(errorEntry(name, "IMPORT_FAILED", "导入失败：${e.message}", 0L))
                }
            }
            emitImportProgress(uris.size, uris.size, "")
            mainHandler.post { result.success(done) }
        }.start()
    }

    private fun errorEntry(name: String, code: String, msg: String, bytes: Long): Map<String, Any> =
        mapOf("ok" to false, "file" to name, "code" to code, "message" to msg, "bytes" to bytes)

    /** 把导入进度推给 Dart（宿主 → Dart 的方法通道，和解压进度同一套）。 */
    private fun emitImportProgress(done: Int, total: Int, current: String) {
        mainHandler.post {
            channel?.invokeMethod(
                "modelImportProgress",
                mapOf("done" to done, "total" to total, "current" to current),
            )
        }
    }

    private fun replyImportError(result: MethodChannel.Result, code: String, msg: String) {
        mainHandler.post { result.error(code, msg, null) }
    }

    private fun recognizeSpeech(result: MethodChannel.Result) {


        if (pendingResult != null) {
            result.error("BUSY", "上一个操作还没结束，请稍候", null)
            return
        }
        // 只有**设备端识别可用**时才必须先要麦克风权限：那条路是 App 自己录音，
        // 没有 RECORD_AUDIO 会直接回调 error=9（用户反馈的"语音依然不能使用"）。
        // 而系统识别 Intent 那条路由系统 App 自己录音，本应用**不需要**麦克风权限 ——
        // 所以设备端不可用的机器（比如用户那台没有任何识别服务）不应该被白弹一次授权。
        if (onDeviceSpeechUsable() &&
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            pendingSpeechResult = result
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQ_MIC)
            return
        }
        recognizeSpeechGranted(result)
    }

    /** Android 12+ 且系统报告"设备端识别可用"。 */
    private fun onDeviceSpeechUsable(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        return try {
            SpeechRecognizer.isOnDeviceRecognitionAvailable(this)
        } catch (e: Throwable) {
            Log.w(TAG, "on-device speech probe failed: ${e.message}")
            false
        }
    }

    /** 已经拿到麦克风权限之后的实际派发（设备端优先，失败回退系统识别）。 */
    private fun recognizeSpeechGranted(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                if (SpeechRecognizer.isOnDeviceRecognitionAvailable(this)) {
                    startOnDeviceSpeech(result)
                    return
                }
                Log.i(TAG, "on-device speech unavailable, falling back to RecognizerIntent")
            } catch (e: Throwable) {
                Log.w(TAG, "on-device speech probe failed: ${e.message}")
            }
        }
        // 回退：老的系统 Intent（需要设备上有识别应用/服务）。
        launchSpeech(result)
    }

    /** Android 12+ 的设备端离线识别（不走 Intent，直接回调）。 */
    private fun startOnDeviceSpeech(result: MethodChannel.Result) {
        var recognizer: SpeechRecognizer? = null
        var replied = false

        fun finish(text: String?) {
            if (replied) return
            replied = true
            try {
                recognizer?.destroy()
            } catch (_: Throwable) {
            }
            speechRecognizer = null
            result.success(text)
        }

        try {
            recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(this)
        } catch (e: Throwable) {
            Log.w(TAG, "createOnDeviceSpeechRecognizer failed: ${e.message}")
            finish(null)
            return
        }
        speechRecognizer = recognizer
        recognizer.setRecognitionListener(object : RecognitionListener {
            override fun onResults(results: Bundle?) {
                val list = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val text = list?.firstOrNull()?.trim()
                Log.i(TAG, "on-device speech -> ${text?.length ?: 0} chars")
                finish(if (text.isNullOrEmpty()) null else text)
            }

            override fun onError(error: Int) {
                Log.w(TAG, "on-device speech error=$error")
                // ⚠️ 设备端识别"自称可用"但实际会失败（这台机器没装该语言的离线模型、
                // 不支持这个语言标签、或识别环境有问题）。这时**必须退回系统识别那条路**，
                // 而不是把"没识别到"直接甩给用户 —— 用户反馈「语音依然不能使用」，
                // 这里是最可能的盲点。
                try {
                    recognizer?.destroy()
                } catch (_: Throwable) {
                }
                speechRecognizer = null
                if (replied) return
                replied = true
                Log.i(TAG, "on-device speech failed, fallback to RecognizerIntent")
                launchSpeech(result)
            }

            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onPartialResults(partialResults: Bundle?) {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            // 用系统语言，别再硬写 zh-CN：用户的设备语言才是他说话的语言。
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, speechLanguageTag())
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        }
        try {
            recognizer.startListening(intent)
        } catch (e: Throwable) {
            // ⚠️ 这里**必须**和上面的 onError 一样回退到系统 Intent。
            // 原来这里是直接 finish(null) —— 设备端识别**同步抛异常**（例如刚拿到
            // 麦克风权限、recognizer 还没就绪、或该机型不支持离线识别）时，
            // Dart 侧只会看到 null，界面提示"没有识别到内容"，
            // 用户完全看不出"设备端识别根本没起来"，也永远等不到回退。
            Log.w(TAG, "on-device startListening failed: ${e.message}")
            try {
                recognizer.destroy()
            } catch (_: Throwable) {
            }
            speechRecognizer = null
            if (!replied) {
                replied = true
                Log.i(TAG, "startListening threw, fallback to RecognizerIntent")
                launchSpeech(result)
            }
        }
    }

    /**
     * 用系统浏览器打开一个**网址**（内置厂家的「去注册 / 申请 Key」按钮用）。
     *
     * 与 [openFileByPath] 分开的原因：那个走 FileProvider（content:// 文件），
     * 这里要的是 http/https 外链，直接用 ACTION_VIEW + Uri.parse 更简单也更正确。
     *
     * 安全约束：**只允许 http/https**。不然界面上一旦被拼进 `file://` 或
     * `intent://` 之类的值，就可能变成一个奇怪的跳转（甚至本地文件外泄路径）。
     */
    private fun openUrlInBrowser(url: String?, result: MethodChannel.Result) {
        val u = url?.trim().orEmpty()
        if (u.isEmpty()) {
            result.error("BAD_ARGS", "缺少 url 参数", null)
            return
        }
        if (!u.startsWith("http://") && !u.startsWith("https://")) {
            result.error("BAD_URL", "只支持 http/https 网址：$u", null)
            return
        }
        try {
            startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse(u)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            Log.i(TAG, "openUrl -> $u")
            result.success("ok")
        } catch (e: android.content.ActivityNotFoundException) {
            // 没有浏览器：环境事实，交给 Dart 如实提示，不假装打开了。
            Log.w(TAG, "openUrl: 没有可用浏览器 -> $u")
            result.success("no_app")
        } catch (e: Throwable) {
            Log.w(TAG, "openUrl failed: ${e.message}")
            result.error("OPEN_FAILED", "打开网址失败：${e.message}", null)
        }
    }

    /**
     * 识别用的语言标签，**规范成两段式**（`zh-CN` 这种）。
     *
     * 为什么不让它直接用 `Locale.getDefault().toLanguageTag()`：中文手机上那会得到
     * **三段式** `zh-Hans-CN`，而相当多厂商的识别服务只认 `zh-CN`，会直接判
     * "不支持该语言"然后失败 —— 用户反馈「语音依然不能使用」，这是首要嫌疑。
     * 两段式是各家的最大公约数；语言本身仍跟随手机（不再写死中文）。
     */
    private fun speechLanguageTag(): String {
        val l = Locale.getDefault()
        return if (!l.country.isNullOrEmpty()) "${l.language}-${l.country}" else l.language
    }

    /** 语音识别能力自检（给"为什么用不了"提供可讲清的依据）。 */
    private fun speechSupport(): Map<String, Any> {
        val handles = try {
            packageManager.queryIntentActivities(
                Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH),
                0,
            ).size
        } catch (e: Throwable) {
            Log.w(TAG, "queryIntentActivities(RECOGNIZE_SPEECH) failed: ${e.message}")
            -1
        }
        val onDevice = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                SpeechRecognizer.isOnDeviceRecognitionAvailable(this)
            } catch (e: Throwable) {
                false
            }
        } else {
            false
        }
        val available = try {
            SpeechRecognizer.isRecognitionAvailable(this)
        } catch (e: Throwable) {
            false
        }
        return mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "recognitionAvailable" to available,
            "onDeviceAvailable" to onDevice,
            "intentHandlers" to handles,
            "language" to speechLanguageTag(),
        )
    }

    /**
     * 松手即停（配合"按下即听"的修正）。
     *
     * 返回 `ok` / `noop`（当前没在识别，例如走的是系统 Intent 路径，由系统 App
     * 自己录音）/ `failed`。**一律 success 返回、不抛错** —— 停止失败不该打断
     * 「取识别结果」这条主链路，Dart 侧按返回文案如实提示即可。
     */
    private fun stopSpeechRecognizer(result: MethodChannel.Result) {
        val r = speechRecognizer
        if (r == null) {
            result.success("noop")
            return
        }
        try {
            r.stopListening()
            result.success("ok")
        } catch (e: Throwable) {
            Log.w(TAG, "stopListening failed: ${e.message}")
            result.success("failed")
        }
    }

    // ---------------------------------------------------- 手机系统权限（用户意见⑦）

    /**
     * 权限键 → Android 权限名的映射。
     *
     * 键是 Dart 侧与原生约定的稳定名字；值可能是**一组**：
     *   * 定位必须 FINE + COARSE **一起**申请 —— Android 12 起单独要 FINE 会被系统忽略；
     *   * 相册在 Android 13+ 用 READ_MEDIA_*，12 及以下退到 READ_EXTERNAL_STORAGE；
     *   * 通知在 Android 13 以下不需要（也是空的，界面上如实说明）。
     */
    private fun permissionGroups(): Map<String, List<String>> {
        val photos = if (Build.VERSION.SDK_INT >= 33) {
            listOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
        } else {
            listOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
        val notif = if (Build.VERSION.SDK_INT >= 33) {
            listOf(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            emptyList()
        }
        return linkedMapOf(
            "microphone" to listOf(Manifest.permission.RECORD_AUDIO),
            "location" to listOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            ),
            "photos" to photos,
            "notifications" to notif,
        )
    }

    /**
     * 某一组权限的当前状态：
     * `granted` / `denied`（还能再弹）/ `permanently-denied`（只能去系统设置）/ `not-declared`。
     */
    private fun groupStatus(names: List<String>): String {
        if (names.isEmpty()) return "not-declared"
        for (n in names) {
            if (checkSelfPermission(n) != PackageManager.PERMISSION_GRANTED) {
                // ⚠️ shouldShowRequestPermissionRationale 的语义是反的：
                // 返回 false 且未授权 = 用户勾了"不再询问"（或系统策略），只能去设置页。
                return if (shouldShowRequestPermissionRationale(n)) "denied" else "permanently-denied"
            }
        }
        return "granted"
    }

    /** 全部权限键 → 状态。 */
    private fun permissionStatus(): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        for ((k, names) in permissionGroups()) out[k] = groupStatus(names)
        return out
    }

    /**
     * 申请一组权限键（可能触发多次系统弹窗，Android 自己合并）。
     * 结果回来后把**最新状态**整体回给 Dart（比逐项回更好用）。
     */
    private fun requestAppPermissions(keys: List<String>, result: MethodChannel.Result) {
        if (pendingPermsResult != null) {
            result.error("BUSY", "上一次权限申请还没结束，请稍候", null)
            return
        }
        val groups = permissionGroups()
        val names = LinkedHashSet<String>()
        for (k in keys) groups[k]?.let { names.addAll(it) }
        if (names.isEmpty()) {
            // 没有要申请的（例如低版本 Android 上的通知）—— 直接回当前状态，不弹空窗。
            result.success(permissionStatus())
            return
        }
        pendingPermsResult = result
        pendingPermsKeys = keys
        requestPermissions(names.toTypedArray(), REQ_PERMS)
    }

    /** 跳到本应用的系统设置详情页（权限被永久拒绝后唯一能做的事）。 */
    private fun openAppSettingsPage(): Boolean {
        return try {
            startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", packageName, null),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } catch (e: Throwable) {
            Log.w(TAG, "openAppSettings failed: ${e.message}")
            false
        }
    }

    /**
     * 「特殊权限」入口。返回 `opened` / `unsupported` / `failed`。
     *
     * ⚠️ 这些**不是**普通运行时权限，必须由用户在系统页面里手动打开 ——
     * 应用无法自行授予，Android 也没有「一键全开」的 API。界面文案必须如实这么写，
     * 不能承诺"点了就全开"。
     *
     * ## 2026-10-11（用户第 7 条「打开以后无法点选」）两处修复
     *
     * 1. **根因在清单**：这 5 项以前一条都没在 AndroidManifest.xml 里声明，而系统设置页
     *    只会给"清单里声明过"的应用显示对应开关 —— 没声明时用户点进去看到的就是
     *    **灰的 / 根本没有本应用这一项**。清单已补齐（每条都附了官方依据）。
     * 2. **多给一个入口**：有些 ROM 把"带包名的专属页"删了或改名了，`startActivity`
     *    会抛 `ActivityNotFoundException`。这时退到**不带包名的全局页**往往还能开
     *    （用户自己在列表里找到本应用）——宁可多退一步，也不要只回一句"失败"。
     */
    private fun openSpecialSettingsPage(which: String): String {
        // 每个 which → **候选入口列表**（先专属页，再全局页）。
        val candidates = mutableListOf<Intent>()
        when (which) {
            "all-files" -> if (Build.VERSION.SDK_INT >= 30) {
                candidates += Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                    .setData(Uri.fromParts("package", packageName, null))
                candidates += Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
            }
            "overlay" -> if (Build.VERSION.SDK_INT >= 23) {
                candidates += Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION)
                    .setData(Uri.fromParts("package", packageName, null))
                candidates += Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION)
            }
            "write-settings" -> if (Build.VERSION.SDK_INT >= 23) {
                candidates += Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS)
                    .setData(Uri.fromParts("package", packageName, null))
                candidates += Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS)
            }
            // ⚠️ 使用情况访问**没有**"只看本应用"的页面：Android 只提供一份全局列表，
            //    用户要在列表里找到本应用再勾选。界面那边是这么写的（别说成"点一下就好"）。
            "usage-access" -> candidates += Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
            "install-packages" -> if (Build.VERSION.SDK_INT >= 26) {
                candidates += Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                    .setData(Uri.fromParts("package", packageName, null))
                candidates += Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
            }
            else -> return "unsupported"
        }
        if (candidates.isEmpty()) return "unsupported"
        for (intent in candidates) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return "opened"
            } catch (e: Throwable) {
                Log.w(TAG, "openSpecialSettings($which) 这个入口打不开，试下一个：${e.message}")
            }
        }
        return "failed"
    }

    private fun launchSpeech(result: MethodChannel.Result) {
        if (pendingResult != null) {
            // ⚠️ 这里的文案要分场景：语音是用户**主动按住说话**发起的，
            // 此时若告诉他"上一个操作还没结束，请稍候"，他根本不知道指什么、
            // 也不知道该等什么（而且很可能永远等不到）。给出可执行的出路。
            result.error(
                "BUSY",
                "现在有另一个操作正在等待系统返回（比如刚点开的文件选择器/相机）。"
                    + "先把它取消掉，再试语音输入。",
                speechSupport(),
            )
            return
        }
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, speechLanguageTag())
            putExtra(RecognizerIntent.EXTRA_PROMPT, "请说话")
        }
        pendingResult = result
        pendingKind = "speech"
        try {
            startActivityForResult(intent, REQ_SPEECH)
        } catch (e: Throwable) {
            pendingResult = null
            pendingKind = null
            // 失败时把**自检结果**一起告诉用户/我们，别只说"用不了"。
            result.error(
                "NO_SPEECH",
                "这台手机没有可用的语音识别服务（系统识别可用=" +
                    "${speechSupport()["recognitionAvailable"]}，能处理语音识别的应用数=" +
                    "${speechSupport()["intentHandlers"]}）。可以先用文字输入；" +
                    "要在系统设置里装/开一个语音识别服务，或者告诉我用哪家云端语音识别（需要那家的 Key）。",
                speechSupport(),
            )
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        // 设置页「手机权限」的一次多项申请（用户意见⑦）。
        // 回来后**整体重读状态**再回给 Dart —— 比逐项映射结果更不容易错。
        if (requestCode == REQ_PERMS) {
            val pending = pendingPermsResult
            val keys = pendingPermsKeys
            pendingPermsResult = null
            pendingPermsKeys = null
            Log.i(TAG, "REQ_PERMS 结果 keys=$keys")
            pending?.success(permissionStatus())
            return
        }
        if (requestCode != REQ_MIC) return
        val pending = pendingSpeechResult ?: return
        pendingSpeechResult = null
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (granted) {
            Log.i(TAG, "RECORD_AUDIO granted, continue speech recognition")
            recognizeSpeechGranted(pending)
        } else {
            Log.w(TAG, "RECORD_AUDIO denied")
            pending.error(
                "NO_MIC",
                "语音输入需要麦克风权限：请在系统设置 → 应用 → 泡泡猫的DSH → 权限里允许" +
                    "「麦克风」，然后重试。",
                null,
            )
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        // ⚠️ 导出日志这条**必须**排在 `pendingResult` 那个 early-return 之前：
        // 它用的是独立的 pendingExportResult，混在一起会导致系统回来时提前 return、
        // Dart 侧永远等不到结果（界面表现就是"点了导出一直转圈"）。
        if (requestCode == REQ_EXPORT) {
            val pending = pendingExportResult
            val source = pendingExportSource
            pendingExportResult = null
            pendingExportSource = null
            if (pending == null) return
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) {
                // 用户自己取消：如实返回 'cancel'，界面要能区分"取消"和"写失败"。
                Log.i(TAG, "exportTextFile canceled by user")
                pending.success("cancel")
                return
            }
            try {
                val f = source?.let { File(it) }
                if (f == null || !f.exists()) {
                    pending.error("NOT_FOUND", "源文件不存在：$source", null)
                    return
                }
                // "wt" = 截断写（用户选了已存在的文件时不要留旧尾巴）。
                val out = contentResolver.openOutputStream(uri, "wt")
                if (out == null) throw IllegalStateException("系统没有给出可写的位置")
                out.use { o -> f.inputStream().use { i -> i.copyTo(o, 256 * 1024) } }
                Log.i(TAG, "exportTextFile -> $uri (${f.length()} bytes)")
                pending.success("ok:$uri")
            } catch (e: Throwable) {
                Log.w(TAG, "exportTextFile 写失败：${e.message}")
                pending.error("WRITE_FAILED", "写入所选位置失败：${e.message}", null)
            }
            return
        }

        // 导入模型同理：它有自己的挂起槽位，**必须**排在下面 pendingResult 的
        // early-return 之前，否则系统回来时会提前 return、Dart 侧永远等不到结果。
        if (requestCode == REQ_IMPORT_MODEL) {
            val pending = pendingImportResult
            val uris = collectUris(data)
            if (resultCode != Activity.RESULT_OK || uris.isEmpty()) {
                clearPendingImport()
                // null = 用户自己取消（不是失败），Dart 侧要能区分。
                pending?.success(null)
                return
            }
            importModelsFromUris(uris)
            return
        }

        val result = pendingResult ?: return
        pendingResult = null
        pendingKind = null

        when (requestCode) {
            REQ_PICK -> {
                val uri = data?.data
                if (resultCode != Activity.RESULT_OK || uri == null) {
                    result.success(null) // 用户取消：如实返回 null，由界面提示
                    return
                }
                try {
                    val name = queryDisplayName(uri) ?: "file-${System.currentTimeMillis()}"
                    val target = uniqueTarget(name)
                    contentResolver.openInputStream(uri).use { input ->
                        if (input == null) throw IllegalStateException("读不到所选内容")
                        target.outputStream().use { out -> input.copyTo(out, 256 * 1024) }
                    }
                    Log.i(TAG, "picker -> ${target.absolutePath} (${target.length()} bytes)")
                    result.success(target.absolutePath)
                } catch (e: Throwable) {
                    Log.w(TAG, "picker copy failed: ${e.message}")
                    result.error("COPY_FAILED", "复制所选文件失败：${e.message}", null)
                }
            }
            REQ_PHOTO -> {
                val f = pendingPhotoFile
                pendingPhotoFile = null
                if (resultCode != Activity.RESULT_OK || f == null || !f.exists() || f.length() == 0L) {
                    f?.delete()
                    result.success(null)
                } else {
                    Log.i(TAG, "camera -> ${f.absolutePath} (${f.length()} bytes)")
                    result.success(f.absolutePath)
                }
            }
            REQ_SPEECH -> {
                if (resultCode != Activity.RESULT_OK) {
                    result.success(null)
                    return
                }
                val list = data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
                result.success(list?.firstOrNull())
            }
            else -> result.success(null)
        }
    }

    // ---------------------------------------------------- 打开文件（ACTION_VIEW）

    /**
     * 用系统的"打开方式"打开一个 App 私有目录里的文件。
     *
     * 为什么必须走 FileProvider：Android 7+ 把 `file://` 交给别的应用会直接抛
     * `FileUriExposedException`，必须换成 `content://` + 临时读权限。
     *
     * 返回约定（Dart 侧据此给用户**准确**的反馈，不假装成功）：
     *   * `"ok"`     —— 已经拉起某个应用；
     *   * `"no_app"` —— 系统里没有能打开这种类型的应用（**不算错误**，是环境事实）。
     * 参数缺失 / 文件不存在则抛 error（`PlatformException`，message 已是中文）。
     */
    // ───────────────────────────────────────────── 系统 TTS（配音）

    private var tts: TextToSpeech? = null
    private var ttsReady = false

    /**
     * 把 [text] 用系统 TTS 合成成 WAV 写到 [path]。
     *
     * 设计要点（都踩过或想过）：
     *  * `TextToSpeech` 的初始化是**异步**的（要在 `onInit` 里才知道引擎可用不可用），
     *    所以这里必须把 result 存到回调里回，不能同步返回；
     *  * 语言单独判定：设备可能装了引擎但**没装中文语音数据** → 返回 `no_lang`，
     *    让 Dart 侧提示"去系统设置装中文语音包，或改用 MiMo"，
     *    而不是抛一个用户看不懂的异常；
     *  * 实例**缓存**复用（每个镜头都新建一次会明显变慢）；
     *  * 超时兜底：合成可能永远不回调（个别引擎的毛病），到点必须给出失败。
     */
    private fun ttsToFile(
        text: String?,
        path: String?,
        rate: Double?,
        pitch: Double?,
        result: MethodChannel.Result
    ) {
        if (text.isNullOrBlank()) { result.success("no_text"); return }
        if (path.isNullOrBlank()) { result.success("bad_path"); return }
        val out = File(path)
        try {
            out.parentFile?.mkdirs()
            if (out.exists()) out.delete()
        } catch (e: Exception) {
            Log.w(TAG, "ttsToFile: 准备输出文件失败 $e")
            result.success("bad_path")
            return
        }

        mainHandler.post {
            var replied = false
            fun reply(value: String) {
                if (replied) return
                replied = true
                mainHandler.post { result.success(value) }
            }

            // ⚠️ 不能在主线程里 Thread.sleep 等初始化（会把界面卡住最多几秒）：
            //    初始化完的回调里再干活。
            fun start(engine: TextToSpeech) {
                val lang = engine.setLanguage(Locale.SIMPLIFIED_CHINESE)
                if (lang == TextToSpeech.LANG_MISSING_DATA ||
                    lang == TextToSpeech.LANG_NOT_SUPPORTED
                ) {
                    Log.w(TAG, "ttsToFile: 中文语音数据缺失/不支持 lang=$lang")
                    reply("no_lang")
                    return
                }
                if (rate != null) engine.setSpeechRate(rate.toFloat())
                if (pitch != null) engine.setPitch(pitch.toFloat())

                val utteranceId = "dsh-tts-" + System.currentTimeMillis()
                engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(id: String?) {}
                    override fun onDone(id: String?) {
                        reply(if (out.exists() && out.length() > 0) "ok" else "error:empty_output")
                    }
                    @Suppress("OVERRIDE_DEPRECATION")
                    override fun onError(id: String?) { reply("error:synth_failed") }
                    override fun onError(id: String?, errorCode: Int) {
                        reply("error:synth_failed_$errorCode")
                    }
                })

                val rc = engine.synthesizeToFile(text, null, out, utteranceId)
                if (rc != TextToSpeech.SUCCESS) {
                    Log.w(TAG, "ttsToFile: synthesizeToFile 返回 $rc")
                    reply("error:submit_failed_$rc")
                    return
                }
                // 超时兜底：个别引擎会永远不回调，到点必须给出失败而不是让用户干等。
                mainHandler.postDelayed({ reply("error:timeout") }, 180_000)
            }

            val existing = tts
            if (existing != null && ttsReady) {
                start(existing)
                return@post
            }
            tts = TextToSpeech(this) { status ->
                if (status != TextToSpeech.SUCCESS) {
                    Log.w(TAG, "ttsToFile: 引擎初始化失败 status=$status")
                    reply("no_engine")
                    return@TextToSpeech
                }
                ttsReady = true
                val engine = tts
                if (engine == null) reply("no_engine") else mainHandler.post { start(engine) }
            }
        }
    }

    // ---------------------------------------------- 应用内更新（下载完之后的三件事）

    /**
     * 安装相关的**全部事实**，一次问清。
     *
     * 为什么把"已装应用的签名"也一起返回：覆盖安装要求新旧包**同一签名**，
     * 而这是唯一能证明"我要装的这个包跟现在这个 App 是同一家签的"的依据。
     * Dart 侧拿它跟下载到的 APK 比对，不一致就**拒绝安装**
     * （见 [verifyApkSignature] 与 Dart 侧 `local/apk_installer.dart`）。
     *
     * `installedSignature` 是**签名证书 DER 的 sha256（小写 hex）** —— 与
     * `apksigner verify --print-certs` / `keytool -list` 显示的口径一致，便于人工核对。
     */
    private fun updateInfo(): Map<String, Any?> {
        val out = mutableMapOf<String, Any?>(
            "packageName" to packageName,
            "sdkInt" to Build.VERSION.SDK_INT,
            // O 之前没有"逐应用允许安装"这个开关，所以老系统一律视为已允许。
            "canInstall" to (Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                packageManager.canRequestPackageInstalls()),
            "installedSignature" to installedSignature(),
        )
        try {
            @Suppress("DEPRECATION")
            val pi = packageManager.getPackageInfo(packageName, 0)
            out["versionCode"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pi.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                pi.versionCode.toLong()
            }
            out["versionName"] = pi.versionName
        } catch (e: Throwable) {
            // 读不到自己的包信息不该让整次查询失败 —— 那两项只是"显示用"。
            Log.w(TAG, "updateInfo: 读不到自身包信息：${e.message}")
        }
        return out
    }

    /** 已装应用的签名证书 sha256；读不到返回 null（**不猜、不兜底**）。 */
    private fun installedSignature(): String? = try {
        @Suppress("DEPRECATION")
        val pi = packageManager.getPackageInfo(packageName, signatureFlags())
        signaturesOf(pi)?.firstOrNull()?.let { sha256Hex(it.toByteArray()) }
    } catch (e: Throwable) {
        Log.w(TAG, "读已装应用签名失败：${e.message}")
        null
    }

    /** API 28 前后取签名的 flag 不同：P 起是 GET_SIGNING_CERTIFICATES，之前是 GET_SIGNATURES。 */
    private fun signatureFlags(): Int = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        PackageManager.GET_SIGNING_CERTIFICATES
    } else {
        @Suppress("DEPRECATION")
        PackageManager.GET_SIGNATURES
    }

    /** 从一个已解析的 PackageInfo 里取出签名数组（P 前后字段不同）。 */
    private fun signaturesOf(
        pi: android.content.pm.PackageInfo
    ): Array<android.content.pm.Signature>? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val si = pi.signingInfo ?: return null
            // 多签名（v1+v2 各自签）走 apkContentsSigners；单签名时两者首个元素相同。
            // 这里统一取**当前 APK 的签名者**，避免把轮换历史里的旧证书当成当前签名。
            return if (si.hasMultipleSigners()) {
                si.apkContentsSigners
            } else {
                si.signingCertificateHistory
            }
        }
        @Suppress("DEPRECATION")
        return pi.signatures
    }

    /**
     * 字节数组 → 小写 hex。
     *
     * ⚠️ `"%02x".format(it)` 对**负的字节**会输出 `ffffff80` 这种 8 位串
     * （Byte 先按有符号提升成 Int）—— 那不是"证书 DER 的 sha256"，
     * 也就跟我文档里写的"与 apksigner 口径一致"对不上。
     * 必须先 `and 0xFF` 掩成无符号。
     */
    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 0xFF) }

    /**
     * 校验一个 APK：它是不是合法 APK，以及**它的签名是不是跟当前这个 App 同一家**。
     *
     * ⚠️ 这是"更新不被换成别人的包"的**唯一防线**，所以只回答事实、不做任何妥协：
     *   * 读不出签名 → `matched = false`（读不出就是不能装，而不是"那就算它对吧"）；
     *   * 包没有签名 → `matched = false`；
     *   * 比对得上才 `matched = true`。
     *
     * 返回 `{matched, apkSignature, installedSignature, reason}`，
     * `reason` 是机器可读的原因（not_an_apk / apk_unsigned / installed_unknown /
     * signature_mismatch / read_failed），由 Dart 侧翻成人话。
     */
    private fun verifyApkSignature(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("BAD_ARGS", "缺少 path 参数", null)
            return
        }
        val f = File(path)
        if (!f.exists() || !f.isFile) {
            result.error("NOT_FOUND", "文件不存在：$path", null)
            return
        }
        val installed = installedSignature()
        val out = mutableMapOf<String, Any?>(
            "installedSignature" to installed,
            "apkSignature" to null,
            "matched" to false,
            "reason" to null,
        )
        try {
            @Suppress("DEPRECATION")
            val pi = packageManager.getPackageArchiveInfo(f.absolutePath, signatureFlags())
            if (pi == null) {
                out["reason"] = "not_an_apk"
                result.success(out)
                return
            }
            val apkSig = signaturesOf(pi)?.firstOrNull()?.let { sha256Hex(it.toByteArray()) }
            out["apkSignature"] = apkSig
            when {
                apkSig == null -> out["reason"] = "apk_unsigned"
                installed == null -> out["reason"] = "installed_unknown"
                apkSig == installed -> out["matched"] = true
                else -> out["reason"] = "signature_mismatch"
            }
        } catch (e: Throwable) {
            Log.w(TAG, "verifyApkSignature 失败：${e.message}")
            out["reason"] = "read_failed"
            out["detail"] = e.message
        }
        result.success(out)
    }

    /**
     * 把下载好的 APK 交给系统安装器（ACTION_VIEW + `application/vnd.android.package-archive`）。
     *
     * 为什么必须走 FileProvider：Android 7 起禁止用 `file://` URI 跨应用传文件
     * （FileUriExposedException），只能换成 content:// 并临时授权读取。
     *
     * 为什么**不**自己实现安装：普通应用在 Android 8+ 上不允许静默安装 ——
     * 系统一定会弹安装界面让用户点确认。所以这里做完就结束，**拿不到"装没装成"**，
     * 界面上也不能假装能拿到（如实写"装完请回到 App"）。
     *
     * 返回（Dart 侧翻成人话）：
     *   * `"ok"`              —— 安装界面已拉起；
     *   * `"need_permission"` —— 还没允许"安装未知应用"，要先引导去系统设置；
     *   * `"no_app"`          —— 系统里没有能处理安装 Intent 的应用（定制 ROM 上才有）；
     *   * `"bad_path"`        —— 路径不在 FileProvider 白名单里（配置问题，要报出来）。
     */
    private fun installApk(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("BAD_ARGS", "缺少 path 参数", null)
            return
        }
        val f = File(path)
        if (!f.exists() || !f.isFile) {
            result.error("NOT_FOUND", "文件不存在：$path", null)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            Log.i(TAG, "installApk: 还没允许安装未知应用")
            result.success("need_permission")
            return
        }
        try {
            val uri: Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", f)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            Log.i(TAG, "installApk -> $path")
            result.success("ok")
        } catch (e: android.content.ActivityNotFoundException) {
            Log.w(TAG, "installApk: 系统里没有安装器 -> $path")
            result.success("no_app")
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "installApk: 路径不在 FileProvider 白名单里 -> $path（${e.message}）")
            result.success("bad_path")
        } catch (e: Throwable) {
            Log.w(TAG, "installApk failed: ${e.message}")
            result.error("INSTALL_FAILED", "拉起安装界面失败：${e.message}", null)
        }
    }

    private fun openFileByPath(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("BAD_ARGS", "缺少 path 参数", null)
            return
        }
        val f = File(path)
        if (!f.exists() || !f.isFile) {
            result.error("NOT_FOUND", "文件不存在：$path", null)
            return
        }
        try {
            val uri: Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", f)
            val mime = mimeTypeFor(f.name)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            Log.i(TAG, "openFile -> $path ($mime)")
            result.success("ok")
        } catch (e: android.content.ActivityNotFoundException) {
            // 没装能打开它的应用 —— 用返回值表达，不要抛异常（这是正常情况）。
            Log.w(TAG, "openFile: 没有可用应用 -> $path")
            result.success("no_app")
        } catch (e: IllegalArgumentException) {
            // FileProvider 的路径白名单（res/xml/file_paths.xml）里没有这个文件所在的目录。
            // 以前这里会落到下面的 Throwable，用户看到的是一句
            // "Failed to find configured root that contains /data/..."（读不懂）。
            // 白名单是**故意**收窄的（见那个文件），所以这条要如实说清楚：
            // 不是文件不存在，是这个位置没被允许对外开 URI。
            Log.w(TAG, "openFile: 路径不在 FileProvider 白名单里 -> $path（${e.message}）")
            result.error("NOT_SHAREABLE", "这个文件所在的位置不允许对外打开：$path", null)
        } catch (e: Throwable) {
            Log.w(TAG, "openFile failed: ${e.message}")
            result.error("OPEN_FAILED", "打开失败：${e.message}", null)
        }
    }

    // ---------------------------------------------------- 分享文件（ACTION_SEND）

    /**
     * 把 App 私有目录里的文件通过系统分享面板（ACTION_SEND）发给别的应用。
     *
     * 为什么不复用 [openFileByPath]：ACTION_VIEW 表达的是"用某个应用打开这个文件"，
     * 分享要的是 ACTION_SEND + EXTRA_STREAM —— 目标应用收到的是"接收到一份内容"。
     * 两者在系统里的解析结果完全不同：很多应用（聊天、笔记）只注册了 ACTION_SEND，
     * 根本不会出现在"打开方式"列表里，所以必须单独一个方法通道。
     *
     * 为什么用 createChooser 而不是直接 startActivity(ACTION_SEND)：裸的 ACTION_SEND
     * 弹出的是"打开方式"形态的对话框；createChooser 才是用户认知里的分享面板
     * （系统自己维护"最近用过的应用 / 始终 / 仅此一次"那一套）。
     *
     * 返回约定与 [openFileByPath] 完全一致（Dart 侧据此给用户**准确**的反馈）：
     *   * `"ok"`     —— 已经拉起分享面板（用户最终选了哪个应用不归我们管）；
     *   * `"no_app"` —— 系统里没有任何能接收分享的应用（**环境事实、不是错误**）。
     * 参数缺失 / 文件不存在则抛 error（`PlatformException`，message 已是中文）。
     *
     * ⚠️ 本段注释同样不能出现"星号紧跟斜杠"那两个字符（见 [mimeTypeFor] 的说明），
     * 所以描述 MIME 时一律用文字，不写通配符。
     */
    private fun shareFileByPath(path: String?, subject: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("BAD_ARGS", "缺少 path 参数", null)
            return
        }
        val f = File(path)
        if (!f.exists() || !f.isFile) {
            result.error("NOT_FOUND", "文件不存在：$path", null)
            return
        }
        try {
            // 私有目录到 content 的转换与 [openFileByPath] 同一套：
            // FileProvider 的 authority 就是包名加上 .fileprovider（Manifest 里已声明）。
            // Android 7+ 把 file 形式的 URI 交给别的应用会直接抛 FileUriExposedException。
            val uri: Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", f)
            val mime = mimeTypeFor(f.name)
            val send = Intent(Intent.ACTION_SEND).apply {
                type = mime
                putExtra(Intent.EXTRA_STREAM, uri)
                // subject 只在非空时放：空串会被部分接收方当成真实主题，显示成一行空白。
                if (!subject.isNullOrBlank()) putExtra(Intent.EXTRA_SUBJECT, subject)
                // 必须显式授予临时读权限，否则接收方读这个 content URI 会 Permission denied
                // （FileProvider 给的 URI 默认谁都不许读，连自己以外的系统应用也读不到）。
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val chooser = Intent.createChooser(send, "分享")
            // 选择器本身也带一次读权限标记：部分 ROM 只把 chooser 上的 flag 透传给最终目标。
            chooser.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            startActivity(chooser)
            Log.i(TAG, "shareFile -> $path ($mime)")
            result.success("ok")
        } catch (e: android.content.ActivityNotFoundException) {
            // 系统里连一个能接收 ACTION_SEND 的应用都没有 —— 用返回值表达，不抛异常。
            // 注意：这种情况下 createChooser 也会抛 ActivityNotFoundException（没有可选项
            // 时系统不会显示空的分享面板），所以这个 catch 同时覆盖了"没有目标应用"。
            Log.w(TAG, "shareFile: 没有可接收分享的应用 -> $path")
            result.success("no_app")
        } catch (e: IllegalArgumentException) {
            // 与 openFileByPath 同一原因：文件所在目录不在 FileProvider 白名单里
            // （见 res/xml/file_paths.xml）。如实说明，别让用户看一句英文的
            // "Failed to find configured root that contains ..."。
            Log.w(TAG, "shareFile: 路径不在 FileProvider 白名单里 -> $path（${e.message}）")
            result.error("NOT_SHAREABLE", "这个文件所在的位置不允许对外分享：$path", null)
        } catch (e: Throwable) {
            Log.w(TAG, "shareFile failed: ${e.message}")
            result.error("SHARE_FAILED", "分享失败：${e.message}", null)
        }
    }

    /**
     * 把 App 私有目录里的文本文件导出到**用户自己选的位置**（SAF 的"保存文件"）。
     *
     * 为什么是 ACTION_CREATE_DOCUMENT 而不是直接写 `/sdcard/Download`：
     * Android 10+ 的分区存储下，写公共目录要么申请一堆权限、要么被厂商 ROM 拦；
     * SAF 是系统给的正路 —— **不需要任何权限**，位置由用户在系统界面里决定
     * （通常是"下载"），而且用户随时能取消。这正是我们要的"用户知道自己在干什么"。
     *
     * 返回约定（Dart 侧据此给用户准确反馈，不假装成功）：
     *   * `"ok:<content-uri>"` —— 已写入用户选的位置；
     *   * `"cancel"`           —— 用户自己取消了（**不是错误**）；
     *   * `"no_app"`           —— 系统里没有"保存文件"界面（极罕见的环境事实）。
     * 参数缺失 / 源文件不存在且不在私有目录内 / 写失败 → error（中文 message）。
     *
     * 安全边界：只允许导出 [filesDir] 里的真实文件 —— 这个通道只服务于"导出日志"，
     * 不能变成一个"把设备上任意文件交出去"的读取器。
     */
    private fun exportTextFile(
        fileName: String?,
        sourcePath: String?,
        mime: String?,
        result: MethodChannel.Result,
    ) {
        if (fileName.isNullOrBlank()) {
            result.error("BAD_ARGS", "缺少 fileName 参数", null)
            return
        }
        if (sourcePath.isNullOrBlank()) {
            result.error("BAD_ARGS", "缺少 sourcePath 参数", null)
            return
        }
        val f = File(sourcePath)
        if (!f.exists() || !f.isFile) {
            result.error("NOT_FOUND", "文件不存在：$sourcePath", null)
            return
        }
        if (!f.canonicalPath.startsWith(filesDir.canonicalPath)) {
            result.error("BAD_PATH", "只允许导出 App 私有目录里的文件：$sourcePath", null)
            return
        }
        if (pendingExportResult != null) {
            result.error("BUSY", "上一个保存还没结束，请稍候", null)
            return
        }
        val type = if (mime.isNullOrBlank()) mimeTypeFor(f.name) else mime
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            this.type = type
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        pendingExportResult = result
        pendingExportSource = f.absolutePath
        try {
            startActivityForResult(intent, REQ_EXPORT)
        } catch (e: android.content.ActivityNotFoundException) {
            pendingExportResult = null
            pendingExportSource = null
            Log.w(TAG, "exportTextFile: 系统里没有「保存文件」界面")
            result.success("no_app")
        } catch (e: Throwable) {
            pendingExportResult = null
            pendingExportSource = null
            result.error("EXPORT_FAILED", "打开保存界面失败：${e.message}", null)
        }
    }

    /**
     * 设备与安装信息（运行日志的头部）。
     *
     * 为什么要走原生：Dart 的 `Platform.*` 在 Android 上只能给到 `android` / `Linux`
     * 这一层，拿不到 manufacturer / SDK / versionCode / ABI / 屏幕尺寸 —— 而那些
     * 恰恰是分析崩溃时第一眼要看的东西（尤其是"同一版在不同机型上表现不同"这类问题）。
     */
    // @Suppress 管的是 `cfg.locale` / `info.versionCode` 这两个在新系统上已废弃的
    // 取值方式 —— 它们仍要保留给 API < 24 / < 28 的真机，用新 API 会直接崩。
    @Suppress("DEPRECATION")
    private fun deviceInfo(): Map<String, Any> {
        val dm = resources.displayMetrics
        val cfg = resources.configuration
        val locale = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            cfg.locales[0]
        } else {
            cfg.locale
        }
        var versionName = ""
        var versionCode = 0L
        try {
            val info = packageManager.getPackageInfo(packageName, 0)
            versionName = info.versionName ?: ""
            versionCode =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode
                else info.versionCode.toLong()
        } catch (e: Throwable) {
            Log.w(TAG, "读 packageInfo 失败：${e.message}")
        }
        val isDebug = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        return mapOf(
            "packageName" to packageName,
            "versionName" to versionName,
            "versionCode" to versionCode,
            "isDebug" to isDebug,
            "manufacturer" to Build.MANUFACTURER,
            "brand" to Build.BRAND,
            "model" to Build.MODEL,
            "device" to Build.DEVICE,
            "androidRelease" to Build.VERSION.RELEASE,
            "sdkInt" to Build.VERSION.SDK_INT,
            "abis" to Build.SUPPORTED_ABIS.toList(),
            "locale" to locale.toString(),
            "screenWidthPx" to dm.widthPixels,
            "screenHeightPx" to dm.heightPixels,
            "densityDpi" to dm.densityDpi,
            "density" to dm.density.toDouble(),
            // 端侧模型清单要按「内存 + 芯片」挑文件：
            // 内存决定"装得下哪一档"，芯片决定"能不能拿 NPU 专属版"（Gemma 4 有
            // sm8750 / Google Tensor G6 的预编译版，命中就优先装它）。
            // 在此之前 deviceInfo 缺这两项，只能让用户手动填 —— 补上后自动匹配。
            "totalRamGb" to totalRamGb(),
            "soc" to socName(),
        )
    }

    /** 物理内存总量（GB）。**不是"可用内存"** —— 能不能装下模型看的是总量。 */
    private fun totalRamGb(): Int = try {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val mi = ActivityManager.MemoryInfo()
        am.getMemoryInfo(mi)
        (mi.totalMem / 1073741824.0).roundToInt()
    } catch (e: Throwable) {
        Log.w(TAG, "读内存总量失败：${e.message}")
        0
    }

    /**
     * 芯片型号（给清单做 NPU 专属版匹配）。
     *
     * API 31+ 才有 `SOC_MANUFACTURER` / `SOC_MODEL`（例如 "Qualcomm SM8750"、
     * "Google Tensor G6"）；更低版本拿不到，如实返回空串 —— 清单会自动退回通用版，
     * 不猜、不编一个假的型号出来。
     */
    private fun socName(): String = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            listOf(Build.SOC_MANUFACTURER, Build.SOC_MODEL)
                .filter { !it.isNullOrBlank() }
                .joinToString(" ")
        } else {
            ""
        }
    } catch (e: Throwable) {
        ""
    }

    /**
     * 按扩展名推断 MIME。
     *
     * 认不出来就给"通配 MIME"（星号 斜杠 星号）—— 让系统自己去挑应用，
     * 比瞎猜一个错的 MIME 好（猜错的话系统会报"没有应用可打开"，其实是 MIME 不对）。
     *
     * ⚠️ 注意：KDoc 里**不能**写出"星号紧跟斜杠"这两个字符，那会**提前结束注释**，
     * 后面的文字会变成野代码、编译直接报一堆 "Expecting member declaration"
     * （这个坑刚踩过；和 XML 注释里不能出现双连字符是同一类问题）。
     */
    private fun mimeTypeFor(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        return when (ext) {
            "txt", "log" -> "text/plain"
            "md", "markdown" -> "text/markdown"
            "json" -> "application/json"
            "csv" -> "text/csv"
            "html", "htm" -> "text/html"
            "xml" -> "text/xml"
            "pdf" -> "application/pdf"
            "doc" -> "application/msword"
            "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            "xls" -> "application/vnd.ms-excel"
            "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            "ppt" -> "application/vnd.ms-powerpoint"
            "pptx" -> "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            "png" -> "image/png"
            "jpg", "jpeg" -> "image/jpeg"
            "webp" -> "image/webp"
            "gif" -> "image/gif"
            "svg" -> "image/svg+xml"
            "mp4" -> "video/mp4"
            "mp3" -> "audio/mpeg"
            "zip" -> "application/zip"
            // 应用内更新下载好的安装包（files/updates/）。必须显式给，
            // 否则落到下面的 `*/*` → 系统认不出这是安装包、不弹安装器。
            "apk" -> "application/vnd.android.package-archive"
            else -> "*/*"
        }
    }

    /** 从 content:// 上取显示名（拿不到就由调用方给个兜底名）。 */
    private fun queryDisplayName(uri: Uri): String? = try {
        contentResolver.query(uri, null, null, null, null)?.use { c ->
            val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (idx >= 0 && c.moveToFirst()) c.getString(idx) else null
        }
    } catch (e: Throwable) {
        null
    }

    /** 目标文件重名时加 -1 / -2 后缀，绝不覆盖已有附件。 */
    private fun uniqueTarget(name: String): File {
        val safe = name.replace(Regex("[^A-Za-z0-9._\\-\\u4e00-\\u9fa5]"), "_").take(80)
        val fallback = safe.ifEmpty { "file-${System.currentTimeMillis()}" }
        var f = File(attachmentsDir(), fallback)
        if (!f.exists()) return f
        val dot = fallback.lastIndexOf('.')
        val base = if (dot > 0) fallback.substring(0, dot) else fallback
        val ext = if (dot > 0) fallback.substring(dot) else ""
        var i = 1
        while (f.exists() && i < 1000) {
            f = File(attachmentsDir(), "$base-$i$ext")
            i++
        }
        return f
    }

    // ---------------------------------------------------------------- paths

    private fun dshDir() = File(filesDir, "dsh")
    private fun shimDir() = File(filesDir, "shims")
    private fun nodeHome() = File(filesDir, "dshhome")

    private fun runtimePaths(): Map<String, Any> = mapOf(
        "nativeLibDir" to applicationInfo.nativeLibraryDir,
        "filesDir" to filesDir.absolutePath,
        "dshDir" to dshDir().absolutePath,
        "dshBin" to File(dshDir(), "lib/bin.js").absolutePath,
        "nodeHome" to nodeHome().absolutePath,
        "fsShim" to File(shimDir(), "android-fs-shim.cjs").absolutePath,
        "nodeBinary" to File(applicationInfo.nativeLibraryDir, "libnode.so").absolutePath,
        "runtimeVersion" to RUNTIME_VERSION
    )

    private fun marker() = File(filesDir, ".dsh-runtime-$RUNTIME_VERSION")

    private fun isRuntimeReady(): Boolean =
        marker().exists() && File(dshDir(), "lib/bin.js").exists()

    // ---------------------------------------------------------------- unpack

    private fun unpackRuntimeAsync(result: MethodChannel.Result) {
        if (isRuntimeReady()) {
            result.success(true)
            return
        }
        if (unpacking) {
            result.error("ALREADY_UNPACKING", "运行时正在解压", null)
            return
        }
        unpacking = true

        Thread {
            try {
                val count = unpack()
                applyShims()
                marker().writeText("v$RUNTIME_VERSION unpacked $count entries\n")
                mainHandler.post {
                    unpacking = false
                    result.success(true)
                }
            } catch (e: Throwable) {
                mainHandler.post {
                    unpacking = false
                    result.error("UNPACK_FAILED", e.message ?: e.toString(), null)
                }
            }
        }.start()
    }

    // 解压 zip：app 下的内容 -> files/dsh/，shims 下的内容 -> files/shims/。返回解出的文件数。
    // 注意：这里不用 KDoc（/** */），因为 Kotlin 支持嵌套块注释，
    // 描述路径时写出的 starslash 序列会意外开启嵌套注释。
    private fun unpack(): Int {
        // 先把 asset 落到文件，再用 ZipFile 解压。
        //
        // 为什么不用 ZipInputStream：实测从 AssetManager 直接流式解压时，
        // 它读几个条目就提前结束（zip 本身有 2.6 万个条目，只解出 3 个）。
        // ZipFile 读 central directory，不受流式读取错位影响。
        val tmpZip = File(filesDir, "runtime.zip")
        if (!tmpZip.exists() || tmpZip.length() == 0L) {
            // ⚠️ 0.75 起这个 zip **不再随包**（APK 因此小 30 MB）——改由 Dart 侧
            // （`local/runtime_bootstrap.dart`）先下载并校验，落到**这个路径**再调
            // `unpackRuntime`。所以这里没有 asset 兜底了，也就必须给一句能读懂的话；
            // 否则用户看到的是 `FileNotFoundException: dsh-runtime.zip`（等于没说）。
            throw IllegalStateException(
                "运行时包不在 ${tmpZip.absolutePath} —— 请先在应用内完成「下载运行环境」这一步，再开始解压。"
            )
        }
        Log.i(TAG, "zip size = ${tmpZip.length()} bytes")

        var files = 0
        var total = 0
        var lastReport = 0L

        ZipFile(tmpZip).use { zip ->
            val entries = zip.entries()
            while (entries.hasMoreElements()) {
                val entry = entries.nextElement()
                total++
                // .NET Framework 的 ZipFile.CreateFromDirectory 在 Windows 上会把条目名
                // 写成 app\xxx（反斜杠），不符合 zip 规范；这里统一成斜杠再判断前缀。
                val name = entry.name.replace('\\', '/')
                val target: File? = when {
                    name.startsWith("app/") -> File(filesDir, "dsh/" + name.removePrefix("app/"))
                    name.startsWith("shims/") -> File(filesDir, "shims/" + name.removePrefix("shims/"))
                    else -> null
                }

                if (target != null && !entry.isDirectory && target.name.isNotEmpty()) {
                    target.parentFile?.mkdirs()
                    zip.getInputStream(entry).use { input ->
                        target.outputStream().use { output -> input.copyTo(output, 256 * 1024) }
                    }
                    files++
                    val now = System.currentTimeMillis()
                    if (now - lastReport > 200) {
                        lastReport = now
                        report(files, target.name)
                    }
                }
            }
        }

        Log.i(TAG, "unpack finished: entries=$total files=$files")
        tmpZip.delete()
        return files
    }

    private fun report(done: Int, current: String) {
        mainHandler.post {
            channel?.invokeMethod("unpackProgress", mapOf("done" to done, "current" to current))
        }
    }

    /**
     * 把 shims 覆盖到 DSH 树里的目标位置。
     *
     * 这三个文件是 DSH 能在 Android 上启动的前提：
     *  - node-addon-require-builtin：该 addon 无 android 构建，用纯 JS require 替代
     *  - node-addon-system/flock：bionic 无 flock()，单进程场景退化为 no-op
     * fs-shim 不走覆盖，而是由 Dart 在启动 node 时用 --require 加载。
     */
    private fun applyShims() {
        val pairs = listOf(
            File(shimDir(), "android-shim-require-builtin.js") to
                File(dshDir(), "node_modules/node-addon-require-builtin/lib/index.js"),
            File(shimDir(), "android-shim-flock.js") to
                File(dshDir(), "node_modules/@deepseek-ai/node-addon-system/lib/flock.js")
        )

        for ((src, dst) in pairs) {
            if (!src.exists()) throw IllegalStateException("shim 缺失: ${src.absolutePath}")
            dst.parentFile?.mkdirs()
            src.copyTo(dst, overwrite = true)
        }
    }
}
