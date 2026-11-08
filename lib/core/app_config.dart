/// 全局常量。所有"魔法数字"和跨文件约定都集中在这里，避免散落在各处。
class AppConfig {
  const AppConfig._();

  static const String appName = 'LocalVoiceSync';

  /// 展示用的版本号。必须跟 `pubspec.yaml` 的 `version:` 保持一致，
  /// 否则用户报障时说的版本号跟 APK 里实际跑的对不上。
  static const String appVersion = '0.1.9';
  static const String bundleId = 'com.localvoicesync.app';

  // ---------------------------------------------------------------- 目录布局
  /// 会被 Syncthing 同步的目录名。
  ///
  /// ⚠️ Android 上它**不在**应用私有目录里，而是在共享存储
  /// `/storage/emulated/0/Documents/LocalVoiceSync`。
  /// 原因：`getApplicationDocumentsDirectory()` 在 Android 上返回
  /// `/data/user/0/<pkg>/app_flutter`，属于应用私有沙箱，
  /// Syncthing（另一个 App）无论如何都读不到。同步根必须放在共享存储，
  /// 这需要 `MANAGE_EXTERNAL_STORAGE`（「所有文件访问」）权限。
  /// iOS / macOS 上仍然用文档目录（iOS 由 Möbius Sync 之类通过 Files 访问）。
  static const String syncRootName = 'LocalVoiceSync';

  /// Android 共享存储根。写死而不是用 `getExternalStorageDirectory()`：
  /// 后者返回 `/storage/emulated/0/Android/data/<pkg>/files`，
  /// 在 Android 11+ 同样被系统挡在 Syncthing 之外。
  static const String androidSharedRoot = '/storage/emulated/0/Documents';

  /// 只属于本机的数据目录名（数据库、日志），**绝不进入同步目录**。
  /// 多台设备的 SQLite 文件互相覆盖会造成不可逆的数据库损坏。
  static const String localRootName = 'LocalVoiceSyncLocal';

  static const String outboxDirName = 'outbox';
  static const String inboxDirName = 'inbox';

  /// 待办状态目录。每台设备一个 `<deviceId>.json`，**只写自己那份**。
  ///
  /// 为什么不共用一个 `todos.json`：两台手机同时勾待办会写同一个文件，
  /// Syncthing 只能留一份再生成 `*.sync-conflict-*`，用户就得手工合并。
  /// 一设备一文件 → 永远只有一个写入者 → 正常路径下不存在冲突。
  static const String todoStateDirName = 'todos';

  /// 待办页面重读状态文件的节奏。
  ///
  /// 别的手机勾掉一条待办不会产生新的笔记 JSON，所以 `memoListProvider`
  /// 不会动；必须有一条独立的轮询才能把跨设备的改动拉过来。
  /// 文件很小（几 KB），12 秒一次在手机上几乎无感。
  static const Duration todoStatePollInterval = Duration(seconds: 12);

  /// 录音过程中的临时目录。Syncthing 通过 `.stignore` 忽略它，
  /// 保证半截文件永远不会离开这台手机。
  static const String incomingDirName = '.incoming';

  static const String tmpPrefix = '.tmp_';
  static const String memoPrefix = 'memo_';
  static const String deviceIdPrefix = 'dev_';

  // ---------------------------------------------------------------- 数据库
  static const int databaseVersion = 2;
  static const String databaseFileName = 'library.db';

  // ---------------------------------------------------------------- 向量模型
  /// 中文最小的官方 BGE 模型（512 维）。
  ///
  /// 说明：需求里写的 `bge-micro-zh` 在 HuggingFace / ModelScope 上并不存在，
  /// BGE 官方中文系列最小的一档就是 `bge-small-zh-v1.5`。这里用它，
  /// 并且把模型 id 写进数据库和 JSON，未来换模型时可以做灰度与重算。
  static const String embeddingModelId = 'bge-small-zh-v1.5';
  static const int embeddingDim = 512;

  /// BGE 官方要求的**查询前缀**（检索场景专用）。
  ///
  /// BGE 是"非对称检索"模型：文档按原样编码，查询要先加上这句指令再编码。
  /// 官方说明不加也能用，但会掉几个点召回；实测更重要的是它**显著压低
  /// 无关查询的基线分**——同一句无关长句，不加前缀能拿 0.52（10 条记录里
  /// 9 条过线），加了前缀掉到 0.41（一条都过不了），而真正相关的"耳机"
  /// 仍稳在 0.54。区分度就是这么拉开的。
  static const String embeddingQueryInstruction = '为这个句子生成表示以用于检索相关文章：';

  /// 语义检索的**绝对相似度下限**。
  ///
  /// 0.35 这个值是从"余弦相似度"的直觉来的，但对 BGE 系中文模型完全不适用：
  /// 它的向量空间是各向异性的，无关短句之间本来就有 0.2~0.4 的基线，
  /// 长句更是能到 0.5。用 0.35 的结果就是"搜什么都把全部记录翻出来"。
  ///
  /// 实测（10 条真实记录 + 模型自带资产，带查询前缀）：
  /// * 相关（"耳机"→ 耳机故障记录）0.50 ~ 0.65
  /// * 无关短句（"今天天气怎么样"）0.28 ~ 0.35
  /// * 无关长句（"完全不相关的话题比如量子力学"）0.31 ~ 0.41
  ///
  /// 0.45 正好落在这两簇之间。宁可"没找到"也不要"返回一堆不相干的"——
  /// 后者会让用户彻底不信任搜索。
  static const double semanticMinScore = 0.45;

  /// 相对上限：只保留与最高分相差不超过这个幅度的结果。
  ///
  /// 绝对阈值管"该不该有结果"，这个管"该有哪几条"。最强命中 0.65 时，
  /// 0.48 的弱相关就不该挤进来占位置。
  static const double semanticRelativeMargin = 0.12;

  static const String modelAssetPath = 'assets/models/bge-small-zh-v1.5.onnx';
  static const String vocabAssetPath = 'assets/models/vocab.txt';

  /// 送入 BERT 的最大 token 数。手机端算力有限，256 足够覆盖摘要 + 标签。
  static const int maxSequenceLength = 256;

  /// 单次查询返回的语义候选数。
  static const int semanticTopK = 30;

  /// RRF（倒数排名融合）常数，业界常用 60。
  static const int rrfK = 60;

  // ---------------------------------------------------------------- 轮询节奏
  static const Duration amplitudeInterval = Duration(milliseconds: 100);
  static const Duration inboxPollInterval = Duration(seconds: 4);
  static const Duration syncStatusPollInterval = Duration(seconds: 8);
  /// Syncthing REST 超时。
  ///
  /// 别设太小：手机上的 TLS 握手偶尔要 1~2 秒，加上 Android 的省电调度，
  /// 3 秒会把正常的偶发抖动误判成"离线"，状态灯就会闪。
  static const Duration syncthingHttpTimeout = Duration(seconds: 6);

  // ---------------------------------------------------------------- 录音参数
  static const int recordBitRate = 128000;
  static const int recordSampleRate = 44100;

  /// 小于这个字节数的录音视为"空录音"，不入库（避免用户误触产生垃圾条目）。
  static const int minValidAudioBytes = 2048;
}
