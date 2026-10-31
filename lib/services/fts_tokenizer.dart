/// 中文 FTS5 分词。
///
/// SQLite 的 `unicode61` 分词器不认识中文：一整段"太阳能配线方案"会被当成
/// **一个** token，用户搜"配线"永远匹配不到。`trigram` 分词器能解决，
/// 但它要 SQLite ≥ 3.34，而 Android 系统自带的 SQLite 版本参差不齐。
///
/// 所以这里自己做切分，只依赖最基础的 `unicode61`：
/// - 索引时：中文连续串切成 **单字 + 相邻二元组**（"太阳能" → 太 太阳 阳 阳能 能）；
/// - 查询时：只切二元组（"太阳能" → 太阳 阳能）。
///
/// 这样"配线"能命中"太阳能配线"，"太阳能"也能命中，且不依赖任何扩展。
class FtsTokenizer {
  const FtsTokenizer._();

  static bool _isCjk(int rune) {
    return (rune >= 0x4E00 && rune <= 0x9FFF) || // CJK 统一表意文字
        (rune >= 0x3400 && rune <= 0x4DBF) || // 扩展 A
        (rune >= 0xF900 && rune <= 0xFAFF) || // 兼容表意文字
        (rune >= 0x3040 && rune <= 0x30FF) || // 日文假名
        (rune >= 0xAC00 && rune <= 0xD7AF); // 韩文
  }

  static bool _isWordRune(int rune) {
    final isDigit = rune >= 0x30 && rune <= 0x39;
    final isUpper = rune >= 0x41 && rune <= 0x5A;
    final isLower = rune >= 0x61 && rune <= 0x7A;
    // 允许下划线与连字符出现在词内，方便 "class-t"、"q4_k_m" 这类术语
    return isDigit || isUpper || isLower || rune == 0x5F || rune == 0x2D;
  }

  static List<String> _tokenize(String text, {required bool forIndex}) {
    final tokens = <String>[];
    final word = StringBuffer();
    final cjkRun = <int>[];

    void flushWord() {
      if (word.isEmpty) return;
      tokens.add(word.toString().toLowerCase());
      word.clear();
    }

    void flushCjk() {
      if (cjkRun.isEmpty) return;
      if (cjkRun.length == 1) {
        tokens.add(String.fromCharCode(cjkRun.first));
      } else {
        if (forIndex) {
          for (final rune in cjkRun) {
            tokens.add(String.fromCharCode(rune));
          }
        }
        for (var i = 0; i + 1 < cjkRun.length; i++) {
          tokens.add(
            '${String.fromCharCode(cjkRun[i])}'
            '${String.fromCharCode(cjkRun[i + 1])}',
          );
        }
      }
      cjkRun.clear();
    }

    for (final rune in text.runes) {
      if (_isCjk(rune)) {
        flushWord();
        cjkRun.add(rune);
      } else if (_isWordRune(rune)) {
        flushCjk();
        word.writeCharCode(rune);
      } else {
        flushCjk();
        flushWord();
      }
    }
    flushCjk();
    flushWord();
    return tokens;
  }

  /// 索引文本：单字 + 二元组，用于写入 `memos.search_text`。
  static String indexText(String text) =>
      _tokenize(text, forIndex: true).join(' ');

  /// 查询 token：中文只取二元组，英文取整词。
  static List<String> queryTokens(String text) =>
      _tokenize(text, forIndex: false);

  /// 组装 FTS5 `MATCH` 表达式。
  ///
  /// 返回 `null` 表示查询里没有任何有效字符（例如全是标点）。
  static String? buildMatchQuery(String raw, {bool useAnd = false}) {
    final tokens = queryTokens(raw);
    if (tokens.isEmpty) return null;
    // 去重并保持顺序，避免 "a a a" 这种重复条件拖慢查询
    final unique = <String>[];
    final seen = <String>{};
    for (final token in tokens) {
      if (seen.add(token)) unique.add(token);
    }
    final joiner = useAnd ? ' AND ' : ' OR ';
    return unique.map((t) => '"$t"').join(joiner);
  }
}
