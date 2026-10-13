import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/configured_models.dart';
import '../local/local_model_server.dart';
import '../data/model_catalog.dart';
import 'provider_keys.dart';

import '../i18n/dsh_i18n.dart';

/// 当前可用的模型清单 + 选中项。
///
/// ## 口径（用户实测反馈驱动的两次改动，别退回去）
///
/// 1. 清单**不再**来自 `data/model_catalog.dart` 里写死的设计稿模型
///    （`Hy4 preview` / `Hy3` / `GLM-5.3` …）。那些名字在用户自己的端点上
///    根本不存在 —— 用户反馈「会话界面模型选择读取的不是设置里已经有的模型，
///    而是我截图上的模型」，根因就在这里。清单现在是
///    `<filesDir>/models.json`（见 [ConfiguredModels]）。
/// 2. 清单里**既有普通模型，也有"轮换组"**（用户第 6 条反馈）。
///    组的标识是 `rotate/<组名>`，在界面/overlay 里和普通模型是同一种东西，
///    所以这里统一用 [ModelChoice] 表述、`routeId` 存**全限定 route**
///    （`<provider>/<model>`），切模型时由 `ui/app_shell.dart`
///    把它拆成 overlay 需要的 provider + model。
///
/// 选中项仍存 `flutter_secure_storage`（与设置页的凭据同一命名空间，
/// 避免"设置页写 A、对话页读 B"）。
class ModelStore extends ChangeNotifier {
  ModelStore({FlutterSecureStorage storage = const FlutterSecureStorage()})
      : _storage = storage;

  static const _kSelected = 'dsh_model_selected_id';

  final FlutterSecureStorage _storage;

  ConfiguredConfig _config = ConfiguredConfig.empty;
  List<ModelEntry> _catalog = const <ModelEntry>[];
  ModelEntry? _selected;
  bool _loaded = false;

  /// 最近一次 [load] 用的私有目录 —— [selectModel] 要把"选中的模型"同步回
  /// `models.json` 时要用（见那里的注释）。
  String _filesDir = '';

  /// 最近一次 [selectModel] 的落盘任务（安全区 + `models.json.selected`）。
  ///
  /// ⚠️ 为什么界面必须能 await 它（用户实测第 2 条「选一次不行，要选第二次」）：
  /// 面板点一下是 `selectModel()`（async）**然后立刻** `Navigator.pop()`，
  /// 调用方（会话页）拿到返回值后会马上 `onModelChanged()` → 重读 `models.json`
  /// → 重写 overlay。如果落盘还没写完，读到的就是**旧 selected**，
  /// overlay 里的默认路由也就还是旧的 —— 于是"看起来切了、实际没切"。
  /// 有了这个 future，调用方可以先等落盘、再重写 overlay。
  Future<void> _selectionPersist = Future<void>.value();

  /// 上一次选择是否已经落盘（给调用方 await 用，永不抛）。 */
  Future<void> get selectionSettled => _selectionPersist;

  /// 上一次选择**落盘失败了没有**（null = 成功）。
  ///
  /// 为什么要有它（审计「被 `catch (_) {}` 吞掉的那次落盘」）：
  /// 落盘失败原来只在 `debugPrint` 里留一行，**调用方看不见** ——
  /// 于是会话页照常 `onModelChanged()`，而它要去**读盘**重写 overlay，
  /// 读到的还是旧的 selected。结果就是用户报的那条
  /// 「选一次不行、要选第二次才可以切换模型」**原样复现，且没有任何痕迹**。
  ///
  /// 所以：失败要能被调用方看见，让它**不要**拿旧数据去重写 overlay，
  /// 并且如实告诉用户"这次只在本次会话生效"。
  String? selectionPersistError;

  List<ModelEntry> get catalog => _catalog;
  ModelEntry? get selected => _selected;
  bool get loaded => _loaded;

  /// 完整配置（多厂家 + 轮换组）。设置页与 overlay 写入都以它为准。
  ConfiguredConfig get config => _config;

  /// 界面上可选的项（普通模型 + 轮换组），给模型面板用。
  List<ModelChoice> get choices => _config.choices;

  /// 有没有真实的模型/组可用。false 时界面**不该**假装能给用户切模型。
  bool get hasModels => _catalog.isNotEmpty;

