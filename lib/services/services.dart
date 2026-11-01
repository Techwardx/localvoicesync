import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/app_config.dart';
import '../core/app_log.dart';
import '../core/app_paths.dart';
import '../core/family_member.dart';
import 'audio_recorder_service.dart';
import 'database_service.dart';
import 'embedding_isolate.dart';
import 'inbox_watcher_service.dart';
import 'search_service.dart';
import 'settings_store.dart';
import 'syncthing_service.dart';
import 'text_note_service.dart';

/// 所有长生命周期服务的容器。
///
/// 为什么不用一堆 Riverpod provider 各自 `await` 初始化：
/// 冷启动时的顺序（路径 → 日志 → 数据库 → 配置 → 目录骨架 → 孤儿文件恢复）
/// 是有严格依赖的，写成一个显式的 `boot()` 比散落在十几个 provider 里好排查得多。
/// UI 层只通过一个 override 拿到它，其余 provider 都从它派生。
class Services {
  Services({
    required this.paths,
    required this.database,
    required this.settingsStore,
    required this.initialSettings,
    required this.embeddingEngine,
    required this.search,
    required this.recorder,
    required this.textNotes,
    required this.inbox,
    required this.syncthing,
    required this.initialPending,
    required this.allFilesAccess,
  });

  final AppPaths paths;
  final DatabaseService database;
  final SettingsStore settingsStore;
  final AppSettings initialSettings;
  final EmbeddingEngine embeddingEngine;
  final SearchService search;
  final AudioRecorderService recorder;
  final TextNoteService textNotes;
  final InboxWatcherService inbox;
  final SyncthingService syncthing;

  /// 冷启动时统计的"待处理条数"，避免首帧显示 0 再跳变。
  final int initialPending;

  /// 是否拿到了「所有文件访问」（`MANAGE_EXTERNAL_STORAGE`）。
  ///
  /// ⚠️ 这跟"同步根在不在共享存储上"**是两件事**，之前混为一谈，
  /// 结果踩了个大坑：部分 ROM（含 HyperOS）允许 App 往 `Documents/`
  /// **写**文件却**不给**权限，于是 `_probeWritable()` 一探就成功、
  /// 我们就以为"已经在共享存储上了、权限没问题"，从来没去要过权限。
  ///
  /// 后果：App 只能读到自己创建的文件，Syncthing 写进来的
  /// `inbox/*.json` 一律看不见 —— 目录 `stat` 得到、`list()` 却是空的，
  /// 表现得像"文件明明在、App 就是不出来"。
  ///
  /// 授权之后会被 [enableSharedSyncRoot] 就地更新，所以不是 final。
  bool allFilesAccess;

  /// Android 上没拿到「所有文件访问」时为 true，需要引导用户去授权。
  bool get needsAllFilesAccess => Platform.isAndroid && !allFilesAccess;

