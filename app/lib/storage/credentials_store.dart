import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一次连接的持久化设置。
class ConnectionSettings {
  const ConnectionSettings({
    required this.host,
    required this.port,
    this.useTls = false,
    this.fingerprint,
    this.deviceId,
    this.deviceToken,
  });

  final String host;
  final int port;

  /// wss 模式：桥存在 `tls/bridge.pfx` 时为 true。
  final bool useTls;

  /// 证书 SHA-256 指纹（wss 下必填，用于 pin）。
  final String? fingerprint;

  final String? deviceId;
  final String? deviceToken;

  bool get isPaired => deviceToken != null && deviceToken!.isNotEmpty;

  ConnectionSettings copyWith({
    String? deviceId,
    String? deviceToken,
  }) =>
      ConnectionSettings(
        host: host,
        port: port,
        useTls: useTls,
        fingerprint: fingerprint,
        deviceId: deviceId ?? this.deviceId,
        deviceToken: deviceToken ?? this.deviceToken,
      );
}

/// 地址类信息放 SharedPreferences；设备凭据放系统安全存储
/// （Android Keystore / iOS Keychain）。
///
/// 安全约定：token 不进备份（Android 侧在 Manifest 关掉 allowBackup）、
/// 不进日志；只存在本机安全区。
class CredentialsStore {
  static const _kHost = 'bridge_host';
  static const _kPort = 'bridge_port';
  static const _kUseTls = 'bridge_use_tls';
  static const _kFingerprint = 'bridge_cert_fingerprint';
  static const _kDeviceId = 'bridge_device_id';
  static const _kTokenKey = 'bridge_device_token';

  static const _secure = FlutterSecureStorage();

  Future<ConnectionSettings?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString(_kHost);
    final port = prefs.getInt(_kPort);
    if (host == null || port == null) return null;
    final token = await _secure.read(key: _kTokenKey);
    final deviceId = prefs.getString(_kDeviceId);
    return ConnectionSettings(
      host: host,
      port: port,
      useTls: prefs.getBool(_kUseTls) ?? false,
      fingerprint: prefs.getString(_kFingerprint),
      deviceId: deviceId,
      deviceToken: token,
    );
  }

  Future<void> saveEndpoint({
    required String host,
    required int port,
    bool useTls = false,
    String? fingerprint,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kHost, host);
    await prefs.setInt(_kPort, port);
    await prefs.setBool(_kUseTls, useTls);
    if (fingerprint == null || fingerprint.trim().isEmpty) {
      await prefs.remove(_kFingerprint);
    } else {
      await prefs.setString(_kFingerprint, fingerprint.trim());
    }
  }

  Future<void> saveDevice(
      {required String deviceId, required String deviceToken}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDeviceId, deviceId);
    await _secure.write(key: _kTokenKey, value: deviceToken);
  }

  /// 只在桥明确返回 auth_failed 时调用（token 被吊销/失效）。
  Future<void> clearDevice() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kDeviceId);
    await _secure.delete(key: _kTokenKey);
  }
}
