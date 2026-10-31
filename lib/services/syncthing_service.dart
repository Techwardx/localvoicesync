import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/app_config.dart';
import '../core/app_log.dart';
import '../models/sync_status.dart';

/// Syncthing 连接配置。
///
/// 默认指向**手机本机**的 Syncthing（`127.0.0.1:8384`）：
/// 真正在同步的是手机上的 Syncthing 客户端，我们要问的是它
/// "你跟 Mac 那台设备连上了吗、还有多少文件没传完"。
/// 如果用户把 Mac 的图形界面暴露在局域网里，也可以直接填 Mac 的地址。
class SyncthingConfig {
  const SyncthingConfig({
    this.baseUrl = 'http://127.0.0.1:8384',
    this.apiKey = '',
    this.folderId = '',
    this.remoteDeviceId = '',
  });

  final String baseUrl;
  final String apiKey;
  final String folderId;
  final String remoteDeviceId;

  bool get isConfigured =>
      apiKey.trim().isNotEmpty && folderId.trim().isNotEmpty;

  SyncthingConfig copyWith({
    String? baseUrl,
    String? apiKey,
    String? folderId,
    String? remoteDeviceId,
  }) => SyncthingConfig(
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
    folderId: folderId ?? this.folderId,
    remoteDeviceId: remoteDeviceId ?? this.remoteDeviceId,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'folderId': folderId,
    'remoteDeviceId': remoteDeviceId,
  };

  factory SyncthingConfig.fromJson(Map<String, Object?> json) =>
      SyncthingConfig(
        baseUrl: (json['baseUrl'] ?? 'http://127.0.0.1:8384').toString(),
        apiKey: (json['apiKey'] ?? '').toString(),
        folderId: (json['folderId'] ?? '').toString(),
        remoteDeviceId: (json['remoteDeviceId'] ?? '').toString(),
      );
}

/// Syncthing REST 探测器。
///
/// 为什么用 REST 而不是 ping：
/// 只有 Syncthing 自己知道"还有 3 个文件没传完"（`needFiles`），
/// ping 只能告诉你"机器活着"。黄灯上那个数字必须是真实的待同步量，
/// 否则用户会以为记录丢了。
class SyncthingService {
  const SyncthingService();

  Future<SyncStatus> probe({
    required SyncthingConfig config,
    required int localPending,
  }) async {
    if (!config.isConfigured) {
      return SyncStatus(
        state: LinkState.unconfigured,
        pendingFiles: localPending,
        detail: '未配置 Syncthing',
        checkedAt: DateTime.now(),
      );
    }

    final client = http.Client();
    try {
      final base = config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
      final headers = <String, String>{'X-API-Key': config.apiKey.trim()};

      final statusUri = Uri.parse(
        '$base/rest/db/status?folder=${Uri.encodeQueryComponent(config.folderId.trim())}',
      );
      final response = await client
          .get(statusUri, headers: headers)
          .timeout(AppConfig.syncthingHttpTimeout);

      if (response.statusCode != 200) {
        return SyncStatus(
          state: LinkState.offline,
          pendingFiles: localPending,
          detail: 'Syncthing 返回 ${response.statusCode}',
          checkedAt: DateTime.now(),
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        return SyncStatus(
          state: LinkState.offline,
          pendingFiles: localPending,
          detail: '响应格式异常',
          checkedAt: DateTime.now(),
        );
      }
      final needFiles = (decoded['needFiles'] as num?)?.toInt() ?? 0;
      final folderState = (decoded['state'] ?? 'idle').toString();

      // 有指定远端设备时，进一步确认它真的在线。
      var remoteConnected = true;
      if (config.remoteDeviceId.trim().isNotEmpty) {
        remoteConnected = await _isRemoteConnected(
          client: client,
          base: base,
          headers: headers,
          deviceId: config.remoteDeviceId.trim(),
        );
      }

      if (!remoteConnected) {
        return SyncStatus(
          state: LinkState.offline,
          pendingFiles: localPending,
          detail: 'Mac 设备未连接',
          checkedAt: DateTime.now(),
        );
      }

      final busy =
          needFiles > 0 ||
          folderState == 'syncing' ||
          folderState == 'scanning' ||
          folderState == 'sync-preparing';
      return SyncStatus(
        state: busy ? LinkState.syncing : LinkState.connected,
        pendingFiles: busy ? needFiles : 0,
        detail: busy ? '同步中（$folderState）' : '已连接',
        checkedAt: DateTime.now(),
      );
    } on Object catch (error) {
      AppLog.d('sync', 'Syncthing 探测失败：$error');
      return SyncStatus(
        state: LinkState.offline,
        pendingFiles: localPending,
        detail: '无法连接 Syncthing',
        checkedAt: DateTime.now(),
      );
    } finally {
      client.close();
    }
  }

  Future<bool> _isRemoteConnected({
    required http.Client client,
    required String base,
    required Map<String, String> headers,
    required String deviceId,
  }) async {
    try {
      final response = await client
          .get(Uri.parse('$base/rest/system/connections'), headers: headers)
          .timeout(AppConfig.syncthingHttpTimeout);
      if (response.statusCode != 200) return true; // 拿不到就不下结论
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return true;
      final connections = decoded['connections'];
      if (connections is! Map) return true;
      final device = connections[deviceId];
      if (device is! Map) return true;
      return device['connected'] == true;
    } on Object {
      return true;
    }
  }
}
