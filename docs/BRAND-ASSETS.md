# 品牌与图标素材（泡泡猫的 DSH）

> 记录 App 品牌名、图标来源与生成链路。**换图标只改一个地方**，见文末。

## 1. 名称

| 位置 | 文案 |
|---|---|
| 应用全名（`AndroidManifest.xml` 的 `android:label`） | `泡泡猫的Deepseek harness` |
| 首页顶栏标题 | `泡泡猫的DSH` |
| 首页标语 | `欢迎来到泡泡猫的DSH` |
| 首页福利行 | `请帮忙推广一下我的公众号，粉丝太少没有更新动力了` |
| 首页中部提示 | `我帮你用泡泡猫的DSH，把想法做成成品` |

> 顶栏用短名是硬约束：全名 13 个字形，17px 顶栏放不下。
> `applicationId` 保持 `com.dshmobile.dsh_mobile`，否则用户手机无法覆盖安装。

## 2. 图标本体（**2026-10-03 已更换**）

用户发来一张图并说「**把白猫都替换为这个图标**」，所以现行图标是：

```
dsh-mobile\design\launcher-icon-source.png      （83x86，PNG，不透明整图）
```

实测特征：

- 83×86（生成时居中裁成 83×83 正方形）
- **无透明通道**（alpha 全 255）→ 所以是"整图就是图标"，不是"抠出主体贴到底上"
- 主色：深蓝 `#16203F`（最多）、金 `#E8C97A`、白 `#FFFFFF`、亮蓝 `#005FB8`；
  四角还各有一点蓝/金黄/绿 → 是一张有内容的彩色设计图，不是纯色底板
- 因主色是深蓝，自适应图标的背景（`drawable/ic_launcher_background.xml`）
  已改成同色系深蓝渐变 `#1B2750 → #16203F`

### ⚠️ 分辨率实话（换图前必读）

源图只有 **83×83**，而 xxxhdpi 传统图标要 192×192、自适应前景要 **432×432** →
**放大 4~5 倍，一定会糊**。目前用 LANCZOS + 小尺寸轻度锐化尽量补救。
**有原始高分辨率图（≥512）就换掉 `design/launcher-icon-source.png` 再跑一次脚本**，
不用改任何代码。

### 历史（已废弃，仅留档）

- **白色卧猫**：`<dsh-client-ui-paopaocat>/assets/mascot-cat.webp`
  （512×512 RGBA、alpha 包围盒 `(61,91,459,427)` → 398×336 卧姿、中心近白），
  即该插件 `src/client/ppc-mascot.ts` 的 `PPC_MASCOT_IMAGE`。
  用户先指定用它当图标，**后来要求全部换成现在这张**。
  本源副本仍在 `design/mascot-cat-source.webp`，但**已不参与生成**。
- **手绘矢量猫**（Dart `CustomPaint` + Android `vector drawable`）：用户说「不好看」，
  已废弃；脚本存档 `install/_legacy/make-icon-vector.py`。

## 3. 图标生成链路

`install/make-icon.py`（唯一入口）读取 `design/launcher-icon-source.png`，产出：

| 产出 | 用途 |
|---|---|
| `res/drawable-{m,h,xh,xxh,xxxh}dpi/ic_launcher_foreground.png` | 自适应图标前景（108dp 画布，图案居中占 **66%**，其余透明） |
| `res/mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher.png` | 传统方形图标（48/72/96/144/192），**满幅 cover + 居中裁切** |
| `res/mipmap-*/ic_launcher_round.png` | 圆形图标（同图 + 圆形遮罩） |
| `res/drawable/ic_launcher_background.xml`、`res/values/colors.xml` | 自适应图标背景（深蓝渐变 / 纯色回退）—— **脚本每次重写，别手改** |
| `app/assets/images/paopaocat_logo.png` | **App 内品牌 logo**（256×256，整图 + 圆角 18%） |
| `install/icon-preview.png`、`icon-preview-48px-zoom.png` | 预览图，供人工过目 |

细节：
- 生成脚本会**主动删除**两个过时文件：`drawable/ic_launcher_foreground.xml`（旧手绘矢量）
  与 `assets/images/paopaocat_mascot.png`（旧白猫资源），避免"旧图还在包里"这种最难查的问题。
- 小尺寸（< 97px）做一次轻度 `UnsharpMask`，缓解放大糊。
- XML 注释里**不能出现双连字符**（`--`），否则编译报错。

重新生成：

```powershell
C:\Python314\python.exe install\make-icon.py
```

## 4. App 内使用

`app/lib/ui/widgets/brand_logo.dart` 的 `BrandLogo` 读 `assets/images/paopaocat_logo.png`
（登记在 `pubspec.yaml` 的 `assets/images/`，与 `assets/experts/agency_catalog.json` 并列）。

```dart
const BrandLogo(size: 70)   // 正方形源图，BoxFit.contain
```

> 历史：这个组件原叫 `CatHeadLogo`、文件 `cat_head.dart`、资源 `paopaocat_mascot.png`。
> 用户要求把白猫全部换掉后，**文件与类名一并改了** —— 免得后人以为
> `cat_head.dart` 里还是只猫。

> ⚠️ **不要手绘第二个 logo**：启动器图标与 App 内 logo 必须同源。
> 换形象就换 `design/launcher-icon-source.png`，然后重跑 `install/make-icon.py`。
