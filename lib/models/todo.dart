import 'dart:convert';

/// 一条待办在「待办页面」里的统一形态。
///
/// 两个来源被抹平成同一种对象，页面只认这一个类：
/// * [TodoOrigin.note]   —— Mac 从某条笔记里提炼出来的，点进去能回到原笔记；
/// * [TodoOrigin.manual] —— 用户在待办页面手工加的，不属于任何笔记。
class TodoEntry {
  const TodoEntry({
    required this.id,
    required this.task,
    required this.completed,
    required this.origin,
    required this.createdAt,
    required this.updatedAt,
    this.memoId,
    this.memoIndex = -1,
    this.author = '',
    this.memoTitle = '',
  });

  /// 笔记待办是稳定 key，手工待办是 `todo_xxx` id。
  final String id;
  final String task;
  final bool completed;
  final TodoOrigin origin;
  final DateTime createdAt;

  /// 最近一次状态变更时间；已完成分组按它排序。
  final DateTime updatedAt;

  final String? memoId;
  final int memoIndex;
  final String author;
  final String memoTitle;

  bool get fromNote => origin == TodoOrigin.note && memoId != null;
  bool get fromManual => origin == TodoOrigin.manual;

  TodoEntry copyWith({
    String? task,
    bool? completed,
    DateTime? updatedAt,
  }) =>
      TodoEntry(
        id: id,
        task: task ?? this.task,
        completed: completed ?? this.completed,
        origin: origin,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        memoId: memoId,
        memoIndex: memoIndex,
        author: author,
        memoTitle: memoTitle,
      );
}

enum TodoOrigin { note, manual }

/// 稳定 key 的唯一生成处。
///
/// ⚠️ Mac 端 `todo_state.py::note_key()` 必须跟这里**逐字一致**，
/// 否则手机上勾掉的待办在 Mac 的总览里会变回未完成。
///
/// 为什么用「笔记 id + 归一化后的任务文本」而不是数组下标：
/// Mac 重新提炼（改了 Whisper 参数后 `--force` 重跑）时待办顺序可能变，
/// 下标会串位；文本不变就能稳稳对上。文本真变了还有 memo_id+index 兜底。
class TodoKeys {
  const TodoKeys._();

  /// 与 Python `re.sub(r"\s+", " ", text.strip()).lower()` 等价。
  static String normalizeTask(String task) =>
      task.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  static String forNote(String memoId, String task) =>
      'note:$memoId:${normalizeTask(task)}';
}

/// 手工待办的一条记录（含墓碑）。
///
/// 删除不能直接从文件里抹掉：别的设备上的旧文件里还留着它，
/// 一合并就会「复活」。所以删除写一条 `deleted: true` 的新记录。
class ManualTodo {
  const ManualTodo({
    required this.id,
    required this.task,
    required this.completed,
    required this.createdAt,
    required this.updatedAt,
    this.author = '',
    this.deviceId = '',
    this.deleted = false,
  });

  final String id;
  final String task;
  final bool completed;
  final int createdAt;
  final int updatedAt;
  final String author;
  final String deviceId;
  final bool deleted;

  static ManualTodo? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.map((key, value) => MapEntry(key.toString(), value));
    final id = (map['id'] ?? '').toString().trim();
    final task = (map['task'] ?? '').toString().trim();
    if (id.isEmpty || task.isEmpty) return null;
    final status = (map['status'] ?? '').toString().toLowerCase();
    return ManualTodo(
      id: id,
      task: task,
      completed: _readBool(map['completed']) ||
          status == 'completed' ||
          status == 'done',
      createdAt: _readInt(map['created_at']),
      updatedAt: _readInt(map['updated_at']),
      author: (map['author'] ?? '').toString(),
      deviceId: (map['device_id'] ?? '').toString(),
      deleted: _readBool(map['deleted']),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'task': task,
    'completed': completed,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'author': author,
    'device_id': deviceId,
    'deleted': deleted,
  };

  ManualTodo copyWith({
    String? task,
    bool? completed,
    int? createdAt,
    int? updatedAt,
    String? author,
    String? deviceId,
    bool? deleted,
  }) =>
      ManualTodo(
        id: id,
        task: task ?? this.task,
        completed: completed ?? this.completed,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        author: author ?? this.author,
        deviceId: deviceId ?? this.deviceId,
        deleted: deleted ?? this.deleted,
      );
}

