import 'dart:convert';

import 'package:intl/intl.dart';

import '../core/app_config.dart';

/// 记录类型：语音备忘 / 纯文本随手记。
enum MemoKind {
  audio('audio'),
  text('text');

  const MemoKind(this.wire);

  final String wire;

  static MemoKind parse(Object? raw) =>
      raw?.toString() == MemoKind.text.wire ? MemoKind.text : MemoKind.audio;
}

/// 处理状态。`processed` 表示 Mac 端已回传结构化结果。
enum MemoStatus {
  local('local'),
  processed('processed'),
  failed('failed');

  const MemoStatus(this.wire);

  final String wire;

  static MemoStatus parse(Object? raw) {
    for (final value in MemoStatus.values) {
      if (value.wire == raw?.toString()) return value;
    }
    return MemoStatus.local;
  }
}

/// 一条待办。契约里是 `{"task": "...", "status": "pending"|"completed"}`。
class TodoItem {
  const TodoItem({required this.task, this.completed = false});

  final String task;
  final bool completed;

  /// 宽容解析：大模型偶尔会退化成纯字符串数组。
  factory TodoItem.fromJson(Object? raw) {
    if (raw is String) {
      return TodoItem(task: raw.trim());
    }
    if (raw is Map) {
      final map = raw.map((key, value) => MapEntry(key.toString(), value));
      final status = (map['status'] ?? '').toString().toLowerCase();
      final flag = map['completed'] ?? map['done'];
      final completed = status == 'completed' ||
          status == 'done' ||
          status == 'finished' ||
          flag == true ||
          flag?.toString() == 'true';
      final task = (map['task'] ?? map['title'] ?? map['content'] ?? '')
          .toString()
          .trim();
      return TodoItem(task: task, completed: completed);
    }
    return const TodoItem(task: '');
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'task': task,
    'status': completed ? 'completed' : 'pending',
  };

  TodoItem copyWith({String? task, bool? completed}) => TodoItem(
    task: task ?? this.task,
    completed: completed ?? this.completed,
  );
}

/// 一条知识库记录。既是 SQLite 的一行，也是同步契约里的一份 JSON。
class Memo {
  const Memo({
    required this.id,
    required this.kind,
    required this.author,
    required this.authorDir,
    required this.deviceId,
    required this.createdAt,
    required this.updatedAt,
    this.audioFilename,
    this.rawText = '',
    this.summary = '',
    this.knowledgePoints = const <String>[],
    this.todos = const <TodoItem>[],
    this.tags = const <String>[],
    this.aliases = const <String>[],
    this.status = MemoStatus.local,
    this.processedAt,
    this.embeddingModel,
    this.embeddingDim,
  });

  final String id;
  final MemoKind kind;

  /// 契约字段 `author`，例如 `Dad`。
  final String author;

  /// 同步目录名，例如 `Dad_Notes`。Mac 端靠它决定回传路径。
  final String authorDir;
  final String deviceId;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 仅语音记录有值，例如 `memo_20261031_123000.m4a`。
  final String? audioFilename;

  /// 语音记录里是 Whisper 原始转写；文本记录里就是用户敲的原文。
  final String rawText;

  final String summary;
  final List<String> knowledgePoints;
  final List<TodoItem> todos;
  final List<String> tags;

  /// 大模型给出的同义词 / 别名（例如"逆变器" ↔ "inverter" ↔ "变流器"）。
  /// 只进检索索引，不占界面上的标签位。
  final List<String> aliases;

  final MemoStatus status;
  final DateTime? processedAt;

  /// 当前向量的来源模型。模型不一致时手机端会重算，避免跨空间比对。
  final String? embeddingModel;
  final int? embeddingDim;

  bool get isProcessed => status == MemoStatus.processed;
  bool get hasAudio => (audioFilename ?? '').isNotEmpty;

  /// 详情页标题：优先摘要首句，其次原文首句。
  String get displayTitle {
    final source = summary.trim().isNotEmpty ? summary.trim() : rawText.trim();
    if (source.isEmpty) return '未命名记录';
    final firstLine = source.split(RegExp(r'[\n。！？!?]')).first.trim();
    if (firstLine.isEmpty) return '未命名记录';
    return firstLine.length > 28 ? '${firstLine.substring(0, 28)}…' : firstLine;
  }

