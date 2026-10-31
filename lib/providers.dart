import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/app_config.dart';
import 'core/family_member.dart';
import 'models/memo.dart';
import 'models/search_hit.dart';
import 'models/sync_status.dart';
import 'services/search_service.dart';
import 'services/settings_store.dart';
import 'services/services.dart';
import 'services/syncthing_service.dart';

/// 服务容器。在 `main()` 里用 `overrideWithValue` 注入真实实例。
final servicesProvider = Provider<Services>(
  (ref) => throw UnimplementedError('servicesProvider 必须被 override'),
);

// ------------------------------------------------------------------ 配置

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.read(servicesProvider).initialSettings;

  Future<void> _persist(AppSettings next) async {
    state = next;
    await ref.read(servicesProvider).settingsStore.save(next);
  }

  Future<void> selectMember(FamilyMember member) async {
    final services = ref.read(servicesProvider);
    // 换人就要换目录，先确保目录骨架存在，避免第一条录音找不到落点。
    await services.paths.ensureMemberLayout(member.dirName);
    await _persist(
      state.copyWith(
        authorId: member.id,
        customAuthorName: member.id == FamilyMember.customId
            ? member.label
            : '',
      ),
    );
  }

  Future<void> renameCustom(String name) async {
    final member = FamilyMember.resolve(
      authorId: FamilyMember.customId,
      customName: name,
    );
    await ref.read(servicesProvider).paths.ensureMemberLayout(member.dirName);
    await _persist(
      state.copyWith(
        authorId: FamilyMember.customId,
        customAuthorName: member.label,
      ),
    );
  }

  Future<void> updateSyncthing(SyncthingConfig config) async {
    await _persist(state.copyWith(syncthing: config));
    ref.invalidate(syncStatusProvider);
  }

  Future<void> finishOnboarding() async {
    await _persist(state.copyWith(onboardingDone: true));
  }
}

// ------------------------------------------------------------------ 向量引擎

enum EmbeddingStatus { loading, ready, unavailable }

class EmbeddingState {
  const EmbeddingState({
    required this.status,
    this.message = '',
    this.indexed = 0,
  });

  final EmbeddingStatus status;
  final String message;
  final int indexed;

  bool get isReady => status == EmbeddingStatus.ready;
}

final embeddingStateProvider =
    NotifierProvider<EmbeddingNotifier, EmbeddingState>(
      EmbeddingNotifier.new,
    );

class EmbeddingNotifier extends Notifier<EmbeddingState> {
  bool _disposed = false;

  @override
  EmbeddingState build() {
    ref.onDispose(() => _disposed = true);
    unawaited(_initialise());
    return const EmbeddingState(
      status: EmbeddingStatus.loading,
      message: '正在加载本地向量模型…',
    );
  }

  Future<void> _initialise() async {
    final services = ref.read(servicesProvider);
    final assets = await Services.loadEmbeddingAssets();
    if (assets == null) {
      _safeSet(
        const EmbeddingState(
          status: EmbeddingStatus.unavailable,
          message: '未安装本地向量模型，当前为纯关键词检索',
        ),
      );
      return;
    }
    final ok = await services.embeddingEngine.start(
      modelBytes: assets.modelBytes,
      vocabText: assets.vocabText,
    );
    if (!ok) {
      _safeSet(
        EmbeddingState(
          status: EmbeddingStatus.unavailable,
          message: services.embeddingEngine.lastError ?? '向量模型加载失败',
        ),
      );
      return;
    }
    await services.search.warmUp();
    _safeSet(
      EmbeddingState(
        status: EmbeddingStatus.ready,
        message: '语义检索已就绪',
        indexed: services.embeddingEngine.indexedCount,
      ),
    );
  }

  void _safeSet(EmbeddingState next) {
    if (_disposed) return;
    state = next;
  }
}

// ------------------------------------------------------------------ 记录列表

final memoListProvider =
    AsyncNotifierProvider<MemoListNotifier, List<Memo>>(MemoListNotifier.new);

class MemoListNotifier extends AsyncNotifier<List<Memo>> {
  @override
  Future<List<Memo>> build() async {
    final services = ref.watch(servicesProvider);
    final subscription = services.inbox.changes.listen((_) {
      ref.invalidateSelf();
    });
    ref.onDispose(subscription.cancel);
    return services.database.recentMemos(limit: 200);
  }

  Future<void> refresh() async {
    final services = ref.read(servicesProvider);
    state = AsyncData(await services.database.recentMemos(limit: 200));
  }

  /// 写一条文本随手记。返回 null 表示失败（UI 据此提示，不抛异常）。
  Future<Memo?> addTextNote(String content) async {
    final services = ref.read(servicesProvider);
    final settings = ref.read(settingsProvider);
    try {
      final memo = await services.textNotes.create(
        member: settings.member,
        deviceId: settings.deviceId,
        content: content,
        createdAt: DateTime.now(),
      );
      // 文本记录本地立刻有内容，可以马上算向量，不必等 Mac。
      await services.search.indexMemo(memo);
      await refresh();
      return memo;
    } on Object {
      return null;
    }
  }

