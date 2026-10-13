import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/bridge_client.dart';
import '../protocol/models.dart';
import '../storage/credentials_store.dart';

import '../i18n/dsh_i18n.dart';

enum ConnState { unpaired, connecting, connected, error }

/// App 的全部运行状态与桥协议编排。
///
/// 数据流：BridgeClient.frames → [_onFrame] → 模型 → notifyListeners → UI
class BridgeState extends ChangeNotifier {
  BridgeState(this.store);

  final CredentialsStore store;

  static const String appVersion = '0.1.0';

  BridgeClient? _client;
  StreamSubscription<Map<String, dynamic>>? _framesSub;

  ConnState conn = ConnState.unpaired;
  String? errorMessage;
  ConnectionSettings? settings;
  HostInfo? host;
  String bridgeStatus = 'starting';
  String? bridgeDetail;

  List<SessionInfo> sessions = const [];
  String? activeSessionId;

  final List<ChatEntry> entries = [];
  final Map<String, ChatEntry> _byKey = {};
  int lastSeq = 0;
  int? usageUsed;
  int? usageSize;

  PermissionRequest? pendingPermission;

  final List<String> logs = [];

  bool get isPaired => settings?.isPaired ?? false;
  bool get isConnected => conn == ConnState.connected;

  SessionInfo? get activeSession {
    for (final s in sessions) {
      if (s.id == activeSessionId) return s;
    }
    return null;
  }

  void _log(String message) {
    final ts = DateTime.now().toIso8601String().substring(11, 19);
    logs.add('$ts $message');
    if (logs.length > 300) logs.removeAt(0);
  }

  // ------------------------------------------------------------------ 生命周期

  Future<void> bootstrap() async {
    settings = await store.load();
    if (settings == null || !settings!.isPaired) {
      conn = ConnState.unpaired;
      notifyListeners();
      return;
    }
    await _connectAndHandshake();
  }

  Future<void> _connectAndHandshake() async {
    final s = settings!;
    conn = ConnState.connecting;
    errorMessage = null;
    notifyListeners();
    try {
      final client = BridgeClient(
        host: s.host,
        port: s.port,
        useTls: s.useTls,
        fingerprint: s.fingerprint,
        onLog: _log,
      );
      await client.connect();
      await _attach(client, s.deviceToken!);
    } catch (e) {
      conn = ConnState.error;
      errorMessage = _humanError(e);
      _log(tr('连接失败：{0}', [e]));
      notifyListeners();
    }
  }

  /// 用一次性配对码完成首次配对。
  Future<void> pair({
    required String host,
    required int port,
    required String code,
    required String deviceName,
    bool useTls = false,
    String? fingerprint,
  }) async {
    conn = ConnState.connecting;
    errorMessage = null;
    notifyListeners();
    BridgeClient? client;
    try {
      client = BridgeClient(
        host: host,
        port: port,
        useTls: useTls,
        fingerprint: fingerprint,
        onLog: _log,
      );
      await client.connect();
      final res = await client.pair(code, deviceName);
      if (res['type'] != 'pair_ok') {
        throw StateError((res['message'] ?? tr('配对失败')).toString());
      }
      await store.saveEndpoint(
        host: host,
        port: port,
        useTls: useTls,
        fingerprint: fingerprint,
      );
      await store.saveDevice(
        deviceId: res['deviceId'] as String,
        deviceToken: res['deviceToken'] as String,
      );
      settings = await store.load();
      await _attach(client, res['deviceToken'] as String);
    } catch (e) {
      conn = ConnState.error;
      errorMessage = _humanError(e);
      _log(tr('配对失败：{0}', [e]));
      await client?.disconnect();
      notifyListeners();
    }
  }

  Future<void> _attach(BridgeClient client, String token) async {
    await _framesSub?.cancel();
    _framesSub = client.frames.listen(_onFrame);
    _client = client;

    final res = await client.hello(token, appVersion);
    final type = res['type'] as String?;
    if (type == 'auth_failed') {
      await store.clearDevice();
      settings = await store.load();
      conn = ConnState.unpaired;
      errorMessage = tr('设备凭据已失效，请重新配对');
      notifyListeners();
      return;
    }
    if (type != 'hello_ok') {
      throw StateError((res['message'] ?? tr('握手失败')).toString());
    }

    host = HostInfo.fromJson(res['host'] as Map<String, dynamic>);
    sessions = (res['sessions'] as List<dynamic>? ?? const [])
        .map((e) => SessionInfo.fromJson(e as Map<String, dynamic>))
        .toList();
    conn = ConnState.connected;
    _log(tr('已连接 {0}（{1}）', [host!.name, host!.permissionMode]));
    notifyListeners();

    // 断线重连后**必须**重新订阅当前会话，否则后续 update 会静默丢失
    // （手机切后台、切 Wi-Fi、锁屏都会走到这里）。
    await _resubscribeActiveSession(client);
  }