  /// 查询当前是否持有「所有文件访问」。非 Android 平台恒为 true。
  static Future<bool> hasAllFilesAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      return await Permission.manageExternalStorage.isGranted;
    } on Object catch (error) {
      AppLog.w('storage', '查询「所有文件访问」状态失败：$error');
      return false;
    }
  }

  static Future<Services> boot() async {
    final paths = await AppPaths.resolve();
    AppLog.init();
    AppLog.i('boot', '文档目录 ${paths.documentsDir.path}');

    final allFiles = await hasAllFilesAccess();
    AppLog.i(
      'boot',
      '「所有文件访问」${allFiles ? '已授予' : '未授予'}'
      '${Platform.isAndroid && !allFiles ? '（Syncthing 写的文件将读不到）' : ''}',
    );

    final database = DatabaseService(paths);
    // 提前打开一次：数据库损坏要在这里就暴露，而不是等用户点了录音才崩。
    await database.database;

    final settingsStore = SettingsStore();
    final settings = await settingsStore.load();

    await paths.writeSyncthingIgnore();
    await paths.writeReadme();
    await paths.ensureMemberLayout(settings.member.dirName);

    final engine = EmbeddingEngine();
    final search = SearchService(db: database, engine: engine);
    final recorder = AudioRecorderService(paths: paths, db: database);
    final textNotes = TextNoteService(paths: paths, db: database);
    final inbox = InboxWatcherService(paths: paths, db: database);

    // 上次进程被杀留下的半截录音，先救回来再进 UI。
    await recorder.recoverOrphans(deviceId: settings.deviceId);

    // Mac 回传的新记录，除了入库还要补向量（如果 Mac 没给）。
    inbox.onIngested = (memo) async {
      try {
        await search.indexMemo(memo);
      } on Object catch (error) {
        AppLog.w('boot', '为新记录补算向量失败：$error');
      }
    };
    inbox.start();

    final pending = await database.pendingCount();

    return Services(
      paths: paths,
      database: database,
      settingsStore: settingsStore,
      initialSettings: settings,
      embeddingEngine: engine,
      search: search,
      recorder: recorder,
      textNotes: textNotes,
      inbox: inbox,
      syncthing: const SyncthingService(),
      initialPending: pending,
      allFilesAccess: allFiles,
    );
  }

  /// 申请「所有文件访问」，必要时把同步根切到共享存储。
  ///
  /// 顺序很重要：**先要权限，再谈目录**。
  ///
  /// 之前的写法是"同步根已经在共享存储上就直接 return true"，
  /// 在 HyperOS 这类 ROM 上会直接跳过整个授权流程 —— 因为往
  /// `Documents/` 写文件本来就不需要权限，`_probeWritable()` 一探就成功。
  /// 结果是：写没问题、读别人的文件全被拒，Syncthing 回传的 json
  /// 永远进不了库。所以现在无条件先查权限。
  ///
  /// 返回 true 表示权限已到手、同步根在共享存储上。
  Future<bool> enableSharedSyncRoot() async {
    if (!Platform.isAndroid) return false;

    if (!await hasAllFilesAccess()) {
      final status = await Permission.manageExternalStorage.request();
      allFilesAccess = status.isGranted;
      if (!allFilesAccess) {
        AppLog.w('storage', '用户未授予「所有文件访问」，将读不到 Syncthing 写的文件');
        return false;
      }
      AppLog.i('storage', '「所有文件访问」已授予');
    }

    if (!paths.syncRootIsShared) {
      if (!await paths.promoteToSharedSyncRoot()) {
        AppLog.w('storage', '共享存储不可写，同步根仍为私有目录');
        return false;
      }
      // 目录骨架要在新位置重建一遍：老成员的 outbox/inbox 都在旧路径下。
      for (final member in FamilyMember.builtIns) {
        await paths.ensureMemberLayout(member.dirName);
      }
      await paths.ensureMemberLayout(initialSettings.member.dirName);
      await paths.writeSyncthingIgnore();
      await paths.writeReadme();
      AppLog.i('storage', '同步根已切换到 ${paths.syncRoot.path}');
    }

    // 权限刚到手，之前读不到的文件现在应该读得到了：立刻扫一轮验证。
    // inbox 轮询每次都会重新取 paths.syncRoot，无需重启定时器。
    unawaited(inbox.scanOnce());
    return true;
  }

  /// 把 ONNX 模型与词表读进内存。
  ///
  /// 模型是可选资产：没下载模型时返回 null，App 降级成纯关键词检索，
  /// 而不是白屏或崩溃。
  static Future<EmbeddingAssets?> loadEmbeddingAssets() async {
    try {
      final model = await rootBundle.load(AppConfig.modelAssetPath);
      final vocab = await rootBundle.loadString(AppConfig.vocabAssetPath);
      return EmbeddingAssets(
        modelBytes: model.buffer.asUint8List(),
        vocabText: vocab,
      );
    } on Object catch (error) {
      AppLog.w(
        'boot',
        '未找到本地向量模型（$error），语义检索将不可用。'
        '运行 tool/fetch_embedding_model.sh 下载后重新构建即可。',
      );
      return null;
    }
  }

  Future<void> dispose() async {
    await inbox.dispose();
    await recorder.dispose();
    await embeddingEngine.dispose();
    await database.close();
  }
}

class EmbeddingAssets {
  const EmbeddingAssets({required this.modelBytes, required this.vocabText});

  final Uint8List modelBytes;
  final String vocabText;
}
