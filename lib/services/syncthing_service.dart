import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

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

/// 诊断中的一步。设置页会把这些逐行显示出来。
class ProbeStep {
  const ProbeStep(this.label, this.ok, [this.detail = '']);

  final String label;
  final bool ok;
  final String detail;

  String get line => '${ok ? '✓' : '✗'} $label${detail.isEmpty ? '' : ' — $detail'}';
}

/// 一次完整探测的结果：既有给状态灯用的 [status]，也有给人看的 [steps]。
class SyncthingDiagnosis {
  const SyncthingDiagnosis({required this.status, required this.steps});

  final SyncStatus status;
  final List<ProbeStep> steps;

  String get report => steps.map((s) => s.line).join('\n');
}

/// Syncthing REST 探测器。
///
/// 为什么用 REST 而不是 ping：
/// 只有 Syncthing 自己知道"还有 3 个文件没传完"（`needFiles`），
/// ping 只能告诉你"机器活着"。黄灯上那个数字必须是真实的待同步量，
/// 否则用户会以为记录丢了。
///
/// 为什么要放行自签证书：
/// Syncthing（尤其 Android 上的 Syncthing-Fork）的 Web GUI 默认可能跑在
/// **HTTPS** 上，证书是它自己签的。用系统信任链去校验必然
/// `CERTIFICATE_VERIFY_FAILED`——但这台"服务器"就在本机回环上，
/// 是我们自己的进程，校验它没有任何安全收益，只会让状态灯永远离线。
/// 因此只对回环/私有网段放行，公网地址仍然严格校验。
class SyncthingService {
  const SyncthingService();

  /// 只关心结果时用这个。
  Future<SyncStatus> probe({
    required SyncthingConfig config,
    required int localPending,
  }) async {
    final diagnosis = await diagnose(
      config: config,
      localPending: localPending,
    );
    return diagnosis.status;
  }

