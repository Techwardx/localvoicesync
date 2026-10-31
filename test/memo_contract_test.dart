import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_voice_sync/models/memo.dart';

/// 这份 JSON 就是需求文档里给出的同步契约，逐字段验证解析不会跑偏。
const String _contractJson = '''
{
  "id": "memo_20261031_123000",
  "created_at": "2026-10-31 12:30:00",
  "audio_filename": "memo_20261031_123000.m4a",
  "author": "Dad",
  "summary": "把逆变器接到 Class T 保险丝上",
  "knowledge_points": ["核心知识点 1", "核心知识点 2"],
  "todos": [
    {"task": "购买 Class T 保险丝", "status": "pending"},
    {"task": "检查逆变器接线", "status": "completed"}
  ],
  "tags": ["太阳能", "配线", "PowMr"],
  "raw_transcript": "Whisper 原始转写口语文本...",
  "embedding": [0.012, -0.045, 0.231]
}
''';

void main() {
  group('同步契约解析', () {
    late Memo memo;

    setUp(() {
      final json =
          jsonDecode(_contractJson) as Map<String, dynamic>;
      memo = Memo.fromContractJson(
        json.map((key, value) => MapEntry(key, value)),
        authorDir: 'Dad_Notes',
        deviceId: 'dev_test',
      );
    });

    test('基础字段', () {
      expect(memo.id, 'memo_20261031_123000');
      expect(memo.author, 'Dad');
      expect(memo.authorDir, 'Dad_Notes');
      expect(memo.kind, MemoKind.audio);
      expect(memo.audioFilename, 'memo_20261031_123000.m4a');
      expect(memo.status, MemoStatus.processed);
    });

    test('时间按 "yyyy-MM-dd HH:mm:ss" 解析', () {
      expect(memo.createdAt, DateTime(2026, 10, 31, 12, 30, 0));
    });

    test('TODO 的 status 正确映射成布尔', () {
      expect(memo.todos.length, 2);
      expect(memo.todos[0].task, '购买 Class T 保险丝');
      expect(memo.todos[0].completed, isFalse);
      expect(memo.todos[1].completed, isTrue);
    });

    test('标签与知识点', () {
      expect(memo.tags, ['太阳能', '配线', 'PowMr']);
      expect(memo.knowledgePoints.length, 2);
    });

    test('回写契约时 TODO 又变回 status 字符串', () {
      final round = memo.toContractJson();
      final todos = round['todos']! as List<Object?>;
      final first = todos.first! as Map<String, Object?>;
      expect(first['task'], '购买 Class T 保险丝');
      expect(first['status'], 'pending');
      expect(round['created_at'], '2026-10-31 12:30:00');
    });
  });

  group('数据库行往返', () {
    test('toRow / fromRow 不丢字段', () {
      final json = jsonDecode(_contractJson) as Map<String, dynamic>;
      final memo = Memo.fromContractJson(
        json.map((key, value) => MapEntry(key, value)),
        authorDir: 'Dad_Notes',
        deviceId: 'dev_test',
      );
      final restored = Memo.fromRow(memo.toRow());

      expect(restored.id, memo.id);
      expect(restored.createdAt, memo.createdAt);
      expect(restored.todos.length, memo.todos.length);
      expect(restored.todos[1].completed, isTrue);
      expect(restored.tags, memo.tags);
      expect(restored.status, MemoStatus.processed);
    });

    test('缺字段时给安全默认值，不抛异常', () {
      final memo = Memo.fromContractJson(
        <String, Object?>{'id': 'memo_x', 'author': 'Me'},
        authorDir: 'Me_Notes',
        deviceId: 'dev_test',
      );
      expect(memo.summary, '');
      expect(memo.todos, isEmpty);
      expect(memo.tags, isEmpty);
      expect(memo.rawText, '');
    });

    test('todos 退化成字符串数组也能吃下', () {
      final memo = Memo.fromContractJson(
        <String, Object?>{
          'id': 'memo_y',
          'todos': <Object?>['买菜', '交电费'],
        },
        authorDir: 'Me_Notes',
        deviceId: 'dev_test',
      );
      expect(memo.todos.length, 2);
      expect(memo.todos.first.task, '买菜');
      expect(memo.todos.first.completed, isFalse);
    });
  });

  group('展示辅助', () {
    test('displayTitle 截断过长摘要', () {
      final memo = Memo.fromContractJson(
        <String, Object?>{
          'id': 'memo_z',
          'summary': '这是一段非常长的摘要' * 10,
        },
        authorDir: 'Me_Notes',
        deviceId: 'dev_test',
      );
      expect(memo.displayTitle.length, lessThanOrEqualTo(29));
    });

    test('searchableText 汇总所有可检索字段', () {
      final json = jsonDecode(_contractJson) as Map<String, dynamic>;
      final memo = Memo.fromContractJson(
        json.map((key, value) => MapEntry(key, value)),
        authorDir: 'Dad_Notes',
        deviceId: 'dev_test',
      );
      expect(memo.searchableText, contains('太阳能'));
      expect(memo.searchableText, contains('保险丝'));
      expect(memo.searchableText, contains('Whisper'));
    });
  });
}