  /// 清单为空，但**并不是因为没配 Key**：厂家有（甚至 Key 也有），只是这个厂家
  /// 名下一条模型都没拉到/没勾选。
  ///
  /// 为什么要单独判它：用户实测遇到过 `models.json` "有厂家、没有模型条目"，
  /// 而会话页那句提示是写死的「填上地址和 API Key，点测试并保存」——
  /// Key 明明已经填好了，用户照那句话做多少遍都没用，因为缺的是**模型清单**。
  /// 界面必须把这两种状态分开说，否则就是"给了一个永远无效的下一步"。
  bool get providersWithoutModels =>
      _config.providers.isNotEmpty &&
      _config.models.isEmpty &&
      _config.groups.isEmpty;

  /// 有没有任何一个厂家配了 Key（只用于给提示语选一句准确的），
  /// 不暴露是哪个厂家、更不暴露 Key 本身。
  bool get hasAnyProviderKey => _keyReady.values.any((v) => v);

  /// 选中项的**全限定 route**（`deepseek/xxx` 或 `rotate/cat`）。
  String? get selectedRoute => _selected?.routeId;

  /// 选中项所属厂家（轮换组返回 `rotate`）。
  String? get provider => _selected == null
      ? (_config.providers.isEmpty ? null : _config.providers.first.id)
      : _selected!.routeId.split('/').first;

  /// 选中项所在厂家的端点（界面/自检用）。
  String? get baseUrl {
    final pid = provider;
    if (pid == null) return null;
    return _config.providerOf(pid)?.baseUrl;
  }

  /// 顶栏 / 输入区旁边显示的名字
  String get selectedName {
    if (_selected != null) return _selected!.name;
    return hasModels ? tr('选择模型') : tr('未配置模型');
  }

  /// 每个厂家"有没有配 Key"（只记布尔，不存 Key 本身）。
  ///
  /// 用途：**没有任何显式选中项时，别把"没配 Key 的厂家"选成默认**。
  /// 用户真机截图踩过这个坑：加了 Agnes 预设但还没填 Key，结果它成了默认模型，
  /// 一发消息整轮失败（`no credential for provider route "agnes"`）。
  final Map<String, bool> _keyReady = <String, bool>{};

  /// 某个厂家是否已配 Key。
  bool providerHasKey(String providerId) => _keyReady[providerId] ?? false;

  /// 当前选中项能不能真的用（厂家有 Key；轮换组看它的成员里有没有一家有 Key）。
  bool get selectedIsUsable {
    final entry = _selected;
    if (entry == null) return false;
    final route = entry.routeId;
    final group = _config.groupOfRoute(route);
    if (group != null) {
      for (final m in group.members) {
        if (providerHasKey(m.split('/').first)) return true;
      }
      return false;
    }
    return providerHasKey(route.split('/').first);
  }

  /// 清单里第一个"能用"的项（厂家有 Key / 组的成员有 Key），都没有就返回 null。
  ModelEntry? _firstUsable() {
    for (final e in _catalog) {
      final group = _config.groupOfRoute(e.routeId);
      if (group != null) {
        for (final m in group.members) {
          if (providerHasKey(m.split('/').first)) return e;
        }
        continue;
      }
      if (providerHasKey(e.routeId.split('/').first)) return e;
    }
    return null;
  }

  /// 从 `<filesDir>/models.json` 载入真实清单，并通知界面。
  Future<void> load({required String filesDir}) async {
    await _loadInto(filesDir);
    notifyListeners();
  }

  /// **只读盘、不发通知**。
  ///
  /// 给"先把新清单写进 overlay，再让界面看到它"的调用方用（`main._onModelChanged`）。
  /// 不这么做就有个竞态：`load()` 内部的 `notifyListeners()` 会**先于** overlay 的
  /// 重写到达会话页，会话页于是按**还没重写的** overlay 决定重建会话 ——
  /// 新进程读到的仍是旧默认路由，表现就是用户报的「选一次不行，要选第二次」。
  Future<void> reloadQuiet({required String filesDir}) => _loadInto(filesDir);

  /// 与 [reloadQuiet] 配对：overlay 落盘之后再发一次通知。
  void publish() => notifyListeners();

