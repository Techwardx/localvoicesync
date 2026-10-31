import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'services/services.dart';
import 'theme.dart';
import 'views/root_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  Services? services;
  Object? bootError;
  try {
    services = await Services.boot();
  } on Object catch (error, stack) {
    bootError = error;
    debugPrint('启动失败：$error\n$stack');
  }

  if (services == null) {
    runApp(BootFailureApp(message: '$bootError'));
    return;
  }

  runApp(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: const LocalVoiceSyncApp(),
    ),
  );
}

class LocalVoiceSyncApp extends StatelessWidget {
  const LocalVoiceSyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LocalVoiceSync',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: const RootShell(),
    );
  }
}

/// 启动阶段的致命错误页。
///
/// 这里刻意不提供"重试"按钮：数据库打不开通常是磁盘或权限问题，
/// 盲目重试只会掩盖真实原因，直接把错误原文给用户更有用。
class BootFailureApp extends StatelessWidget {
  const BootFailureApp({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 40),
                const Icon(
                  Icons.error_outline,
                  color: AppTheme.danger,
                  size: 32,
                ),
                const SizedBox(height: 16),
                const Text(
                  '本地存储初始化失败',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                const Text(
                  'App 无法打开本机数据库，数据没有丢失。请检查存储空间后重启 App。',
                  style: TextStyle(color: AppTheme.muted, height: 1.6),
                ),
                const SizedBox(height: 24),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.hairline),
                  ),
                  child: SelectableText(
                    message,
                    style: const TextStyle(fontSize: 12, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
