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

  /// 本轮**枚举目录**找到的 `.json` 数。
  int enumerated = 0;

  /// 本轮**按已知 id 直接探**到的 `.json` 数。
  ///
  /// 这两个数字对比着看就能定位"目录视图"问题：
  /// 枚举 0、探测 >0 → 文件在，只是 App 列不出目录内容。
  int probed = 0;

  /// "能写不能读"的告警只喊一次，别每 4 秒刷屏。
  bool _warnedAboutVisibility = false;

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

      // "能写不能读"的典型特征：inbox 一个都读不到，outbox 里却是有文件的。
      // 这几乎一定是没拿到「所有文件访问」——写 `Documents/` 在部分 ROM 上
      // 不需要权限，读别的 App 创建的文件却需要。每次启动只喊一次，别刷屏。
      if (entries.isEmpty && !_warnedAboutVisibility) {
        _warnedAboutVisibility = true;
        var outboxCount = 0;
        try {
          final root = _paths.syncRoot;
          if (await root.exists()) {
            await for (final member in root.list(followLinks: false)) {
              if (member is! Directory) continue;
              if (p.basename(member.path).startsWith('.')) continue;
              outboxCount += await _countFiles(
                Directory(p.join(member.path, AppConfig.outboxDirName)),
              );
            }
          }
        } on Object {
          // 数不出来就不断言，免得日志里冒出误导性的结论。
        }
        if (outboxCount > 0) {
          AppLog.w(
            'inbox',
            '收件箱一个文件都读不到，但 outbox 里有 $outboxCount 个 —— '
            '典型的"能写不能读"，请检查是否授予了「所有文件访问」',
          );
        }
      }

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
  /// 两条路并用，因为单靠第一条在真机上翻过车：
  ///
  /// 1. **枚举目录**（常规情况，一次递归就能拿全）；
  /// 2. **按已知 id 直接探文件**（兜底，见 [_probeKnownIds]）。
  ///
  /// 真机现象：Syncthing 索引里明明有 `Me_Notes/inbox/memo_xxx.json`，
  /// 手机端 Syncthing 也报 needFiles=0，但 App 用 `Directory.list()` 看
  /// 那个目录是**空的**——同一层级的 `outbox/` 里 7 个文件却看得见
  /// （那些是 App 自己写的）。也就是说"看得见自己写的、看不见别人写的"。
  ///
  /// 与其去赌 Android 的目录视图什么时候恢复正常，不如换一条完全不依赖
  /// 枚举的路：这些文件叫什么名字我们本来就知道。
  Future<List<({File file, String dirName})>> _collectInboxFiles() async {
    final byPath = <String, ({File file, String dirName})>{};

    final root = _paths.syncRoot;
    if (await root.exists()) {
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.startsWith('.') || !name.endsWith('.json')) continue;
        if (p.basename(p.dirname(entity.path)) != AppConfig.inboxDirName) {
          continue;
        }
        final memberDir = p.basename(p.dirname(p.dirname(entity.path)));
        // `.stfolder` / `.stversions` 里不会有 inbox，但仍防一手。
        if (memberDir.isEmpty || memberDir.startsWith('.')) continue;
        byPath[entity.path] = (file: entity, dirName: memberDir);
      }
    }
    enumerated = byPath.length;

    // 兜底探测只在必要时做：目录枚举一旦正常，它就纯属浪费。
    // 每 4 秒扫一轮、每个 id 两次 stat，outbox 里又只增不减，
    // 常年跑下去会变成几千次 stat —— 所以这条路径必须"按需"。
    final probedEntries = await _probeKnownIds(
      includeOutbox: byPath.isEmpty,
    );
    probed = probedEntries.length;
    for (final entry in probedEntries) {
      byPath.putIfAbsent(entry.file.path, () => entry);
    }

    // 先处理错误回执，避免"成功文件不存在但错误文件存在"时状态卡在 local。
    final out = byPath.values.toList(growable: false)
      ..sort((a, b) => a.file.path.compareTo(b.file.path));
    return out;
  }

  /// 不枚举目录，直接按**已知文件名**去 `inbox/` 里探。
  ///
  /// 名字从哪来？两个都是 App 自己看得到的：
  /// * 数据库里还没处理完的记录 → `inbox/<memo_id>.json`；
  /// * `outbox/` 里的文件名 → Mac 会用同一个 id 回写 `inbox/<id>.json`。
  ///
  /// 第二条尤其重要：有些记录**写库失败了**（文件落盘成功、DB 报错），
  /// 数据库里根本没有它们，只能靠 outbox 的文件名反推 id。
  /// 但它也最贵，所以只在 [includeOutbox] 为真时做——也就是目录枚举
  /// 一个文件都没找到的时候。
  Future<List<({File file, String dirName})>> _probeKnownIds({
    required bool includeOutbox,
  }) async {
    final out = <({File file, String dirName})>[];
    final seen = <String>{};

    Future<void> consider(String dirName, String id) async {
      if (dirName.isEmpty || id.isEmpty || id.startsWith('.')) return;
      final inbox = _paths.inboxDir(dirName);
      for (final name in <String>['$id.json', '$id.error.json']) {
        // 同一个目录的几种等价写法都试一遍：少数机型/权限组合下
        // `/storage/emulated/0` 读不到、`/sdcard` 却能读到。
        for (final alias in AppPaths.aliasPaths(p.join(inbox.path, name))) {
          final file = File(alias);
          if (!seen.add(file.path)) continue;
          try {
            if (await file.exists()) {
              out.add((file: file, dirName: dirName));
            }
          } on Object catch (error) {
            lastError = '探测 $name 失败：$error';
          }
        }
      }
    }

    try {
      for (final row in await _db.unprocessedIds()) {
        await consider(row.authorDir, row.id);
      }
    } on Object catch (error) {
      lastError = '读取待处理 id 失败：$error';
    }

    if (includeOutbox) {
      try {
        final root = _paths.syncRoot;
        if (await root.exists()) {
          await for (final member in root.list(followLinks: false)) {
            if (member is! Directory) continue;
            final dirName = p.basename(member.path);
            if (dirName.startsWith('.')) continue;
            final outbox = Directory(
              p.join(member.path, AppConfig.outboxDirName),
            );
            if (!await outbox.exists()) continue;
            final names = <String>[];
            await for (final entity in outbox.list(followLinks: false)) {
              if (entity is! File) continue;
              final name = p.basename(entity.path);
              if (name.startsWith('.')) continue;
              names.add(name);
            }
            // outbox 只增不减，按文件名倒序 ≈ 时间倒序（id 里带时间戳），
            // 取最近 200 个就够了，不必为几千个历史文件反复 stat。
            names.sort((a, b) => b.compareTo(a));
            for (final name in names.take(200)) {
              await consider(dirName, p.basenameWithoutExtension(name));
            }
          }
        }
      } on Object catch (error) {
        lastError = '扫描 outbox 文件名失败：$error';
      }
    }

    // 计数由调用方负责：诊断也要复用这个方法，但不该污染扫描统计。
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
          // `todos/` 是共享的待办状态目录，不是成员目录；
          // 不排除的话诊断报告里会冒出一行假的「todos/inbox 不存在」。
          .where(
            (dir) =>
                !p.basename(dir.path).startsWith('.') &&
                p.basename(dir.path) != AppConfig.todoStateDirName,
          )
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

      // 目录 mtime 是最硬的判据。
      //
      // 如果 Syncthing 真往 `Me_Notes/inbox` 里写过 12 个文件，这个目录的
      // mtime 必须接近最近一次落盘时间。若它停在很早以前（比如只剩 App
      // 当初 mkdir 的那个时间），说明 **Syncthing 写的根本不是这个目录** ——
      // 那就不是 App 读不到，而是两边指向了不同的物理位置。
      lines.add('— 收件箱目录 mtime —');
      for (final memberDir in members) {
        final name = p.basename(memberDir.path);
        final inbox = Directory(p.join(memberDir.path, AppConfig.inboxDirName));
        try {
          if (!await inbox.exists()) {
            lines.add('$name/inbox 不存在');
            continue;
          }
          final stat = await inbox.stat();
          lines.add('$name/inbox → ${_fmtTime(stat.modified)}');
        } on Object catch (error) {
          lines.add('$name/inbox stat 失败：$error');
        }
      }

      // 枚举 vs 直接探测。
      //
      // 真机上出现过最难查的一种：Syncthing 索引里明明有
      // `Me_Notes/inbox/memo_xxx.json`、手机端 needFiles=0，但
      // `Directory.list()` 看那个目录是空的，而同一层级的 outbox
      // （App 自己写的）却有 7 个文件。这两行就是判据：
      //   探测到 >0 且枚举 =0  → 文件在，只是目录列不出来
      //   两者都是 0            → 文件确实没到，或者根本没权限读
      lines.add('— 枚举 vs 直接探测 —');
      final probedFiles = await _probeKnownIds(includeOutbox: true);
      lines.add(
        '枚举目录找到 $totalFiles 个 / 按已知 id 直接探到 ${probedFiles.length} 个',
      );
      for (final entry in probedFiles.take(8)) {
        lines.add('  ${entry.dirName}/inbox/${p.basename(entry.file.path)} → 存在');
      }
      if (probedFiles.length > 8) {
        lines.add('  …共 ${probedFiles.length} 个');
      }

      // 挑一个已知 id，把三种等价路径的探测结果都列出来。
      // 这一步是为了区分"文件不在"和"这个路径写法读不到"。
      final sample = await _sampleKnownId();
      if (sample != null) {
        final full = p.join(_paths.inboxDir(sample.dirName).path, '${sample.id}.json');
        lines.add('对照 ${sample.dirName}/inbox/${sample.id}.json：');
        for (final alias in AppPaths.aliasPaths(full)) {
          String verdict;
          try {
            final f = File(alias);
            verdict = await f.exists()
                ? '存在（${await f.length()} 字节）'
                : '不存在';
          } on Object catch (error) {
            verdict = '异常 $error';
          }
          lines.add('  $alias → $verdict');
        }
      }
    } on Object catch (error) {
      lines.add('读取目录失败：$error');
    }
    return InboxDiagnostics(lines: lines, totalFiles: totalFiles);
  }

  /// 挑一个"已知 id"做对照探测：优先用数据库里未处理的记录，
  /// 没有就退而取 outbox 里最新的文件名。
  Future<({String dirName, String id})?> _sampleKnownId() async {
    try {
      final rows = await _db.unprocessedIds();
      if (rows.isNotEmpty) {
        return (dirName: rows.first.authorDir, id: rows.first.id);
      }
    } on Object {
      // 忽略：退到 outbox
    }
    try {
      final root = _paths.syncRoot;
      if (!await root.exists()) return null;
      await for (final member in root.list(followLinks: false)) {
        if (member is! Directory) continue;
        final dirName = p.basename(member.path);
        if (dirName.startsWith('.')) continue;
        final outbox = Directory(p.join(member.path, AppConfig.outboxDirName));
        if (!await outbox.exists()) continue;
        final names = <String>[];
        await for (final entity in outbox.list(followLinks: false)) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          if (name.startsWith('.')) continue;
          names.add(name);
        }
        if (names.isEmpty) continue;
        names.sort((a, b) => b.compareTo(a));
        return (
          dirName: dirName,
          id: p.basenameWithoutExtension(names.first),
        );
      }
    } on Object {
      // 忽略
    }
    return null;
  }

  static String _fmtTime(DateTime t) =>
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';

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

    // 从这一行往下全是"锦上添花"，**任何失败都不能算入库失败**。
    //
    // 之前的实现里 upsertVector 抛错会一路冒到 scanOnce 的 catch，
    // 于是 `ingested` 不 +1 → changes 流不推送 → 列表永远不刷新。
    // 表现就是最坑的一种："记录确实在数据库里，界面上却一条都没有"，
    // 用户只能靠杀进程重启才看得见。
    var vectorStored = false;
    try {
      // 回传的向量只有在模型一致时才能用，否则宁可不要（跨模型比对毫无意义）。
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
    } on Object catch (error) {
      AppLog.w('inbox', '回传向量写库失败，改由本机重算：$error');
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
