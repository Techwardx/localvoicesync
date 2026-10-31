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

  /// 写一条文本随手记。
  ///
  /// 返回值里的 [dbError] 非空表示"文件已经安全落盘，但写数据库失败"。
  ///
  /// 为什么不能在这里抛异常：真机上出现过写库失败（文件其实已经进了
  /// outbox、Mac 也处理了），但整次调用抛错 → 界面报"保存失败，请重试"
  /// → 用户反复点 → outbox 里堆出一串重复文件。文件是唯一的真源，
  /// 只要它落盘成功，这次保存就算成功；数据库可以之后再补。
  Future<({Memo memo, Object? dbError})> create({
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

    Object? dbError;
    try {
      await _db.upsertMemo(memo);
    } on Object catch (error) {
      dbError = error;
      AppLog.e('note', '文本记录已落盘但写库失败（文件不会丢）：$error');
    }
    AppLog.i('note', '文本记录已写入 ${target.path}');
    return (memo: memo, dbError: dbError);
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
