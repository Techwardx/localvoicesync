import 'package:flutter/material.dart';

import '../theme.dart';
import 'home_page.dart';
import 'search_page.dart';
import 'settings_page.dart';

/// 三个主页面的外壳。
///
/// 用 [IndexedStack] 而不是重建页面：搜索页的状态（输入、结果、滚动位置）
/// 在切走再切回来时必须还在，否则用户会觉得自己"刚才搜的东西没了"。
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

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
