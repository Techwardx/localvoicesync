import 'dart:io';

import 'package:flutter/services.dart';

import '../core/app_log.dart';

/// Android 前台服务桥。
///
/// Android 10+ 在后台录麦克风必须有前台服务（Foreground Service），
/// 否则系统会在息屏几分钟后直接掐掉录音。这里通过 MethodChannel 拉起
/// 原生 `RecordingForegroundService`，让"锁屏继续录音"真正成立。
///
/// iOS / macOS 不需要：iOS 靠 `UIBackgroundModes: audio`，
/// macOS 靠 entitlement，都不需要常驻通知。
class RecordingForegroundService {
  const RecordingForegroundService._();

  static const MethodChannel _channel = MethodChannel(
    'localvoicesync/foreground',
  );

  static bool get _supported => Platform.isAndroid;

  static Future<void> start(String title, String body) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('start', <String, String>{
        'title': title,
        'body': body,
      });
    } on PlatformException catch (error) {
      AppLog.w('fg', '启动前台服务失败：${error.message}');
    } on MissingPluginException {
      AppLog.w('fg', '前台服务通道未注册（非 Android 环境可忽略）');
    }
  }

  static Future<void> stop() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException catch (error) {
      AppLog.w('fg', '停止前台服务失败：${error.message}');
    } on MissingPluginException {
      // 忽略
    }
  }
}
