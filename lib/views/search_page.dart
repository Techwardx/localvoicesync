import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../services/search_service.dart';
import '../theme.dart';
import '../widgets/memo_card.dart';
import 'memo_detail_page.dart';

/// 全局语义搜索页。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final search = ref.watch(searchStateProvider);
    final notifier = ref.read(searchStateProvider.notifier);
    final embedding = ref.watch(embeddingStateProvider);

    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.pageInset,
              AppSpace.md,
              AppSpace.pageInset,
              AppSpace.lg,
            ),
            child: Text('搜索', style: AppType.pageTitle),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.pageInset,
            ),
            child: TextField(
              controller: _controller,
              onChanged: notifier.onQueryChanged,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => notifier.run(),
              style: const TextStyle(fontSize: 14.5, height: 1.5),
              decoration: InputDecoration(
                hintText: '记得录过，但想不起关键词…',
                hintStyle: AppType.inputHint,
                prefixIcon: const Icon(Icons.search, size: 19),
                suffixIcon: search.query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 17),
                        onPressed: () {
                          _controller.clear();
                          notifier.reset();
                        },
                      ),
              ),
            ),
          ),
          // 模式切换放在一条浅色承托条上：文字标签 + 细下划线表示选中，
          // 既有分组骨架，又不回到 SegmentedButton 那种三层描边的重控件。
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.pageInset,
              AppSpace.md,
              AppSpace.pageInset,
              0,
            ),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.md,
                vertical: AppSpace.xs,
              ),
              decoration: AppTheme.panel(),
              child: Row(
                children: [
                  for (final mode in SearchMode.values)
                    _ModeTab(
                      label: switch (mode) {
                        SearchMode.auto => '混合',
                        SearchMode.keyword => '关键词',
                        SearchMode.semantic => '语义',
                      },
                      selected: search.mode == mode,
                      onTap: () => notifier.setMode(mode),
                    ),
                ],
              ),
            ),
          ),
          if (!embedding.isReady)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.pageInset,
                AppSpace.sm,
                AppSpace.pageInset,
                0,
              ),
              child: Text(embedding.message, style: AppType.footnote),
            ),
          const SizedBox(height: AppSpace.sm),
          Expanded(
            child: search.loading
                ? const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : _Results(
                    state: search,
                    onTapTag: (tag) {
                      _controller.text = tag;
                      notifier.onQueryChanged(tag);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _Results extends ConsumerWidget {
  const _Results({required this.state, required this.onTapTag});

  final SearchState state;
  final ValueChanged<String> onTapTag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (state.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '搜索出错：${state.error}',
            style: const TextStyle(fontSize: 13, color: AppTheme.danger),
          ),
        ),
      );
    }

    if (!state.hasRun) {
      return _TagCloud(onTapTag: onTapTag);
    }

    if (state.hits.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '没有找到相关记录\n换个说法试试，语义检索能理解近义表达',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, height: 1.7, color: AppTheme.muted),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.pageInset,
        AppSpace.xs,
        AppSpace.pageInset,
        AppSpace.xxl,
      ),
      itemCount: state.hits.length,
      itemBuilder: (context, index) {
        final hit = state.hits[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.panelGap),
          child: MemoCard(
            memo: hit.memo,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => MemoDetailPage(memoId: hit.memo.id),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TagCloud extends ConsumerStatefulWidget {
  const _TagCloud({required this.onTapTag});

  final ValueChanged<String> onTapTag;

  @override
  ConsumerState<_TagCloud> createState() => _TagCloudState();
}

class _TagCloudState extends ConsumerState<_TagCloud> {
  /// 折叠时露几个。
  ///
  /// 3 个是个有意的取舍：标签多起来之后，搜索页一进来满屏都是标签，
  /// 把真正该被看见的输入框挤到上面去了。露最近 3 个足够提示"我最近在记什么"，
  /// 想看全的再展开——信息没丢，只是不喧宾夺主。
  static const int _collapsedCount = 3;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final tags = ref.watch(tagCountsProvider);
    return tags.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (all) {
        if (all.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                '搜索框里可以写一整句话，比如\n"上次说的那个保险丝要买哪种"',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.7,
                  color: AppTheme.muted,
                ),
              ),
            ),
          );
        }

        final visible = _expanded
            ? all
            : all.take(_collapsedCount).toList(growable: false);
        final hidden = all.length - visible.length;

        return ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.pageInset,
            AppSpace.xs,
            AppSpace.pageInset,
            AppSpace.xxl,
          ),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.md),
              child: Text('最近用过的标签', style: AppType.section),
            ),
            Wrap(
              spacing: AppSpace.xl - 4,
              runSpacing: AppSpace.md,
              children: [
                for (final entry in visible)
                  _TagChip(
                    label: entry.tag,
                    count: entry.count,
                    onTap: () => widget.onTapTag(entry.tag),
                  ),
                if (hidden > 0)
                  _ToggleChip(
                    label: '展开 $hidden 个',
                    icon: Icons.expand_more,
                    onTap: () => setState(() => _expanded = true),
                  ),
                if (_expanded && all.length > _collapsedCount)
                  _ToggleChip(
                    label: '收起',
                    icon: Icons.expand_less,
                    onTap: () => setState(() => _expanded = false),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// 模式标签：靠字重与一条细下划线表示选中，不用描边控件。
class _ModeTab extends StatelessWidget {
  const _ModeTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(right: AppSpace.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.3,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? AppTheme.primary : AppTheme.muted,
                ),
              ),
            ),
            Container(
              height: 2,
              width: 18,
              decoration: BoxDecoration(
                color: selected ? AppTheme.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单个标签：轻量描边小片，浅面 + 细边，能看出是一个可点的独立项，
/// 但绝不做成重色按钮，也不抢搜索框的注意力。
class _TagChip extends StatelessWidget {
  const _TagChip({
    required this.label,
    required this.count,
    required this.onTap,
  });

  final String label;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surface,
      borderRadius: BorderRadius.circular(AppSpace.radiusChip),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppSpace.radiusChip),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.md,
            vertical: AppSpace.sm,
          ),
          decoration: AppTheme.panel(radius: AppSpace.radiusChip),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: AppTheme.ink,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 6),
              Text('$count', style: AppTheme.mono),
            ],
          ),
        ),
      ),
    );
  }
}

/// 展开/收起：最弱一级，浅灰文字，与真标签明确区分。
class _ToggleChip extends StatelessWidget {
  const _ToggleChip({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: AppTheme.faint),
            const SizedBox(width: 2),
            Text(label, style: AppType.footnote),
          ],
        ),
      ),
    );
  }
}