  /// 重连后恢复当前会话的订阅：从本地 lastSeq 增量补拉断线期间缺的那一段。
  Future<void> _resubscribeActiveSession(BridgeClient client) async {
    final sessionId = activeSessionId;
    if (sessionId == null) return;
    try {
      final res = await client.request('subscribe', {
        'sessionId': sessionId,
        'fromSeq': lastSeq,
      });
      final needSnapshot = res['needSnapshot'] == true;
      _log(tr('已恢复订阅 {0}（fromSeq={1}{2}）',
          [sessionId, lastSeq, needSnapshot ? '，需快照' : '']));
      if (needSnapshot) {
        // 桥的事件日志已滚出窗口：本地视图作废，等桥下发 snapshot 基线
        entries.clear();
        _byKey.clear();
        lastSeq = 0;
        notifyListeners();
      }
    } catch (e) {
      // 会话可能已在电脑端失效（例如 DSH 重启后该会话未恢复）
      _log(tr('恢复订阅失败：{0}', [e]));
      errorMessage = tr('会话已失效，请返回列表重新打开或新建会话');
      activeSessionId = null;
      notifyListeners();
    }
  }

  Future<void> forgetDevice() async {
    await _framesSub?.cancel();
    await _client?.disconnect();
    _client = null;
    await store.clearDevice();
    settings = await store.load();
    conn = ConnState.unpaired;
    sessions = const [];
    entries.clear();
    _byKey.clear();
    notifyListeners();
  }

  Future<void> reconnect() => _connectAndHandshake();

  String _humanError(Object e) {
    final text = e.toString();
    if (text.contains(tr('超时'))) return tr('连接超时：请确认桥在运行、地址端口正确、手机与电脑在同一网络。');
    if (text.contains('refused') || text.contains('Connection refused')) {
      return tr('连接被拒绝：桥未启动或端口不对。');
    }
    return text.replaceFirst('Exception: ', '');
  }

  // ------------------------------------------------------------------ 帧分发

  void _onFrame(Map<String, dynamic> msg) {
    switch (msg['type']) {
      case 'update':
        _onUpdate(msg);
        break;
      case 'permission_request':
        pendingPermission = PermissionRequest.fromJson(msg);
        _log(tr('收到审批请求：{0}',
            [pendingPermission!.command ?? pendingPermission!.requestId]));
        notifyListeners();
        break;
      case 'permission_ack':
        pendingPermission = null;
        notifyListeners();
        break;
      case 'session_status':
        _updateSessionStatus(
            msg['sessionId'] as String?, msg['state'] as String?);
        break;
      case 'bridge_status':
        bridgeStatus = (msg['dsh'] ?? 'unknown') as String;
        bridgeDetail = msg['detail'] as String?;
        notifyListeners();
        break;
      case 'sessions':
        sessions = (msg['sessions'] as List<dynamic>? ?? const [])
            .map((e) => SessionInfo.fromJson(e as Map<String, dynamic>))
            .toList();
        notifyListeners();
        break;
      case 'error':
        final code = msg['code'] as String?;
        final message = (msg['message'] ?? tr('未知错误')).toString();
        _log(tr('错误[{0}] {1}', [code, message]));
        errorMessage = message;
        notifyListeners();
        break;
      case 'pong':
        break;
      default:
        _log(tr('未处理的帧类型：{0}', [msg['type']]));
    }
  }

  void _updateSessionStatus(String? sessionId, String? state) {
    if (sessionId == null || state == null) return;
    sessions = sessions
        .map((s) => s.id == sessionId ? s.copyWith(status: state) : s)
        .toList();
    notifyListeners();
  }

  void _onUpdate(Map<String, dynamic> msg) {
    final sessionId = msg['sessionId'] as String?;
    if (sessionId == null || sessionId != activeSessionId) return;
    final seq = (msg['seq'] as int?) ?? 0;
    if (seq <= lastSeq) return; // 去重：补拉与实时推送可能重叠
    lastSeq = seq;
    final update = BridgeUpdate.fromJson(msg['update'] as Map<String, dynamic>);
    _applyUpdate(update);
    notifyListeners();
  }

