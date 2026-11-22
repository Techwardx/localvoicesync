import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/memo.dart';
import '../theme.dart';

/// 列表里的一条记录。
///
/// 一块有边界的浅色面板：月白底上浮起青白面 + 0.8px 细边，
/// 靠内边距与行高把标题、摘要、元信息分层托住——不是无边界的纯文字平铺。
/// 信息仍然克制：状态只用一枚米粒点，标签是末行浅字，不堆胶囊与徽章。
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

    return Material(
      color: AppTheme.surface,
      borderRadius: BorderRadius.circular(AppSpace.radiusCard),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppSpace.radiusCard),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(
            AppSpace.lg,
            AppSpace.lg,
            AppSpace.lg,
            AppSpace.md + 2,
          ),
          decoration: AppTheme.panel(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题行：一枚米粒点标状态，标题是这一卡片的主角。
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
                const SizedBox(height: AppSpace.sm + 2),
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
              const SizedBox(height: AppSpace.md + 2),
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
              // 标签在面板内以一条极细分割线隔开，浅字呈现，不做色块。
              if (memo.tags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 17, top: AppSpace.md),
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
      ),
    );
  }
}
