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

  // ------------------------------------------------------------- 诊断状态
  //
  // 手机上拿不到 logcat 也进不了私有目录，所以这些字段是唯一的排查入口。
  // 设置页会把它们显示出来，出问题时让用户截图即可定位。

  /// 最近一次扫描的时间。
  DateTime? lastScanAt;

  /// 最近一次扫描看到的 `.json` 文件数（含已入库的）。
  int lastSeen = 0;

  /// 最近一次扫描新入库的条数。
  int lastIngested = 0;

  /// 最近一次扫描中出现的错误（空字符串表示没出错）。
  String lastError = '';

  /// 扫描到的收件箱目录数（正常情况下 = 成员数）。
  int lastInboxDirs = 0;

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
    var seen = 0;
    var inboxDirs = 0;
    try {
      final entries = await _collectInboxFiles();
      seen = entries.length;
      inboxDirs = entries.map((e) => e.dirName).toSet().length;

      for (final entry in entries) {
        final file = entry.file;
        final name = p.basename(file.path);
        // 单个文件出问题绝不能中断整轮扫描：之前的实现只捕获
        // FileSystemException，一旦某条记录的解析或写库抛错，
        // 整个 Timer 回调就静默中断，表现为"文件明明在，却永远不入库"。
        try {
          final ok = name.endsWith('.error.json')
              ? await _ingestError(file)
              : await _ingestSuccess(file, entry.dirName);
          if (ok) ingested += 1;
        } on Object catch (error, stack) {
          lastError = '$name: $error';
          AppLog.e('inbox', '处理 $name 失败：$error\n$stack');
        }
      }
    } on FileSystemException catch (error) {
      lastError = '扫描同步根失败：$error';
      AppLog.w('inbox', '扫描收件箱失败：$error');
    } on Object catch (error) {
      lastError = '扫描异常：$error';
      AppLog.e('inbox', '扫描收件箱异常：$error');
    } finally {
      _scanning = false;
      lastScanAt = DateTime.now();
      lastSeen = seen;
      lastIngested = ingested;
      lastInboxDirs = inboxDirs;
    }

    if (ingested > 0) {
      _changes.add(ingested);
      AppLog.i('inbox', '本轮入库 $ingested 条');
    }
    return ingested;
  }

  /// 从同步根**递归**找出所有 `<成员>/inbox/*.json`。
  ///
  /// 为什么不再逐个成员目录列：部分 Android 设备上，对"应用自己创建、
  /// 由别的 App（Syncthing）填充"的目录做单层 readdir 会拿到陈旧的空列表。
  /// 从根做一次递归遍历走的是同一条路径，但能顺带覆盖成员目录被重建、
  /// 以及成员目录名带前缀等意外情况，容错性明显更好。
  Future<List<({File file, String dirName})>> _collectInboxFiles() async {
    final out = <({File file, String dirName})>[];
    final root = _paths.syncRoot;
    if (!await root.exists()) return out;

    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('.') || !name.endsWith('.json')) continue;
      if (p.basename(p.dirname(entity.path)) != AppConfig.inboxDirName) {
        continue;
      }
      final memberDir = p.basename(p.dirname(p.dirname(entity.path)));
      // `.stfolder` / `.stversions` 里不会有 inbox，但仍防一手。
      if (memberDir.isEmpty || memberDir.startsWith('.')) continue;
      out.add((file: entity, dirName: memberDir));
    }
    // 先处理错误回执，避免"成功文件不存在但错误文件存在"时状态卡在 local。
    out.sort((a, b) => a.file.path.compareTo(b.file.path));
    return out;
  }

  /// 给设置页用的快照：同步根、各成员收件箱里到底有什么。
  Future<InboxDiagnostics> diagnose() async {
    final lines = <String>[];
    var totalFiles = 0;
    try {
      lines.add('同步根 ${_paths.syncRoot.path}');
      lines.add(
        '是否共享存储 ${_paths.syncRootIsShared ? '是' : '否（Syncthing 读不到）'}',
      );
      if (!await _paths.syncRoot.exists()) {
        lines.add('同步根目录不存在');
        return InboxDiagnostics(lines: lines, totalFiles: 0);
      }
      // `.stfolder` 是 Syncthing 认领这个目录时放的标记。
      // 它不在 → 这个路径根本不是 Syncthing 的文件夹（只是同名目录）。
      final marker = Directory(
        p.join(_paths.syncRoot.path, '.stfolder'),
      );
      lines.add('Syncthing 已认领此目录 ${await marker.exists() ? '是' : '否'}');
      final members = await _paths.syncRoot
          .list()
          .where((e) => e is Directory)
          .cast<Directory>()
          .where((dir) => !p.basename(dir.path).startsWith('.'))
          .toList();
      if (members.isEmpty) {
        lines.add('同步根下没有任何成员目录');
      }
      for (final memberDir in members) {
        final name = p.basename(memberDir.path);
        final inbox = Directory(p.join(memberDir.path, AppConfig.inboxDirName));
        final outbox = Directory(
          p.join(memberDir.path, AppConfig.outboxDirName),
        );

        // outbox 里有东西、inbox 是空的 —— 说明"发得出去、收不回来"，
        // 问题在 Syncthing 的文件夹模式（Send Only / Receive Only），
        // 不在 App 这边。这条信息比单纯数 inbox 文件有用得多。
        final outCount = await _countFiles(outbox);
        final outNames = await _sampleNames(outbox);
        if (!await inbox.exists()) {
          lines.add('$name/inbox 不存在（outbox 有 $outCount 个文件）');
          continue;
        }
        final files = await inbox
            .list()
            .where((e) => e is File)
            .cast<File>()
            .toList();
        totalFiles += files.length;
        final names = files.map((f) => p.basename(f.path)).take(6).join('、');
        lines.add(
          '$name/inbox 共 ${files.length} 个文件'
          '${files.isEmpty ? '' : '：$names'}',
        );
        lines.add(
          '$name/outbox 共 $outCount 个文件'
          '${outNames.isEmpty ? '' : '：$outNames'}',
        );
      }

      // 完整树（深度 2）：让"App 到底看见了什么"一目了然，
      // 不用再靠猜是权限、路径还是目录缓存的问题。
      lines.add('— 目录树（深度 2）—');
      for (final memberDir in members) {
        final name = p.basename(memberDir.path);
        final subs = await memberDir
            .list()
            .where((e) => e is Directory)
            .cast<Directory>()
            .toList();
        if (subs.isEmpty) {
          lines.add('$name/（空）');
          continue;
        }
        for (final sub in subs) {
          final count = await _countFiles(sub);
          lines.add('$name/${p.basename(sub.path)}/ → $count 个文件');
        }
      }
    } on Object catch (error) {
      lines.add('读取目录失败：$error');
    }
    return InboxDiagnostics(lines: lines, totalFiles: totalFiles);
  }

  static Future<int> _countFiles(Directory dir) async {
    try {
      if (!await dir.exists()) return 0;
      return await dir.list().where((e) => e is File).length;
    } on Object {
      return 0;
    }
  }

  static Future<String> _sampleNames(Directory dir) async {
    try {
      if (!await dir.exists()) return '';
      final names = await dir
          .list()
          .where((e) => e is File)
          .map((e) => p.basename(e.path))
          .take(3)
          .toList();
      return names.join('、');
    } on Object {
      return '';
    }
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

/// 收件箱目录快照，给设置页的「诊断」区用。
class InboxDiagnostics {
  const InboxDiagnostics({required this.lines, required this.totalFiles});

  final List<String> lines;
  final int totalFiles;

  String get report => lines.join('\n');
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
