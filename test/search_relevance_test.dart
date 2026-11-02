import 'package:flutter_test/flutter_test.dart';
import 'package:local_voice_sync/core/app_config.dart';
import 'package:local_voice_sync/services/database_service.dart';
import 'package:local_voice_sync/services/embedding_isolate.dart';
import 'package:local_voice_sync/services/search_service.dart';

/// 语义检索"搜什么都返回全部"的回归测试。
///
/// 阈值是拿真机数据标定的（见 AppConfig.semanticMinScore 的注释），
/// 这里用的分数就是当时实测出来的那一组，任何改动一旦让行为退化都会红。
void main() {
  VectorHit hit(String id, double score) =>
      VectorHit(memoId: id, score: score);

  group('语义检索的两级过滤', () {
    test('全部低于绝对阈值时一条都不返回', () {
      // "完全不相关的话题比如量子力学" 加前缀后的实测分数（0.35 阈值时代
      // 这组数据会让 10 条记录全部通过，正是用户报的 bug）。
      final kept = SearchService.applyThresholds(<VectorHit>[
        hit('a', 0.41),
        hit('b', 0.40),
        hit('c', 0.35),
        hit('d', 0.31),
      ]);
      expect(kept, isEmpty);
    });

    test('相关的那一簇保留，陪跑的弱相关被相对幅度切掉', () {
      // "耳机" 实测：0.54 / 0.54 / 0.50 是三条耳机故障记录，
      // 0.39 以下跟耳机无关。
      final kept = SearchService.applyThresholds(<VectorHit>[
        hit('qcy-1', 0.54),
        hit('qcy-2', 0.54),
        hit('qcy-3', 0.50),
        hit('other-1', 0.39),
        hit('other-2', 0.39),
      ]);
      expect(kept.map((h) => h.memoId), <String>['qcy-1', 'qcy-2', 'qcy-3']);
    });

    test('强命中时相对幅度会收窄结果', () {
      // "上次那个蓝牙耳机坏了" 实测 0.65/0.65/0.65/0.59/0.49。
      // 绝对阈值 0.45 会放进 0.49，但相对幅度 0.12 把它挡在外面。
      final kept = SearchService.applyThresholds(<VectorHit>[
        hit('a', 0.65),
        hit('b', 0.65),
        hit('c', 0.65),
        hit('d', 0.59),
        hit('e', 0.49),
      ]);
      expect(kept.length, 4);
      expect(kept.map((h) => h.memoId), isNot(contains('e')));
    });

    test('输入无序也按分数取，不依赖上游顺序', () {
      final kept = SearchService.applyThresholds(<VectorHit>[
        hit('low', 0.30),
        hit('best', 0.62),
        hit('mid', 0.58),
      ]);
      expect(kept.first.memoId, 'best');
      expect(kept.map((h) => h.memoId), <String>['best', 'mid']);
    });

    test('空输入不炸', () {
      expect(SearchService.applyThresholds(const <VectorHit>[]), isEmpty);
    });

    test('阈值常量本身要落在实测的两簇之间', () {
      // 相关簇最低 0.50，无关簇最高 0.41（带查询前缀）。
      expect(AppConfig.semanticMinScore, greaterThan(0.41));
      expect(AppConfig.semanticMinScore, lessThan(0.50));
    });
  });

  group('关键词检索的覆盖率下限', () {
    test('短查询要求全中', () {
      expect(DatabaseService.minMatchedTokens(1), 1);
      expect(DatabaseService.minMatchedTokens(2), 2);
    });

    test('长查询至少中一半，避免口语长句把整库翻出来', () {
      expect(DatabaseService.minMatchedTokens(3), 2);
      expect(DatabaseService.minMatchedTokens(4), 2);
      expect(DatabaseService.minMatchedTokens(8), 4);
    });
  });

  group('BGE 查询前缀', () {
    test('前缀存在且是官方那句，不能被悄悄改掉', () {
      expect(AppConfig.embeddingQueryInstruction, '为这个句子生成表示以用于检索相关文章：');
    });
  });
}
