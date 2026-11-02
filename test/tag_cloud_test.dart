import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_voice_sync/services/database_service.dart';

/// 标签云的排序规则：**最近使用优先**，不是出现次数优先。
///
/// 搜索页默认只露 3 个，露错了用户会觉得"这不是我最近记的东西"。
void main() {
  String tags(List<String> values) => jsonEncode(values);

  group('标签按最近使用排序', () {
    test('最新记录里的标签排最前，即使它只出现过一次', () {
      // 数据库按 created_at 倒序给出，第一条是最新的。
      final result = DatabaseService.orderTagsByRecency([
        tags(['万圣节', '要糖']),
        tags(['蓝牙耳机', '硬件维修']),
        tags(['蓝牙耳机']),
      ]);

      expect(result.map((e) => e.tag).toList(), <String>[
        '万圣节',
        '要糖',
        '蓝牙耳机',
        '硬件维修',
      ]);
    });

    test('次数照常累加，只是不参与排序', () {
      final result = DatabaseService.orderTagsByRecency([
        tags(['新标签']),
        tags(['老标签']),
        tags(['老标签']),
        tags(['老标签']),
      ]);

      expect(result.first.tag, '新标签');
      expect(result.first.count, 1);
      // 老标签出现 3 次但排在后面 —— 这正是"最近优先"的语义。
      expect(result.last.tag, '老标签');
      expect(result.last.count, 3);
    });

    test('同一条记录里的重复标签只算一次顺序、次数照加', () {
      final result = DatabaseService.orderTagsByRecency([
        tags(['A', 'A', 'B']),
      ]);
      expect(result.map((e) => e.tag).toList(), <String>['A', 'B']);
      expect(result.first.count, 2);
      expect(result.last.count, 1);
    });

    test('坏 JSON、空列、空标签都被跳过，不会让整个标签云挂掉', () {
      final result = DatabaseService.orderTagsByRecency([
        '{不是数组}',
        null,
        '',
        'not json at all',
        tags(['  ', '正常']),
      ]);
      expect(result.map((e) => e.tag).toList(), <String>['正常']);
    });

    test('空输入返回空列表', () {
      expect(DatabaseService.orderTagsByRecency(const <String?>[]), isEmpty);
    });
  });
}
