import 'dart:typed_data';

import '../core/app_config.dart';
import '../core/app_log.dart';
import '../models/memo.dart';
import '../models/search_hit.dart';
import 'database_service.dart';
import 'embedding_isolate.dart';

/// 检索模式。`auto` 是默认：能语义就语义 + 关键词一起上。
enum SearchMode { auto, keyword, semantic }

/// 混合检索编排层。
///
/// 两条路各自跑，最后用 **RRF（倒数排名融合）** 合并：
///
/// ```
/// score(d) = Σ 1 / (k + rank_i(d))
/// ```
///
/// 选 RRF 而不是加权求和，是因为 bm25 分数和余弦相似度**量纲完全不同**，
/// 直接相加需要调参且容易在不同数据规模下失衡；RRF 只看排名，天然免疫量纲问题，
/// 也是 Elasticsearch / Vespa 的默认混合方案。
class SearchService {
  SearchService({required DatabaseService db, required EmbeddingEngine engine})
    : _db = db,
      _engine = engine;

  final DatabaseService _db;
  final EmbeddingEngine _engine;

  EmbeddingEngine get engine => _engine;

  /// App 启动后调用：把数据库里的向量灌进 Isolate 内存索引。
  Future<void> warmUp() async {
    if (!_engine.isReady) return;
    try {
      final records = await _db.allVectors();
      await _engine.loadIndex(records);
      AppLog.i('search', '语义索引就绪：${records.length} 条向量');
    } on Object catch (error, stack) {
      AppLog.e('search', '加载向量索引失败', error, stack);
    }
  }

  /// 为单条记录生成并落库向量（新记录入库后调用）。
  Future<bool> indexMemo(Memo memo) async {
    if (!_engine.isReady) return false;
    final text = memo.searchableText.trim();
    if (text.isEmpty) return false;
    final vector = await _engine.embed(text);
    if (vector == null) return false;
    await _db.upsertVector(memo.id, vector);
    await _engine.upsert(memo.id, vector);
    return true;
  }

  /// 批量补齐缺失向量（换模型、或历史数据首次启用语义检索时用）。
  Future<int> rebuildIndex({
    void Function(int done, int total)? onProgress,
  }) async {
    if (!_engine.isReady) return 0;
    final records = await _db.allVectors();
    final indexed = records.map((r) => r.memoId).toSet();
    final memos = await _db.recentMemos(limit: 5000);
    final missing = memos.where((m) => !indexed.contains(m.id)).toList();
    var done = 0;
    for (final memo in missing) {
      if (await indexMemo(memo)) done += 1;
      onProgress?.call(done, missing.length);
    }
    if (done > 0) {
      await warmUp();
    }
    return done;
  }

  Future<List<SearchHit>> search(
    String query, {
    SearchMode mode = SearchMode.auto,
    int limit = 40,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const <SearchHit>[];

    final keywordHits = mode == SearchMode.semantic
        ? const <SearchHit>[]
        : await _db.searchKeyword(trimmed, limit: limit * 2);

    final semanticHits = mode == SearchMode.keyword
        ? const <SearchHit>[]
        : await _semanticHits(trimmed);

    if (keywordHits.isEmpty && semanticHits.isEmpty) return const <SearchHit>[];

    // 纯关键词模式：直接返回 bm25 排序，不再融合。
    if (mode == SearchMode.keyword) {
      return keywordHits.take(limit).toList(growable: false);
    }
    if (mode == SearchMode.semantic) {
      return semanticHits.take(limit).toList(growable: false);
    }
    return _fuse(keywordHits, semanticHits, limit);
  }

  Future<List<SearchHit>> _semanticHits(String query) async {
    if (!_engine.isReady) return const <SearchHit>[];
    final vector = await _engine.embed(query);
    if (vector == null) return const <SearchHit>[];
    final hits = await _engine.search(vector, topK: AppConfig.semanticTopK);
    if (hits.isEmpty) return const <SearchHit>[];

    final memos = await _db.memosByIds(
      hits.map((hit) => hit.memoId).toList(growable: false),
    );
    final result = <SearchHit>[];
    for (final hit in hits) {
      final memo = memos[hit.memoId];
      if (memo == null) continue;
      // 余弦相似度低于 0.35 基本是噪声，直接丢掉，避免"什么都搜得出来"。
      if (hit.score < 0.35) continue;
      result.add(
        SearchHit(
          memo: memo,
          score: hit.score,
          source: HitSource.semantic,
          snippet: _snippet(memo),
        ),
      );
    }
    return result;
  }

  List<SearchHit> _fuse(
    List<SearchHit> keywordHits,
    List<SearchHit> semanticHits,
    int limit,
  ) {
    final scores = <String, double>{};
    final memos = <String, Memo>{};
    final inKeyword = <String>{};
    final inSemantic = <String>{};

    for (var i = 0; i < keywordHits.length; i++) {
      final id = keywordHits[i].memo.id;
      memos[id] = keywordHits[i].memo;
      inKeyword.add(id);
      scores[id] = (scores[id] ?? 0) + 1 / (AppConfig.rrfK + i + 1);
    }
    for (var i = 0; i < semanticHits.length; i++) {
      final id = semanticHits[i].memo.id;
      memos[id] = semanticHits[i].memo;
      inSemantic.add(id);
      scores[id] = (scores[id] ?? 0) + 1 / (AppConfig.rrfK + i + 1);
    }

    final ordered = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return ordered.take(limit).map((entry) {
      final inBoth = inKeyword.contains(entry.key) &&
          inSemantic.contains(entry.key);
      final memo = memos[entry.key]!;
      return SearchHit(
        memo: memo,
        score: entry.value,
        source: inBoth
            ? HitSource.hybrid
            : (inSemantic.contains(entry.key)
                  ? HitSource.semantic
                  : HitSource.keyword),
        snippet: _snippet(memo),
      );
    }).toList(growable: false);
  }

  static String _snippet(Memo memo) {
    final source = memo.summary.trim().isNotEmpty
        ? memo.summary.trim()
        : memo.rawText.trim();
    final flat = source.replaceAll(RegExp(r'\s+'), ' ');
    if (flat.length <= 90) return flat;
    return '${flat.substring(0, 90)}…';
  }

  /// 供设置页展示的引擎状态。
  Map<String, Object?> engineStatus() => <String, Object?>{
    'ready': _engine.isReady,
    'indexed': _engine.indexedCount,
    'dim': _engine.dimension,
    'error': _engine.lastError,
    'fts': _db.ftsAvailable,
  };
}

/// 便于测试与调试：把向量打印成可读字符串。
String debugVector(Float32List? vector) {
  if (vector == null) return 'null';
  final head = vector.take(4).map((v) => v.toStringAsFixed(4)).join(', ');
  return '[$head, …] dim=${vector.length}';
}