  void _applyUpdate(BridgeUpdate u) {
    switch (u.kind) {
      case 'message':
        final key = 'msg:${u.messageId ?? 'unknown'}';
        final entry = _byKey.putIfAbsent(key, () {
          final e = ChatEntry(id: key, kind: 'assistant', text: '');
          entries.add(e);
          return e;
        });
        entry.text = u.text ?? '';
        break;

      case 'thought':
        final key = 'thought:${u.messageId ?? 'unknown'}';
        final entry = _byKey.putIfAbsent(key, () {
          final e = ChatEntry(id: key, kind: 'thought', text: '');
          entries.add(e);
          return e;
        });
        entry.text = u.text ?? '';
        break;

      case 'tool_call':
        final key = 'tool:${u.toolCallId}';
        final entry = _byKey.putIfAbsent(key, () {
          final e = ChatEntry(id: key, kind: 'tool', text: '');
          entries.add(e);
          return e;
        });
        entry.toolCallId = u.toolCallId;
        entry.toolTitle = u.title;
        entry.toolCommand = u.command;
        entry.toolStatus = u.status;
        break;

      case 'tool_result':
        final key = 'tool:${u.toolCallId}';
        final entry = _byKey[key];
        if (entry != null) {
          entry.toolStatus = u.status;
          entry.toolOutput = u.output;
        }
        break;

      case 'usage':
        usageUsed = u.used;
        usageSize = u.size;
        break;

      case 'snapshot':
        // 补拉窗口不足：桥给了基线，保留已有条目并刷新状态。
        _log(tr('收到快照基线'));
        break;

      default:
        _log(tr('未知 update kind：{0}', [u.kind]));
    }
  }

  // ------------------------------------------------------------------ 会话操作

  Future<void> loadSessions() async {
    final client = _client;
    if (client == null || !isConnected) return;
    final res = await client.request('list_sessions', {'cwd': host?.cwd ?? ''});
    sessions = (res['sessions'] as List<dynamic>? ?? const [])
        .map((e) => SessionInfo.fromJson(e as Map<String, dynamic>))
        .toList();
    notifyListeners();
  }

  Future<String?> createSession() async {
    final client = _client;
    if (client == null) return null;
    final res = await client.request('new_session', {'cwd': host?.cwd ?? ''});
    final session = res['session'] as Map<String, dynamic>?;
    if (session == null) {
      errorMessage = (res['message'] ?? tr('创建会话失败')).toString();
      notifyListeners();
      return null;
    }
    final info = SessionInfo.fromJson({
      'id': session['id'],
      'cwd': session['cwd'],
      'status': 'idle',
      'lastSeq': session['lastSeq'] ?? 0,
      'updatedAt': 0,
    });
    sessions = [info, ...sessions];
    notifyListeners();
    return info.id;
  }

  /// 打开并订阅一个会话：清空本地视图，按 seq 从头补拉。
  Future<void> openSession(String sessionId) async {
    final client = _client;
    if (client == null) return;
    activeSessionId = sessionId;
    entries.clear();
    _byKey.clear();
    lastSeq = 0;
    usageUsed = null;
    usageSize = null;
    notifyListeners();
    try {
      await client.request('subscribe', {'sessionId': sessionId, 'fromSeq': 0});
    } catch (e) {
      errorMessage = tr('订阅失败：{0}', [e]);
      notifyListeners();
    }
  }

  void closeSessionView() {
    final client = _client;
    if (client != null && activeSessionId != null) {
      // 只取消订阅，绝不销毁会话（ACP 无 load，关掉就拿不回上下文）
      client.request('unsubscribe', {'sessionId': activeSessionId}).catchError(
          (_) => <String, dynamic>{});
    }
    activeSessionId = null;
    entries.clear();
    _byKey.clear();
    lastSeq = 0;
    notifyListeners();
  }

  Future<void> sendPrompt(String text) async {
    final client = _client;
    final sessionId = activeSessionId;
    if (client == null || sessionId == null || text.trim().isEmpty) return;
    final key = 'user:${DateTime.now().microsecondsSinceEpoch}';
    entries.add(ChatEntry(id: key, kind: 'user', text: text.trim()));
    notifyListeners();
    try {
      await client.request('prompt', {
        'sessionId': sessionId,
        'text': text.trim(),
        'clientMsgId': key,
      });
    } catch (e) {
      errorMessage = tr('发送失败：{0}', [e]);
      notifyListeners();
    }
  }

  Future<void> cancelTurn() async {
    final client = _client;
    final sessionId = activeSessionId;
    if (client == null || sessionId == null) return;
    await client.request('cancel', {'sessionId': sessionId});
  }

  Future<void> decidePermission(String decision) async {
    final client = _client;
    final request = pendingPermission;
    if (client == null || request == null) return;
    pendingPermission = null;
    notifyListeners();
    await client.request('permission_decision', {
      'sessionId': request.sessionId,
      'requestId': request.requestId,
      'decision': decision,
    });
  }

  @override
  void dispose() {
    _framesSub?.cancel();
    _client?.dispose();
    super.dispose();
  }
}
