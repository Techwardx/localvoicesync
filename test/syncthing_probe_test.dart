import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_voice_sync/models/sync_status.dart';
import 'package:local_voice_sync/services/syncthing_service.dart';

/// 复现真机上踩到的坑：Syncthing-Fork 的 Web GUI 跑在 **HTTPS + 自签证书** 上，
/// 用系统信任链去校验必然 `CERTIFICATE_VERIFY_FAILED`，状态灯就永远离线。
///
/// 这个测试起一个真的自签 HTTPS 服务器（证书在 test/fixtures/tls/），
/// 断言探测器能连上并正确解析出"已连接"。
void main() {
  const phoneDevice = 'M3R3PTK-EYOFHM2-6K74GMI-VYXYPXR-2Z7NBR3-5GJX77T-O3RSUSW-T43LAQB';

  late HttpServer server;
  late String base;

  /// 让测试能改服务器对"文件夹模式"的回答，验证 Send Only 能被识别出来。
  var folderType = 'sendreceive';

  setUpAll(() async {
    final context = SecurityContext()
      ..useCertificateChain('test/fixtures/tls/cert.pem')
      ..usePrivateKey('test/fixtures/tls/key.pem');

    // 绑定 127.0.0.1 的随机端口，完全模拟手机上的回环 GUI。
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    base = 'https://127.0.0.1:${server.port}';

    server.listen((request) async {
      final path = request.uri.path;
      request.response.headers.contentType = ContentType.json;

      if (path == '/rest/noauth/health') {
        request.response.statusCode = 200;
        request.response.write('{"status":"OK"}');
      } else if (path == '/rest/db/status') {
        if (request.uri.queryParameters['folder'] != 'lvs') {
          request.response.statusCode = 404;
          request.response.write('{"error":"no such folder"}');
        } else if (request.headers.value('X-API-Key') != 'good-key') {
          request.response.statusCode = 403;
          request.response.write('{"error":"csrf"}');
        } else {
          request.response.statusCode = 200;
          request.response.write(
            jsonEncode({
              'state': 'idle',
              'needFiles': 0,
              'localFiles': 7,
              'globalFiles': 7,
            }),
          );
        }
      } else if (path == '/rest/system/connections') {
        request.response.statusCode = 200;
        request.response.write(
          jsonEncode({
            'connections': {
              // 故意用带连字符的原始形式，验证归一化比较
              phoneDevice: {'connected': true},
            },
          }),
        );
      } else if (path == '/rest/config/folders') {
        request.response.statusCode = 200;
        request.response.write(
          jsonEncode([
            {'id': 'lvs', 'type': folderType},
          ]),
        );
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  test('自签 HTTPS 的 Syncthing GUI 能被连上（这是真机离线的原因）', () async {
    final diagnosis = await const SyncthingService().diagnose(
      config: SyncthingConfig(
        baseUrl: base,
        apiKey: 'good-key',
        folderId: 'lvs',
        // 设备 ID 故意写成"去掉连字符 + 小写"，验证归一化比较
        remoteDeviceId: phoneDevice.replaceAll('-', '').toLowerCase(),
      ),
      localPending: 0,
    );

    expect(
      diagnosis.status.state,
      LinkState.connected,
      reason: '诊断明细：\n${diagnosis.report}',
    );
    expect(diagnosis.status.isOnline, isTrue);
    expect(diagnosis.status.detail, '已连接');
  });

  test('填的是 http:// 也能自动切到 https://（协议填错不该让用户猜）', () async {
    final diagnosis = await const SyncthingService().diagnose(
      config: SyncthingConfig(
        baseUrl: base.replaceFirst('https://', 'http://'),
        apiKey: 'good-key',
        folderId: 'lvs',
      ),
      localPending: 0,
    );

    expect(
      diagnosis.status.state,
      LinkState.connected,
      reason: '诊断明细：\n${diagnosis.report}',
    );
  });

  test('API Key 不对时给出 401/403 的明确结论，而不是笼统的"离线"', () async {
    final diagnosis = await const SyncthingService().diagnose(
      config: SyncthingConfig(
        baseUrl: base,
        apiKey: 'wrong-key',
        folderId: 'lvs',
      ),
      localPending: 3,
    );

    expect(diagnosis.status.state, LinkState.offline);
    expect(diagnosis.status.detail, contains('API Key'));
    expect(diagnosis.status.pendingFiles, 3);
  });

  test('文件夹 ID 不对时明确说是文件夹 ID 的问题', () async {
    final diagnosis = await const SyncthingService().diagnose(
      config: SyncthingConfig(
        baseUrl: base,
        apiKey: 'good-key',
        folderId: 'wrong-folder',
      ),
      localPending: 0,
    );

    expect(diagnosis.status.state, LinkState.offline);
    expect(diagnosis.status.detail, contains('文件夹 ID'));
  });

  test('Send Only 的文件夹会被指出来（这是"发得出去收不回来"的元凶）', () async {
    folderType = 'sendonly';
    addTearDown(() => folderType = 'sendreceive');

    final diagnosis = await const SyncthingService().diagnose(
      config: SyncthingConfig(
        baseUrl: base,
        apiKey: 'good-key',
        folderId: 'lvs',
      ),
      localPending: 0,
    );

    final step = diagnosis.steps.firstWhere(
      (s) => s.label == '文件夹是双向同步',
      orElse: () => throw StateError('没有检查文件夹模式：\n${diagnosis.report}'),
    );
    expect(step.ok, isFalse);
    expect(step.detail, contains('sendonly'));
  });

  test('设备不在连接表里时，报出它认识哪些设备', () async {    final diagnosis = await const SyncthingService().diagnose(
      config: SyncthingConfig(
        baseUrl: base,
        apiKey: 'good-key',
        folderId: 'lvs',
        remoteDeviceId: 'AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH',
      ),
      localPending: 0,
    );

    expect(diagnosis.status.state, LinkState.offline);
    expect(diagnosis.status.detail, contains('没有该设备'));
    expect(diagnosis.status.detail, contains('M3R3PTK'));
  });
}
