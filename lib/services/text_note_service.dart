import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/app_log.dart';
import '../core/app_paths.dart';
import '../core/family_member.dart';
import '../models/memo.dart';
import 'atomic_io.dart';
import 'database_service.dart';

/// 纯文本随手记。
///
/// 与录音一样遵守"先临时后重命名"的规矩：文本文件虽然小，但 Syncthing
/// 完全可能在 `writeAsString` 执行到一半时读到 0 字节版本，
/// Mac 端就会拿到一条空记录。
class TextNoteService {
  TextNoteService({required AppPaths paths, required DatabaseService db})
    : _paths = paths,
      _db = db;

  final AppPaths _paths;
  final DatabaseService _db;

  Future<Memo> create({
    required FamilyMember member,
    required String deviceId,
    required String content,
    required DateTime createdAt,
  }) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('内容为空');
    }
    await _paths.ensureMemberLayout(member.dirName);

    final id = await _uniqueId(member.dirName, createdAt);
    final target = _paths.outboxFile(member.dirName, '$id.txt');
    await AtomicIo.writeString(target, trimmed);

    final memo = Memo(
      id: id,
      kind: MemoKind.text,
      author: member.author,
      authorDir: member.dirName,
      deviceId: deviceId,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      rawText: trimmed,
      summary: '',
      status: MemoStatus.local,
    );
    await _db.upsertMemo(memo);
    AppLog.i('note', '文本记录已写入 ${target.path}');
    return memo;
  }

  Future<String> _uniqueId(String dirName, DateTime createdAt) async {
    final base = Memo.newId(createdAt);
    var candidate = base;
    var counter = 1;
    while (await _paths.outboxFile(dirName, '$candidate.txt').exists()) {
      counter += 1;
      candidate = '${base}_$counter';
    }
    return candidate;
  }

  /// 调试用：列出某个成员 outbox 里还没被处理的文件。
  Future<List<String>> listPendingFiles(String dirName) async {
    final dir = _paths.outboxDir(dirName);
    if (!await dir.exists()) return const <String>[];
    final names = <String>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      names.add(p.basename(entity.path));
    }
    names.sort();
    return names;
  }
}
