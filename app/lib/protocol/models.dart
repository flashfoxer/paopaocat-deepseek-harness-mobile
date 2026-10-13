/// 桥协议 v1 的数据模型。
///
/// 对应 `bridge/bridge-protocol.md`。App 只认这些模型，
/// 不接触任何 ACP / DSH 内部概念。
library;

import '../i18n/dsh_i18n.dart';

/// 一个会话的摘要（来自 `sessions` / `hello_ok`）。
class SessionInfo {
  const SessionInfo({
    required this.id,
    required this.cwd,
    this.title,
    required this.status,
    required this.lastSeq,
    required this.updatedAt,
  });

  final String id;
  final String cwd;
  final String? title;

  /// idle | running | cancelling
  final String status;
  final int lastSeq;
  final int updatedAt;

  bool get isRunning => status != 'idle';

  /// 显示名：ACP 不提供标题，所以用工作目录末段兜底。
  String get displayName {
    if (title != null && title!.trim().isNotEmpty) return title!;
    final parts =
        cwd.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).toList();
    return parts.isEmpty ? cwd : parts.last;
  }

  factory SessionInfo.fromJson(Map<String, dynamic> json) => SessionInfo(
        id: json['id'] as String,
        cwd: (json['cwd'] ?? '') as String,
        title: json['title'] as String?,
        status: (json['status'] ?? 'idle') as String,
        lastSeq: (json['lastSeq'] ?? 0) as int,
        updatedAt: (json['updatedAt'] ?? 0) as int,
      );

  SessionInfo copyWith({String? status, int? lastSeq}) => SessionInfo(
        id: id,
        cwd: cwd,
        title: title,
        status: status ?? this.status,
        lastSeq: lastSeq ?? this.lastSeq,
        updatedAt: updatedAt,
      );
}

/// 会话内的一条更新（`update` 帧的 `update` 字段）。
///
/// kind 取值：message / thought / tool_call / tool_result / usage / snapshot
class BridgeUpdate {
  const BridgeUpdate({
    required this.kind,
    this.messageId,
    this.text,
    this.complete,
    this.toolCallId,
    this.title,
    this.toolKind,
    this.status,
    this.command,
    this.description,
    this.output,
    this.used,
    this.size,
  });

  final String kind;
  final String? messageId;
  final String? text;
  final bool? complete;

  final String? toolCallId;
  final String? title;
  final String? toolKind;
  final String? status;
  final String? command;
  final String? description;
  final String? output;

  final int? used;
  final int? size;

  factory BridgeUpdate.fromJson(Map<String, dynamic> json) => BridgeUpdate(
        kind: (json['kind'] ?? 'unknown') as String,
        messageId: json['messageId'] as String?,
        text: json['text'] as String?,
        complete: json['complete'] as bool?,
        toolCallId: json['toolCallId'] as String?,
        title: json['title'] as String?,
        toolKind: json['toolKind'] as String?,
        status: json['status'] as String?,
        command: json['command'] as String?,
        description: json['description'] as String?,
        output: json['output'] as String?,
        used: json['used'] as int?,
        size: json['size'] as int?,
      );
}

/// 一条带序号的事件（`update` 帧的外层）。
class SequencedUpdate {
  const SequencedUpdate(
      {required this.sessionId, required this.seq, required this.update});

  final String sessionId;
  final int seq;
  final BridgeUpdate update;
}

/// 权限审批请求。
class PermissionRequest {
  const PermissionRequest({
    required this.sessionId,
    required this.requestId,
    this.toolCallId,
    this.title,
    this.command,
    required this.cwd,
    required this.riskFlags,
    required this.expiresAt,
  });

  final String sessionId;
  final String requestId;
  final String? toolCallId;
  final String? title;
  final String? command;
  final String cwd;
  final List<String> riskFlags;
  final int expiresAt;

  bool get isHighRisk => riskFlags.isNotEmpty;

  String get riskLabel {
    if (riskFlags.isEmpty) return '';
    final names = {
      'destructive': tr('删除性操作'),
      'remote-exec': tr('远程代码执行'),
      'secret-access': tr('访问敏感凭据'),
      'history-rewrite': tr('改写历史'),
      'system-write': tr('写系统目录'),
    };
    return riskFlags.map((f) => names[f] ?? f).join(' · ');
  }

  factory PermissionRequest.fromJson(Map<String, dynamic> json) =>
      PermissionRequest(
        sessionId: (json['sessionId'] ?? '') as String,
        requestId: (json['requestId'] ?? '') as String,
        toolCallId: json['toolCallId'] as String?,
        title: json['title'] as String?,
        command: json['command'] as String?,
        cwd: (json['cwd'] ?? '') as String,
        riskFlags: (json['riskFlags'] as List<dynamic>? ?? const [])
            .map((e) => '$e')
            .toList(),
        expiresAt: (json['expiresAt'] ?? 0) as int,
      );
}

/// 会话历史中的一条消息（本地聚合结果，用于渲染）。
class ChatEntry {
  ChatEntry({required this.id, required this.kind, required this.text});

  final String id;

  /// user | assistant | thought | tool
  final String kind;
  String text;

  // 工具条目专用
  String? toolCallId;
  String? toolTitle;
  String? toolCommand;
  String? toolStatus;
  String? toolOutput;

  bool get isTool => kind == 'tool';
}

/// 主机信息（`hello_ok` 的 host 字段）。
class HostInfo {
  const HostInfo({
    required this.name,
    this.dshVersion,
    required this.cwd,
    required this.permissionMode,
  });

  final String name;
  final String? dshVersion;
  final String cwd;
  final String permissionMode;

  bool get hasApproval => permissionMode != 'danger-full-access';

  factory HostInfo.fromJson(Map<String, dynamic> json) => HostInfo(
        name: (json['name'] ?? tr('未知主机')) as String,
        dshVersion: json['dshVersion'] as String?,
        cwd: (json['cwd'] ?? '') as String,
        permissionMode: (json['permissionMode'] ?? '') as String,
      );
}
