import 'dart:math' as math;
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

  /// 语义检索的**唯一正确用法**：查询走 [EmbeddingEngine.embedQuery]（带
  /// BGE 检索指令前缀），然后两级过滤。
  ///
  /// 为什么必须两级：
  /// * **绝对阈值** [AppConfig.semanticMinScore] 决定"这次搜索到底有没有结果"。
  ///   只靠它不够——BGE 的向量空间各向异性，同一个查询对 10 条记录的分数
  ///   常常是 0.54/0.54/0.50/0.49/0.39…，一条明显的分界线都没有。
  /// * **相对幅度** [AppConfig.semanticRelativeMargin] 决定"该留哪几条"。
  ///   最强命中 0.65 时，0.50 的那条纯属陪跑，不该占位置。
  ///
  /// 两级都过不了就返回空 —— 界面显示"没找到"，比返回一堆不相干的诚实得多。
  Future<List<SearchHit>> _semanticHits(String query) async {
    if (!_engine.isReady) return const <SearchHit>[];
    final vector = await _engine.embedQuery(query);
    if (vector == null) return const <SearchHit>[];

    final hits = await _engine.search(vector, topK: AppConfig.semanticTopK);
    if (hits.isEmpty) return const <SearchHit>[];

    final kept = applyThresholds(hits);
    AppLog.d(
      'search',
      '语义检索「$query」：最高 ${hits.first.score.toStringAsFixed(3)}，'
      '保留 ${kept.length}/${hits.length} 条',
    );
    if (kept.isEmpty) return const <SearchHit>[];

    final memos = await _db.memosByIds(
      kept.map((hit) => hit.memoId).toList(growable: false),
    );
    final result = <SearchHit>[];
    for (final hit in kept) {
      final memo = memos[hit.memoId];
      if (memo == null) continue;
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

  /// 语义结果的取舍规则，抽成纯函数以便单测。
  ///
  /// 输入不要求有序（内部会先按分数降序排），因为 worker 侧的顺序是实现细节，
  /// 不该让正确性依赖它。
  static List<VectorHit> applyThresholds(
    List<VectorHit> hits, {
    double minScore = AppConfig.semanticMinScore,
    double margin = AppConfig.semanticRelativeMargin,
  }) {
    if (hits.isEmpty) return const <VectorHit>[];
    final sorted = <VectorHit>[...hits]
      ..sort((a, b) => b.score.compareTo(a.score));
    final cutoff = math.max(minScore, sorted.first.score - margin);
    return sorted.where((hit) => hit.score >= cutoff).toList(growable: false);
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

  /// 检索自检：把"语义检索到底有没有区分度"直接摊成文字。
  ///
  /// 语义检索出问题时，界面上只表现为"结果不对"，完全看不出是模型没加载、
  /// 阈值不合适、还是索引里根本没有向量。这个自检跑三条探测查询：
  ///
  /// * 取最近一条记录的开头 12 个字 —— **必须命中它自己**（正例）
  /// * "今天天气怎么样" —— **不该命中**（负例，短句）
  /// * "完全不相关的话题比如量子力学" —— **不该命中**（负例，长句，最容易被
  ///   各向异性带偏的那一类，也是当初 0.35 阈值翻车的元凶）
  ///
  /// 三条的判定都符合预期，说明阈值是合适的；正例不中说明模型/索引有问题；
  /// 负例命中说明阈值要往上调。
  Future<List<String>> selfCheck() async {
    final status = engineStatus();
    final lines = <String>[
      '向量引擎：${status['ready'] == true ? '就绪' : '未就绪（${status['error'] ?? '无错误信息'}）'}',
      '索引条数：${status['indexed']}（维度 ${status['dim']}）',
      '全文索引：${status['fts'] == true ? 'FTS5 可用' : 'FTS5 未编译，用内置命中数评分'}',
      '语义阈值：绝对 ${AppConfig.semanticMinScore}，'
          '相对最高分 ±${AppConfig.semanticRelativeMargin}',
    ];
    if (!_engine.isReady) return lines;

    final recent = await _db.recentMemos(limit: 1);
    final positive = recent.isEmpty
        ? '测试'
        : _probePhrase(recent.first);

    final probes = <({String query, bool expectHit})>[
      (query: positive, expectHit: true),
      (query: '今天天气怎么样', expectHit: false),
      (query: '完全不相关的话题比如量子力学', expectHit: false),
    ];

    for (final probe in probes) {
      final vector = await _engine.embedQuery(probe.query);
      if (vector == null) {
        lines.add('「${probe.query}」→ 查询向量计算失败');
        continue;
      }
      final raw = await _engine.search(vector, topK: 3);
      if (raw.isEmpty) {
        lines.add('「${probe.query}」→ 索引里没有可比较的向量');
        continue;
      }
      final shown = raw
          .map((hit) => hit.score.toStringAsFixed(3))
          .join(' / ');
      final kept = await _semanticHits(probe.query);
      final verdict = probe.expectHit
          ? (kept.isNotEmpty ? '✓ 命中' : '✗ 该命中却没有')
          : (kept.isEmpty ? '✓ 正确排除' : '✗ 不该命中却返回 ${kept.length} 条');
      lines
        ..add('「${probe.query}」top3 分数：$shown')
        ..add('    保留 ${kept.length} 条 → $verdict');
    }
    return lines;
  }

  /// 从一条记录里取一段"应该能搜回自己"的探针文本。
  static String _probePhrase(Memo memo) {
    final source = memo.summary.trim().isNotEmpty
        ? memo.summary.trim()
        : memo.rawText.trim();
    final flat = source.replaceAll(RegExp(r'\s+'), '');
    if (flat.isEmpty) return '测试';
    return flat.length <= 12 ? flat : flat.substring(0, 12);
  }
}

/// 便于测试与调试：把向量打印成可读字符串。
String debugVector(Float32List? vector) {
  if (vector == null) return 'null';
  final head = vector.take(4).map((v) => v.toStringAsFixed(4)).join(', ');
  return '[$head, …] dim=${vector.length}';
}
