import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_config.dart';
import '../models/memo.dart';
import '../providers.dart';
import '../theme.dart';

/// 编辑一条**文本**笔记：正文 + 标签。
///
/// 语音笔记不进来——正文是 Whisper 的转写结果，改它等于伪造转写，
/// 而且音频本身也没法编辑。详情页只在 `kind == text` 时给入口。
///
/// 保存不是"只改本地"：正文写回 `outbox/<id>.txt`、标签写进
/// `outbox/<id>.meta.json`，Syncthing 送到 Mac 后自动重跑一次提炼。
class MemoEditPage extends ConsumerStatefulWidget {
  const MemoEditPage({super.key, required this.memo});

  final Memo memo;

  @override
  ConsumerState<MemoEditPage> createState() => _MemoEditPageState();
}

class _MemoEditPageState extends ConsumerState<MemoEditPage> {
  late final TextEditingController _body;
  late final TextEditingController _tagInput;
  late List<String> _tags;
  bool _tagsEdited = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _body = TextEditingController(text: widget.memo.rawText);
    _tagInput = TextEditingController();
    _tags = List<String>.from(widget.memo.tags);
    _body.addListener(_onChanged);
  }

  @override
  void dispose() {
    _body.removeListener(_onChanged);
    _body.dispose();
    _tagInput.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  bool get _dirty {
    if (_body.text.trim() != widget.memo.rawText.trim()) return true;
    if (!_tagsEdited) return false;
    return true;
  }

  bool get _canSave => !_saving && _body.text.trim().isNotEmpty;

  void _addTag(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return;
    if (text.length > AppConfig.maxTagLength) {
      _toast('标签太长（最多 ${AppConfig.maxTagLength} 个字）');
      return;
    }
    final exists = _tags.any(
      (tag) => tag.toLowerCase() == text.toLowerCase(),
    );
    if (exists) {
      _tagInput.clear();
      return;
    }
    if (_tags.length >= AppConfig.maxUserTags) {
      _toast('最多 ${AppConfig.maxUserTags} 个标签');
      return;
    }
    setState(() {
      _tags.add(text);
      _tagsEdited = true;
      _tagInput.clear();
    });
  }

  void _removeTag(String tag) {
    setState(() {
      _tags.remove(tag);
      _tagsEdited = true;
    });
  }

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _saving = true);
    final updated = await ref
        .read(memoListProvider.notifier)
        .saveEdit(
          memo: widget.memo,
          content: _body.text,
          tags: _tags,
          tagsEdited: _tagsEdited,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (updated == null) {
      _toast('保存失败，请重试（设置 → 诊断 可看原因）');
      return;
    }
    Navigator.of(context).pop(updated);
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty || _saving) return true;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('放弃这次修改？'),
        content: const Text('改动还没有保存，返回后会丢失。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('继续编辑'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('放弃', style: TextStyle(color: AppTheme.danger)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = ref.watch(tagCountsProvider);
    return PopScope(
      canPop: !_dirty || _saving,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // 先把 Navigator 抓在手里：await 之后 build 的 context 可能已经失效，
        // 分析器也不会认 `mounted` 能护住它。
        final navigator = Navigator.of(context);
        if (await _confirmDiscard() && mounted) {
          navigator.pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('编辑文本'),
          actions: [
            TextButton(
              onPressed: _canSave ? _save : null,
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存'),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: [
            _Hint(
              icon: Icons.cloud_sync_outlined,
              text: '保存后会同步到电脑重新提炼：摘要、知识点、待办都会按新内容重算，'
                  '标签以你写的为准。',
            ),
            const SizedBox(height: 14),
            const _SectionLabel('正文'),
            const SizedBox(height: 6),
            Container(
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppTheme.hairline),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: TextField(
                controller: _body,
                minLines: 12,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                style: const TextStyle(fontSize: 14, height: 1.8),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  hintText: '写下要记的内容…',
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                const Expanded(child: _SectionLabel('标签')),
                Text(
                  '${_tags.length}/${AppConfig.maxUserTags}',
                  style: AppTheme.mono,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_tags.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  '还没有标签。加几个，以后按标签找得到。',
                  style: TextStyle(fontSize: 12.5, color: AppTheme.muted),
                ),
              )
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in _tags)
                    InputChip(
                      label: Text(tag),
                      labelStyle: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.primary,
                        fontWeight: FontWeight.w500,
                      ),
                      backgroundColor: AppTheme.primarySoft,
                      side: BorderSide.none,
                      deleteIconColor: AppTheme.primary,
                      onDeleted: () => _removeTag(tag),
                    ),
                ],
              ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _tagInput,
                    textInputAction: TextInputAction.done,
                    onSubmitted: _addTag,
                    style: const TextStyle(fontSize: 13.5),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '添加标签，回车确认',
                      hintStyle: const TextStyle(
                        fontSize: 13,
                        color: AppTheme.muted,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 11,
                      ),
                      filled: true,
                      fillColor: AppTheme.surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppTheme.hairline),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppTheme.hairline),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: () => _addTag(_tagInput.text),
                  icon: const Icon(Icons.add, size: 18),
                  style: IconButton.styleFrom(
                    backgroundColor: AppTheme.primarySoft,
                    foregroundColor: AppTheme.primary,
                  ),
                ),
              ],
            ),
            // 已有标签：点一下就加，避免用户自己造同义变体。
            suggestions.when(
              data: (items) {
                final pool = items
                    .map((e) => e.tag)
                    .where(
                      (tag) => !_tags.any(
                        (picked) => picked.toLowerCase() == tag.toLowerCase(),
                      ),
                    )
                    .take(12)
                    .toList(growable: false);
                if (pool.isEmpty) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '已有标签',
                        style: TextStyle(fontSize: 12, color: AppTheme.muted),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final tag in pool)
                            ActionChip(
                              label: Text(tag),
                              labelStyle: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.muted,
                              ),
                              backgroundColor: Colors.transparent,
                              side: const BorderSide(color: AppTheme.hairline),
                              onPressed: () => _addTag(tag),
                            ),
                        ],
                      ),
                    ],
                  ),
                );
              },
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _canSave ? _save : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                backgroundColor: AppTheme.primary,
              ),
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('保存并重新提炼'),
            ),
            const SizedBox(height: 10),
            const Text(
              '语音记录不支持编辑：它的正文是转写结果，改了就不真实了。',
              style: TextStyle(fontSize: 11.5, color: AppTheme.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: AppTheme.muted.withValues(alpha: 0.95),
        letterSpacing: 0.4,
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppTheme.primarySoft,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: AppTheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 12,
                height: 1.6,
                color: AppTheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
