import 'package:flutter/material.dart';

import '../models/memo.dart';
import '../theme.dart';

/// 可交互的 TODO 清单（详情页内）。
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
        style: AppType.caption,
      );
    }
    final done = todos.where((t) => t.completed).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('$done/${todos.length}', style: AppTheme.mono),
          ],
        ),
        const SizedBox(height: AppSpace.sm),
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
      onTap: () => onChanged(!todo.completed),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.sm + 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: Checkbox(
                value: todo.completed,
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
              child: Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text(
                  todo.task,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.6,
                    color: todo.completed ? AppTheme.faint : AppTheme.ink,
                    decoration: todo.completed
                        ? TextDecoration.lineThrough
                        : TextDecoration.none,
                    decorationColor: AppTheme.faint,
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
