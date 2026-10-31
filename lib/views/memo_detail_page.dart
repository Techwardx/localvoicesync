import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';

import '../core/app_paths.dart';
import '../models/memo.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/todo_list.dart';

/// 记录详情：Markdown 摘要 + 可勾选 TODO + 标签 + 可折叠原始转写。
class MemoDetailPage extends ConsumerStatefulWidget {
  const MemoDetailPage({super.key, required this.memoId});

  final String memoId;

  @override
  ConsumerState<MemoDetailPage> createState() => _MemoDetailPageState();
}

class _MemoDetailPageState extends ConsumerState<MemoDetailPage> {
  Memo? _memo;
  bool _loading = true;
  bool _transcriptExpanded = false;

  static final DateFormat _fullFormat = DateFormat('yyyy年M月d日 HH:mm:ss');

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final memo = await ref
        .read(servicesProvider)
        .database
        .memoById(widget.memoId);
    if (!mounted) return;
    setState(() {
      _memo = memo;
      _loading = false;
    });
  }

  Future<void> _toggleTodo(int index, bool completed) async {
    final memo = _memo;
    if (memo == null) return;
    // 先乐观更新 UI，再落库；失败就回滚。
    final optimistic = memo.copyWith(
      todos: [
        for (var i = 0; i < memo.todos.length; i++)
          i == index ? memo.todos[i].copyWith(completed: completed) : memo.todos[i],
      ],
    );
    setState(() => _memo = optimistic);
    try {
      await ref
          .read(memoListProvider.notifier)
          .toggleTodo(memo.id, index, completed);
      await _load();
    } on Object {
      if (!mounted) return;
      setState(() => _memo = memo);
    }
  }

  Future<void> _confirmDelete() async {
    final memo = _memo;
    if (memo == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这条记录？'),
        content: const Text('数据库里的这条记录会被移除。已经同步到 Mac 的音频文件不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除', style: TextStyle(color: AppTheme.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(memoListProvider.notifier).remove(memo.id);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final memo = _memo;
    return Scaffold(
      appBar: AppBar(
        title: const Text(''),
        actions: [
          if (memo != null)
            IconButton(
              tooltip: '删除',
              onPressed: _confirmDelete,
              icon: const Icon(Icons.delete_outline, size: 20),
            ),
        ],
      ),
      body: _loading
          ? const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : memo == null
          ? const Center(
              child: Text(
                '这条记录不存在了',
                style: TextStyle(color: AppTheme.muted),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
              children: [
                _MetaRow(memo: memo, format: _fullFormat),
                const SizedBox(height: 16),
                if (memo.hasAudio) ...[
                  _AudioBar(
                    path: AppPaths.instance
                        .audioFile(memo.authorDir, memo.audioFilename!)
                        .path,
                  ),
                  const SizedBox(height: 16),
                ],
                if (memo.summary.trim().isNotEmpty) ...[
                  _SectionCard(
                    title: '摘要',
                    child: MarkdownBody(
                      data: memo.summary,
                      selectable: true,
                      styleSheet: _markdownStyle,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (memo.knowledgePoints.isNotEmpty) ...[
                  _SectionCard(
                    title: '知识点',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final point in memo.knowledgePoints)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Padding(
                                  padding: EdgeInsets.only(top: 6, right: 8),
                                  child: SizedBox(
                                    width: 4,
                                    height: 4,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: AppTheme.primary,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    point,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      height: 1.65,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (memo.todos.isNotEmpty) ...[
                  _SectionCard(
                    title: '待办',
                    child: TodoList(
                      todos: memo.todos,
                      onChanged: (index, value) =>
                          unawaited(_toggleTodo(index, value)),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (memo.tags.isNotEmpty) ...[
                  _SectionCard(
                    title: '标签',
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final tag in memo.tags)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.primarySoft,
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: Text(
                              tag,
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.primary,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (memo.rawText.trim().isNotEmpty)
                  _SectionCard(
                    title: memo.kind == MemoKind.audio ? '原始转写' : '原文',
                    trailing: memo.kind == MemoKind.audio
                        ? TextButton(
                            onPressed: () => setState(
                              () => _transcriptExpanded = !_transcriptExpanded,
                            ),
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              minimumSize: Size.zero,
                              tapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text(
                              _transcriptExpanded ? '收起' : '展开',
                              style: const TextStyle(fontSize: 12),
                            ),
                          )
                        : null,
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 180),
                      alignment: Alignment.topCenter,
                      child: Text(
                        memo.rawText,
                        maxLines:
                            (memo.kind == MemoKind.audio &&
                                !_transcriptExpanded)
                            ? 4
                            : null,
                        overflow:
                            (memo.kind == MemoKind.audio &&
                                !_transcriptExpanded)
                            ? TextOverflow.ellipsis
                            : TextOverflow.clip,
                        style: const TextStyle(
                          fontSize: 13.5,
                          height: 1.85,
                          color: AppTheme.muted,
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                Text(
                  'ID  ${memo.id}\n'
                  '目录 ${memo.authorDir} · 设备 ${memo.deviceId}',
                  style: AppTheme.mono,
                ),
              ],
            ),
    );
  }

  static final MarkdownStyleSheet _markdownStyle = MarkdownStyleSheet(
    p: const TextStyle(fontSize: 14, height: 1.75, color: AppTheme.ink),
    h1: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, height: 1.5),
    h2: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, height: 1.5),
    h3: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.5),
    strong: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.ink),
    code: const TextStyle(
      fontSize: 12.5,
      backgroundColor: AppTheme.primarySoft,
      color: AppTheme.primary,
    ),
    listBullet: const TextStyle(fontSize: 14, height: 1.75),
    blockSpacing: 8,
    codeblockDecoration: BoxDecoration(
      color: AppTheme.primarySoft,
      borderRadius: BorderRadius.circular(8),
    ),
    blockquoteDecoration: const BoxDecoration(
      border: Border(left: BorderSide(color: AppTheme.primary, width: 3)),
    ),
  );
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.memo, required this.format});

  final Memo memo;
  final DateFormat format;

  @override
  Widget build(BuildContext context) {
    final isAudio = memo.kind == MemoKind.audio;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: isAudio ? AppTheme.primarySoft : const Color(0xFFF3EEE4),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isAudio ? Icons.graphic_eq : Icons.notes_rounded,
                size: 12,
                color: isAudio ? AppTheme.primary : AppTheme.accent,
              ),
              const SizedBox(width: 4),
              Text(
                isAudio ? '语音' : '文本',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: isAudio ? AppTheme.primary : AppTheme.accent,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Text(memo.author, style: AppTheme.mono),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            format.format(memo.createdAt),
            style: AppTheme.mono,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.muted.withValues(alpha: 0.95),
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// 极简音频播放条。
class _AudioBar extends StatefulWidget {
  const _AudioBar({required this.path});

  final String path;

  @override
  State<_AudioBar> createState() => _AudioBarState();
}

class _AudioBarState extends State<_AudioBar> {
  final AudioPlayer _player = AudioPlayer();
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  bool _playing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      final duration = await _player.setFilePath(widget.path);
      if (!mounted) return;
      setState(() => _duration = duration ?? Duration.zero);
      _player.positionStream.listen((position) {
        if (mounted) setState(() => _position = position);
      });
      _player.playerStateStream.listen((state) {
        if (mounted) setState(() => _playing = state.playing);
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = '无法播放：$error');
    }
  }

  @override
  void dispose() {
    unawaited(_player.dispose());
    super.dispose();
  }

  String _fmt(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.hairline),
        ),
        child: Text(
          error,
          style: const TextStyle(fontSize: 12, color: AppTheme.danger),
        ),
      );
    }

    final maxMs = _duration.inMilliseconds.toDouble();
    final value = _position.inMilliseconds
        .clamp(0, maxMs <= 0 ? 0 : maxMs.toInt())
        .toDouble();

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 14, 8),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.hairline),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () async {
              if (_playing) {
                await _player.pause();
              } else {
                if (_position >= _duration && _duration > Duration.zero) {
                  await _player.seek(Duration.zero);
                }
                await _player.play();
              }
            },
            icon: Icon(
              _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            ),
            style: IconButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: AppTheme.primary,
                inactiveTrackColor: AppTheme.hairline,
                thumbColor: AppTheme.primary,
              ),
              child: Slider(
                value: maxMs <= 0 ? 0 : value,
                max: maxMs <= 0 ? 1 : maxMs,
                onChanged: (next) {
                  unawaited(
                    _player.seek(Duration(milliseconds: next.round())),
                  );
                },
              ),
            ),
          ),
          Text(
            '${_fmt(_position)} / ${_fmt(_duration)}',
            style: AppTheme.mono,
          ),
        ],
      ),
    );
  }
}
