import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_voice_sync/models/todo.dart';

/// 待办同步里最容易写错、又最不能在真机上试错的三件事：
/// 稳定 key、多设备 LWW 合并、已完成折叠分组。全部抽成纯函数后在这里锁死。
void main() {
  group('笔记待办的稳定 key', () {
    test('同一条任务在不同空白/大小写下生成同一个 key', () {
      expect(
        TodoKeys.forNote('memo_20261108_153000', '  买  牛奶  '),
        'note:memo_20261108_153000:买 牛奶',
      );
      expect(
        TodoKeys.forNote('memo_1', 'QCY T20'),
        TodoKeys.forNote('memo_1', '  qcy   t20 '),
      );
      expect(TodoKeys.normalizeTask('换\n保险\t丝'), '换 保险 丝');
    });

    test('不同笔记、不同任务不会撞 key', () {
      final a = TodoKeys.forNote('memo_1', '买牛奶');
      final b = TodoKeys.forNote('memo_2', '买牛奶');
      final c = TodoKeys.forNote('memo_1', '买酸奶');
      expect(<String>{a, b, c}.length, 3);
    });
  });

  group('状态文件解析', () {
    test('标准文件能读出勾选记录与手工待办', () {
      final doc = TodoStateDoc.tryParseText(
        jsonEncode(<String, Object?>{
          'schema_version': 1,
          'device_id': 'dev_a',
          'updated_at': 1000,
          'states': <String, Object?>{
            'note:memo_1:买牛奶': <String, Object?>{
              'completed': true,
              'updated_at': 900,
              'memo_id': 'memo_1',
              'index': 0,
            },
          },
          'manual': <Object?>[
            <String, Object?>{
              'id': 'todo_1',
              'task': '交电费',
              'completed': false,
              'created_at': 800,
              'updated_at': 800,
              'author': 'Me',
              'device_id': 'dev_a',
            },
          ],
        }),
      );

      expect(doc, isNotNull);
      expect(doc!.states.length, 1);
      expect(doc.states.values.first.completed, isTrue);
      expect(doc.manual['todo_1']!.task, '交电费');
      expect(doc.manual['todo_1']!.deleted, isFalse);
    });

    test('坏 JSON、非对象、半截文件都不抛异常', () {
      expect(TodoStateDoc.tryParseText('{不是 json'), isNull);
      expect(TodoStateDoc.tryParseText('[]'), isNull);
      expect(TodoStateDoc.tryParseText('null'), isNull);
      final empty = TodoStateDoc.tryParseText('{}', fallbackDeviceId: 'dev_x');
      expect(empty!.deviceId, 'dev_x');
      expect(empty.states, isEmpty);
      expect(empty.manual, isEmpty);
    });

    test('缺时间戳按 0 处理，绝不拿"现在"补（否则会赢过新记录）', () {
      final doc = TodoStateDoc.tryParseText(
        jsonEncode(<String, Object?>{
          'states': <String, Object?>{
            'k': <String, Object?>{'completed': true},
          },
        }),
      );
      expect(doc!.states['k']!.updatedAt, 0);
    });

    test('status / done 等旧写法也能识别', () {
      final manual = ManualTodo.tryParse(<String, Object?>{
        'id': 'todo_old',
        'task': '取快递',
        'status': 'completed',
        'created_at': 1,
        'updated_at': 2,
      });
      expect(manual!.completed, isTrue);
    });

    test('toJson → tryParse 往返不丢字段', () {
      var doc = TodoStateDoc.empty('dev_a');
      doc = doc.withState(
        'note:memo_1:买牛奶',
        const CompletionState(
          completed: true,
          updatedAt: 1234,
          memoId: 'memo_1',
          index: 0,
        ),
      );
      doc = doc.withManual(
        const ManualTodo(
          id: 'todo_1',
          task: '买牛奶',
          completed: false,
          createdAt: 1000,
          updatedAt: 1000,
          author: 'Me',
          deviceId: 'dev_a',
        ),
      );
      final roundTrip = TodoStateDoc.tryParseText(jsonEncode(doc.toJson()));
      expect(roundTrip!.states.length, 1);
      expect(roundTrip.states.values.first.updatedAt, 1234);
      expect(roundTrip.manual['todo_1']!.task, '买牛奶');
    });
  });

  group('多设备合并（last-write-wins）', () {
    TodoStateDoc doc(
      String device,
      Map<String, CompletionState> states,
      Map<String, ManualTodo> manual,
    ) =>
        TodoStateDoc(
          schemaVersion: 1,
          deviceId: device,
          updatedAt: 0,
          states: states,
          manual: manual,
        );

    test('同一 key 取 updated_at 更大的那份', () {
      final older = doc('dev_a', <String, CompletionState>{
        'k': const CompletionState(
          completed: true,
          updatedAt: 100,
          memoId: 'm1',
          index: 0,
        ),
      }, <String, ManualTodo>{});
      final newer = doc('dev_b', <String, CompletionState>{
        'k': const CompletionState(
          completed: false,
          updatedAt: 200,
          memoId: 'm1',
          index: 0,
        ),
      }, <String, ManualTodo>{});

      expect(mergeTodoStateDocs(<TodoStateDoc>[older, newer]).states['k']!.completed,
          isFalse);
      expect(mergeTodoStateDocs(<TodoStateDoc>[newer, older]).states['k']!.completed,
          isFalse);
    });

    test('每台设备各写自己的文件，各自的记录都保留', () {
      final a = doc('dev_a', <String, CompletionState>{
        'ka': const CompletionState(
          completed: true,
          updatedAt: 100,
          memoId: 'm1',
          index: 0,
        ),
      }, <String, ManualTodo>{});
      final b = doc('dev_b', <String, CompletionState>{
        'kb': const CompletionState(
          completed: true,
          updatedAt: 100,
          memoId: 'm2',
          index: 0,
        ),
      }, <String, ManualTodo>{});
      final merged = mergeTodoStateDocs(<TodoStateDoc>[a, b]);
      expect(merged.states.keys.toSet(), <String>{'ka', 'kb'});
    });

    test('删除墓碑时间更晚时胜出，旧文件不能让待办复活', () {
      final created = doc('dev_a', <String, CompletionState>{}, <String, ManualTodo>{
        'todo_1': const ManualTodo(
          id: 'todo_1',
          task: '交电费',
          completed: false,
          createdAt: 100,
          updatedAt: 100,
        ),
      });
      final deleted = doc('dev_b', <String, CompletionState>{}, <String, ManualTodo>{
        'todo_1': const ManualTodo(
          id: 'todo_1',
          task: '交电费',
          completed: false,
          createdAt: 100,
          updatedAt: 300,
          deleted: true,
        ),
      });
      expect(
        mergeTodoStateDocs(<TodoStateDoc>[deleted, created]).manual['todo_1']!.deleted,
        isTrue,
      );
    });

    test('空输入返回合法空文档', () {
      final merged = mergeTodoStateDocs(const <TodoStateDoc>[]);
      expect(merged.states, isEmpty);
      expect(merged.manual, isEmpty);
    });
  });

  group('状态查询兜底', () {
    test('文本 key 精确命中', () {
      final merged = mergeTodoStateDocs(<TodoStateDoc>[
        TodoStateDoc.empty('a').withState(
          TodoKeys.forNote('m1', '买牛奶'),
          const CompletionState(
            completed: true,
            updatedAt: 10,
            memoId: 'm1',
            index: 0,
          ),
        ),
      ]);
      expect(lookupCompletion(merged, 'm1', '买牛奶', 0)!.completed, isTrue);
    });

    test('Mac 重新提炼把任务文本改了，仍能靠 memo_id + 原下标找回', () {
      final merged = mergeTodoStateDocs(<TodoStateDoc>[
        TodoStateDoc.empty('a').withState(
          TodoKeys.forNote('m1', '买牛奶'),
          const CompletionState(
            completed: true,
            updatedAt: 10,
            memoId: 'm1',
            index: 2,
          ),
        ),
      ]);
      final hit = lookupCompletion(merged, 'm1', '买两盒牛奶', 2);
      expect(hit, isNotNull);
      expect(hit!.completed, isTrue);
      expect(lookupCompletion(merged, 'm2', '别的任务', 2), isNull);
    });

    test('兜底有多条时取最近的一条', () {
      var doc = TodoStateDoc.empty('a');
      doc = doc.withState(
        'k1',
        const CompletionState(
          completed: false,
          updatedAt: 10,
          memoId: 'm1',
          index: 0,
        ),
      );
      doc = doc.withState(
        'k2',
        const CompletionState(
          completed: true,
          updatedAt: 20,
          memoId: 'm1',
          index: 0,
        ),
      );
      expect(lookupCompletion(doc, 'm1', '全新文本', 0)!.completed, isTrue);
    });
  });

  group('页面分组：未完成在前，已完成默认折叠', () {
    TodoEntry item(
      String id,
      bool done, {
      DateTime? created,
      DateTime? updated,
    }) =>
        TodoEntry(
          id: id,
          task: id,
          completed: done,
          origin: TodoOrigin.manual,
          createdAt: created ?? DateTime(2026, 11, 1),
          updatedAt: updated ?? DateTime(2026, 11, 1),
        );

    test('两组分开，总数正确', () {
      final groups = groupTodos(<TodoEntry>[
        item('A', false),
        item('B', true),
        item('C', false),
      ]);
      expect(groups.pending.map((e) => e.id).toList(), <String>['A', 'C']);
      expect(groups.completed.map((e) => e.id).toList(), <String>['B']);
      expect(groups.total, 3);
    });

    test('未完成按记录时间倒序，已完成按勾选时间倒序', () {
      final groups = groupTodos(<TodoEntry>[
        item('旧待办', false, created: DateTime(2026, 11, 1)),
        item('新待办', false, created: DateTime(2026, 11, 8)),
        item('早完成', true, updated: DateTime(2026, 11, 2)),
        item('刚完成', true, updated: DateTime(2026, 11, 7)),
      ]);
      expect(groups.pending.first.id, '新待办');
      expect(groups.completed.first.id, '刚完成');
    });

    test('空任务被跳过，空输入返回两个空列表', () {
      final groups = groupTodos(<TodoEntry>[item('  ', false)]);
      expect(groups.total, 0);
      expect(groupTodos(const <TodoEntry>[]).total, 0);
    });
  });

  group('时间戳单调', () {
    test('时钟回拨也不会让新操作输给旧记录', () {
      final merged = mergeTodoStateDocs(<TodoStateDoc>[
        TodoStateDoc.empty('a').withState(
          'k',
          const CompletionState(
            completed: true,
            updatedAt: 999999,
            memoId: 'm',
            index: 0,
          ),
        ),
      ]);
      expect(nextTimestamp(merged, 1000), greaterThan(999999));
    });

    test('正常情况下就用当前时间', () {
      expect(nextTimestamp(TodoStateDoc.empty('a'), 12345), 12345);
    });
  });
}
