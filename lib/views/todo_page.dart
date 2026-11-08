import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/todo.dart';
import '../providers.dart';
import '../theme.dart';
import 'memo_detail_page.dart';

/// 独立的待办页面。
///
/// 与其它页面零耦合：不改数据库表结构、不改笔记内容、不参与检索索引，
/// 只在底部导航多一个入口。数据来自两处——所有笔记里的 `todos`，以及
/// 用户在这里手工加的条目；两者的完成状态都写进同步目录的 `todos/*.json`。
///
/// 已完成默认折叠在未完成下面：完成的条目会越积越多，展开铺一屏会把
/// 真正要做的事挤到看不见的地方。
class TodoPage extends ConsumerStatefulWidget {
  const TodoPage({super.key});

  @override
  ConsumerState<TodoPage> createState() => _TodoPageState();
}

class _TodoPageState extends ConsumerState<TodoPage> {
  final TextEditingController _composer = TextEditingController();

  /// 已完成分组默认折叠。
  bool _showCompleted = false;
  bool _adding = false;

  static final DateFormat _shortTime = DateFormat('MM-dd HH:mm');

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _adding) return;
    setState(() => _adding = true);
    await ref.read(todoListProvider.notifier).add(text);
    if (!mounted) return;
    setState(() => _adding = false);
    _composer.clear();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }

  Future<void> _delete(TodoEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这条待办？'),
        content: Text('「${entry.task}」会从所有设备上移除。'),
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
    await ref.read(todoListProvider.notifier).remove(entry);
    _toast('已删除');
  }

  @override
  Widget build(BuildContext context) {
    final asyncTodos = ref.watch(todoListProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('待办'),
        actions: [
          IconButton(
            tooltip: '重新对账（读取别的设备刚同步过来的状态）',
            onPressed: () => unawaited(
              ref.read(todoListProvider.notifier).reconcile(),
            ),
            icon: const Icon(Icons.sync_outlined, size: 20),
          ),
        ],
      ),
      body: asyncTodos.when(
        loading: () => const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '待办读取失败：$error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.muted, fontSize: 13),
            ),
          ),
        ),
        data: (entries) {
          final groups = groupTodos(entries);
          return RefreshIndicator(
            onRefresh: () =>
                ref.read(todoListProvider.notifier).reconcile(),
            child: ListView(
              // 内容再少也要能下拉刷新：状态文件是别的设备写的。
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 48),
              children: [
                _Composer(
                  controller: _composer,
                  busy: _adding,
                  onSubmit: () => unawaited(_add()),
                ),
                const SizedBox(height: 18),
                _SectionHeader(
                  title: '未完成',
                  count: groups.pending.length,
                  color: AppTheme.primary,
                ),
                const SizedBox(height: 8),
                if (groups.pending.isEmpty)
                  const _EmptyHint(
                    text: '还没有待办。\n笔记里被提炼出来的事项会自动出现在这里，\n也可以直接在上方手动添加。',
                  )
                else
                  for (final entry in groups.pending)
                    _TodoTile(
                      entry: entry,
                      timeFormat: _shortTime,
                      onChanged: (value) => unawaited(
                        ref.read(todoListProvider.notifier).toggle(entry, value),
                      ),
                      onDelete: () => unawaited(_delete(entry)),
                      onOpen: () => _openMemo(entry),
                    ),
                const SizedBox(height: 22),
                // 已完成永远排在未完成下面，且默认折叠。
                _CompletedSection(
                  count: groups.completed.length,
                  expanded: _showCompleted,
                  onToggle: () =>
                      setState(() => _showCompleted = !_showCompleted),
                  children: [
                    for (final entry in groups.completed)
                      _TodoTile(
                        entry: entry,
                        timeFormat: _shortTime,
                        onChanged: (value) => unawaited(
                          ref
                              .read(todoListProvider.notifier)
                              .toggle(entry, value),
                        ),
                        onDelete: () => unawaited(_delete(entry)),
                        onOpen: () => _openMemo(entry),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                const _SyncHint(),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _openMemo(TodoEntry entry) async {
    final id = entry.memoId;
    if (id == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MemoDetailPage(memoId: id),
      ),
    );
    // 详情页里可能也勾过待办，回来重新对一次账。
    if (mounted) {
      await ref.read(todoListProvider.notifier).reconcile();
    }
  }
}

/// 手工新增待办的输入条。
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.busy,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.hairline),
      ),
      child: Row(
        children: [
          const SizedBox(width: 8),
          const Icon(Icons.add_task_outlined, size: 19, color: AppTheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 2,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => onSubmit(),
              decoration: const InputDecoration(
                hintText: '添加一条待办…',
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: EdgeInsets.symmetric(vertical: 10),
              ),
              style: const TextStyle(fontSize: 14, color: AppTheme.ink),
            ),
          ),
          const SizedBox(width: 4),
          IconButton.filled(
            onPressed: busy ? null : onSubmit,
            style: IconButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
              disabledBackgroundColor: AppTheme.hairline,
              minimumSize: const Size(38, 38),
            ),
            icon: busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.add, size: 20),
            tooltip: '添加',
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.count,
    required this.color,
  });

  final String title;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 13,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: AppTheme.muted.withValues(alpha: 0.95),
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(width: 8),
        Text('$count', style: AppTheme.mono),
      ],
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 26),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.hairline),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 13,
          height: 1.9,
          color: AppTheme.muted,
        ),
      ),
    );
  }
}

