import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/app_config.dart';
import '../core/app_log.dart';
import '../core/app_paths.dart';
import '../models/memo.dart';
import 'database_service.dart';

/// 收件箱监听：把 Mac 端回传的 JSON 解析入库。
///
/// 为什么用轮询而不是 `Directory.watch`？
/// 因为 Syncthing 的落盘方式不保证产生 inotify/FSEvents 事件
/// （尤其是先写临时文件再 rename 的场景），而轮询 4 秒一次的成本
/// 在手机上几乎为零，却不会漏事件。可靠性优先。
class InboxWatcherService {
  InboxWatcherService({required AppPaths paths, required DatabaseService db})
    : _paths = paths,
      _db = db;

  final AppPaths _paths;
  final DatabaseService _db;

  final StreamController<int> _changes = StreamController<int>.broadcast();
  Timer? _timer;
  bool _scanning = false;

  /// 每次入库完成后推送"本轮新增条数"，UI 据此刷新列表。
  Stream<int> get changes => _changes.stream;

  /// 新记录入库后的回调（用于补算向量）。由 [Services.boot] 注入。
  Future<void> Function(Memo memo)? onIngested;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(AppConfig.inboxPollInterval, (_) => scanOnce());
    unawaited(scanOnce());
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> dispose() async {
    await stop();
    await _changes.close();
  }

  /// 扫描一轮所有成员的 inbox。返回本轮成功入库的条数。
  Future<int> scanOnce() async {
    if (_scanning) return 0;
    _scanning = true;
    var ingested = 0;
    try {
      final members = await _paths.syncRoot
          .list()
          .where((entity) => entity is Directory)
          .cast<Directory>()
          .toList();

      for (final memberDir in members) {
        final dirName = p.basename(memberDir.path);
        final inbox = Directory(p.join(memberDir.path, AppConfig.inboxDirName));
        if (!await inbox.exists()) continue;

        final files = await inbox
            .list()
            .where((entity) => entity is File)
            .cast<File>()
            .toList();
        // 先处理错误回执，避免"成功文件不存在但错误文件存在"时状态卡在 local。
        files.sort((a, b) => a.path.compareTo(b.path));

        for (final file in files) {
          final name = p.basename(file.path);
          if (!name.endsWith('.json')) continue;
          if (name.endsWith('.error.json')) {
            if (await _ingestError(file)) ingested += 1;
            continue;
          }
          if (name.startsWith('.')) continue;
          if (await _ingestSuccess(file, dirName)) ingested += 1;
        }
      }
    } on FileSystemException catch (error) {
      AppLog.w('inbox', '扫描收件箱失败：$error');
    } finally {
      _scanning = false;
    }

    if (ingested > 0) {
      _changes.add(ingested);
      AppLog.i('inbox', '本轮入库 $ingested 条');
    }
    return ingested;
  }

  Future<bool> _ingestSuccess(File file, String dirName) async {
    if (await _db.isIngested(file)) return false;

    // 文件可能正在被写入：解析失败就留到下一轮，不报错、不删文件。
    String content;
    try {
      content = await file.readAsString();
    } on FileSystemException {
      return false;
    }
    if (content.trim().isEmpty) return false;

    Map<String, Object?> json;
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map) {
        AppLog.w('inbox', '${file.path} 不是对象，跳过');
        return false;
      }
      json = decoded.map((key, value) => MapEntry(key.toString(), value));
    } on FormatException catch (error) {
      AppLog.d('inbox', '${file.path} 解析失败（可能仍在写入）：$error');
      return false;
    }

    final fallbackId = p.basenameWithoutExtension(file.path);
    final incoming = Memo.fromContractJson(
      json,
      authorDir: dirName,
      deviceId: json['device_id']?.toString() ?? '',
      fallbackId: fallbackId,
    );
    if (incoming.id.isEmpty) {
      AppLog.w('inbox', '${file.path} 缺少 id 字段');
      return false;
    }

    final merged = await _db.mergeProcessed(incoming);
    await _db.markIngested(file);

    // 回传的向量只有在模型一致时才能用，否则宁可不要（跨模型比对毫无意义）。
    var vectorStored = false;
    final rawEmbedding = json['embedding'];
    if (rawEmbedding is List && rawEmbedding.isNotEmpty) {
      final model = json['embedding_model']?.toString();
      final compatible = model == null || model == AppConfig.embeddingModelId;
      if (compatible) {
        final vector = parseFloat32List(rawEmbedding);
        if (vector != null && vector.length == AppConfig.embeddingDim) {
          await _db.upsertVector(merged.id, vector);
          vectorStored = true;
        }
      } else {
        AppLog.i(
          'inbox',
          '向量模型不匹配（$model），忽略回传向量，改由本机重算',
        );
      }
    }

    // Mac 没给向量（或给了不兼容的），本机补算——语义检索不能有空洞。
    if (!vectorStored) {
      final hook = onIngested;
      if (hook != null) {
        unawaited(hook(merged));
      }
    }
    return true;
  }

  Future<bool> _ingestError(File file) async {
    if (await _db.isIngested(file)) return false;
    final id = p.basenameWithoutExtension(
      p.basenameWithoutExtension(file.path),
    );
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        final message = decoded['error']?.toString() ?? '未知错误';
        await _db.markFailed(id, reason: message);
      } else {
        await _db.markFailed(id);
      }
    } on Object catch (error) {
      AppLog.d('inbox', '错误回执解析失败：$error');
      return false;
    }
    await _db.markIngested(file);
    AppLog.w('inbox', '记录 $id 处理失败');
    return true;
  }
}

/// 把 JSON 数字数组转成 Float32List，顺带做合法性校验。
Float32List? parseFloat32List(List<dynamic> raw) {
  final buffer = Float32List(raw.length);
  for (var i = 0; i < raw.length; i++) {
    final value = raw[i];
    if (value is num) {
      buffer[i] = value.toDouble();
    } else {
      return null;
    }
  }
  return buffer;
}
