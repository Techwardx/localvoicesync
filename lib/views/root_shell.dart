import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_log.dart';
import '../providers.dart';
import '../theme.dart';
import 'home_page.dart';
import 'search_page.dart';
import 'settings_page.dart';

/// 三个主页面的外壳。
///
/// 用 [IndexedStack] 而不是重建页面：搜索页的状态（输入、结果、滚动位置）
/// 在切走再切回来时必须还在，否则用户会觉得自己"刚才搜的东西没了"。
///
/// 另外它还是**回到前台时的对账入口**（见 [_resyncOnResume]）。
class RootShell extends ConsumerStatefulWidget {
  const RootShell({super.key});

  @override
  ConsumerState<RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<RootShell>
    with WidgetsBindingObserver {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_resyncOnResume());
    }
  }

  /// 回到前台立刻对一次账：扫收件箱 → 刷新列表 → 重探连接。
  ///
  /// 为什么非做不可：手机被系统冻结时定时器不跑，而 Syncthing 是**独立进程**，
  /// 它照样在后台把 Mac 的结果落盘。用户切回 App 看到的必须是"此刻"的真实状态，
  /// 而不是十分钟前的快照——否则就会重现"文件明明在，App 里却什么都没有"。
  Future<void> _resyncOnResume() async {
    final services = ref.read(servicesProvider);
    try {
      await services.inbox.scanOnce();
    } on Object catch (error) {
      AppLog.w('lifecycle', '回到前台重扫收件箱失败：$error');
    }
    try {
      await ref.read(memoListProvider.notifier).refresh();
    } on Object catch (error) {
      AppLog.w('lifecycle', '刷新记录列表失败：$error');
    }
    try {
      await ref.read(syncStatusProvider.notifier).refresh();
    } on Object catch (error) {
      AppLog.w('lifecycle', '重探连接状态失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [HomePage(), SearchPage(), SettingsPage()],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: AppTheme.surface,
          border: Border(top: BorderSide(color: AppTheme.hairline)),
        ),
        child: SafeArea(
          top: false,
          child: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (value) => setState(() => _index = value),
            height: 58,
            backgroundColor: AppTheme.surface,
            surfaceTintColor: Colors.transparent,
            indicatorColor: AppTheme.primarySoft,
            labelBehavior:
                NavigationDestinationLabelBehavior.alwaysShow,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.mic_none_outlined),
                selectedIcon: Icon(Icons.mic_none, color: AppTheme.primary),
                label: '记录',
              ),
              NavigationDestination(
                icon: Icon(Icons.search_outlined),
                selectedIcon: Icon(Icons.search, color: AppTheme.primary),
                label: '搜索',
              ),
              NavigationDestination(
                icon: Icon(Icons.tune_outlined),
                selectedIcon: Icon(Icons.tune, color: AppTheme.primary),
                label: '设置',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
