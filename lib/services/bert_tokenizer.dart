/// BERT WordPiece 分词器（纯 Dart，无原生依赖）。
///
/// BGE 系列模型要求输入是 BERT 的 `input_ids / attention_mask / token_type_ids`，
/// 而 Flutter 生态里没有一个能同时支持 iOS / Android / macOS 的现成分词插件，
/// 所以这里直接实现标准算法：
///
/// 1. **基础切分**：转小写、去控制字符、把 CJK 字符逐个用空格包起来
///    （BERT 的经典做法，中文因此天然按字切）；
/// 2. **WordPiece**：对每个词做「最长前缀匹配 + `##` 续接」；
/// 3. **拼装**：`[CLS] ... [SEP]`，补 `[PAD]` 到固定长度。
///
/// vocab.txt 从 HuggingFace 下载，一行一个 token，行号即 id。
class BertTokenizer {
  BertTokenizer(this._vocab);

  final Map<String, int> _vocab;

  static const int padId = 0;
  static const int unkId = 100;
  static const int clsId = 101;
  static const int sepId = 102;

  /// 单个词最多切多少个 subword（防止病态输入拖慢推理）。
  static const int _maxCharsPerWord = 100;

  factory BertTokenizer.fromVocabText(String vocabText) {
    final vocab = <String, int>{};
    final lines = vocabText.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final token = lines[i].replaceAll('\r', '');
      if (token.isEmpty && i != 0) continue;
      vocab.putIfAbsent(token, () => i);
    }
    if (vocab.isEmpty) {
      throw const FormatException('vocab.txt 为空或格式不正确');
    }
    return BertTokenizer(vocab);
  }

  int get size => _vocab.length;

  /// 把一段文本编码成模型输入。
  TokenizedInput encode(String text, {required int maxLength}) {
    final tokens = <int>[clsId];
    for (final word in _basicTokenize(text)) {
      for (final id in _wordPiece(word)) {
        if (tokens.length >= maxLength - 1) break;
        tokens.add(id);
      }
      if (tokens.length >= maxLength - 1) break;
    }
    tokens.add(sepId);

    final length = tokens.length;
    final inputIds = List<int>.filled(maxLength, padId);
    final attentionMask = List<int>.filled(maxLength, 0);
    for (var i = 0; i < length; i++) {
      inputIds[i] = tokens[i];
      attentionMask[i] = 1;
    }
    return TokenizedInput(
      inputIds: inputIds,
      attentionMask: attentionMask,
      tokenTypeIds: List<int>.filled(maxLength, 0),
      tokenCount: length,
    );
  }

  List<String> _basicTokenize(String text) {
    final cleaned = StringBuffer();
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      if (_isControl(rune)) continue;
      if (_isWhitespace(rune)) {
        cleaned.write(' ');
      } else if (_isCjk(rune)) {
        // 中文逐字切开，交给 WordPiece 查单字
        cleaned
          ..write(' ')
          ..write(ch)
          ..write(' ');
      } else {
        cleaned.write(ch.toLowerCase());
      }
    }

    final words = <String>[];
    for (final chunk in cleaned.toString().split(' ')) {
      if (chunk.isEmpty) continue;
      // 标点单独成词，避免 "配线，" 这种把标点粘进 token 的情况
      final buffer = StringBuffer();
      for (final rune in chunk.runes) {
        final ch = String.fromCharCode(rune);
        if (_isPunctuation(rune)) {
          if (buffer.isNotEmpty) {
            words.add(buffer.toString());
            buffer.clear();
          }
          words.add(ch);
        } else {
          buffer.write(ch);
        }
      }
      if (buffer.isNotEmpty) words.add(buffer.toString());
    }
    return words;
  }

  List<int> _wordPiece(String word) {
    if (word.isEmpty) return const <int>[];
    final direct = _vocab[word];
    if (direct != null) return <int>[direct];

    final ids = <int>[];
    var start = 0;
    while (start < word.length) {
      var end = word.length;
      final limit = start + _maxCharsPerWord;
      if (end > limit) end = limit;
      int? matched;
      while (start < end) {
        var piece = word.substring(start, end);
        if (start > 0) piece = '##$piece';
        final id = _vocab[piece];
        if (id != null) {
          matched = id;
          break;
        }
        end -= 1;
      }
      if (matched == null) {
        // 整词都没匹配上，退化成 [UNK]
        return <int>[unkId];
      }
      ids.add(matched);
      start = end;
    }
    return ids;
  }

  static bool _isWhitespace(int rune) =>
      rune == 0x20 || rune == 0x09 || rune == 0x0A || rune == 0x0D;

  static bool _isControl(int rune) =>
      (rune >= 0x00 && rune <= 0x1F) || rune == 0x7F;

  static bool _isCjk(int rune) =>
      (rune >= 0x4E00 && rune <= 0x9FFF) ||
      (rune >= 0x3400 && rune <= 0x4DBF) ||
      (rune >= 0xF900 && rune <= 0xFAFF) ||
      (rune >= 0x3040 && rune <= 0x30FF) ||
      (rune >= 0xAC00 && rune <= 0xD7AF);

  static bool _isPunctuation(int rune) {
    // ASCII 标点
    if ((rune >= 0x21 && rune <= 0x2F) ||
        (rune >= 0x3A && rune <= 0x40) ||
        (rune >= 0x5B && rune <= 0x60) ||
        (rune >= 0x7B && rune <= 0x7E)) {
      return true;
    }
    // 常见全角标点
    const fullWidth = <int>{
      0x3001, 0x3002, 0xFF0C, 0xFF1A, 0xFF1B, 0xFF01, 0xFF1F,
      0x201C, 0x201D, 0x2018, 0x2019, 0xFF08, 0xFF09, 0x3010,
      0x3011, 0x300A, 0x300B, 0x2014, 0x2026, 0xFF05,
    };
    return fullWidth.contains(rune);
  }
}

/// 模型输入三件套。
class TokenizedInput {
  const TokenizedInput({
    required this.inputIds,
    required this.attentionMask,
    required this.tokenTypeIds,
    required this.tokenCount,
  });

  final List<int> inputIds;
  final List<int> attentionMask;
  final List<int> tokenTypeIds;

  /// 含 `[CLS]` / `[SEP]` 的真实 token 数。
  final int tokenCount;
}
