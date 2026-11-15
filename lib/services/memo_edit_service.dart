import 'dart:convert';

import '../core/app_config.dart';
import '../core/app_log.dart';
import '../core/app_paths.dart';
import '../models/memo.dart';
import 'atomic_io.dart';
import 'database_service.dart';
import 'search_service.dart';

/// 一次编辑保存的结果。
class MemoEditResult {
  const MemoEditResult({
    required this.memo,
    required this.changed,
    required this.wroteText,
    required this.wroteTags,
    this.indexError,
  });

  final Memo memo;

  /// 有没有真的写文件。false 表示正文和标签都没变，什么都没发生。
  final bool changed;
  final bool wroteText;
  final bool wroteTags;

  /// 本地向量重算失败的原因。**不影响保存**，只是搜索会暂时用旧向量。
  final Object? indexError;
}

/// 文本笔记的编辑：把改动写回 outbox，等 Mac 重新提炼。
///
/// ## 只允许文本笔记
///
/// 语音笔记的正文是 Whisper 转写，改它等于伪造转写结果；而且音频本身没法
/// 编辑。所以这里硬性拒绝 `MemoKind.audio`，UI 也不给入口。
///
/// ## 写回哪里
///
/// 正文覆盖 `<成员>_Notes/outbox/<id>.txt`——这是 Mac 端唯一的输入源。
/// 内容变了 → sha256 变 → Mac 自动重跑，不需要任何"上传"动作。
///
/// 标签写进并排的 `<id>.meta.json`（旁车）。**不能**只改本地数据库：
/// Mac 重提炼时会用 AI 结果覆盖 `tags`，用户改的标签会白改。也不能写进
/// 正文——正文会被原样当作转写喂给模型。
///
/// ## 顺序
///
/// 先写正文、再写旁车，最后才改数据库。文件是唯一的真源：只要文件写成功，
/// 即使数据库这一步失败，Mac 回传后也会自动补齐。
class MemoEditService {
  MemoEditService({
    required AppPaths paths,
    required DatabaseService db,
    required SearchService search,
  }) : _paths = paths,
       _db = db,
       _search = search;

  final AppPaths _paths;
  final DatabaseService _db;
  final SearchService _search;

  /// 清洗用户输入的标签：去空白、丢空值、去重、限长、限数量。
  ///
  /// 大小写不敏感去重（"QCY" / "qcy" 只留第一个），但**保留原始写法**——
  /// 用户打的品牌名不该被 App 擅自改成小写。
  static List<String> cleanTags(Iterable<String> raw) {
    final result = <String>[];
    final seen = <String>{};
    for (final item in raw) {
      final text = item.trim();
      if (text.isEmpty || text.length > AppConfig.maxTagLength) continue;
      final key = text.replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
      if (!seen.add(key)) continue;
      result.add(text);
      if (result.length >= AppConfig.maxUserTags) break;
    }
    return result;
  }

