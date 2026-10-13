# 0.63（2026-10-12）

依据：用户 2026-10-12 四条，附真机 `dsh-report-20261012-000919.txt`
（v0.62 · nubia NX809J · SM8850 · 15 GB · Android 16 / SDK 36 · 1216×2688 · zh_CN）。

原话：

> 几个问题，本地大模型依然无法使用，而且开启以后，退出去选其他服务有的时候会跳转到本地会话这个页面。
> 2：图像/视频模型貌似没有写key的位置。
> 3：影视的去水印功能，只能选择固定位置，我记得以前说过把这个去水印改成擦除，用户可以选择照片任意位置进行擦除。
> 4：有些弹出的面板透明度太高，能背景的字体，降低透明度

---

## 1 本地大模型「依然无法使用」

**上一版（0.62）只改了提示文字，没修根因 —— 用户说"依然无法使用"，是对的。**

### 真根因

`lib/local/local_model_server.dart`：

```dart
// 改之前
static const String executableName = 'libllamaserver.so';
String get executablePath => '$_nativeLibDir/$executableName';   // ← 不看引擎
```

守卫写的是"这个文件在不在"，但文件名是**常量**。于是**每一个**模型（含 `litert-lm`
的 Gemma 4）都在查 `libllamaserver.so` —— 而 llama.cpp 自 0.47 起就**有意不随包**。
结果：所有模型都在这一步被判"引擎不存在"，`litert-lm` 那条分支**永远走不到**。

日志自证（报告里连着 7 次，00:04:55 → 00:05:19）：

```
引擎不存在：/data/app/…/lib/arm64/libllamaserver.so（模型要的是 litert-lm）
```

括号里那句是**选文件那段代码自己打印的** —— 它一边说"模型要的是 litert-lm"，
一边去查 llama.cpp 的 `.so`。

APK 内已确认：`lib/arm64-v8a/liblitertlm_jni.so` **在**，`libllamaserver.so` **不在**。

### 修复

* 新增 `engineLibName(engine)`：`llama.cpp → libllamaserver.so`、
  `litert-lm → liblitertlm_jni.so`、其余 `null`；
* 新增 `hasEngine(engine)`，守卫改成**按模型要的引擎**去查对应的那个 `.so`；
* 引擎不认识 / 包内没有 → 返回 `null`，并如实说明「这个模型要的是 X 引擎，而本版包里没有它」；
* `listDevices()` 在引擎缺失时**直接短路**（不再空转探测 Vulkan）；
* 上下文那句提示从「已按它启动」改成「上下文已收敛到 {0} 格」—— 它在引擎检查
  **之前**打印，原话会让人以为已经起来了。

### 测试

`test/local_model_start_reason_test.dart` 新增一组 5 例（「拿 A 的文件判 B 的模型 = 谁都起不来」）：
litert 映射到 `liblitertlm_jni.so` 且**不是** `executableName`、llama 映射到
`executableName`、未知/空 → `null`、两个名字确实不同、`_nativeLibDir` 为空时 `hasEngine` 为假。

---

## 2 「退出去选其他服务，有时会跳转到本地会话」

两个 bug 叠在一起。

### (a) 标记只置位、从不清除

`media_page.dart` 有 **3 处** `setPickInFlight(true)`，而
`setPickInFlight(false)` 在整个文件里**一处都没有**（只有 `local_chat_page` 写了 `finally`）。
于是"在影视页选过一张参考图"这件事会在盘上留 **3 分钟**，期间任何一次重建都会推页。

### (b) 推哪一页是写死的 + 挂错了地方

`app_shell.dart` 的恢复逻辑在 `_onSchedulesChanged()` 里 —— 那是个**调度器监听器**
（定时任务一变就响）。真机日志里同一句话在 76 秒内出现了 **6 次**：

```
00:05:51.462 恢复上次停留的 Tab：4
00:05:51.462 检测到"刚才在取图" → 恢复「本地对话」页
00:06:58.197 恢复上次停留的 Tab：4
00:06:58.197 检测到"刚才在取图" → 恢复「本地对话」页
…
```

