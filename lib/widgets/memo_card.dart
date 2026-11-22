import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/memo.dart';
import '../theme.dart';

/// 列表里的一条记录。
///
/// 视觉上刻意做成"一段文字"而不是"一张卡片"：
/// 顶部一条极细分割线分隔条目，标题用字重、摘要用行高建立层级，
/// 状态与来源只用一枚米粒大的圆点提示，绝不再套胶囊和徽章。
class MemoCard extends StatelessWidget {
  const MemoCard({super.key, required this.memo, this.onTap, this.highlight});

  final Memo memo;
  final VoidCallback? onTap;

  /// 搜索页用来高亮命中的关键词。（保留接口，当前由 Markdown 正文承载高亮。）
  final String? highlight;

  static final DateFormat _dayFormat = DateFormat('M月d日 HH:mm');
  static final DateFormat _yearFormat = DateFormat('yyyy年M月d日 HH:mm');

  String _timeLabel() {
    final now = DateTime.now();
    final sameYear = memo.createdAt.year == now.year;
    return (sameYear ? _dayFormat : _yearFormat).format(memo.createdAt);
  }

  Color get _statusDot {
    switch (memo.status) {
      case MemoStatus.processed:
        return AppTheme.online;
      case MemoStatus.failed:
        return AppTheme.danger;
      case MemoStatus.local:
        return AppTheme.accent;
    }
  }

  @override
  Widget build(BuildContext context) {
    final snippet = memo.summary.trim().isNotEmpty
        ? memo.summary.trim()
        : memo.rawText.trim();

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题行：状态只用一枚米粒点，不再抢标题的位置。
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: _statusDot,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Text(
                    memo.displayTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.title,
                  ),
                ),
              ],
            ),
            if (snippet.isNotEmpty) ...[
              const SizedBox(height: AppSpace.sm),
              Padding(
                padding: const EdgeInsets.only(left: 17),
                child: Text(
                  snippet,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.secondary,
                ),
              ),
            ],
            const SizedBox(height: AppSpace.md),
            Padding(
              padding: const EdgeInsets.only(left: 17),
              child: Row(
                children: [
                  Text(_timeLabel(), style: AppTheme.mono),
                  const SizedBox(width: AppSpace.sm),
                  Text('·', style: AppTheme.mono),
                  const SizedBox(width: AppSpace.sm),
                  Flexible(
                    child: Text(
                      memo.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.mono,
                    ),
                  ),
                  if (memo.todos.isNotEmpty) ...[
                    const SizedBox(width: AppSpace.sm),
                    Icon(
                      Icons.checklist,
                      size: 12,
                      color: AppTheme.faint,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      '${memo.todos.where((t) => t.completed).length}'
                      '/${memo.todos.length}',
                      style: AppTheme.mono,
                    ),
                  ],
                ],
              ),
            ),
            // 标签降级为最末一行的浅淡文字，用间隔号相连，不再做色块。
            if (memo.tags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 17, top: 6),
                child: Text(
                  memo.tags.take(4).join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.footnote,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
