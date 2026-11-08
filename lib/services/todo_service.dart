import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../core/app_config.dart';
import '../core/app_log.dart';
import '../core/app_paths.dart';
import '../models/memo.dart';
import '../models/todo.dart';
import 'atomic_io.dart';
import 'database_service.dart';

/// 一次「读全部状态 → 对账 → 汇总」的结果。
class TodoSnapshot {
  const TodoSnapshot({
    required this.entries,
    required this.files,
    required this.stateRecords,
    required this.manualRecords,
    required this.dbUpdates,
    required this.seeded,
  });

  final List<TodoEntry> entries;

  /// 读到了几台设备的状态文件（0 表示共享目录还读不到）。
  final int files;
  final int stateRecords;
  final int manualRecords;

  /// 本次把多少条笔记的 TODO 状态从共享文件落实进了本地库。
  final int dbUpdates;

  /// 本次把多少条「老版本只在本地库里勾过」的状态补种进了共享文件。
  final int seeded;
}

/// 待办事项的真源与对账中心。
///
/// 三类数据在这里合流：
/// * 笔记待办   —— `memos.todos`（Mac 提炼，落在 `*/inbox/*.json`）；
/// * 完成状态   —— `<同步根>/todos/<deviceId>.json` 的 `states`；
/// * 手工待办   —— 同一批文件的 `manual`。
///
/// **单写者原则**：本进程只写 `_paths.todoStateFile(deviceId)` 这一个文件。
/// 所有设备（含 Mac）都读全部文件并按 `updated_at` 合并，因此两台手机
/// 同时勾待办也不会产生 Syncthing 冲突副本。
///
/// 另一条铁律：**文件写失败不能让本地勾选失败**。共享目录可能因为权限、
/// 同步根退化成私有目录而不可写；这时本地 SQLite 仍然要更新，等下次
/// 可写了再补种。用户看到的永远是「点一下就勾上了」。
class TodoService {
  TodoService({
    required AppPaths paths,
    required DatabaseService db,
    required String deviceId,
  }) : _paths = paths,
       _db = db,
       _deviceId = deviceId;

  final AppPaths _paths;
  final DatabaseService _db;
  final String _deviceId;
  final Random _random = Random();

  /// 串行化所有「读-改-写」，避免连续点两下丢失一次更新。
  Future<void> _queue = Future<void>.value();

