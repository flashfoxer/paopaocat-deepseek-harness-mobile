/// 「检查更新」用的更新源地址 —— 也就是那份 `update.json` **放在哪**。
///
/// ## 结论：清单放 Git 仓库、包放 Release，两处各管一段
///
///   * **清单**（`update.json`，1 KB 量级）→ 仓库根目录，与 `README.md` 并排，
///     `git push` 完就自动有两个公网入口（见下面 [defaultUpdateSources]）。
///   * **APK 本体**（110 MB 量级）→ **不放仓库**，打成 GitHub Release 附件；
///     清单里给它的直链。三条理由，都是实测出来的：
///       ① GitHub 单文件硬限 100 MB，111 MB 的包**会被直接拒绝推送**；
///       ② jsDelivr 对 GitHub 单文件另有 20 MB 上限；
///       ③ jsDelivr **不能代发 Release 附件**（实测 404）。
///     而 Release 附件的直链可用、且支持断点续传（实测 HTTP 206 · 2.27 s）。
///
/// ## 为什么主源是 raw、而不是"更快"的 jsDelivr（这条我一开始说反了）
///
/// 本机实测（2026-10-13，1 KB 量级的同一份文件）：
///
/// | 源 | 耗时 | 缓存 |
/// |---|---|---|
/// | `raw.githubusercontent.com` | **0.47 s** | 几分钟 |
/// | `cdn.jsdelivr.net/gh` | 2.16 s | **12 小时**（`s-maxage=43200`，`x-jsd-version-type: branch`）|
///
/// 更关键的是**新鲜度**：jsDelivr 对"分支"类型的缓存是 12 小时 —— 推了新清单后，
/// 走 CDN 的用户**最多半天**才看到新版本。而更新检查最怕的就是"发了新版没人看得见"。
/// （真要立刻生效可以调 `https://purge.jsdelivr.net/gh/<repo>@main/update.json`
/// 清缓存，实测可用 —— 但那是发版时多一步人工操作，不如直接把 raw 放前面。）
///
/// ⚠️ 我之前那次"raw 慢到 25 秒超时"的实测是**误判**：那测的是 26 KB 的 README
/// 撞上网络抖动，不是 raw 对小文件的通病。这里留下更正记录，免得以后再翻案。
///
/// ## 兜底
///
/// 三条都不通时不弹窗、不卡启动 —— 只在设置页如实写"这次没查到"，见
/// `update_checker.dart` 的静默约定。用户还可以在设置里**自填镜像地址**
/// （国内网络的自救手段）。
library;

/// 仓库坐标。**换仓库时只改这一处**（更新源、下载页、Release 接口都跟着走）。
const String kUpdateRepo = 'zmm863-commits/paopaocat-deepseek-harness-mobile';

/// 更新清单的文件名。放**仓库根目录**（与 `README.md` 并排）。
const String kUpdateManifestName = 'update.json';

/// 按优先级排的更新源。清单是**同一个文件**，区别只在入口。
///
/// 顺序有讲究（都是上面那两条实测结论推出来的）：
///   1. raw —— 快且新鲜，当主源；
///   2. jsDelivr —— 国内直连 raw 常被污染/超时时的加速兜底，代价是最多 12 小时延迟。
List<String> defaultUpdateSources() => <String>[
      'https://raw.githubusercontent.com/$kUpdateRepo/main/$kUpdateManifestName',
      'https://cdn.jsdelivr.net/gh/$kUpdateRepo@main/$kUpdateManifestName',
    ];

/// GitHub 官方的"最新 Release"接口（可选兜底，**当前没接进主流程**）。
///
/// 留着它是因为它能一次给出 tag 名、资产直链和 `digest`（sha256）—— 即"连
/// update.json 都不用维护"的那条路。没接的理由：匿名调用有 **60 次/小时/IP**
/// 的限流，一旦被限流，用户看到的是"检查失败"，而静态清单文件没有这个问题。
const String kLatestReleaseApi = 'https://api.github.com/repos/$kUpdateRepo/releases/latest';

/// 给人点的下载页（Release 列表，`latest` 自动指向最新正式版）。
///
/// ⚠️ 一律写 `releases/latest` 而**不是** `releases/tag/vX.Y`：latest 会跟着
/// 新版本走，不必每次发版改代码；写死 tag 的话，旧版本里的用户点到的永远是旧包。
const String kReleasesPage = 'https://github.com/$kUpdateRepo/releases/latest';

/// 用户自填的更新源是否看起来能用（只做基本校验，不联网）。
///
/// 只收 `http(s)://`：本机测试要能填 `http://127.0.0.1:xxxx/update.json`，
/// 而 `file://` 之类不该出现在这里。
bool looksLikeUpdateSource(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return false;
  final lower = s.toLowerCase();
  if (!lower.startsWith('http://') && !lower.startsWith('https://')) return false;
  // 至少要有个主机名，否则是 `https://` 这种半截地址。
  return s.length > 'https://'.length + 1;
}