/// 已完成分组：默认折叠，点击标题才展开。
class _CompletedSection extends StatelessWidget {
  const _CompletedSection({
    required this.count,
    required this.expanded,
    required this.onToggle,
    required this.children,
  });

  final int count;
  final bool expanded;
  final VoidCallback onToggle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: count == 0 ? null : onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
            child: Row(
              children: [
                const Icon(
                  Icons.check_circle_outline,
                  size: 15,
                  color: AppTheme.muted,
                ),
                const SizedBox(width: 8),
                Text(
                  '已完成',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.muted.withValues(alpha: 0.95),
                  ),
                ),
                const SizedBox(width: 8),
                Text('$count', style: AppTheme.mono),
                const Spacer(),
                Text(
                  expanded ? '收起' : '展开',
                  style: const TextStyle(fontSize: 12, color: AppTheme.primary),
                ),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: AppTheme.primary,
                ),
              ],
            ),
          ),
        ),
        if (expanded && count > 0) ...[
          const SizedBox(height: 4),
          ...children,
        ],
      ],
    );
  }
}

class _TodoTile extends StatelessWidget {
  const _TodoTile({
    required this.entry,
    required this.timeFormat,
    required this.onChanged,
    required this.onDelete,
    required this.onOpen,
  });

  final TodoEntry entry;
  final DateFormat timeFormat;
  final ValueChanged<bool> onChanged;
  final VoidCallback onDelete;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.hairline),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: entry.fromNote ? onOpen : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 26,
                height: 26,
                child: Checkbox(
                  value: entry.completed,
                  onChanged: (value) => onChanged(value ?? false),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  side: const BorderSide(color: AppTheme.hairline, width: 1.6),
                  activeColor: AppTheme.primary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.task,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: entry.completed ? AppTheme.muted : AppTheme.ink,
                          decoration: entry.completed
                              ? TextDecoration.lineThrough
                              : TextDecoration.none,
                          decorationColor: AppTheme.muted,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _SourceChip(fromNote: entry.fromNote),
                          if (entry.fromNote && entry.memoTitle.isNotEmpty)
                            Text(
                              entry.memoTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppTheme.muted,
                              ),
                            ),
                          if (entry.author.isNotEmpty)
                            Text(entry.author, style: AppTheme.mono),
                          Text(
                            timeFormat.format(entry.createdAt),
                            style: AppTheme.mono,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (entry.fromManual)
                IconButton(
                  tooltip: '删除这条手工待办',
                  onPressed: onDelete,
                  icon: const Icon(Icons.close, size: 16),
                  color: AppTheme.muted,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.fromNote});

  final bool fromNote;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: fromNote ? AppTheme.primarySoft : const Color(0xFFF3EEE4),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        fromNote ? '来自笔记' : '手动添加',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: fromNote ? AppTheme.primary : AppTheme.accent,
        ),
      ),
    );
  }
}

/// 一句话讲清状态存在哪儿，避免用户以为"重装 App 就没了"。
class _SyncHint extends StatelessWidget {
  const _SyncHint();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text(
        '勾选状态和手动待办保存在同步目录 todos/ 下，每台设备各写一份，'
        'Mac 与其它手机会自动同步。下拉或点右上角可重新对账。',
        style: TextStyle(
          fontSize: 11,
          height: 1.7,
          color: AppTheme.muted.withValues(alpha: 0.8),
        ),
      ),
    );
  }
}
