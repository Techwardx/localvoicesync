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
///
/// 视觉上：待办本体是主角，来源与时间弱化成一行浅淡小字；
/// 同步机制的说明移到「设置 → 高级」，不占主视图。
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
        // 与其它页面左上角大标题统一到 24，不再用主题里的 19。
        titleTextStyle: AppType.pageTitle,
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
              padding: const EdgeInsets.fromLTRB(
                AppSpace.pageInset,
                AppSpace.md,
                AppSpace.pageInset,
                48,
              ),
              children: [
                _Composer(
                  controller: _composer,
                  busy: _adding,
                  onSubmit: () => unawaited(_add()),
                ),
                const SizedBox(height: AppSpace.xxl),
                _SectionHeader(title: '未完成', count: groups.pending.length),
                const SizedBox(height: AppSpace.sm),
                if (groups.pending.isEmpty)
                  const _EmptyHint(
                    text: '还没有待办。\n笔记里被提炼出来的事项会自动出现在这里，\n也可以直接在上方手动添加。',
                  )
                else
                  for (final entry in groups.pending)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpace.panelGap),
                      child: _TodoTile(
                        entry: entry,
                        timeFormat: _shortTime,
                        onChanged: (value) => unawaited(
                          ref.read(todoListProvider.notifier).toggle(entry, value),
                        ),
                        onDelete: () => unawaited(_delete(entry)),
                        onOpen: () => _openMemo(entry),
                      ),
                    ),
                const SizedBox(height: AppSpace.xxl),
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

/// 手工新增待办的输入条：一块浅色面板，与下方列表项同一套承托。
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
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: AppSpace.sm + 2,
      ),
      decoration: AppTheme.panel(),
      child: Row(
        children: [
          Icon(Icons.add, size: 19, color: AppTheme.primary),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 2,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => onSubmit(),
              decoration: const InputDecoration(
                hintText: '添加一条待办…',
                hintStyle: AppType.inputHint,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
              style: const TextStyle(
                fontSize: 14,
                color: AppTheme.ink,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          IconButton(
            onPressed: busy ? null : onSubmit,
            icon: busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppTheme.primary,
                    ),
                  )
                : const Icon(Icons.arrow_upward_rounded, size: 19),
            color: AppTheme.primary,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            tooltip: '添加',
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Row(
        children: [
          Text(title, style: AppType.section),
          const SizedBox(width: AppSpace.sm),
          Text('$count', style: AppTheme.mono),
        ],
      ),
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
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.lg,
        vertical: AppSpace.xxl,
      ),
      decoration: AppTheme.panel(),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: AppType.secondary,
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
          onTap: count == 0 ? null : onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
            child: Row(
              children: [
                Text('已完成', style: AppType.section),
                const SizedBox(width: AppSpace.sm),
                Text('$count', style: AppTheme.mono),
                const Spacer(),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: AppTheme.faint,
                ),
              ],
            ),
          ),
        ),
        if (expanded && count > 0) ...[
          const SizedBox(height: AppSpace.xs),
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
    // 来源与时间并成一行浅淡小字：信息仍在，但不再用彩色标抢注意力。
    final source = entry.fromNote
        ? (entry.memoTitle.isNotEmpty ? entry.memoTitle : '来自笔记')
        : '手动添加';
    final meta = <String>[
      source,
      if (entry.author.isNotEmpty) entry.author,
      timeFormat.format(entry.createdAt),
    ].join(' · ');

    return Material(
      color: entry.completed ? AppTheme.background : AppTheme.surface,
      borderRadius: BorderRadius.circular(AppSpace.radiusCard),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppSpace.radiusCard),
        onTap: entry.fromNote ? onOpen : null,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            vertical: AppSpace.md + 2,
            horizontal: AppSpace.md,
          ),
          decoration: AppTheme.panel(
            color: entry.completed ? AppTheme.background : null,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: Checkbox(
                  value: entry.completed,
                  onChanged: (value) => onChanged(value ?? false),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  side: BorderSide(color: AppTheme.hairline, width: 1.5),
                  activeColor: AppTheme.primary,
                  fillColor: WidgetStateProperty.resolveWith<Color>((states) {
                    if (states.contains(WidgetState.selected)) {
                      return AppTheme.primary;
                    }
                    return Colors.transparent;
                  }),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.task,
                      style: TextStyle(
                        fontSize: 14.5,
                        height: 1.5,
                        color: entry.completed
                            ? AppTheme.faint
                            : AppTheme.ink,
                        decoration: entry.completed
                            ? TextDecoration.lineThrough
                            : TextDecoration.none,
                        decorationColor: AppTheme.faint,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.footnote,
                    ),
                  ],
                ),
              ),
              if (entry.fromManual)
                IconButton(
                  tooltip: '删除这条手工待办',
                  onPressed: onDelete,
                  icon: const Icon(Icons.close, size: 15),
                  color: AppTheme.faint,
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
