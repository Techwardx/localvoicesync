import 'memo.dart';

/// 命中来源。UI 上会用它给结果打不同的标记，让用户知道"为什么这条被搜出来"。
enum HitSource { keyword, semantic, hybrid }

/// 一条搜索结果。
class SearchHit {
  const SearchHit({
    required this.memo,
    required this.score,
    required this.source,
    this.snippet = '',
  });

  final Memo memo;

  /// 融合后的排序分（越大越靠前）。不同来源之间不可直接比较，仅用于排序。
  final double score;
  final HitSource source;

  /// 命中片段，用于列表里做关键词高亮。
  final String snippet;

  SearchHit copyWith({
    Memo? memo,
    double? score,
    HitSource? source,
    String? snippet,
  }) => SearchHit(
    memo: memo ?? this.memo,
    score: score ?? this.score,
    source: source ?? this.source,
    snippet: snippet ?? this.snippet,
  );
}