  /// [load] 的函数体（不含最后的通知）。
  Future<void> _loadInto(String filesDir) async {
    _filesDir = filesDir;
    final cfg = ConfiguredModels.readConfig(filesDir);
    _config = cfg;

    // 先记下"哪些厂家配了 Key" —— 下面决定默认选谁要用它。
    _keyReady.clear();
    for (final p in cfg.providers) {
      // 「凭据由 App 自己提供」的厂家（免费模型 / 本机模型）：Key **不进安全区**，
      // 由 `ProviderKeys.envFor` 注入占位值 → 这里必须直接当成**可用**。
      //
      // 不这样判的后果（2026-10-11 用户纠正）：模型选择器把「免费模型」那一组
      // 标成「未配 Key」，展开还让用户"去设置里填 Key" —— 而这条通道的前提就是
      // **不用写 Key**。详见 ConfiguredModels.appProvidedCredentialIds 的注释。
      if (ConfiguredModels.appProvidedCredentialIds.contains(p.id)) {
        _keyReady[p.id] = true;
        continue;
      }
      try {
        final k = await ProviderKeys.read(p.id);
        _keyReady[p.id] = k != null && k.trim().isNotEmpty;
      } catch (_) {
        _keyReady[p.id] = false;
      }
    }

    _catalog = <ModelEntry>[
      for (final c in cfg.choices)
        ModelEntry(
          id: c.route,
          name: c.name,
          // routeId 就是全限定 route —— overlay 里会把前半段当 provider、
          // 后半段当 model（见 DshRuntime.writeOverlayFromConfig）。
          routeId: c.route,
          description: c.description,
        ),
    ];

    String? selectedId;
    try {
      selectedId = await _storage.read(key: _kSelected);
    } catch (_) {}

    // 选中项恢复顺序（**2026-10-04 改：`models.json` 优先**）
    //
    // 原来是「安全区里上次点过的 → 配置里写着的」，也就是安全区那份**无条件覆盖**
    // `models.json.selected`。后果正是用户报的那条：
    //   「设置里模型设置好了，会话里调用的不是设置里的模型」——
    // 在会话里点过一次别的模型（只写了安全区）之后，设置页按 `models.json.selected`
    // 标记/展示的那个"默认"就再也回不来了，而会话一直在用安全区那个。
    //
    // 现在反过来：**以设置页真正落盘的那份为准**（它就是用户在设置里看到的东西，
    // 会话必须跟着它走），安全区那份退化成兜底（老值/字段缺失时用）。
    // 另外 [selectModel] 现在会把选择同步写回 `models.json`，
    // 所以"会话里换的模型"和"设置页显示的默认"是同一个值，不会再分叉。
    ModelEntry? restored = _find(cfg.selected) ?? _find(selectedId);
    // 本地模型（`local/<id>`）不在清单里，必须**从正在跑的本地服务重建**这条选中项。
    //
    // 不重建会怎样：_find 找不到 → 下面按前缀找也找不到 → 一路回落到
    // `_firstUsable()`/清单第一条（云端模型）→ 用户点的本地模型被"弹回去"，
    // 表现正是「能看到、选不了」。这是同一个 bug 的另一半。
    if (restored == null) {
      final want = (cfg.selected ?? selectedId ?? '');
      final local = LocalModelServer.instance.spec;
      if (local != null &&
          want.startsWith('${LocalModelSpec.providerId}/') &&
          want == local.route) {
        restored = ModelEntry(
          id: local.modelId,
          name: local.displayName,
          routeId: local.route,
          description: tr('本机运行，不联网也能用'),
        );
        debugPrint('[dsh-model] 选中项是本机模型，已从运行中的服务重建：${local.route}');
      }
    }
    if (restored == null) {
      // 配置文件变了（厂家/模型被删）：配置里记的选中项找不到了，
      // 就退回"上次选中项"所属的厂家/组，尽量贴近用户预期。
      final hint = ((cfg.selected ?? selectedId) ?? '').split('/').first;
      for (final m in _catalog) {
        if (m.routeId.startsWith('$hint/')) {
          restored = m;
          break;
        }
      }
    }
    _selected = restored ??
        // 没有显式选中项 → **优先挑"能用"的那一个**（厂家配了 Key），
        // 免得把刚加进来、还没配 Key 的厂家（如 Agnes 预设）当默认，一发消息就失败。
        _firstUsable() ??
        (_catalog.isEmpty ? null : _catalog.first);

    // ⚠️ **自愈（这一步很关键，别再删）**
    //
    // 用户实测反馈：「会话里模型，虽然已经模型设置好了，也可以用，但是还是显示
    // 未配置模型，点击下拉菜单里边显示'还没有可用的模型'」。
    //
    // 原因是清单只认 `models.json`，而"配过但没走过新版设置页保存"的用户
    // （包括升级上来的老用户）根本没有这个文件。兜底在 [_readFallbackRoute]：
    // 安全存储的模型 id + 设置页写过的 provider，或者 overlay 里
    // `agent-default-model` 那一段（那是 DSH 真正在跑的路由）。
    if (_catalog.isEmpty) {
      final route = await _readFallbackRoute(filesDir);
      if (route != null && route.isNotEmpty) {
        _catalog = <ModelEntry>[
          ModelEntry(
              id: route, name: route, routeId: route, description: route),
        ];
        _selected = _catalog.first;
        debugPrint('[dsh-model] models.json 为空，用兜底模型：$route');
      } else {
        debugPrint('[dsh-model] models.json 为空，且安全存储/overlay 里都找不到模型');
      }
    }

    _loaded = true;
    debugPrint(
      '[dsh-model] 清单载入：${_catalog.length} 项'
      '（${_config.providers.length} 个厂家 / ${_config.groups.length} 个轮换组），'
      '选中=${_selected?.routeId ?? '无'}',
    );
  }

