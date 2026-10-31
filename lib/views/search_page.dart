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
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 10),
            child: Text(
              '搜索',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _controller,
              onChanged: notifier.onQueryChanged,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => notifier.run(),
              style: const TextStyle(fontSize: 15),
              decoration: InputDecoration(
                hintText: '记得录过，但想不起关键词…',
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
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: SegmentedButton<SearchMode>(
                    segments: const [
                      ButtonSegment(
                        value: SearchMode.auto,
                        label: Text('混合'),
                      ),
                      ButtonSegment(
                        value: SearchMode.keyword,
                        label: Text('关键词'),
                      ),
                      ButtonSegment(
                        value: SearchMode.semantic,
                        label: Text('语义'),
                      ),
                    ],
                    selected: <SearchMode>{search.mode},
                    showSelectedIcon: false,
                    onSelectionChanged: (value) =>
                        notifier.setMode(value.first),
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      textStyle: WidgetStateProperty.all(
                        const TextStyle(fontSize: 12),
                      ),
                      side: WidgetStateProperty.all(
                        const BorderSide(color: AppTheme.hairline),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (!embedding.isReady)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(
                embedding.message,
                style: AppTheme.mono,
              ),
            ),
          const SizedBox(height: 8),
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
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      itemCount: state.hits.length,
      itemBuilder: (context, index) {
        final hit = state.hits[index];
        return MemoCard(
          memo: hit.memo,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => MemoDetailPage(memoId: hit.memo.id),
            ),
          ),
        );
      },
    );
  }
}

class _TagCloud extends ConsumerWidget {
  const _TagCloud({required this.onTapTag});

  final ValueChanged<String> onTapTag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tags = ref.watch(tagCountsProvider);
    return tags.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (counts) {
        if (counts.isEmpty) {
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
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 10, left: 2),
              child: Text(
                '标签',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.muted.withValues(alpha: 0.9),
                  letterSpacing: 0.4,
                ),
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in counts.entries)
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => onTapTag(entry.key),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.surface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppTheme.hairline),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            entry.key,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text('${entry.value}', style: AppTheme.mono),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}