  Future<T> _exclusive<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then((_) {}).catchError((Object _) {});
    return result;
  }

  File get ownFile => _paths.todoStateFile(_deviceId);

  // ------------------------------------------------------------- 读

  /// 读目录里所有设备的状态文件并合并。
  ///
  /// 跳过 `.sync-conflict-*`（Syncthing 万一留下的冲突副本）：它们是同一份
  /// 数据的旧快照，混进来只会让"谁更新"的判断变复杂。
  /// 自己那份额外按三种等价路径直接探一次——真机上出现过「目录列得出、
  /// 别人的文件看不见」的权限组合，至少要保证本机刚加的待办不会丢。
  Future<TodoStateDoc> _readMerged() async {
    final docs = <TodoStateDoc>[];
    final visited = <String>{};
    var files = 0;

    Future<void> readFile(File file, String fallbackId) async {
      if (!visited.add(file.path)) return;
      try {
        if (!await file.exists()) return;
        final doc = TodoStateDoc.tryParseText(
          await file.readAsString(),
          fallbackDeviceId: fallbackId,
        );
        if (doc != null) {
          docs.add(doc);
          files += 1;
        }
      } on Object catch (error) {
        AppLog.w('todo', '读取待办状态文件失败 ${p.basename(file.path)}：$error');
      }
    }

    try {
      final dir = _paths.todoStateDir;
      if (await dir.exists()) {
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          if (!name.endsWith('.json')) continue;
          if (name.contains('.sync-conflict-')) continue;
          await readFile(entity, p.basenameWithoutExtension(name));
        }
      }
    } on Object catch (error) {
      AppLog.w('todo', '枚举待办状态目录失败：$error');
    }

    for (final alias in AppPaths.aliasPaths(ownFile.path)) {
      await readFile(File(alias), _deviceId);
    }
    _lastFileCount = files;
    return mergeTodoStateDocs(docs);
  }

  int _lastFileCount = 0;

  Future<TodoStateDoc> _readOwn() async {
    for (final alias in AppPaths.aliasPaths(ownFile.path)) {
      final file = File(alias);
      try {
        if (!await file.exists()) continue;
        final doc = TodoStateDoc.tryParseText(
          await file.readAsString(),
          fallbackDeviceId: _deviceId,
        );
        if (doc != null) return doc;
      } on Object catch (error) {
        AppLog.w('todo', '读取本机待办状态失败：$error');
      }
    }
    return TodoStateDoc.empty(_deviceId);
  }

  Future<void> _writeOwn(TodoStateDoc doc) async {
    try {
      await AtomicIo.writeString(ownFile, jsonEncode(doc.toJson()));
    } on Object catch (error) {
      // 共享目录写不进去时绝不抛给 UI：本地库已经是最新，
      // 下次 reconcile 会再次尝试补种。
      AppLog.w('todo', '写入待办状态文件失败（本地状态仍然有效）：$error');
    }
  }

  Future<void> _appendOwnStates(Map<String, CompletionState> states) async {
    if (states.isEmpty) return;
    var own = await _readOwn();
    for (final entry in states.entries) {
      own = own.withState(entry.key, entry.value);
    }
    await _writeOwn(own);
  }

  Future<void> _appendOwnManual(ManualTodo todo) async {
    final own = await _readOwn();
    await _writeOwn(own.withManual(todo));
  }

  // ------------------------------------------------------------- 汇总 / 对账

  /// 读状态 → 把跨设备的勾选落实进本地库 → 把老版本本地状态补种出去 → 汇总。
  Future<TodoSnapshot> snapshot() => _exclusive(_snapshotRaw);

  Future<TodoSnapshot> _snapshotRaw() async {
    final merged = await _readMerged();
    final memos = await _db.allMemos();

    var dbUpdates = 0;
    var seeded = 0;
    var timestamp = nextTimestamp(merged);
    final seeds = <String, CompletionState>{};

    for (final memo in memos) {
      final nextTodos = <TodoItem>[];
      var changed = false;
      for (var i = 0; i < memo.todos.length; i++) {
        final todo = memo.todos[i];
        final key = TodoKeys.forNote(memo.id, todo.task);
        final state = lookupCompletion(merged, memo.id, todo.task, i);
        if (state != null && state.completed != todo.completed) {
          nextTodos.add(todo.copyWith(completed: state.completed));
          changed = true;
        } else {
          nextTodos.add(todo);
          if (state == null && todo.completed) {
            // 老版本只在 SQLite 里勾过，共享文件里查无此条。
            // 补种一条，让这台手机的历史勾选也能同步给 Mac 和别的手机。
            timestamp += 1;
            seeds[key] = CompletionState(
              completed: true,
              updatedAt: timestamp,
              memoId: memo.id,
              index: i,
            );
            seeded += 1;
          }
        }
      }
      if (changed) {
        await _db.setTodos(memo.id, nextTodos);
        dbUpdates += 1;
      }
    }

    if (seeds.isNotEmpty) {
      await _appendOwnStates(seeds);
      AppLog.i('todo', '把 $seeded 条历史勾选补种进共享状态文件');
    }

    // 数据库刚可能被改过，重新读一遍，保证页面与详情页看到同一份状态。
    final fresh = await _db.allMemos();
    final entries = <TodoEntry>[];
    for (final memo in fresh) {
      for (var i = 0; i < memo.todos.length; i++) {
        final todo = memo.todos[i];
        final state = lookupCompletion(merged, memo.id, todo.task, i);
        entries.add(
          TodoEntry(
            id: TodoKeys.forNote(memo.id, todo.task),
            task: todo.task,
            completed: todo.completed,
            origin: TodoOrigin.note,
            createdAt: memo.createdAt,
            updatedAt: state == null
                ? memo.updatedAt
                : DateTime.fromMillisecondsSinceEpoch(state.updatedAt),
            memoId: memo.id,
            memoIndex: i,
            author: memo.author,
            memoTitle: memo.displayTitle,
          ),
        );
      }
    }
    for (final record in merged.manual.values) {
      if (record.deleted) continue;
      entries.add(
        TodoEntry(
          id: record.id,
          task: record.task,
          completed: record.completed,
          origin: TodoOrigin.manual,
          createdAt: DateTime.fromMillisecondsSinceEpoch(record.createdAt),
          updatedAt: DateTime.fromMillisecondsSinceEpoch(record.updatedAt),
          author: record.author,
        ),
      );
    }

    return TodoSnapshot(
      entries: entries,
      files: _lastFileCount,
      stateRecords: merged.states.length,
      manualRecords: merged.manual.values.where((e) => !e.deleted).length,
      dbUpdates: dbUpdates,
      seeded: seeded,
    );
  }

  Future<List<TodoEntry>> load() async => (await snapshot()).entries;

  /// 给「回到前台 / 手动刷新」用：只关心对账，不关心返回值。
  Future<TodoSnapshot> reconcile() => snapshot();

  // ------------------------------------------------------------- 写

  /// 勾选 / 取消一条**笔记**待办。详情页与待办页共用这一条路径。
  Future<void> setNoteTodoCompleted({
    required String memoId,
    required int index,
    required String task,
    required bool completed,
  }) async {
    // 本地库先落地：即使共享目录不可写，用户这一下也必须生效。
    await _db.setTodoCompleted(memoId, index, completed);
    await _exclusive(() async {
      final merged = await _readMerged();
      final stamp = nextTimestamp(merged);
      await _appendOwnStates(<String, CompletionState>{
        TodoKeys.forNote(memoId, task): CompletionState(
          completed: completed,
          updatedAt: stamp,
          memoId: memoId,
          index: index,
        ),
      });
    });
  }

  /// 手工新增一条待办。返回新条目，方便 UI 立刻滚到它。
  Future<TodoEntry> addManual(String content, {required String author}) async {
    final task = content.trim();
    if (task.isEmpty) throw ArgumentError('待办内容为空');
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'todo_${now}_${_random.nextInt(1 << 20).toRadixString(16)}';
    final record = ManualTodo(
      id: id,
      task: task.length > 120 ? task.substring(0, 120) : task,
      completed: false,
      createdAt: now,
      updatedAt: now,
      author: author,
      deviceId: _deviceId,
    );
    await _exclusive(() => _appendOwnManual(record));
    return TodoEntry(
      id: record.id,
      task: record.task,
      completed: record.completed,
      origin: TodoOrigin.manual,
      createdAt: DateTime.fromMillisecondsSinceEpoch(record.createdAt),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(record.updatedAt),
      author: record.author,
    );
  }

  /// 勾选 / 取消一条**手工**待办。
  ///
  /// 这条待办可能是别的手机加的，本机文件里本来没有它 —— 所以写一条
  /// 同 id 的新记录去覆盖，把 task / createdAt / author 一并带上，
  /// 合并时按 updated_at 自然胜出。
  Future<void> setManualCompleted(String id, bool completed) =>
      _exclusive(() async {
        final merged = await _readMerged();
        final source = merged.manual[id];
        if (source == null) return;
        final stamp = nextTimestamp(merged);
        await _appendOwnManual(
          source.copyWith(completed: completed, updatedAt: stamp, deleted: false),
        );
      });

  /// 删除手工待办：写墓碑，不真删记录。
  Future<void> deleteManual(String id) => _exclusive(() async {
    final merged = await _readMerged();
    final source = merged.manual[id];
    if (source == null) return;
    final stamp = nextTimestamp(merged);
    await _appendOwnManual(
      source.copyWith(deleted: true, updatedAt: stamp),
    );
  });

  // ------------------------------------------------------------- 诊断

  Future<List<String>> debugInfo() async {
    final lines = <String>[];
    try {
      final snap = await snapshot();
      lines.add('状态目录 ${_paths.todoStateDir.path}');
      lines.add('本机状态文件 ${p.basename(ownFile.path)}');
      lines.add('读到 ${snap.files} 个设备状态文件 / ${snap.stateRecords} 条勾选记录');
      lines.add('共享手工待办 ${snap.manualRecords} 条');
      lines.add('待办合计 ${groupTodos(snap.entries).total} 条');
      lines.add('本次对账：落实 ${snap.dbUpdates} 篇笔记 / 补种 ${snap.seeded} 条');
    } on Object catch (error) {
      lines.add('待办状态读取失败：$error');
    }
    return lines;
  }

  /// 给设置页展示的「同步根是否可写」，比抽象的权限描述直观。
  bool get stateDirIsShared => _paths.syncRootIsShared;

  static String get stateDirName => AppConfig.todoStateDirName;
}