  ModelEntry? _find(String? id) {
    if (id == null || id.trim().isEmpty) return null;
    final want = id.trim();
    for (final m in _catalog) {
      if (m.routeId == want) return m;
    }
    // 兼容老值：以前存的是**不带厂家前缀**的 model id。
    for (final m in _catalog) {
      if (m.routeId.endsWith('/$want')) return m;
    }
    return null;
  }

  /// 清单为空时，从"更底层"的真源里捞出当前路由。
  ///
  /// 优先级：
  ///   1. 安全存储的 `dsh_model_id`（设置页写过）+ `dsh_model_provider`；
  ///   2. overlay 里 `agent-default-model` 段的 provider + model
  ///      —— 这是 DSH **真正在跑**的那个。只要对话能通，它就一定在。
  Future<String?> _readFallbackRoute(String filesDir) async {
    String? modelId;
    String? providerId;
    try {
      modelId = (await _storage.read(key: 'dsh_model_id'))?.trim();
      providerId = (await _storage.read(key: 'dsh_model_provider'))?.trim();
    } catch (_) {}

    if (modelId != null && modelId.isNotEmpty) {
      if (modelId.contains('/')) return modelId;
      if (providerId != null && providerId.isNotEmpty) {
        return '${ConfiguredModels.sanitizeProviderId(providerId)}/$modelId';
      }
      return modelId;
    }

    try {
      final f = File('$filesDir/dshhome/model.overlay.yml');
      if (!f.existsSync()) return null;
      var inDefault = false;
      String? provider;
      String? model;
      for (final line in f.readAsLinesSync()) {
        if (RegExp(r'^- id:\s*agent-default-model\s*$').hasMatch(line)) {
          inDefault = true;
          continue;
        }
        if (inDefault && line.startsWith('- id:')) break;
        if (!inDefault) continue;
        provider ??= RegExp(r'^\s+provider:\s*(\S+)')
            .firstMatch(line)
            ?.group(1)
            ?.replaceAll('"', '');
        model ??= RegExp(r'^\s+model:\s*(\S+)')
            .firstMatch(line)
            ?.group(1)
            ?.replaceAll('"', '');
      }
      if (model == null || model.isEmpty) return null;
      if (provider == null || provider.isEmpty || model.contains('/')) {
        return model;
      }
      return '$provider/$model';
    } catch (e) {
      debugPrint('[dsh-model] 读 overlay 兜底失败：$e');
    }
    return null;
  }