  /// 供 FTS5 / 语义检索使用的合并文本。
  String get searchableText {
    final parts = <String>[
      summary,
      knowledgePoints.join(' '),
      tags.join(' '),
      aliases.join(' '),
      todos.map((t) => t.task).join(' '),
      rawText,
    ];
    return parts.where((e) => e.trim().isNotEmpty).join('\n');
  }

  static final DateFormat _wireFormat = DateFormat('yyyy-MM-dd HH:mm:ss');

  /// 解析 Mac 端回传的 JSON（同步契约）。
  ///
  /// [authorDir] / [deviceId] 由本地推断补齐，因为契约里不一定带。
  factory Memo.fromContractJson(
    Map<String, Object?> json, {
    required String authorDir,
    required String deviceId,
    String? fallbackId,
  }) {
    final id = (json['id'] ?? fallbackId ?? '').toString().trim();
    final audio = json['audio_filename']?.toString();
    final kind = MemoKind.parse(json['kind'] ?? (audio == null ? 'text' : 'audio'));
    final created = _parseDateTime(json['created_at']) ?? DateTime.now();
    final todos = <TodoItem>[];
    final rawTodos = json['todos'];
    if (rawTodos is List) {
      for (final item in rawTodos) {
        final todo = TodoItem.fromJson(item);
        if (todo.task.isNotEmpty) todos.add(todo);
      }
    }
    final points = _toStringList(json['knowledge_points']);
    final tags = _toStringList(json['tags']);
    final aliases = _toStringList(json['aliases']);

    return Memo(
      id: id,
      kind: kind,
      author: (json['author'] ?? 'Unknown').toString(),
      authorDir: authorDir,
      deviceId: (json['device_id'] ?? deviceId).toString(),
      createdAt: created,
      updatedAt: DateTime.now(),
      audioFilename: (audio == null || audio.isEmpty) ? null : audio,
      rawText: (json['raw_transcript'] ?? json['raw_text'] ?? '').toString(),
      summary: (json['summary'] ?? '').toString(),
      knowledgePoints: points,
      todos: todos,
      tags: tags,
      aliases: aliases,
      status: MemoStatus.processed,
      processedAt: _parseDateTime(json['processed_at']) ?? DateTime.now(),
      embeddingModel: json['embedding_model']?.toString(),
      embeddingDim: _parseInt(json['embedding_dim']),
    );
  }

  /// 生成回传契约 JSON。Mac 端写文件时用同一份结构，保证双向一致。
  Map<String, Object?> toContractJson() => <String, Object?>{
    'id': id,
    'created_at': _wireFormat.format(createdAt),
    'kind': kind.wire,
    'audio_filename': audioFilename,
    'author': author,
    'device_id': deviceId,
    'summary': summary,
    'knowledge_points': knowledgePoints,
    'todos': todos.map((t) => t.toJson()).toList(),
    'tags': tags,
    'aliases': aliases,
    'raw_transcript': rawText,
    'embedding': null,
    'embedding_model': embeddingModel,
    'embedding_dim': embeddingDim,
  };

