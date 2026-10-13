import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../i18n/dsh_i18n.dart';

/// 桥协议 v1 的 WebSocket 客户端。
///
/// 职责边界：
///  - 只做传输、请求/响应关联、心跳、重连；
///  - 不解释 ACP 语义（App 侧永远看不到 session/update 这类原始帧）；
///  - 断线不负责补拉，补拉由 [BridgeState] 用 seq 发起 `subscribe`。
class BridgeClient {
  BridgeClient({
    required this.host,
    required this.port,
    this.useTls = false,
    this.fingerprint,
    this.onLog,
  });

  final String host;
  final int port;

  /// 是否使用 wss（TLS）。桥在存在 `tls/bridge.pfx` 时监听 wss。
  final bool useTls;

  /// 证书 SHA-256 指纹（形如 `AA:BB:…`）。wss 下**必须**提供：
  /// 我们不做"盲信任自签证书"，没有指纹就拒绝连接。
  final String? fingerprint;

  final void Function(String message)? onLog;

  static const int protocolVersion = 1;
  static const Duration requestTimeout = Duration(seconds: 30);
  static const Duration pingInterval = Duration(seconds: 15);

  WebSocketChannel? _channel;
  HttpClient? _httpClient;
  StreamSubscription<dynamic>? _sub;
  final StreamController<Map<String, dynamic>> _frames =
      StreamController<Map<String, dynamic>>.broadcast();
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  int _idSeq = 0;
  bool _connected = false;
  int _missedPongs = 0;
  Timer? _pingTimer;

  Stream<Map<String, dynamic>> get frames => _frames.stream;
  bool get isConnected => _connected;

  void _log(String m) => onLog?.call('[bridge] $m');

  /// 归一化指纹：忽略大小写、冒号与空格，便于用户粘贴任意格式。
  static String normalizeFingerprint(String value) =>
      value.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '').toUpperCase();

  /// 只信任指纹匹配的证书；空指纹一律拒绝。
  bool _certificateIsPinned(X509Certificate cert) {
    final expected = fingerprint;
    if (expected == null || expected.trim().isEmpty) return false;
    final actual = sha256.convert(cert.der).toString();
    return normalizeFingerprint(actual) == normalizeFingerprint(expected);
  }

  Future<void> connect() async {
    await disconnect();
    final scheme = useTls ? 'wss' : 'ws';
    final uri = Uri.parse('$scheme://$host:$port');
    _log(tr('连接 {0}{1}', [uri, useTls ? '（已 pin 证书指纹）' : '']));

    WebSocketChannel channel;
    if (useTls) {
      if (fingerprint == null || fingerprint!.trim().isEmpty) {
        throw StateError(tr('wss 必须提供证书指纹——没有指纹就不该信任自签证书'));
      }
      final client = HttpClient()
        ..badCertificateCallback = (X509Certificate cert, String _, int __) =>
            _certificateIsPinned(cert);
      _httpClient = client;
      channel = IOWebSocketChannel.connect(uri, customClient: client);
    } else {
      channel = WebSocketChannel.connect(uri);
    }

    await channel.ready.timeout(const Duration(seconds: 15));
    _channel = channel;
    _connected = true;
    _missedPongs = 0;
    _sub = channel.stream.listen(_onData, onError: _onError, onDone: _onDone);
    _startHeartbeat();
    _log(tr('已连接'));
  }

  void _onData(dynamic raw) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (e) {
      _log(tr('收到无法解析的帧：{0}', [e]));
      return;
    }
    final id = msg['id'];
    if (id is String && _pending.containsKey(id)) {
      final completer = _pending.remove(id)!;
      if (!completer.isCompleted) completer.complete(msg);
      return;
    }
    if (msg['type'] == 'pong') {
      _missedPongs = 0;
      return;
    }
    _frames.add(msg);
  }

  void _onError(Object error) {
    _log(tr('连接错误：{0}', [error]));
    _connected = false;
  }

  void _onDone() {
    _log(tr('连接已关闭'));
    _connected = false;
    _pingTimer?.cancel();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError(tr('连接已断开')));
    }
    _pending.clear();
  }

  void _startHeartbeat() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(pingInterval, (_) {
      if (!_connected) return;
      _missedPongs += 1;
      if (_missedPongs > 3) {
        _log(tr('心跳连续丢失，判为死链'));
        disconnect();
        return;
      }
      try {
        _channel?.sink.add(jsonEncode(
            {'v': protocolVersion, 'type': 'ping', 'id': 'p${++_idSeq}'}));
      } catch (e) {
        _log(tr('心跳发送失败：{0}', [e]));
      }
    });
  }

  void _raw(Map<String, dynamic> frame) {
    final channel = _channel;
    if (channel == null || !_connected) throw StateError(tr('尚未连接'));
    channel.sink.add(jsonEncode(frame));
  }

  /// 发一个需要应答的请求，按 `id` 关联响应。
  Future<Map<String, dynamic>> request(
    String type, [
    Map<String, dynamic> payload = const {},
  ]) {
    final id = 'c${++_idSeq}';
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    try {
      _raw({'v': protocolVersion, 'type': type, 'id': id, ...payload});
    } catch (e) {
      _pending.remove(id);
      rethrow;
    }
    return completer.future.timeout(
      requestTimeout,
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException(tr('请求 {0} 超时', [type]));
      },
    );
  }

  /// 发一个不需要应答的帧（例如 unsubscribe）。
  void send(String type, [Map<String, dynamic> payload = const {}]) {
    _raw(
        {'v': protocolVersion, 'type': type, 'id': 'n${++_idSeq}', ...payload});
  }

  /// 首次配对：用一次性配对码换取设备凭据。
  Future<Map<String, dynamic>> pair(String code, String deviceName) =>
      request('pair', {'code': code, 'deviceName': deviceName});

  /// 握手：用已保存的设备凭据登录。
  Future<Map<String, dynamic>> hello(String deviceToken, String appVersion) =>
      request(
        'hello',
        {
          'deviceToken': deviceToken,
          'client': {'platform': 'flutter', 'appVersion': appVersion},
        },
      );

  Future<void> disconnect() async {
    _pingTimer?.cancel();
    _pingTimer = null;
    await _sub?.cancel();
    _sub = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    try {
      _httpClient?.close(force: true);
    } catch (_) {}
    _httpClient = null;
    _channel = null;
    _connected = false;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError(tr('连接已断开')));
    }
    _pending.clear();
  }

  void dispose() {
    disconnect();
    _frames.close();
  }
}
