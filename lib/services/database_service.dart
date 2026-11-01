import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/app_config.dart';
import '../core/app_log.dart';
import '../core/app_paths.dart';
import '../models/memo.dart';
import '../models/search_hit.dart';
import 'fts_tokenizer.dart';

/// 一条向量记录。
class VectorRecord {
  const VectorRecord({required this.memoId, required this.vector});

  final String memoId;
  final Float32List vector;
}

/// SQLite 数据层：表结构、迁移、FTS5 全文索引、向量表。
///
/// 设计要点：
/// 1. 所有表结构变更都走 [_migrations] 这张"版本 → SQL"表，
///    `onUpgrade` 逐版本执行，历史数据无损；
/// 2. FTS5 单独建表（非 external content），由代码显式维护，
///    避免触发器在批量写入时带来的不确定性；
/// 3. 向量以 `Float32List` 的原始字节存 BLOB，读取时零拷贝还原。
class DatabaseService {
  DatabaseService(this._paths);

  final AppPaths _paths;
  Database? _database;

  /// 默认 **false**：没经过 [_ensureFtsTable] 真实查询验证之前，一律当成不可用。
  /// 反过来（默认 true）会让"表不存在"和"表可用"无法区分，代价是每次写库都失败。
  bool _ftsAvailable = false;

  bool get ftsAvailable => _ftsAvailable;

  /// 无需切换数据库工厂。
  ///
  /// `sqflite` 的 `sqflite_darwin` 插件同时覆盖 iOS 与 macOS，
  /// Android 走 `sqflite_android`，三端都是原生实现，不需要 FFI 兜底。
  ///
  /// 早期版本这里接过 `sqflite_common_ffi`，但它会拖入 `sqlite3` 的
  /// native build hook，在没有 Android SDK/NDK 的环境里会直接让构建失败，
  /// 而收益仅仅是"自带一份 SQLite"。既然三端系统 SQLite 都带 FTS5
  /// （Android 8.0+ / iOS 10+ / macOS 10.12+），就没必要付这个代价。
  static void configurePlatformFactory() {
    // 有意为空：保留方法名，方便未来真需要切 FFI 时有落点。
  }

  // ------------------------------------------------------------- 表结构迁移

  /// 版本号 → 该版本需要执行的 SQL 列表。
  ///
  /// 加新版本时**只追加，不改历史条目**，这是保证老用户升级不丢数据的前提。
  static const Map<int, List<String>> _migrations = <int, List<String>>{
    1: <String>[
      '''
      CREATE TABLE memos (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        author TEXT NOT NULL,
        author_dir TEXT NOT NULL,
        device_id TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        audio_filename TEXT,
        raw_text TEXT NOT NULL DEFAULT '',
        summary TEXT NOT NULL DEFAULT '',
        knowledge_points TEXT NOT NULL DEFAULT '[]',
        todos TEXT NOT NULL DEFAULT '[]',
        tags TEXT NOT NULL DEFAULT '[]',
        status TEXT NOT NULL DEFAULT 'local',
        processed_at INTEGER,
        embedding_model TEXT,
        embedding_dim INTEGER,
        search_text TEXT NOT NULL DEFAULT ''
      )
      ''',
      'CREATE INDEX idx_memos_created ON memos(created_at DESC)',
      'CREATE INDEX idx_memos_author ON memos(author_dir, created_at DESC)',
      'CREATE INDEX idx_memos_status ON memos(status)',
      '''
      CREATE TABLE memo_vectors (
        memo_id TEXT PRIMARY KEY,
        model TEXT NOT NULL,
        dim INTEGER NOT NULL,
        vec BLOB NOT NULL
      )
      ''',
      'CREATE INDEX idx_vectors_model ON memo_vectors(model)',
      '''
      CREATE TABLE ingest_log (
        file_path TEXT PRIMARY KEY,
        file_size INTEGER NOT NULL,
        file_mtime INTEGER NOT NULL,
        ingested_at INTEGER NOT NULL
      )
      ''',
    ],
    // v2：大模型提取的同义词别名。只参与检索，不在界面上当标签展示。
    2: <String>[
      "ALTER TABLE memos ADD COLUMN aliases TEXT NOT NULL DEFAULT '[]'",
    ],
  };