/// 一条完成状态覆盖记录。
///
/// [memoId] / [index] 是给「任务文本被改过」时兜底用的：key 对不上时，
/// 还能靠笔记 id + 原来的下标把勾选状态找回来。
class CompletionState {
  const CompletionState({
    required this.completed,
    required this.updatedAt,
    required this.memoId,
    required this.index,
  });

  final bool completed;
  final int updatedAt;
  final String memoId;
  final int index;

  static CompletionState? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.map((key, value) => MapEntry(key.toString(), value));
    return CompletionState(
      completed: _readBool(map['completed']),
      updatedAt: _readInt(map['updated_at']),
      memoId: (map['memo_id'] ?? '').toString(),
      index: _readInt(map['index']),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'completed': completed,
    'updated_at': updatedAt,
    'memo_id': memoId,
    'index': index,
  };
}

/// 一台设备的待办状态文件。
///
/// 文件名就是 `<deviceId>.json`。**每台设备只写自己那一份**，
/// 这是整套方案不产生 Syncthing 冲突副本的关键：两个写入者永远不碰同一个文件。
/// 读取时把所有设备的文件按 `updated_at` 做 last-write-wins 合并。
class TodoStateDoc {
  const TodoStateDoc({
    required this.schemaVersion,
    required this.deviceId,
    required this.updatedAt,
    required this.states,
    required this.manual,
  });

  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final String deviceId;
  final int updatedAt;
  final Map<String, CompletionState> states;
  final Map<String, ManualTodo> manual;

  static TodoStateDoc empty(String deviceId) => TodoStateDoc(
    schemaVersion: currentSchemaVersion,
    deviceId: deviceId,
    updatedAt: 0,
    states: <String, CompletionState>{},
    manual: <String, ManualTodo>{},
  );

  /// 坏文件、旧版本、半截 JSON 都不能让整个待办页面挂掉。
  static TodoStateDoc? tryParse(Object? raw, {String fallbackDeviceId = ''}) {
    if (raw is! Map) return null;
    final map = raw.map((key, value) => MapEntry(key.toString(), value));

    final states = <String, CompletionState>{};
    final rawStates = map['states'];
    if (rawStates is Map) {
      rawStates.forEach((key, value) {
        final parsed = CompletionState.tryParse(value);
        if (parsed != null) states[key.toString()] = parsed;
      });
    } else if (rawStates is List) {
      // 兼容早期/第三方写法：[{"key": "...", ...}]
      for (final item in rawStates) {
        if (item is! Map) continue;
        final key = item['key']?.toString() ?? '';
        if (key.isEmpty) continue;
        final parsed = CompletionState.tryParse(item);
        if (parsed != null) states[key] = parsed;
      }
    }

    final manual = <String, ManualTodo>{};
    final rawManual = map['manual'];
    if (rawManual is List) {
      for (final item in rawManual) {
        final parsed = ManualTodo.tryParse(item);
        if (parsed != null) manual[parsed.id] = parsed;
      }
    } else if (rawManual is Map) {
      rawManual.forEach((key, value) {
        final parsed = ManualTodo.tryParse(value);
        if (parsed != null) {
          final id = parsed.id.isEmpty ? key.toString() : parsed.id;
          manual[id] = parsed;
        }
      });
    }

    return TodoStateDoc(
      schemaVersion: _readInt(map['schema_version']) > 0
          ? _readInt(map['schema_version'])
          : currentSchemaVersion,
      deviceId: (map['device_id'] ?? fallbackDeviceId).toString(),
      updatedAt: _readInt(map['updated_at']),
      states: states,
      manual: manual,
    );
  }

