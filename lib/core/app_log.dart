import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_paths.dart';

enum LogLevel { debug, info, warn, error }

/// 极简日志器：控制台 + 按天追加到本地日志文件。
///
/// 后台服务类 App 出问题时用户很难描述现象，日志文件是唯一线索。
/// 写入失败一律静默，日志永远不能成为新的故障源。
class AppLog {
  AppLog._();

  static File? _file;
  static bool _initialized = false;

  static void init() {
    if (_initialized) return;
    _initialized = true;
    try {
      final dir = AppPaths.instance.logDir;
      final today = DateTime.now();
      final stamp =
          '${today.year}-${_two(today.month)}-${_two(today.day)}';
      _file = File(p.join(dir.path, 'app-$stamp.log'));
    } on Object {
      _file = null;
    }
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static void d(String tag, Object? message) =>
      _write(LogLevel.debug, tag, message);

  static void i(String tag, Object? message) =>
      _write(LogLevel.info, tag, message);

  static void w(String tag, Object? message) =>
      _write(LogLevel.warn, tag, message);

  static void e(String tag, Object? message, [Object? error, StackTrace? st]) {
    _write(LogLevel.error, tag, message);
    if (error != null) _write(LogLevel.error, tag, error);
    if (st != null && !kReleaseMode) _write(LogLevel.error, tag, st);
  }

  static void _write(LogLevel level, String tag, Object? message) {
    final now = DateTime.now();
    final line =
        '${now.toIso8601String()} [${level.name.toUpperCase().padRight(5)}] [$tag] $message';
    if (kDebugMode || level != LogLevel.debug) {
      debugPrint(line);
    }
    final file = _file;
    if (file == null) return;
    try {
      file.writeAsStringSync('$line\n', mode: FileMode.append, flush: false);
    } on Object {
      // 磁盘满 / 权限问题：放弃写文件，绝不影响主流程。
    }
  }
}