  Future<Database> get database async {
    final cached = _database;
    if (cached != null) return cached;
    final opened = await _open();
    _database = opened;
    return opened;
  }

  Future<Database> _open() async {
    final path = _paths.databaseFile.path;
    await _paths.databaseFile.parent.create(recursive: true);
    AppLog.i('db', '打开数据库 $path');
    final db = await openDatabase(
      path,
      version: AppConfig.databaseVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await _runMigrations(db, 0, version);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        AppLog.i('db', '数据库迁移 $oldVersion → $newVersion');
        await _runMigrations(db, oldVersion, newVersion);
      },
    );
    // FTS 表必须在**每次打开**时确认，不能只放在 onCreate/onUpgrade 里。
    //
    // 真机上就是这么翻的车：数据库文件早就存在、版本号也没变，
    // 于是这两个回调一次都不触发 → `memos_fts` 从来没被创建，
    // 而 `_ftsAvailable` 还停在字段默认值 true（那是撒谎）。
    // 结果每一次写库都在 `DELETE FROM memos_fts` 上抛
    // `no such table: memos_fts`，整条记录跟着回滚 ——
    // 文件明明写进了 outbox，App 里却一条都没有。
    await _ensureFtsTable(db);
    await _backfillFtsIfNeeded(db);
    return db;
  }

  Future<void> _runMigrations(Database db, int from, int to) async {
    for (var version = from + 1; version <= to; version++) {
      final statements = _migrations[version];
      if (statements == null) {
        throw StateError('缺少数据库版本 $version 的迁移脚本');
      }
      for (final statement in statements) {
        await db.execute(statement);
      }
      AppLog.i('db', '已应用迁移 v$version（${statements.length} 条语句）');
    }
  }

  /// FTS5 表独立创建，因为部分老系统 SQLite 未编译 FTS5。
  /// 拿不到就降级成 LIKE 检索，App 照常可用（宁可慢，不可崩）。
  ///
  /// 建完必须**真查一次**才算数：`CREATE ... IF NOT EXISTS` 成功不代表表能用，
  /// 而 `_ftsAvailable` 一旦说谎，后面每次写库都会失败。
  Future<void> _ensureFtsTable(Database db) async {
    try {
      await db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS memos_fts USING fts5(
          memo_id UNINDEXED,
          search_text,
          tokenize = 'unicode61'
        )
      ''');
      await db.rawQuery('SELECT memo_id FROM memos_fts LIMIT 1');
      if (!_ftsAvailable) {
        AppLog.i('db', 'FTS5 索引表已就绪');
      }
      _ftsAvailable = true;
    } on DatabaseException catch (error) {
      _ftsAvailable = false;
      AppLog.w('db', 'FTS5 不可用，降级为 LIKE 检索：$error');
    }
  }

  // ------------------------------------------------------------- 写入

  /// 插入或更新一条记录，并同步维护 FTS 索引。
  ///
  /// **搜索索引永远不能拖累记录本身。** 索引写失败只降级检索能力，
  /// 记录该存还得存——否则就是"文件在、界面空"。
  Future<void> upsertMemo(Memo memo, {bool refreshIndex = true}) async {
    final db = await database;
    final searchText = FtsTokenizer.indexText(memo.searchableText);
    final row = memo.toRow()..['search_text'] = searchText;

    await db.transaction((txn) async {
      await txn.insert(
        'memos',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (!refreshIndex || !_ftsAvailable) return;
      try {
        await txn.delete(
          'memos_fts',
          where: 'memo_id = ?',
          whereArgs: <Object?>[memo.id],
        );
        await txn.insert('memos_fts', <String, Object?>{
          'memo_id': memo.id,
          'search_text': searchText,
        });
      } on DatabaseException catch (error) {
        AppLog.w('db', 'FTS 索引更新失败，本条记录仍已保存：$error');
        if (_looksLikeMissingTable(error)) _ftsAvailable = false;
      }
    });
  }

  /// 判断异常是不是"表不存在"。
  ///
  /// 遇到这种要立刻把 `_ftsAvailable` 拉回 false，否则每一轮扫描、
  /// 每一次保存都会重复抛同一个错。
  static bool _looksLikeMissingTable(DatabaseException error) {
    final text = error.toString().toLowerCase();
    return text.contains('no such table') || text.contains('no such module');
  }

  /// FTS 表刚被创建出来（或条目数落后于 memos）时补建索引。
  ///
  /// 表是这次才建出来的 → 里面一条都没有 → 老记录一条都搜不到。
  /// 直接用 `memos.search_text` 回填即可，不需要重新分词。
  Future<void> _backfillFtsIfNeeded(Database db) async {
    if (!_ftsAvailable) return;
    try {
      final indexed =
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM memos_fts'),
          ) ??
          0;
      final total =
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM memos'),
          ) ??
          0;
      if (indexed >= total) return;
      await db.transaction((txn) async {
        await txn.delete('memos_fts');
        await txn.rawInsert(
          'INSERT INTO memos_fts (memo_id, search_text) '
          'SELECT id, search_text FROM memos',
        );
      });
      AppLog.i('db', 'FTS 索引已回填 $total 条（原有 $indexed 条）');
    } on DatabaseException catch (error) {
      AppLog.w('db', 'FTS 索引回填失败（不影响记录本身）：$error');
      if (_looksLikeMissingTable(error)) _ftsAvailable = false;
    }
  }

  /// 合并 Mac 端回传的结果。
  ///
  /// 关键细节：如果本地已经勾选过某些 TODO，重新同步时不能被 Mac 的
  /// 旧状态覆盖——按任务文本对齐，保留用户本地的完成状态。
  Future<Memo> mergeProcessed(Memo incoming) async {
    final existing = await memoById(incoming.id);
    if (existing == null) {
      await upsertMemo(incoming);
      return incoming;
    }
    final merged = existing.copyWith(
      kind: incoming.kind,
      author: incoming.author,
      // Mac 端不知道设备 id（也不该编造），空值一律保留本机原值
      deviceId: incoming.deviceId.isEmpty ? existing.deviceId : incoming.deviceId,
      createdAt: incoming.createdAt,
      audioFilename: incoming.audioFilename ?? existing.audioFilename,
      rawText: incoming.rawText.isEmpty ? existing.rawText : incoming.rawText,
      summary: incoming.summary.isEmpty ? existing.summary : incoming.summary,
      knowledgePoints: incoming.knowledgePoints.isEmpty
          ? existing.knowledgePoints
          : incoming.knowledgePoints,
      todos: _mergeTodos(existing.todos, incoming.todos),
      tags: incoming.tags.isEmpty ? existing.tags : incoming.tags,
      aliases: incoming.aliases.isEmpty
          ? existing.aliases
          : incoming.aliases,
      status: MemoStatus.processed,
      processedAt: incoming.processedAt ?? DateTime.now(),
      embeddingModel: incoming.embeddingModel ?? existing.embeddingModel,
      embeddingDim: incoming.embeddingDim ?? existing.embeddingDim,
      updatedAt: DateTime.now(),
    );
    await upsertMemo(merged);
    return merged;
  }

  static List<TodoItem> _mergeTodos(
    List<TodoItem> existing,
    List<TodoItem> incoming,
  ) {
    if (incoming.isEmpty) return existing;
    final completedByText = <String, bool>{
      for (final todo in existing) todo.task: todo.completed,
    };
    return incoming
        .map(
          (todo) => completedByText.containsKey(todo.task)
              ? todo.copyWith(completed: completedByText[todo.task])
              : todo,
        )
        .toList(growable: false);
  }

  /// 更新单条 TODO 的勾选状态。
  Future<Memo?> setTodoCompleted(
    String memoId,
    int index,
    bool completed,
  ) async {
    final memo = await memoById(memoId);
    if (memo == null) return null;
    if (index < 0 || index >= memo.todos.length) return memo;
    final todos = List<TodoItem>.from(memo.todos);
    todos[index] = todos[index].copyWith(completed: completed);
    final updated = memo.copyWith(todos: todos, updatedAt: DateTime.now());
    await upsertMemo(updated);
    return updated;
  }

  /// 标记处理失败（Mac 端回了 error 或本地解析异常时使用）。
  Future<void> markFailed(String memoId, {String? reason}) async {
    final memo = await memoById(memoId);
    if (memo == null) return;
    if (reason != null && reason.isNotEmpty) {
      AppLog.w('db', '记录 $memoId 处理失败：$reason');
    }
    await upsertMemo(
      memo.copyWith(status: MemoStatus.failed, updatedAt: DateTime.now()),
    );
  }

  Future<void> deleteMemo(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('memos', where: 'id = ?', whereArgs: <Object?>[id]);
      await txn.delete(
        'memo_vectors',
        where: 'memo_id = ?',
        whereArgs: <Object?>[id],
      );
      if (_ftsAvailable) {
        try {
          await txn.delete(
            'memos_fts',
            where: 'memo_id = ?',
            whereArgs: <Object?>[id],
          );
        } on DatabaseException catch (error) {
          AppLog.w('db', 'FTS 索引清理失败，记录本身已删除：$error');
          if (_looksLikeMissingTable(error)) _ftsAvailable = false;
        }
      }
    });
  }

  // ------------------------------------------------------------- 读取

  Future<Memo?> memoById(String id) async {
    final db = await database;
    final rows = await db.query(
      'memos',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Memo.fromRow(rows.first);
  }

  Future<List<Memo>> recentMemos({
    int limit = 50,
    String? authorDir,
    MemoKind? kind,
  }) async {
    final db = await database;
    final where = <String>[];
    final args = <Object?>[];
    if (authorDir != null && authorDir.isNotEmpty) {
      where.add('author_dir = ?');
      args.add(authorDir);
    }
    if (kind != null) {
      where.add('kind = ?');
      args.add(kind.wire);
    }
    final rows = await db.query(
      'memos',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: where.isEmpty ? null : args,
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(Memo.fromRow).toList(growable: false);
  }

  /// 批量取记录（语义检索命中后回表用，避免 N 次单条查询）。
  Future<Map<String, Memo>> memosByIds(List<String> ids) async {
    if (ids.isEmpty) return <String, Memo>{};
    final db = await database;
    final placeholders = List<String>.filled(ids.length, '?').join(',');
    final rows = await db.query(
      'memos',
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
    return <String, Memo>{
      for (final row in rows) row['id']! as String: Memo.fromRow(row),
    };
  }

  /// 还没被 Mac 处理完的记录 id + 所属成员目录。
  ///
  /// 收件箱兜底探测要用它：有了 id 就能**直接按文件名**去读
  /// `inbox/<id>.json`，完全不用枚举目录。
  Future<List<({String id, String authorDir})>> unprocessedIds() async {
    final db = await database;
    final rows = await db.query(
      'memos',
      columns: <String>['id', 'author_dir'],
      where: "status != 'processed'",
    );
    return rows
        .map(
          (row) => (
            id: row['id']?.toString() ?? '',
            authorDir: row['author_dir']?.toString() ?? '',
          ),
        )
        .where((e) => e.id.isNotEmpty)
        .toList(growable: false);
  }

  /// 数据库自检：版本号、memos 的实际列、FTS 是否可用。
  ///
  /// 手机上拿不到 logcat，写库失败时只能靠这几行判断到底是
  /// "迁移没跑"（缺列）还是"FTS5 不可用"还是别的问题。
  Future<List<String>> debugInfo() async {
    final lines = <String>[];
    try {
      final db = await database;
      final version = await db.rawQuery('PRAGMA user_version');
      lines.add('schema 版本 ${version.first.values.first}（期望 ${AppConfig.databaseVersion}）');
      final cols = await db.rawQuery('PRAGMA table_info(memos)');
      lines.add('memos 列 ${cols.map((c) => c['name']).join(', ')}');
      lines.add('FTS5 ${_ftsAvailable ? '可用' : '不可用（已降级为 LIKE）'}');
      final counts = await db.rawQuery(
        'SELECT status, COUNT(*) AS c FROM memos GROUP BY status',
      );
      lines.add(
        '按状态：'
        '${counts.isEmpty ? '（空）' : counts.map((r) => '${r['status']}=${r['c']}').join(' ')}',
      );
      final vectors = await db.rawQuery('SELECT COUNT(*) AS c FROM memo_vectors');
      lines.add('向量 ${vectors.first['c']} 条');
      final ingested = await db.rawQuery('SELECT COUNT(*) AS c FROM ingest_log');
      lines.add('已入库文件记录 ${ingested.first['c']} 条');
    } on Object catch (error) {
      lines.add('自检失败：$error');
    }
    return lines;
  }

  /// 还没被 Mac 处理完的条数，黄灯上显示的那个数字。
  Future<int> pendingCount() async {
    final db = await database;
    final rows = await db.rawQuery(
      "SELECT COUNT(*) AS c FROM memos WHERE status != 'processed'",
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  Future<int> totalCount() async {
    final db = await database;
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM memos');
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  /// 标签云：统计所有记录里出现过的标签。
  Future<Map<String, int>> tagCounts() async {
    final db = await database;
    final rows = await db.query('memos', columns: <String>['tags']);
    final counter = <String, int>{};
    for (final row in rows) {
      final raw = row['tags'];
      if (raw is! String || raw.isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final tag in decoded) {
            final text = tag.toString().trim();
            if (text.isEmpty) continue;
            counter[text] = (counter[text] ?? 0) + 1;
          }
        }
      } on FormatException {
        continue;
      }
    }
    final entries = counter.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Map<String, int>.fromEntries(entries);
  }

  // ------------------------------------------------------------- 检索

  /// 硬关键词检索：FTS5 → bm25 排序；FTS5 不可用时退回 LIKE。
  Future<List<SearchHit>> searchKeyword(String query, {int limit = 50}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const <SearchHit>[];

    if (_ftsAvailable) {
      final hits = await _searchFts(trimmed, limit);
      if (hits.isNotEmpty) return hits;
    }
    return _searchLike(trimmed, limit);
  }

  Future<List<SearchHit>> _searchFts(String query, int limit) async {
    final db = await database;
    final match = FtsTokenizer.buildMatchQuery(query);
    if (match == null) return const <SearchHit>[];

    Future<List<SearchHit>> run(String expression) async {
      final rows = await db.rawQuery(
        '''
        SELECT m.*, bm25(memos_fts) AS rank
        FROM memos_fts
        JOIN memos m ON m.id = memos_fts.memo_id
        WHERE memos_fts MATCH ?
        ORDER BY rank
        LIMIT ?
        ''',
        <Object?>[expression, limit],
      );
      return rows.map((row) {
        final rank = (row['rank'] as num?)?.toDouble() ?? 0;
        return SearchHit(
          memo: Memo.fromRow(row),
          score: -rank,
          source: HitSource.keyword,
        );
      }).toList(growable: false);
    }

    try {
      // 先尝试 AND（精度优先），无结果再放宽成 OR（召回优先）。
      final strict = await run(
        FtsTokenizer.buildMatchQuery(query, useAnd: true)!,
      );
      if (strict.isNotEmpty) return strict;
      return await run(match);
    } on DatabaseException catch (error) {
      _ftsAvailable = false;
      AppLog.w('db', 'FTS 查询失败，本次降级 LIKE：$error');
      return const <SearchHit>[];
    }
  }

  Future<List<SearchHit>> _searchLike(String query, int limit) async {
    final db = await database;
    final tokens = FtsTokenizer.queryTokens(query);
    if (tokens.isEmpty) return const <SearchHit>[];
    final where = <String>[];
    final args = <Object?>[];
    for (final token in tokens.take(8)) {
      where.add('search_text LIKE ?');
      args.add('%$token%');
    }
    args.add(limit);
    final rows = await db.rawQuery(
      '''
      SELECT * FROM memos
      WHERE ${where.join(' OR ')}
      ORDER BY created_at DESC
      LIMIT ?
      ''',
      args,
    );
    return rows
        .map(
          (row) => SearchHit(
            memo: Memo.fromRow(row),
            score: 1,
            source: HitSource.keyword,
          ),
        )
        .toList(growable: false);
  }

  // ------------------------------------------------------------- 向量

  Future<void> upsertVector(String memoId, Float32List vector) async {
    final db = await database;
    await db.insert(
      'memo_vectors',
      <String, Object?>{
        'memo_id': memoId,
        'model': AppConfig.embeddingModelId,
        'dim': vector.length,
        'vec': vector.buffer.asUint8List(
          vector.offsetInBytes,
          vector.lengthInBytes,
        ),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 读出所有与当前模型匹配的向量，供 Isolate 建立内存索引。
  Future<List<VectorRecord>> allVectors() async {
    final db = await database;
    final rows = await db.query(
      'memo_vectors',
      where: 'model = ?',
      whereArgs: <Object?>[AppConfig.embeddingModelId],
    );
    final result = <VectorRecord>[];
    for (final row in rows) {
      final blob = row['vec'];
      if (blob is! Uint8List) continue;
      final expectedDim = (row['dim'] as num?)?.toInt() ?? 0;
      if (blob.lengthInBytes % 4 != 0) continue;
      final vector = blob.buffer.asFloat32List(
        blob.offsetInBytes,
        blob.lengthInBytes ~/ 4,
      );
      if (expectedDim > 0 && vector.length != expectedDim) continue;
      result.add(
        VectorRecord(memoId: row['memo_id']! as String, vector: vector),
      );
    }
    return result;
  }

  Future<int> vectorCount() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM memo_vectors WHERE model = ?',
      <Object?>[AppConfig.embeddingModelId],
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  // ------------------------------------------------------------- 收件箱去重

  Future<bool> isIngested(File file) async {
    final db = await database;
    final stat = await file.stat();
    final rows = await db.query(
      'ingest_log',
      where: 'file_path = ? AND file_size = ? AND file_mtime = ?',
      whereArgs: <Object?>[
        file.path,
        stat.size,
        stat.modified.millisecondsSinceEpoch,
      ],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> markIngested(File file) async {
    final db = await database;
    final stat = await file.stat();
    await db.insert(
      'ingest_log',
      <String, Object?>{
        'file_path': file.path,
        'file_size': stat.size,
        'file_mtime': stat.modified.millisecondsSinceEpoch,
        'ingested_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 调试用：数据库文件大小与路径。
  Future<String> describe() async {
    final file = _paths.databaseFile;
    final exists = await file.exists();
    final size = exists ? await file.length() : 0;
    final total = await totalCount();
    final vectors = await vectorCount();
    return '${p.basename(file.path)} · ${(size / 1024).toStringAsFixed(0)} KB · '
        '$total 条记录 · $vectors 条向量';
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