  static TodoStateDoc? tryParseText(String content, {String fallbackDeviceId = ''}) {
    try {
      return tryParse(jsonDecode(content), fallbackDeviceId: fallbackDeviceId);
    } on FormatException {
      return null;
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': schemaVersion,
    'device_id': deviceId,
    'updated_at': updatedAt,
    'states': <String, Object?>{
      for (final entry in states.entries) entry.key: entry.value.toJson(),
    },
    'manual': manual.values.map((e) => e.toJson()).toList(growable: false),
    // 纯说明字段，方便家人在 Mac 上直接打开这个文件看得懂。
    'note': '每台设备只写自己这一份；勾选状态与手工待办由所有设备按 updated_at 合并。',
  };

  TodoStateDoc withState(String key, CompletionState state) {
    final next = Map<String, CompletionState>.from(states)..[key] = state;
    return TodoStateDoc(
      schemaVersion: schemaVersion,
      deviceId: deviceId,
      updatedAt: state.updatedAt,
      states: next,
      manual: manual,
    );
  }

  TodoStateDoc withManual(ManualTodo todo) {
    final next = Map<String, ManualTodo>.from(manual)..[todo.id] = todo;
    return TodoStateDoc(
      schemaVersion: schemaVersion,
      deviceId: deviceId,
      updatedAt: todo.updatedAt,
      states: states,
      manual: next,
    );
  }
}

/// 合并所有设备的状态文件：同一 key 取 `updated_at` 最大的那条。
///
/// 抽成纯函数是为了能单测——多设备冲突最容易写错，又不值得为此起真文件系统。
TodoStateDoc mergeTodoStateDocs(Iterable<TodoStateDoc> docs) {
  final states = <String, CompletionState>{};
  final manual = <String, ManualTodo>{};
  var latest = 0;
  for (final doc in docs) {
    if (doc.updatedAt > latest) latest = doc.updatedAt;
    doc.states.forEach((key, value) {
      final current = states[key];
      if (current == null || value.updatedAt >= current.updatedAt) {
        states[key] = value;
      }
      if (value.updatedAt > latest) latest = value.updatedAt;
    });
    doc.manual.forEach((key, value) {
      final current = manual[key];
      if (current == null || value.updatedAt >= current.updatedAt) {
        manual[key] = value;
      }
      if (value.updatedAt > latest) latest = value.updatedAt;
    });
  }
  return TodoStateDoc(
    schemaVersion: TodoStateDoc.currentSchemaVersion,
    deviceId: '',
    updatedAt: latest,
    states: states,
    manual: manual,
  );
}

/// 在合并后的状态里查一条笔记待办的完成状态。
///
/// 先按稳定 key 精确命中；命中不到（Mac 重新提炼后任务文本变了）就退回
/// 「同一笔记 + 同一原下标」里最近的一条记录。
CompletionState? lookupCompletion(
  TodoStateDoc merged,
  String memoId,
  String task,
  int index,
) {
  final exact = merged.states[TodoKeys.forNote(memoId, task)];
  if (exact != null) return exact;

  CompletionState? fallback;
  for (final state in merged.states.values) {
    if (state.memoId != memoId || state.index != index) continue;
    if (fallback == null || state.updatedAt > fallback.updatedAt) {
      fallback = state;
    }
  }
  return fallback;
}

/// 页面分组：未完成在前、已完成在后（已完成默认折叠，不占视觉空间）。
class TodoGroups {
  const TodoGroups({required this.pending, required this.completed});

  final List<TodoEntry> pending;
  final List<TodoEntry> completed;

  int get total => pending.length + completed.length;
}

TodoGroups groupTodos(Iterable<TodoEntry> entries) {
  final pending = <TodoEntry>[];
  final completed = <TodoEntry>[];
  for (final entry in entries) {
    if (entry.task.trim().isEmpty) continue;
    (entry.completed ? completed : pending).add(entry);
  }
  // 未完成的按「记录时间」倒序：刚说的事在最上面。
  pending.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  // 已完成的按「什么时候勾掉的」倒序：刚做完的排前面。
  completed.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return TodoGroups(
    pending: List<TodoEntry>.unmodifiable(pending),
    completed: List<TodoEntry>.unmodifiable(completed),
  );
}

/// 单调递增的时间戳：即使两台设备时钟有偏差，也不会让新操作输给旧记录。
int nextTimestamp(TodoStateDoc merged, [int? nowMillis]) {
  final now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
  return now > merged.updatedAt ? now : merged.updatedAt + 1;
}

bool _readBool(Object? raw) =>
    raw == true || raw?.toString().toLowerCase() == 'true';

/// 缺失/坏掉的时间戳一律回 0，绝不拿"现在"补：
/// 那会让一条没有时间的旧记录凭空赢过 newer 的记录（LWW 最怕这个）。
int _readInt(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse(raw?.toString().trim() ?? '') ?? 0;
}
