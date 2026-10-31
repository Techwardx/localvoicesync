import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_config.dart';

/// 统一管理所有磁盘路径。
///
/// 铁律：**全部落在系统持久化目录**，绝不用 Temporary / Cache
/// （那两者随时可能被系统清空）。但"持久化"在两个平台上指向不同地方：
///
/// * **本机私有区**（数据库、日志）→ `getApplicationDocumentsDirectory()`
/// * **同步根**（要给 Syncthing 看的）→ Android 上必须是共享存储，
///   否则 Syncthing 作为另一个 App 进不了我们的沙箱。
///
/// 目录结构：
/// ```
/// <私有区>/LocalVoiceSyncLocal/     ← 本机独占，永不同步
///   library.db
///   logs/
///
/// <同步根>/                        ← Android: /storage/emulated/0/Documents/LocalVoiceSync
///   .stignore                      ←   iOS/macOS: <Documents>/LocalVoiceSync
///   README.txt
///   Me_Notes/
///     .incoming/                   ← 录音中的半截文件（被 Syncthing 忽略）
///     outbox/                      ← 手机 → Mac
///     inbox/                       ← Mac → 手机
///   Dad_Notes/ ...
///   Mom_Notes/ ...
/// ```
class AppPaths {
  AppPaths._(this.documentsDir, this._syncRoot, this._syncRootShared);

  /// 私有持久区。数据库与日志永远在这里。
  final Directory documentsDir;

  Directory _syncRoot;
  bool _syncRootShared;

  /// 同步根当前是否落在共享存储上（只有共享存储才可能被 Syncthing 看到）。
  bool get syncRootIsShared => _syncRootShared;

  /// Android 上没拿到「所有文件访问」时会退化成私有目录，
  /// 此时 App 自身完全可用，但录音传不到 Mac。
  bool get syncRootNeedsPermission =>
      Platform.isAndroid && !_syncRootShared;

  static AppPaths? _instance;

  /// 全局单例。必须在 `runApp` 之前 await 一次。
  static AppPaths get instance {
    final cached = _instance;
    if (cached == null) {
      throw StateError('AppPaths 尚未初始化，请先 await AppPaths.resolve()');
    }
    return cached;
  }

  static Future<AppPaths> resolve() async {
    final docs = await getApplicationDocumentsDirectory();
    final picked = await _pickSyncRoot(docs);
    final paths = AppPaths._(docs, picked.$1, picked.$2);
    await paths.ensureLayout();
    _instance = paths;
    return paths;
  }

  /// 选出同步根：Android 优先共享存储，失败则退回私有目录（不阻塞启动）。
  static Future<(Directory, bool)> _pickSyncRoot(Directory docs) async {
    final privateDir = Directory(p.join(docs.path, AppConfig.syncRootName));
    if (!Platform.isAndroid) {
      return (privateDir, false);
    }
    final shared = Directory(
      p.join(AppConfig.androidSharedRoot, AppConfig.syncRootName),
    );
    if (await _probeWritable(shared)) {
      return (shared, true);
    }
    return (privateDir, false);
  }

