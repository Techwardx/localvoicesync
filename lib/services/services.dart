import 'package:flutter/services.dart';

import '../core/app_config.dart';
import '../core/app_log.dart';
import '../core/app_paths.dart';
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

  static Future<Services> boot() async {
    final paths = await AppPaths.resolve();
    AppLog.init();
    AppLog.i('boot', '文档目录 ${paths.documentsDir.path}');

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
    );
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
