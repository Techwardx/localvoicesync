import 'package:flutter/material.dart';

import '../models/memo.dart';
import '../theme.dart';

/// 可交互的 TODO 清单。
///
/// 勾选会立刻写回 SQLite，并且在下一次 Mac 回传时按任务文本对齐保留，
/// 不会被旧状态覆盖（见 `DatabaseService._mergeTodos`）。
class TodoList extends StatelessWidget {
  const TodoList({
    super.key,
    required this.todos,
    required this.onChanged,
  });

  final List<TodoItem> todos;
  final void Function(int index, bool completed) onChanged;

  @override
  Widget build(BuildContext context) {
    if (todos.isEmpty) {
      return const Text(
        '这条记录里没有待办事项',
        style: TextStyle(fontSize: 13, color: AppTheme.muted),
      );
    }
    final done = todos.where((t) => t.completed).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '待办',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppTheme.muted.withValues(alpha: 0.9),
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(width: 8),
            Text('$done/${todos.length}', style: AppTheme.mono),
          ],
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < todos.length; i++)
          _TodoRow(
            todo: todos[i],
            onChanged: (value) => onChanged(i, value),
          ),
      ],
    );
  }
}

class _TodoRow extends StatelessWidget {
  const _TodoRow({required this.todo, required this.onChanged});

  final TodoItem todo;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => onChanged(!todo.completed),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: todo.completed,
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
            const SizedBox(width: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  todo.task,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: todo.completed ? AppTheme.muted : AppTheme.ink,
                    decoration: todo.completed
                        ? TextDecoration.lineThrough
                        : TextDecoration.none,
                    decorationColor: AppTheme.muted,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