  /// 真的写一个探针文件再删掉——比 `exists()` 可靠：
  /// 没授予 MANAGE_EXTERNAL_STORAGE 时目录可能"存在但不可写"。
  static Future<bool> _probeWritable(Directory dir) async {
    try {
      await dir.create(recursive: true);
      final probe = File(p.join(dir.path, '.lvs_write_probe'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return true;
    } on Object {
      return false;
    }
  }

  /// 用户在设置页点「允许访问文件」之后调用。
  ///
  /// 成功则把同步根切到共享存储并重建目录骨架。返回是否成功。
  /// 注意：**数据库不跟着搬**——它必须留在私有区，搬动反而有损坏风险。
  Future<bool> promoteToSharedSyncRoot() async {
    if (!Platform.isAndroid || _syncRootShared) return _syncRootShared;
    final shared = Directory(
      p.join(AppConfig.androidSharedRoot, AppConfig.syncRootName),
    );
    if (!await _probeWritable(shared)) return false;
    _syncRoot = shared;
    _syncRootShared = true;
    await ensureLayout();
    return true;
  }

  Directory get syncRoot => _syncRoot;

  Directory get localRoot =>
      Directory(p.join(documentsDir.path, AppConfig.localRootName));

  Directory get logDir => Directory(p.join(localRoot.path, 'logs'));

  File get databaseFile =>
      File(p.join(localRoot.path, AppConfig.databaseFileName));

  File get syncthingIgnoreFile => File(p.join(syncRoot.path, '.stignore'));

  Directory memberRoot(String dirName) =>
      Directory(p.join(syncRoot.path, dirName));

  Directory incomingDir(String dirName) =>
      Directory(p.join(memberRoot(dirName).path, AppConfig.incomingDirName));

  Directory outboxDir(String dirName) =>
      Directory(p.join(memberRoot(dirName).path, AppConfig.outboxDirName));

  Directory inboxDir(String dirName) =>
      Directory(p.join(memberRoot(dirName).path, AppConfig.inboxDirName));

  /// 音频最终位置（录音完成后的家）。
  File audioFile(String dirName, String fileName) =>
      File(p.join(outboxDir(dirName).path, fileName));

  /// outbox 里的任意文件（文本随手记等）。
  File outboxFile(String dirName, String fileName) =>
      File(p.join(outboxDir(dirName).path, fileName));

  /// 录音过程中的临时文件位置。
  File temporaryAudioFile(String dirName, String fileName) =>
      File(p.join(incomingDir(dirName).path, fileName));

  Future<void> ensureLayout() async {
    await documentsDir.create(recursive: true);
    await syncRoot.create(recursive: true);
    await localRoot.create(recursive: true);
    await logDir.create(recursive: true);
  }

  /// 为某个成员准备好目录骨架，并写入 `.stignore`。
  Future<void> ensureMemberLayout(String dirName) async {
    await memberRoot(dirName).create(recursive: true);
    await incomingDir(dirName).create(recursive: true);
    await outboxDir(dirName).create(recursive: true);
    await inboxDir(dirName).create(recursive: true);
  }

  /// 写入 Syncthing 忽略规则。
  ///
  /// 这是"原子录音"防线的第二道保险：即使代码出 bug 把 `.tmp_` 文件留在了
  /// 非 `.incoming` 目录，Syncthing 也不会把它传出去。
  Future<void> writeSyncthingIgnore() async {
    const content = '''
// LocalVoiceSync —— 由 App 自动生成，可手工追加规则
// 正在写入的临时文件绝不能同步出去，否则 Mac 端会拿到半截音频。
(?d).incoming
(?d).tmp_*
(?d)*.tmp
(?d)*.part
// 系统垃圾
(?d).DS_Store
(?d)Thumbs.db
''';
    try {
      final existing = await syncthingIgnoreFile.exists()
          ? await syncthingIgnoreFile.readAsString()
          : '';
      if (existing.trim() == content.trim()) return;
      await syncthingIgnoreFile.writeAsString(content, flush: true);
    } on FileSystemException {
      // 忽略：只读文件系统或权限问题不应该阻塞 App 启动。
    }
  }

  /// 在同步根目录写一份人类可读的说明，方便家人自己排查。
  Future<void> writeReadme() async {
    final file = File(p.join(syncRoot.path, 'README.txt'));
    const content = '''
LocalVoiceSync 同步目录
=======================

每个家庭成员一个子目录（Me_Notes / Dad_Notes / Mom_Notes / <自定义>_Notes）。

  .incoming/  录音进行中的临时文件，Syncthing 已忽略，不要手工删除
  outbox/     手机 → Mac：原始录音（memo_*.m4a）和文字随手记（memo_*.txt）
  inbox/      Mac → 手机：处理完的结构化结果（memo_*.json + memo_*.md）

⚠️ outbox / inbox 是**站在手机的视角**命名的，不是 Mac 的视角：

  outbox = 手机「发出去」的东西 → 所以手机产生的原始文件都在这里
  inbox  = 手机「收进来」的东西 → 所以 Mac 的转写总结结果都在这里

在 Mac 上看到的就是同一个目录，只是对 Mac 而言方向正好相反：
它从 outbox/ **读**任务、往 inbox/ **写**结果。
这不是放反了，两边必须共用同一套名字才能对上。

正常流程：
  1. 手机录音 → outbox/ 出现 memo_xxx.m4a
  2. Mac 监听到 → 转写 → 总结 → 在 inbox/ 写出 memo_xxx.json + memo_xxx.md
  3. 手机监听到 inbox/ 的新 json → 入库 → 界面上看到摘要和待办

如果 outbox/ 里长期堆着文件不动，说明 Mac 端处理服务没在跑。
如果 inbox/ 里有 json 但手机上没显示，去 App「设置 → 诊断 → 扫描收件箱」看具体原因。

请不要在两个设备上同时修改同一个文件；Syncthing 会保留冲突副本（*.sync-conflict-*）。
''';
    try {
      // 内容不一致就重写：老用户升级后也能看到最新的说明。
      final existing = await file.exists() ? await file.readAsString() : '';
      if (existing.trim() == content.trim()) return;
      await file.writeAsString(content, flush: true);
    } on FileSystemException {
      // 同上，非致命。
    }
  }
}
