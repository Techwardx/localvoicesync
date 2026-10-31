import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/memo.dart';
import '../theme.dart';

/// 列表里的一条记录。
class MemoCard extends StatelessWidget {
  const MemoCard({super.key, required this.memo, this.onTap, this.highlight});

  final Memo memo;
  final VoidCallback? onTap;

  /// 搜索页用来高亮命中的关键词。
  final String? highlight;

  static final DateFormat _dayFormat = DateFormat('M月d日 HH:mm');
  static final DateFormat _yearFormat = DateFormat('yyyy年M月d日 HH:mm');

  String _timeLabel() {
    final now = DateTime.now();
    final sameYear = memo.createdAt.year == now.year;
    return (sameYear ? _dayFormat : _yearFormat).format(memo.createdAt);
  }

  @override
  Widget build(BuildContext context) {
    final isAudio = memo.kind == MemoKind.audio;
    final snippet = memo.summary.trim().isNotEmpty
        ? memo.summary.trim()
        : memo.rawText.trim();

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.hairline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: isAudio
                            ? AppTheme.primarySoft
                            : const Color(0xFFF3EEE4),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(
                        isAudio ? Icons.graphic_eq : Icons.notes_rounded,
                        size: 17,
                        color: isAudio ? AppTheme.primary : AppTheme.accent,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        memo.displayTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.35,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.1,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _StatusPill(status: memo.status),
                  ],
                ),
                if (snippet.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    snippet,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.55,
                      color: AppTheme.muted,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text(
                      _timeLabel(),
                      style: AppTheme.mono,
                    ),
                    const SizedBox(width: 10),
                    Text('·', style: AppTheme.mono),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        memo.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.mono,
                      ),
                    ),
                    if (memo.todos.isNotEmpty) ...[
                      const SizedBox(width: 10),
                      Icon(
                        Icons.checklist_rounded,
                        size: 13,
                        color: AppTheme.muted.withValues(alpha: 0.8),
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '${memo.todos.where((t) => t.completed).length}/'
                        '${memo.todos.length}',
                        style: AppTheme.mono,
                      ),
                    ],
                  ],
                ),
                if (memo.tags.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final tag in memo.tags.take(4))
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.primarySoft,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            tag,
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppTheme.primary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});

  final MemoStatus status;

  @override
  Widget build(BuildContext context) {
    late final String label;
    late final Color color;
    switch (status) {
      case MemoStatus.processed:
        label = '已提炼';
        color = AppTheme.online;
      case MemoStatus.failed:
        label = '失败';
        color = AppTheme.danger;
      case MemoStatus.local:
        label = '待处理';
        color = AppTheme.pending;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
