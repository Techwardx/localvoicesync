import 'package:flutter_test/flutter_test.dart';
import 'package:local_voice_sync/services/fts_tokenizer.dart';

void main() {
  group('FtsTokenizer 索引切分', () {
    test('中文长词切出单字与二元组', () {
      final text = FtsTokenizer.indexText('太阳能配线');
      final tokens = text.split(' ');
      expect(tokens, contains('太阳'));
      expect(tokens, contains('阳能'));
      expect(tokens, contains('配线'));
      // 单字也要在，保证单字查询能命中
      expect(tokens, contains('配'));
    });

    test('中英混排不会把中文粘进英文词', () {
      final tokens = FtsTokenizer.indexText('买 Class T 保险丝').split(' ');
      expect(tokens, contains('class'));
      expect(tokens, contains('t'));
      expect(tokens, contains('保险'));
      expect(tokens, contains('险丝'));
      expect(tokens.any((t) => t.contains('class保')), isFalse);
    });

    test('下划线与连字符保留在词内', () {
      final tokens = FtsTokenizer.indexText('qwen3.5:9b-q4_K_M').split(' ');
      expect(tokens, contains('qwen3'));
      expect(tokens, contains('9b-q4_k_m'));
    });

    test('标点不会产生 token', () {
      expect(FtsTokenizer.indexText('，，。 ！？').trim(), isEmpty);
      expect(FtsTokenizer.queryTokens('—— …… ！'), isEmpty);
    });
  });

  group('FtsTokenizer 查询表达式', () {
    test('中文查询只取二元组', () {
      final expression = FtsTokenizer.buildMatchQuery('太阳能');
      expect(expression, '"太阳" OR "阳能"');
    });

    test('单字查询保留单字', () {
      expect(FtsTokenizer.buildMatchQuery('线'), '"线"');
    });

    test('AND 模式用 AND 连接', () {
      final expression = FtsTokenizer.buildMatchQuery('配线方案', useAnd: true);
      expect(expression, contains(' AND '));
      expect(expression, isNot(contains(' OR ')));
    });

    test('纯标点返回 null', () {
      expect(FtsTokenizer.buildMatchQuery('—— …… ！'), isNull);
      expect(FtsTokenizer.buildMatchQuery(''), isNull);
    });

    test('重复 token 去重', () {
      final expression = FtsTokenizer.buildMatchQuery('保险丝保险丝');
      final parts = expression!.split(' OR ');
      expect(parts.toSet().length, parts.length);
    });
  });
}