  /// 在面板里点选某一项（普通模型或轮换组）。
  ///
  /// 两处都要落：
  ///   1. 安全区 `dsh_model_selected_id`（本方法的原有行为，保留兼容）；
  ///   2. **`models.json` 的 `selected`** —— 设置页的「默认」徽标、`ModelStore.load`
  ///      的优先级、以及 `applyModelSelection` 写进 overlay 的默认路由都以它为准。
  ///
  /// 为什么必须写第 2 处：只写安全区的话，"会话里点过的模型"和"设置页显示的默认"
  /// 会长期不一致（用户实测反馈就是这条：设置里配好了 A，会话在跑 B）。
  ///
  /// ⚠️ **顺序**：`_selected` 在内存里先改（界面要立刻响应），但
  /// `notifyListeners()` 放在**落盘之后** —— 监听者（会话页）会立刻"读盘重写
  /// overlay"，先通知就等于让它读到旧 `selected`。
  Future<void> selectModel(ModelEntry model) async {
    _selected = model;
    _selectionPersist = _persistSelection(model);
    await _selectionPersist;
    notifyListeners();
  }

  /// 落盘（安全区 + `models.json.selected`）。
  ///
  /// ⚠️ 异常仍然**不往外抛**（"选模型不该因为写盘失败就卡住界面"——内存里已经切了），
  /// 但也**不再只是打一行日志**：失败记进 [selectionPersistError]，调用方必须查它。
  /// 只吞不报的后果见那个字段的注释（"选一次不行"会原样复现）。
  Future<void> _persistSelection(ModelEntry model) async {
    selectionPersistError = null;
    try {
      await _storage.write(key: _kSelected, value: model.routeId);
    } catch (e) {
      debugPrint('[dsh-model] persist failed: $e');
      selectionPersistError = '安全区写入失败：$e';
    }
    await _persistSelectionToConfig(model.routeId);
  }

  /// 把选中项写回 `models.json.selected`（**只改 selected，别的字段一个不动**）。
  ///
  /// 两个安全前提：
  ///   * [route] 必须真的在这份配置里存在（模型或轮换组）—— 否则不写。
  ///     兜底清单（`models.json` 为空时从安全区/overlay 捞出来的单条）走不到这里，
  ///     免得写出一个 providers 为空、selected 指向不存在 route 的坏文件；
  ///   * 读盘 → 改 selected → 写盘，避免用内存里的旧配置覆盖用户在设置页刚改的东西。
  Future<void> _persistSelectionToConfig(String route) async {
    if (_filesDir.isEmpty) return;
    try {
      final onDisk = ConfiguredModels.readConfig(_filesDir);
      // 运行时虚拟厂家（`local/<模型 id>`）：它**不在 models.json 里**，是 App
      // 起本地推理服务时才出现的。以前这里一刀切"不在配置里就不落盘"，后果是
      // **选中本地模型后，紧接的一次 reloadQuiet 会把选中项回落成清单第一条**
      // → 用户看到「本地大模型能看到、却选不了」（2026-10-06 真机实测）。
      // 所以它必须允许落盘：overlay 那边（writeOverlayFromConfig）本来就认这个前缀。
      final isRuntimeVirtual =
          route.startsWith('${LocalModelSpec.providerId}/');
      final known = isRuntimeVirtual ||
          onDisk.models.any((m) => m.route == route) ||
          onDisk.groups.any((g) => g.route == route);
      if (!known) {
        debugPrint('[dsh-model] 选中的 $route 不在 models.json 里，跳过 selected 落盘');
        return;
      }
      if ((onDisk.selected ?? '') == route) return;
      await ConfiguredModels.saveConfig(
        filesDir: _filesDir,
        config: onDisk.copyWith(selected: route),
      );
      debugPrint('[dsh-model] 已把选中项写回 models.json.selected=$route');
    } catch (e) {
      debugPrint('[dsh-model] 写回 models.json.selected 失败：$e');
      // 不覆盖上面安全区的失败原因（先发生的那个更接近现场）。
      selectionPersistError ??= 'models.json 写入失败：$e';
    }
  }

  /// 用于 overlay 的「激活 route」。清单为空时返回 null。
  String? get activeRouteId => _selected?.routeId;

  /// 除激活项外其余项 —— 保留给还在用旧签名的调用点。
  /// v2 的 overlay 会写入**整份配置**，所以这个列表只作参考。
  List<String> get otherRouteIds {
    final active = _selected?.routeId;
    final set = <String>{};
    for (final m in _catalog) {
      if (m.routeId != active) set.add(m.routeId);
    }
    return set.toList();
  }
}