  /// 是否属于"可以放行自签证书"的地址：本机回环 + 私有网段。
  static bool _isTrustedHost(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h == '127.0.0.1' || h == '::1') return true;
    if (h.startsWith('192.168.') || h.startsWith('10.')) return true;
    final m = RegExp(r'^172\.(\d+)\.').firstMatch(h);
    if (m != null) {
      final second = int.tryParse(m.group(1)!) ?? 0;
      if (second >= 16 && second <= 31) return true;
    }
    return false;
  }

  static http.Client _buildClient() {
    final inner = HttpClient()
      ..connectionTimeout = AppConfig.syncthingHttpTimeout
      // 只对回环/局域网放行自签证书；外部地址照常严格校验。
      ..badCertificateCallback = (cert, host, port) => _isTrustedHost(host);
    return IOClient(inner);
  }

  /// 用户可能把 `http://` 填成 `https://`（或反过来）。
  /// 两个都试一遍，谁通算谁——比让用户自己去猜协议友好得多。
  static List<String> _candidateBases(String raw) {
    final base = raw.trim().replaceAll(RegExp(r'/+$'), '');
    final out = <String>[base];
    if (base.startsWith('http://')) {
      out.add('https://${base.substring(7)}');
    } else if (base.startsWith('https://')) {
      out.add('http://${base.substring(8)}');
    }
    return out;
  }

  /// 完整探测，返回每一步的成败，供设置页展示。
  Future<SyncthingDiagnosis> diagnose({
    required SyncthingConfig config,
    required int localPending,
  }) async {
    final steps = <ProbeStep>[];

    SyncStatus fail(String detail) {
      AppLog.d('sync', '探测失败：$detail');
      return SyncStatus(
        state: LinkState.offline,
        pendingFiles: localPending,
        detail: detail,
        checkedAt: DateTime.now(),
      );
    }

    if (!config.isConfigured) {
      steps.add(const ProbeStep('已填写 API Key 与文件夹 ID', false, '未配置'));
      return SyncthingDiagnosis(
        status: SyncStatus(
          state: LinkState.unconfigured,
          pendingFiles: localPending,
          detail: '未配置 Syncthing',
          checkedAt: DateTime.now(),
        ),
        steps: steps,
      );
    }
    steps.add(const ProbeStep('已填写 API Key 与文件夹 ID', true));

    final client = _buildClient();
    try {
      final headers = <String, String>{'X-API-Key': config.apiKey.trim()};

      // ---- 第 1 步：找到能通的协议与地址
      String? reachable;
      final errors = <String>[];
      for (final base in _candidateBases(config.baseUrl)) {
        try {
          final ping = await client
              .get(Uri.parse('$base/rest/noauth/health'))
              .timeout(AppConfig.syncthingHttpTimeout);
          if (ping.statusCode == 200) {
            reachable = base;
            break;
          }
          errors.add('$base → HTTP ${ping.statusCode}');
        } on Object catch (error) {
          errors.add('$base → ${_short(error)}');
        }
      }

      if (reachable == null) {
        steps.add(
          ProbeStep('能连上 Syncthing', false, errors.join('；')),
        );
        return SyncthingDiagnosis(
          status: fail('连不上 ${config.baseUrl}，Syncthing 可能没在运行'),
          steps: steps,
        );
      }
      steps.add(
        ProbeStep(
          '能连上 Syncthing',
          true,
          reachable == config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '')
              ? reachable
              : '$reachable（协议和填写的不一致，建议改成这个）',
        ),
      );

      // ---- 第 2 步：API Key 对不对（用需要鉴权的接口试）
      final statusUri = Uri.parse(
        '$reachable/rest/db/status?folder=${Uri.encodeQueryComponent(config.folderId.trim())}',
      );
      final response = await client
          .get(statusUri, headers: headers)
          .timeout(AppConfig.syncthingHttpTimeout);

      if (response.statusCode == 401 || response.statusCode == 403) {
        steps.add(
          ProbeStep('API Key 有效', false, 'HTTP ${response.statusCode}'),
        );
        return SyncthingDiagnosis(
          status: fail('API Key 不对（HTTP ${response.statusCode}）'),
          steps: steps,
        );
      }
      steps.add(const ProbeStep('API Key 有效', true));

      if (response.statusCode == 404) {
        steps.add(
          ProbeStep('文件夹 ID「${config.folderId.trim()}」存在', false, 'HTTP 404'),
        );
        return SyncthingDiagnosis(
          status: fail('文件夹 ID 不对：${config.folderId.trim()}'),
          steps: steps,
        );
      }
      if (response.statusCode != 200) {
        steps.add(
          ProbeStep('读取文件夹状态', false, 'HTTP ${response.statusCode}'),
        );
        return SyncthingDiagnosis(
          status: fail('Syncthing 返回 ${response.statusCode}'),
          steps: steps,
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        steps.add(const ProbeStep('解析文件夹状态', false, '响应不是对象'));
        return SyncthingDiagnosis(
          status: fail('响应格式异常'),
          steps: steps,
        );
      }
      steps.add(const ProbeStep('文件夹状态可读', true));

      final needFiles = (decoded['needFiles'] as num?)?.toInt() ?? 0;
      final folderState = (decoded['state'] ?? 'idle').toString();

      // ---- 文件夹模式：Send Only 会导致"手机发得出去、Mac 的结果收不回来"，
      //      而且状态灯还是绿的（因为本机没有待传文件），极难自查。
      final folderType = await _folderType(
        client: client,
        base: reachable,
        headers: headers,
        folderId: config.folderId.trim(),
      );
      if (folderType != null) {
        final bidirectional = folderType == 'sendreceive';
        steps.add(
          ProbeStep(
            '文件夹是双向同步',
            bidirectional,
            bidirectional
                ? ''
                : '$folderType —— 收不到 Mac 的回传结果，请在 Syncthing 里改成「发送和接收」',
          ),
        );
      }

      // ---- 第 3 步：Mac 那台设备在线吗
      var remoteConnected = true;
      final wanted = config.remoteDeviceId.trim();
      if (wanted.isNotEmpty) {
        final result = await _remoteState(
          client: client,
          base: reachable,
          headers: headers,
          deviceId: wanted,
        );
        remoteConnected = result.connected;
        steps.add(
          ProbeStep(
            'Mac 设备已连接',
            remoteConnected,
            remoteConnected ? '' : result.detail,
          ),
        );
        if (!remoteConnected) {
          return SyncthingDiagnosis(
            status: fail(result.detail),
            steps: steps,
          );
        }
      } else {
        steps.add(const ProbeStep('Mac 设备已连接', true, '未填设备 ID，跳过'));
      }

      final busy =
          needFiles > 0 ||
          folderState == 'syncing' ||
          folderState == 'scanning' ||
          folderState == 'sync-preparing';
      steps.add(
        ProbeStep('没有待传输文件', !busy, busy ? '$needFiles 个' : ''),
      );

      return SyncthingDiagnosis(
        status: SyncStatus(
          state: busy ? LinkState.syncing : LinkState.connected,
          pendingFiles: busy ? needFiles : 0,
          detail: busy ? '同步中（$folderState）' : '已连接',
          checkedAt: DateTime.now(),
        ),
        steps: steps,
      );
    } on Object catch (error) {
      steps.add(ProbeStep('探测过程未抛异常', false, _short(error)));
      return SyncthingDiagnosis(
        status: fail('探测异常：${_short(error)}'),
        steps: steps,
      );
    } finally {
      client.close();
    }
  }

  /// 把异常压缩成一行，别把整个堆栈塞进 UI。
  static String _short(Object error) {
    final text = error.toString().replaceAll('\n', ' ');
    return text.length <= 120 ? text : '${text.substring(0, 120)}…';
  }

  /// 读文件夹模式（`sendreceive` / `sendonly` / `receiveonly` …）。
  /// 拿不到就返回 null，不因此判定离线。
  Future<String?> _folderType({
    required http.Client client,
    required String base,
    required Map<String, String> headers,
    required String folderId,
  }) async {
    try {
      final response = await client
          .get(Uri.parse('$base/rest/config/folders'), headers: headers)
          .timeout(AppConfig.syncthingHttpTimeout);
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is! List) return null;
      for (final item in decoded) {
        if (item is Map && item['id']?.toString() == folderId) {
          return (item['type'] ?? 'sendreceive').toString();
        }
      }
      return null;
    } on Object {
      return null;
    }
  }

  /// 设备 ID 比较必须宽容：
  /// Syncthing 展示时带连字符（`Z3JXJNT-RMKH...`），用户手工抄写时
  /// 很容易多打/漏打连字符、大小写写错。这里统一去掉所有非字母数字再比。
  static String _normaliseDeviceId(String raw) =>
      raw.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();

  Future<({bool connected, String detail})> _remoteState({
    required http.Client client,
    required String base,
    required Map<String, String> headers,
    required String deviceId,
  }) async {
    try {
      final response = await client
          .get(Uri.parse('$base/rest/system/connections'), headers: headers)
          .timeout(AppConfig.syncthingHttpTimeout);
      if (response.statusCode != 200) {
        // 拿不到就不下结论，别把"读不到"误报成"离线"。
        return (connected: true, detail: 'HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return (connected: true, detail: '响应不是对象');
      final connections = decoded['connections'];
      if (connections is! Map) return (connected: true, detail: '缺少 connections');

      final wanted = _normaliseDeviceId(deviceId);
      Map? matched;
      for (final entry in connections.entries) {
        if (_normaliseDeviceId(entry.key.toString()) == wanted) {
          matched = entry.value is Map ? entry.value as Map : null;
          break;
        }
      }
      if (matched == null) {
        final known = connections.keys
            .map((k) => k.toString().substring(0, 7))
            .join(', ');
        return (
          connected: false,
          detail: '这台 Syncthing 里没有该设备（已知：${known.isEmpty ? '无' : known}）',
        );
      }
      final connected = matched['connected'] == true;
      return (
        connected: connected,
        detail: connected ? '' : '设备已配对但当前未建立连接（Mac 端 Syncthing 没开？）',
      );
    } on Object catch (error) {
      return (connected: true, detail: _short(error));
    }
  }
}