  /// 保存编辑。
  ///
  /// [tagsEdited] 为 true 表示用户在编辑页动过标签——哪怕最后把标签全删了，
  /// 也要写旁车，因为"没有标签"本身也是用户的决定，不能让 AI 再补回来。
  Future<MemoEditResult> save({
    required Memo memo,
    required String content,
    required List<String> tags,
    required bool tagsEdited,
  }) async {
    if (memo.kind != MemoKind.text) {
      throw ArgumentError('语音记录不支持编辑');
    }
    final text = content.trim();
    if (text.isEmpty) {
      throw ArgumentError('内容不能为空');
    }

    final clean = tagsEdited ? cleanTags(tags) : memo.tags;
    final tagsChanged = tagsEdited && !_sameTags(clean, memo.tags);

    await _paths.ensureMemberLayout(memo.authorDir);
    final noteFile = _paths.noteSourceFile(memo.authorDir, memo.id);

    // 正文文件可能因为同步没到位而不存在；这时即使正文没改也要补写，
    // 否则旁车会指向一个不存在的笔记，Mac 永远处理不了。
    var fileText = '';
    var fileExists = false;
    try {
      fileExists = await noteFile.exists();
      if (fileExists) fileText = await noteFile.readAsString();
    } on Object catch (error) {
      AppLog.w('edit', '读取待编辑正文失败（按不存在处理）：$error');
      fileExists = false;
    }

    final needText = !fileExists || fileText != text;
    if (!needText && !tagsChanged) {
      return MemoEditResult(
        memo: memo,
        changed: false,
        wroteText: false,
        wroteTags: false,
      );
    }

    var wroteText = false;
    var wroteTags = false;
    try {
      if (needText) {
        await AtomicIo.writeString(noteFile, text);
        wroteText = true;
      }
      if (tagsChanged) {
        await AtomicIo.writeString(
          _paths.noteMetaFile(memo.authorDir, memo.id),
          jsonEncode(<String, Object?>{
            'id': memo.id,
            'tags': clean,
            'tags_edited': true,
            'edited_at': _formatStamp(DateTime.now()),
          }),
        );
        wroteTags = true;
      }
    } on Object catch (error) {
      // 文件没写成功就不能假装保存成功：这次编辑根本没送到 Mac。
      AppLog.e('edit', '编辑写回 outbox 失败：$error');
      rethrow;
    }

    // 本地立刻可见：正文与标签先按用户写的显示，状态回到"待处理"，
    // 等 Mac 回传后 summary / 知识点 / 待办会被整体刷新。
    final updated = memo.copyWith(
      rawText: text,
      tags: clean,
      status: MemoStatus.local,
      updatedAt: DateTime.now(),
    );
    await _db.upsertMemo(updated);

    Object? indexError;
    try {
      await _search.indexMemo(updated);
    } on Object catch (error) {
      indexError = error;
      AppLog.w('edit', '编辑后重算向量失败（搜索暂用旧向量）：$error');
    }

    AppLog.i(
      'edit',
      '已保存编辑 ${memo.id}：正文${wroteText ? '已写' : '未变'}、'
          '标签${wroteTags ? '已写' : '未变'}（等 Mac 重新提炼）',
    );
    return MemoEditResult(
      memo: updated,
      changed: true,
      wroteText: wroteText,
      wroteTags: wroteTags,
      indexError: indexError,
    );
  }

  /// 手动把某条文本笔记重新推一次（正文没改也可以）。
  ///
  /// 用途：Mac 端处理失败、或者用户就是想再跑一遍提炼。直接把正文原样
  /// 重写一遍并不够——内容没变，哈希也没变，Mac 还是会跳过。所以这里
  /// 强制写一份旁车（即使标签没动），让组合哈希必然变化。
  Future<MemoEditResult> resubmit(Memo memo) async {
    if (memo.kind != MemoKind.text) {
      throw ArgumentError('语音记录不支持重新提交');
    }
    await _paths.ensureMemberLayout(memo.authorDir);
    final noteFile = _paths.noteSourceFile(memo.authorDir, memo.id);
    if (!await noteFile.exists()) {
      await AtomicIo.writeString(noteFile, memo.rawText.trim());
    }

    // 旁车必须存在，否则哈希不变、Mac 仍然跳过。但**不能**趁机把标签锁死：
    // 用户点「重新提炼」多半是嫌摘要不好，这时标签应该重新由 AI 判断。
    // 所以：已有旁车就只更新 edited_at（保留他改过的标签），没有就写一份
    // `tags_edited: false` 的空旁车，纯粹用来改变哈希。
    final metaFile = _paths.noteMetaFile(memo.authorDir, memo.id);
    final stamp = _formatStamp(DateTime.now());
    Map<String, Object?> meta = <String, Object?>{
      'id': memo.id,
      'tags': <String>[],
      'tags_edited': false,
    };
    try {
      if (await metaFile.exists()) {
        final decoded = jsonDecode(await metaFile.readAsString());
        if (decoded is Map) {
          meta = decoded.map((key, value) => MapEntry(key.toString(), value));
        }
      }
    } on Object catch (error) {
      AppLog.w('edit', '读取已有旁车失败，按空旁车重写：$error');
    }
    meta['id'] = memo.id;
    meta['edited_at'] = stamp;
    await AtomicIo.writeString(metaFile, jsonEncode(meta));
    final updated = memo.copyWith(
      status: MemoStatus.local,
      updatedAt: DateTime.now(),
    );
    await _db.upsertMemo(updated);
    return MemoEditResult(
      memo: updated,
      changed: true,
      wroteText: false,
      wroteTags: true,
    );
  }

  static bool _sameTags(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _formatStamp(DateTime moment) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${moment.year}-${two(moment.month)}-${two(moment.day)} '
        '${two(moment.hour)}:${two(moment.minute)}:${two(moment.second)}';
  }

}