  factory Memo.fromRow(Map<String, Object?> row) => Memo(
    id: row['id']! as String,
    kind: MemoKind.parse(row['kind']),
    author: (row['author'] ?? '') as String,
    authorDir: (row['author_dir'] ?? '') as String,
    deviceId: (row['device_id'] ?? '') as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (row['created_at'] as num?)?.toInt() ?? 0,
    ),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      (row['updated_at'] as num?)?.toInt() ?? 0,
    ),
    audioFilename: row['audio_filename'] as String?,
    rawText: (row['raw_text'] ?? '') as String,
    summary: (row['summary'] ?? '') as String,
    knowledgePoints: _decodeList(row['knowledge_points']),
    todos: _decodeTodos(row['todos']),
    tags: _decodeList(row['tags']),
    aliases: _decodeList(row['aliases']),
    status: MemoStatus.parse(row['status']),
    processedAt: (row['processed_at'] as num?) == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            (row['processed_at'] as num).toInt(),
          ),
    embeddingModel: row['embedding_model'] as String?,
    embeddingDim: (row['embedding_dim'] as num?)?.toInt(),
  );

  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'kind': kind.wire,
    'author': author,
    'author_dir': authorDir,
    'device_id': deviceId,
    'created_at': createdAt.millisecondsSinceEpoch,
    'updated_at': updatedAt.millisecondsSinceEpoch,
    'audio_filename': audioFilename,
    'raw_text': rawText,
    'summary': summary,
    'knowledge_points': jsonEncode(knowledgePoints),
    'todos': jsonEncode(todos.map((t) => t.toJson()).toList()),
    'tags': jsonEncode(tags),
    'aliases': jsonEncode(aliases),
    'status': status.wire,
    'processed_at': processedAt?.millisecondsSinceEpoch,
    'embedding_model': embeddingModel,
    'embedding_dim': embeddingDim,
  };

  Memo copyWith({
    String? id,
    MemoKind? kind,
    String? author,
    String? authorDir,
    String? deviceId,
    DateTime? createdAt,
    DateTime? updatedAt,
    Object? audioFilename = _sentinel,
    String? rawText,
    String? summary,
    List<String>? knowledgePoints,
    List<TodoItem>? todos,
    List<String>? tags,
    List<String>? aliases,
    MemoStatus? status,
    Object? processedAt = _sentinel,
    Object? embeddingModel = _sentinel,
    Object? embeddingDim = _sentinel,
  }) {
    return Memo(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      author: author ?? this.author,
      authorDir: authorDir ?? this.authorDir,
      deviceId: deviceId ?? this.deviceId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      audioFilename: audioFilename == _sentinel
          ? this.audioFilename
          : audioFilename as String?,
      rawText: rawText ?? this.rawText,
      summary: summary ?? this.summary,
      knowledgePoints: knowledgePoints ?? this.knowledgePoints,
      todos: todos ?? this.todos,
      tags: tags ?? this.tags,
      aliases: aliases ?? this.aliases,
      status: status ?? this.status,
      processedAt: processedAt == _sentinel
          ? this.processedAt
          : processedAt as DateTime?,
      embeddingModel: embeddingModel == _sentinel
          ? this.embeddingModel
          : embeddingModel as String?,
      embeddingDim: embeddingDim == _sentinel
          ? this.embeddingDim
          : embeddingDim as int?,
    );
  }

  /// 生成形如 `memo_20261031_123000` 的 id。
  static String newId([DateTime? now]) {
    final ts = now ?? DateTime.now();
    return '${AppConfig.memoPrefix}${DateFormat('yyyyMMdd_HHmmss').format(ts)}';
  }
}

const Object _sentinel = Object();

DateTime? _parseDateTime(Object? raw) {
  if (raw == null) return null;
  if (raw is DateTime) return raw;
  final text = raw.toString().trim();
  if (text.isEmpty) return null;
  final direct = DateTime.tryParse(text);
  if (direct != null) return direct;
  for (final pattern in <String>[
    'yyyy-MM-dd HH:mm:ss',
    'yyyy/MM/dd HH:mm:ss',
    'yyyy-MM-dd HH:mm',
  ]) {
    try {
      return DateFormat(pattern).parseStrict(text);
    } on FormatException {
      continue;
    }
  }
  return null;
}

int? _parseInt(Object? raw) {
  if (raw == null) return null;
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse(raw.toString());
}

List<String> _toStringList(Object? raw) {
  if (raw is List) {
    return raw
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }
  if (raw is String && raw.trim().isNotEmpty) {
    return raw
        .split(RegExp(r'[,，;；、]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }
  return const <String>[];
}

List<String> _decodeList(Object? raw) {
  if (raw is String) {
    try {
      return _toStringList(jsonDecode(raw));
    } on FormatException {
      return const <String>[];
    }
  }
  return _toStringList(raw);
}

List<TodoItem> _decodeTodos(Object? raw) {
  Object? decoded = raw;
  if (raw is String) {
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const <TodoItem>[];
    }
  }
  if (decoded is List) {
    return decoded
        .map(TodoItem.fromJson)
        .where((t) => t.task.isNotEmpty)
        .toList(growable: false);
  }
  return const <TodoItem>[];
}