  Future<void> toggleTodo(String memoId, int index, bool completed) async {
    final services = ref.read(servicesProvider);
    await services.database.setTodoCompleted(memoId, index, completed);
    await refresh();
  }

  Future<void> remove(String memoId) async {
    final services = ref.read(servicesProvider);
    await services.database.deleteMemo(memoId);
    await refresh();
  }

  Future<Memo?> byId(String memoId) async {
    final services = ref.read(servicesProvider);
    return services.database.memoById(memoId);
  }
}

// ------------------------------------------------------------------ 连接状态

final syncStatusProvider = NotifierProvider<SyncStatusNotifier, SyncStatus>(
  SyncStatusNotifier.new,
);

class SyncStatusNotifier extends Notifier<SyncStatus> {
  Timer? _timer;
  bool _busy = false;
  bool _disposed = false;

  @override
  SyncStatus build() {
    ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
      _timer = null;
    });
    _timer = Timer.periodic(
      AppConfig.syncStatusPollInterval,
      (_) => unawaited(refresh()),
    );
    unawaited(refresh());
    final services = ref.read(servicesProvider);
    final configured = ref.read(settingsProvider).syncthing.isConfigured;
    // 已经填过配置的，别先给一个"未配置"的灰灯再跳变——那会让人以为配置没保存。
    return SyncStatus(
      state: configured ? LinkState.offline : LinkState.unconfigured,
      pendingFiles: services.initialPending,
      detail: configured ? '正在探测…' : '未配置 Syncthing',
    );
  }

  Future<void> refresh() async {
    if (_busy || _disposed) return;
    _busy = true;
    try {
      final services = ref.read(servicesProvider);
      final settings = ref.read(settingsProvider);
      final pending = await services.database.pendingCount();
      final status = await services.syncthing.probe(
        config: settings.syncthing,
        localPending: pending,
      );
      if (!_disposed) state = status;
    } on Object {
      // 探测失败本身就是"离线"的一种表现，不往 UI 抛错。
    } finally {
      _busy = false;
    }
  }
}

// ------------------------------------------------------------------ 检索

class SearchState {
  const SearchState({
    this.query = '',
    this.mode = SearchMode.auto,
    this.loading = false,
    this.hits = const <SearchHit>[],
    this.error,
    this.hasRun = false,
  });

  final String query;
  final SearchMode mode;
  final bool loading;
  final List<SearchHit> hits;
  final String? error;
  final bool hasRun;

  SearchState copyWith({
    String? query,
    SearchMode? mode,
    bool? loading,
    List<SearchHit>? hits,
    String? error,
    bool? hasRun,
  }) => SearchState(
    query: query ?? this.query,
    mode: mode ?? this.mode,
    loading: loading ?? this.loading,
    hits: hits ?? this.hits,
    error: error,
    hasRun: hasRun ?? this.hasRun,
  );
}

final searchStateProvider = NotifierProvider<SearchNotifier, SearchState>(
  SearchNotifier.new,
);

class SearchNotifier extends Notifier<SearchState> {
  Timer? _debounce;
  bool _disposed = false;

  @override
  SearchState build() {
    ref.onDispose(() {
      _disposed = true;
      _debounce?.cancel();
    });
    return const SearchState();
  }

  /// 输入变化时防抖 250ms，避免每个字符都跑一次 ONNX 推理。
  void onQueryChanged(String query) {
    state = state.copyWith(query: query);
    _debounce?.cancel();
    if (query.trim().isEmpty) {
      state = state.copyWith(hits: const <SearchHit>[], hasRun: false);
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(run()),
    );
  }

  void setMode(SearchMode mode) {
    state = state.copyWith(mode: mode);
    unawaited(run());
  }

  Future<void> run() async {
    final query = state.query.trim();
    if (query.isEmpty) return;
    state = state.copyWith(loading: true);
    try {
      final services = ref.read(servicesProvider);
      final hits = await services.search.search(query, mode: state.mode);
      if (_disposed) return;
      state = state.copyWith(
        loading: false,
        hits: hits,
        hasRun: true,
        error: null,
      );
    } on Object catch (error) {
      if (_disposed) return;
      state = state.copyWith(loading: false, error: '$error', hasRun: true);
    }
  }

  void reset() {
    _debounce?.cancel();
    state = const SearchState();
  }
}

// ------------------------------------------------------------------ 标签云

final tagCountsProvider = FutureProvider<Map<String, int>>((ref) async {
  // 依赖列表：新增/删除记录后自动重算，不需要手工 invalidate。
  ref.watch(memoListProvider);
  return ref.watch(servicesProvider).database.tagCounts();
});
