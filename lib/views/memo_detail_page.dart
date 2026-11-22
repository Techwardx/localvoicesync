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
import 'memo_edit_page.dart';

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

  /// 打开编辑页。只有文本笔记有这个入口。
  Future<void> _openEditor() async {
    final memo = _memo;
    if (memo == null || memo.kind != MemoKind.text) return;
    final updated = await Navigator.of(context).push<Memo>(
      MaterialPageRoute(builder: (_) => MemoEditPage(memo: memo)),
    );
    if (!mounted) return;
    if (updated != null) {
      setState(() => _memo = updated);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('已保存，电脑正在重新提炼（通常几十秒后自动刷新）'),
          ),
        );
    }
    await _load();
  }

  /// Mac 端上次处理失败时，手动把这条文本笔记再推一次。
  Future<void> _resubmit() async {
    final memo = _memo;
    if (memo == null) return;
    final updated = await ref
        .read(memoListProvider.notifier)
        .resubmitEdit(memo);
    if (!mounted) return;
    if (updated == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('重新提交失败，请重试')),
      );
      return;
    }
    setState(() => _memo = updated);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已重新提交，等电脑提炼')),
    );
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
          // 只有文本笔记可编辑：语音的正文是转写结果，改它就不真实了。
          if (memo != null && memo.kind == MemoKind.text) ...[
            // 始终给一个「重新提炼」：处理失败时是重试，正常时是"让 AI 重新
            // 判断标签"（用户手改过标签后后悔了，这是唯一的退路）。
            IconButton(
              tooltip: '重新提炼',
              onPressed: _resubmit,
              icon: const Icon(Icons.refresh, size: 20),
            ),
            IconButton(
              tooltip: '编辑正文与标签',
              onPressed: _openEditor,
              icon: const Icon(Icons.edit_outlined, size: 20),
            ),
          ],
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
              padding: const EdgeInsets.fromLTRB(
                AppSpace.pageInset,
                AppSpace.lg,
                AppSpace.pageInset,
                40,
              ),
              children: [
                _MetaRow(memo: memo, format: _fullFormat),
                const SizedBox(height: AppSpace.xl),
                if (memo.hasAudio) ...[
                  _AudioBar(
                    path: AppPaths.instance
                        .audioFile(memo.authorDir, memo.audioFilename!)
                        .path,
                  ),
                  const SizedBox(height: AppSpace.lg),
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
                  const SizedBox(height: AppSpace.lg),
                ],
                if (memo.knowledgePoints.isNotEmpty) ...[
                  _SectionCard(
                    title: '知识点',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < memo.knowledgePoints.length; i++)
                          Padding(
                            padding: EdgeInsets.only(
                              bottom: i == memo.knowledgePoints.length - 1
                                  ? 0
                                  : AppSpace.md + 2,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  margin: const EdgeInsets.only(top: 9, right: AppSpace.md),
                                  width: 5,
                                  height: 5,
                                  decoration: const BoxDecoration(
                                    color: AppTheme.primaryMid,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    memo.knowledgePoints[i],
                                    style: AppType.reading,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpace.lg),
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
                  const SizedBox(height: AppSpace.lg),
                ],
                if (memo.tags.isNotEmpty) ...[
                  _SectionCard(
                    title: '标签',
                    child: Text(
                      memo.tags.join('  ·  '),
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.7,
                        color: AppTheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.lg),
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
                        style: AppType.reading,
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
    p: const TextStyle(fontSize: 14, height: 1.8, color: AppTheme.ink),
    h1: const TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w600,
      height: 1.5,
      color: AppTheme.ink,
    ),
    h2: const TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      height: 1.5,
      color: AppTheme.ink,
    ),
    h3: const TextStyle(
      fontSize: 14.5,
      fontWeight: FontWeight.w600,
      height: 1.5,
      color: AppTheme.ink,
    ),
    strong: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.ink),
    code: const TextStyle(
      fontSize: 12.5,
      backgroundColor: AppTheme.surfaceSoft,
      color: AppTheme.primary,
    ),
    listBullet: const TextStyle(fontSize: 14, height: 1.8),
    blockSpacing: 10,
    codeblockDecoration: BoxDecoration(
      color: AppTheme.surfaceSoft,
      borderRadius: BorderRadius.circular(AppSpace.radiusField),
    ),
    blockquoteDecoration: const BoxDecoration(
      border: Border(left: BorderSide(color: AppTheme.primary, width: 2)),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              isAudio ? Icons.graphic_eq : Icons.notes_rounded,
              size: 14,
              color: AppTheme.faint,
            ),
            const SizedBox(width: 6),
            Text(isAudio ? '语音记录' : '文本记录', style: AppType.section),
          ],
        ),
        const SizedBox(height: AppSpace.sm),
        Row(
          children: [
            Text(
              format.format(memo.createdAt),
              style: AppTheme.mono,
            ),
            const SizedBox(width: AppSpace.sm),
            Text('·', style: AppTheme.mono),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Text(
                memo.author,
                style: AppTheme.mono,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 安静的分区：靠小标题与留白分段，正文直接落在纸面上，
/// 不再用带描边的卡片把每一段内容都框起来。
/// 阅读分区：一块浅色面板 + 一条标题下细线托住内容，
/// 让长笔记在视觉上有分段与承托，读起来不糊成一片纯文字。
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
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.md + 2,
        AppSpace.lg,
        AppSpace.lg,
      ),
      decoration: AppTheme.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: AppType.section)),
              ?trailing,
            ],
          ),
          const Padding(
            padding: EdgeInsets.only(top: AppSpace.md),
            child: Divider(height: 1),
          ),
          const SizedBox(height: AppSpace.md + 2),
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
      return Text(
        error,
        style: const TextStyle(fontSize: 12, color: AppTheme.danger),
      );
    }

    final maxMs = _duration.inMilliseconds.toDouble();
    final value = _position.inMilliseconds
        .clamp(0, maxMs <= 0 ? 0 : maxMs.toInt())
        .toDouble();

    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.sm,
        AppSpace.sm,
        AppSpace.md,
        AppSpace.sm,
      ),
      decoration: AppTheme.panel(),
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
              size: 22,
            ),
            style: IconButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
              minimumSize: const Size(42, 42),
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