而且它**一律**推「本地对话」—— 在**影视页**选图，回来也被推去本地对话。

### 修复

* 三处取图点全部补 `finally { setPickInFlight(false); }`，并记下**出发页**；
* `AppSettings` 新增 `pickInFlightFromWithin()`，返回 `'media'` / `'localchat'` / `''`
  （清除时把出发页一起清掉，避免上一次的名字粘住）；
* `app_shell.dart` 把恢复抽成 `_restoreNavOnce()`：**每个进程只做一次**
  （`initState` 里 `addPostFrameCallback`），`_onSchedulesChanged` 只留 `_syncSchedulerService()`；
* **只有** `localchat` 出发才推「本地对话」；`media` 出发就按 `lastTab` 回影视页（不换页）。

### 测试

`test/pick_in_flight_test.dart`（新增 6 例），其中两条是**源码纪律**——
这类"忘记配对"的 bug 光靠运行时测试抓不住：

1. `setPickInFlight(true)` 与 `setPickInFlight(false)` 必须**成对出现在同一文件**；
2. `_onSchedulesChanged` 的函数体里**不许**再出现 `_openLocalChat` 或 `lastTabRestorable`。

---

## 3 图像 / 视频模型「没有写 key 的位置」

属实 —— 那一页只有一句「记得先在『云端大模型』里把『{0}』这家配好（厂家 id 用 {1}）——
Key 是从那边读的」，把入口藏到别的页去了。

* 模型编辑弹层里**就地**加 `API Key` 输入框，写进**同一个**凭据库
  （`ProviderKeys`，与「云端大模型」共用，**不新增第二份存储**）；
* 留空 = 不改动；**从不回显**已存的 Key；
* 该页新增「**各厂家的 Key（点一下就能填）**」一段：列出实际用到的厂家 id、
  显示「已配 Key / 还没配 Key —— 没凭据这条模型必然失败」、一键填或换一把
  （只读**有无**，不把 Key 读进内存显示）；
* 说明文案改成"与『云端大模型』是**同一个地方**，哪边填都认"。

---

## 4 擦除改成「在照片上自己框」

0.61 只做到「起点（右下/左上…）+ 拖动偏移」，尺寸还得靠两根滑杆，
而且"能拖"这件事**没有任何视觉提示** —— 用户看到的就是"只能选固定位置"。

* `edit_box.dart` 新增纯函数 **`boxFromRect()`**：按百分比给任意矩形。
  收边界口径与 `computeDelogoBox` 的**共同不变量**一致（不越界、有最小尺寸）——
  但**刻意不相等**：起点那套会留 2% 边距（水印通常不贴边），自由框允许贴边；
* 预览图上三种手势（`_editDrag` 区分）：
  * 按**空白处**拖动 → **拉出一个新框**（放哪、多大都随你）；
  * 按**框内**拖动 → **整块移动**；
  * 拖**四角的圆点** → **缩放**（最小 12×12 像素，有视觉把手）；
* 位置 chip 降级为「快捷起点（也可以直接在图上框）」，点了会放弃自由框；
* 宽/高滑杆改成「微调」，范围放宽到 2%~100%，改的是当前这块的大小、左上角不动；
* **脚本侧一行未改** —— `edit-image.mjs --delogo x:y:w:h` 本来就只认像素框，
  两套模型产出的是同一种东西。

### 测试

`test/edit_box_test.dart` 新增一组 5 例：框在哪儿就是哪儿、拖到右下角外会收进画面、
负数/超大百分比不越界、画面太小（短边 < 8）→ `null`、两套模型的共同不变量。

---

## 5 弹出面板「透明度太高」

范围比想象的大。根因不止一个：

| 位置 | 深色下的实际不透明度 |
|---|---|
| `bottomSheetTheme.backgroundColor` = `Colors.transparent` | **0%**（没传底色的弹层完全没底） |
| `navBg` = `0x1AFFFFFF` | **10%** |
| `surface` = `0x12FFFFFF` | **7%** |
| `DshColors.panel()` 默认 `surfaceHigh` = `0x1FFFFFFF` | **12%** |

### 修复

