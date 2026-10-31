import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_config.dart';
import '../core/family_member.dart';
import '../providers.dart';
import '../services/syncthing_service.dart';
import '../theme.dart';

/// 设置页：成员、Syncthing、引擎状态、数据目录。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _folderId;
  late final TextEditingController _deviceId;
  late final TextEditingController _customName;

  String _dbSummary = '正在统计…';
  bool _savingSync = false;

  @override
  void initState() {
    super.initState();
    final services = ref.read(servicesProvider);
    final settings = services.initialSettings;
    _baseUrl = TextEditingController(text: settings.syncthing.baseUrl);
    _apiKey = TextEditingController(text: settings.syncthing.apiKey);
    _folderId = TextEditingController(text: settings.syncthing.folderId);
    _deviceId = TextEditingController(
      text: settings.syncthing.remoteDeviceId,
    );
    _customName = TextEditingController(text: settings.customAuthorName);
    unawaited(_loadStats());
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _folderId.dispose();
    _deviceId.dispose();
    _customName.dispose();
    super.dispose();
  }

  Future<void> _loadStats() async {
    try {
      final summary = await ref.read(servicesProvider).database.describe();
      if (!mounted) return;
      setState(() => _dbSummary = summary);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _dbSummary = '统计失败：$error');
    }
  }

  Future<void> _saveSyncthing() async {
    setState(() => _savingSync = true);
    await ref
        .read(settingsProvider.notifier)
        .updateSyncthing(
          SyncthingConfig(
            baseUrl: _baseUrl.text.trim().isEmpty
                ? 'http://127.0.0.1:8384'
                : _baseUrl.text.trim(),
            apiKey: _apiKey.text.trim(),
            folderId: _folderId.text.trim(),
            remoteDeviceId: _deviceId.text.trim(),
          ),
        );
    if (!mounted) return;
    setState(() => _savingSync = false);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('已保存，状态灯会在几秒内更新')),
      );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final embedding = ref.watch(embeddingStateProvider);
    final services = ref.read(servicesProvider);

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          const Text(
            '设置',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 18),
          _Section(
            title: '成员',
            subtitle: '决定这条记录进哪个同步目录，家人之间互不干扰',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final member in FamilyMember.builtIns)
                      _ChoiceChip(
                        label: member.label,
                        hint: member.dirName,
                        selected: settings.authorId == member.id,
                        onTap: () => ref
                            .read(settingsProvider.notifier)
                            .selectMember(member),
                      ),
                    _ChoiceChip(
                      label: '自定义',
                      hint: settings.authorId == FamilyMember.customId
                          ? settings.member.dirName
                          : '自己填名字',
                      selected: settings.authorId == FamilyMember.customId,
                      onTap: () => ref
                          .read(settingsProvider.notifier)
                          .selectMember(
                            FamilyMember.resolve(
                              authorId: FamilyMember.customId,
                              customName: _customName.text.isEmpty
                                  ? '其他成员'
                                  : _customName.text,
                            ),
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _customName,
                        decoration: const InputDecoration(
                          hintText: '自定义名字，例如「奶奶」',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => ref
                          .read(settingsProvider.notifier)
                          .renameCustom(_customName.text),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                      child: const Text('应用'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  '当前：${settings.member.label} → ${settings.member.dirName}',
                  style: AppTheme.mono,
                ),
              ],
            ),
          ),
          _Section(
            title: 'Syncthing',
            subtitle: '填手机本机 Syncthing 的地址和 API Key，用于读取真实同步进度',
            child: Column(
              children: [
                _Field(controller: _baseUrl, label: '地址', hint: 'http://127.0.0.1:8384'),
                _Field(controller: _apiKey, label: 'API Key', hint: '在 Syncthing 设置里查看'),
                _Field(controller: _folderId, label: '文件夹 ID', hint: '例如 localvoicesync'),
                _Field(
                  controller: _deviceId,
                  label: 'Mac 设备 ID',
                  hint: '留空则只判断文件夹状态',
                ),
                const SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _savingSync ? null : _saveSyncthing,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: _savingSync
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          )
                        : const Text('保存并立即探测'),
                  ),
                ),
              ],
            ),
          ),
          _Section(
            title: '检索引擎',
            subtitle: '模型 ${AppConfig.embeddingModelId} · ${AppConfig.embeddingDim} 维',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _StatRow(
                  label: '语义检索',
                  value: embedding.isReady ? '就绪' : '未启用',
                  good: embedding.isReady,
                  note: embedding.isReady
                      ? '已索引 ${embedding.indexed} 条'
                      : embedding.message,
                ),
                const SizedBox(height: 8),
                _StatRow(
                  label: '全文索引',
                  value: services.database.ftsAvailable ? 'FTS5' : 'LIKE 降级',
                  good: services.database.ftsAvailable,
                  note: services.database.ftsAvailable
                      ? '中文按单字 + 二元组切分'
                      : '当前系统 SQLite 未编译 FTS5，检索较慢',
                ),
                const SizedBox(height: 8),
                _StatRow(
                  label: '本地数据库',
                  value: _dbSummary,
                  good: true,
                ),
              ],
            ),
          ),
          _Section(
            title: '数据目录',
            subtitle: services.paths.syncRootIsShared
                ? '同步根在共享存储上，Syncthing 可以读取'
                : '数据库与日志在应用私有区，覆盖升级不会丢失',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  '同步根目录\n${services.paths.syncRoot.path}',
                  style: AppTheme.mono.copyWith(fontSize: 11.5),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  '本机数据\n${services.paths.localRoot.path}',
                  style: AppTheme.mono.copyWith(fontSize: 11.5),
                ),
                if (services.paths.syncRootNeedsPermission) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '未授予「所有文件访问」，Syncthing 读不到同步目录。',
                          style: TextStyle(fontSize: 12, color: AppTheme.danger),
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          await services.enableSharedSyncRoot();
                          if (context.mounted) setState(() {});
                        },
                        child: const Text('去授权'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'LocalVoiceSync ${AppConfig.appVersion} · 数据不出家门',
              style: AppTheme.mono,
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              subtitle,
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: AppTheme.muted,
              ),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
    required this.label,
    required this.hint,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String hint;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppTheme.primarySoft : AppTheme.background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppTheme.primary : AppTheme.hairline,
            width: selected ? 1.2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected ? AppTheme.primary : AppTheme.ink,
              ),
            ),
            Text(
              hint,
              style: AppTheme.mono.copyWith(fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    required this.hint,
  });

  final TextEditingController controller;
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
        ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({
    required this.label,
    required this.value,
    required this.good,
    this.note,
  });

  final String label;
  final String value;
  final bool good;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 5),
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: good ? AppTheme.online : AppTheme.pending,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      value,
                      style: AppTheme.mono.copyWith(fontSize: 11.5),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              if (note != null && note!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    note!,
                    style: const TextStyle(
                      fontSize: 11,
                      height: 1.5,
                      color: AppTheme.muted,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