* 主题 `bottomSheetTheme` 改用**完全不透明**的 `surfaceStrong`
  （浅色 `#FFFFFF` / 深色 `#262E33`）—— 覆盖所有没传底色的弹层；
* 显式传了半透明底色的逐个改 `surfaceStrong`：`model_sheet`、
  `local_chat_page`（取模型弹层 + 输入栏 + 待发小圆点）、`send_log_button`、
  `scheduled_page` 编辑器、`enabled_experts_sheet`、`expert_page`×2、
  `app_shell` 新建工作区对话框、`chat_page` / `kb_page` / `task_home_view` 的对话框、
  `message_stream` 的标题带；
* **不动** `panel()` 的默认色与底部导航栏 —— 页面内卡片保留"半透明玻璃"的
  设计语言（那是这套皮肤的观感来源），只改"弹出来盖住内容"的那些。

---

## 6 版本与验证

* `kAppVersion = '0.63'`，`pubspec.yaml` `version: 0.0.63+63`；
* i18n：1268 / 1268，0 漂移（`rewrite-tables.mjs` 写盘 + `check-tables.mjs` 复核）；
  本次 +16 条新键、-18 条陈旧键；
* `flutter analyze` 干净；全量测试（除截图类）通过 —— 见 §7；
* 新增测试文件 1 个（`pick_in_flight_test.dart`）+ 3 个既有文件扩测
  （`local_model_start_reason_test.dart` +5、`edit_box_test.dart` +5、`i18n_test.dart` 计数 1258→1268）。

## 7 出包与验签

用户 2026-10-12 回复「打包」后生成。

### 产物

| 项 | 值 |
|---|---|
| 文件 | `dist/paopaocat-preview-0.63-arm64-v8a.apk` |
| 大小 | 100,744,600 B（96.1 MB） |
| sha256 | `d510526945db9dde69eee264b3527d0934b61238c6040f1f29283c4871e61d8f` |
| versionCode / versionName | 63 / 0.0.63 |
| minSdk / targetSdk | 24 / 36 |
| ABI | arm64-v8a |

构建：`sync-dsh-app.sh` → `android/gradle.properties` 追加 `dshAbi=arm64-v8a` →
`flutter build apk --release --target-platform android-arm64`（Gradle `assembleRelease` 62.5s）。
release 仍用 **debug 签名**（预览包惯例）。

### 验签（本机 `apksigner` 不可用）

用 `keytool -exportcert` 导出 debug 证书 DER，再做二进制比对：

| 检查 | 结果 |
|---|---|
| v2 签名块（`APK Sig Block 42`） | ✅ 在 |
| v2 块固定标识 `1a870971` | ✅ 在 |
| debug 证书 DER | ✅ 在包里 |
| v1（`META-INF/*.RSA`） | 无（只走 v2，符合预期） |

### 出包后核对（`install/check-release.py`）

```
[PASS] 版本同一            versionName = 0.0.63（与 pubspec 一致）
[PASS] 落盘表自检          11 个脚本的字符串都在包内 libapp.so 里
[PASS] 资产同一            28 个资产逐名一致，size + sha256 全部相同
[PASS] 运行时包            assets/dsh-runtime.zip  32.1 MB
[PASS] 引擎检查（下线）     没有任何 llama.cpp 相关库
[PASS] 引擎检查（dlopen）   14 个（LiteRT 加速器/Qualcomm 插件/JNI 桥 + ffmpeg/ffprobe）都在
[PASS] ffmpeg 架构         libffmpeg.so / libffprobe.so 都是 AArch64 ELF
结论：全部通过 —— 这个包里的字节和当前源码树一致，可以发
```

### 顺带被这个包坐实的一件事

`unzip -l` 显示包内**只有** `lib/arm64-v8a/liblitertlm_jni.so`，
**没有** `libllamaserver.so` —— 这正是 §1 里那个 bug 的现场：
改之前的守卫拿 `libllamaserver.so` 这个名字去查**每一个**模型，
而它从来就不在包里，所以谁都起不来。

### 未做

* **未推仓库**（要另行单独确认）；
* 真机复验由用户装机完成（截图仍停留在 0.19）。
