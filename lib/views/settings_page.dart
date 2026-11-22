import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_config.dart';
import '../core/family_member.dart';
import '../providers.dart';
import '../services/services.dart';
import '../services/syncthing_service.dart';
import '../theme.dart';

/// 设置页：常规设置在上，诊断/引擎/路径收进「高级」折叠区。
///
/// 信息分层：成员与连接是日常会碰的，放在第一屏；
/// 诊断按钮、向量引擎、存储路径是出问题时才看的，不该和常规设置平铺在一起，
/// 否则整页看起来像一块原始调试面板。
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

  /// 检索自检正在跑（要现场跑三次 ONNX 推理，手机上要几秒）。
  bool _checkingSearch = false;

  /// 上一次连接诊断的逐行结果，留在页面上方便截图。
  String _syncReport = '';

  /// 上一次收件箱扫描的逐行结果。
  String _inboxReport = '';

  /// 「高级」折叠区默认收起——常规设置才是这一页的主角。
  bool _advancedExpanded = false;

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
    final config = SyncthingConfig(
      baseUrl: _baseUrl.text.trim().isEmpty
          ? 'http://127.0.0.1:8384'
          : _baseUrl.text.trim(),
      apiKey: _apiKey.text.trim(),
      folderId: _folderId.text.trim(),
      remoteDeviceId: _deviceId.text.trim(),
    );
    await ref.read(settingsProvider.notifier).updateSyncthing(config);
    // 保存后立刻跑一次完整诊断，把每一步的结果摊开给用户看。
    // 只弹一句"已保存"是没用的——用户真正想知道的是"为什么还是离线"。
    final syncthing = ref.read(servicesProvider).syncthing;
    final diagnosis = await syncthing.diagnose(config: config, localPending: 0);
    // 再问一次手机端 Syncthing **自己**怎么看待这个文件夹：路径、模式、
    // 索引里有哪些文件。诊断"Mac 写了结果、手机收不到"时，这几行是关键——
    // 如果它报的路径跟 App 的同步根不是同一个，问题立刻水落石出。
    final snapshot = await syncthing.snapshot(config: config);
    if (!mounted) return;
    final report = <String>[
      diagnosis.report,
      '',
      '—— 手机端 Syncthing 自述 ——',
      ...snapshot,
      '',
      '结论：${diagnosis.status.detail}',
    ].join('\n');
    setState(() {
      _savingSync = false;
      _syncReport = report;
    });
    ref.invalidate(syncStatusProvider);
    await _showReport('连接诊断', report);
  }

  /// 手动扫一轮收件箱，并把目录里的真实内容摊出来。
  Future<void> _scanInbox() async {
    final services = ref.read(servicesProvider);
    // 权限可能在本次会话中被改过（用户去系统设置里点了开关），先刷新一次。
    services.allFilesAccess = await Services.hasAllFilesAccess();
    final ingested = await services.inbox.scanOnce();
    final diag = await services.inbox.diagnose();
    // 数据库条数是区分两种"看不到"的关键：
    //   文件在、库里 0 条 → 解析/入库失败；
    //   文件在、库里有条 → 入库成功，只是列表没刷新（或筛选条件挡住了）。
    final total = await services.database.totalCount();
    final pending = await services.database.pendingCount();
    final dbInfo = await services.database.debugInfo();
    final todoInfo = await services.todos.debugInfo();
    if (!mounted) return;
    final inbox = services.inbox;
    final last = inbox.lastScanAt;
    final summary = <String>[
      diag.report,
      '',
      '「所有文件访问」'
          '${services.allFilesAccess ? '已授予' : '未授予 ← 读不到 Syncthing 写的文件'}',
      '本轮新入库：$ingested',
      '扫描到的收件箱目录：${inbox.lastInboxDirs}',
      '看到的 .json 文件：${inbox.lastSeen}',
      // 这两个数字对比着看，就能判断是不是"目录列不出来"：
      // 枚举 0 / 探测 >0 → 文件确实在，只是 App 列不出目录内容。
      '目录枚举到 ${inbox.enumerated} 个 / 按 id 直接探到 ${inbox.probed} 个',
      '最近扫描：${last == null ? '尚未扫描' : _fmt(last)}',
      '本机数据库：共 $total 条，待处理 $pending 条',
      if (inbox.lastError.isNotEmpty) '上次错误：${inbox.lastError}',
      '',
      '— 数据库自检 —',
      ...dbInfo,
      '',
      '— 待办状态 —',
      ...todoInfo,
      '',
      if (ref.read(lastErrorProvider).isNotEmpty) ...[
        '',
        '— 最近一次操作错误 —',
        ref.read(lastErrorProvider),
      ],
    ].join('\n');
    setState(() => _inboxReport = summary);
    ref.invalidate(memoListProvider);
    ref.invalidate(todoListProvider);
    await _showReport('收件箱诊断', summary);
  }

  /// 检索自检。
  ///
  /// 语义检索"结果不对"在界面上完全看不出原因，所以这里直接跑三条探测查询，
  /// 把每条的最高分和判定摊开。正例不中 = 模型/索引有问题；
  /// 负例命中 = 阈值要往上调。两种都有明确的下一步动作。
  Future<void> _checkSearch() async {
    setState(() => _checkingSearch = true);
    final services = ref.read(servicesProvider);
    List<String> lines;
    try {
      lines = await services.search.selfCheck();
    } on Object catch (error) {
      lines = <String>['自检失败：$error'];
    }
    if (!mounted) return;
    setState(() => _checkingSearch = false);
    await _showReport('检索自检', lines.join('\n'));
  }

  /// 把今天的日志尾部摊出来。
  ///
  /// 手机上拿不到 logcat，也没有文件管理器能进应用私有目录，
  /// 所以这个按钮往往是唯一能看到"到底抛了什么异常"的地方。
  Future<void> _showLogs() async {
    final dir = ref.read(servicesProvider).paths.logDir;
    final now = DateTime.now();
    final stamp =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    final file = File('${dir.path}/app-$stamp.log');
    String body;
    try {
      if (!await file.exists()) {
        body = '今天还没有日志文件。\n${file.path}';
      } else {
        final lines = await file.readAsLines();
        final tail = lines.length > 120
            ? lines.sublist(lines.length - 120)
            : lines;
        body = '${file.path}\n\n${tail.join('\n')}';
      }
    } on Object catch (error) {
      body = '读取日志失败：$error\n${file.path}';
    }
    if (!mounted) return;
    await _showReport('日志（最近 120 行）', body);
  }

  static String _fmt(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';

  Future<void> _showReport(String title, String body) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        content: SingleChildScrollView(
          child: SelectableText(
            body,
            style: AppTheme.mono.copyWith(fontSize: 11.5, height: 1.55),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
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
        padding: const EdgeInsets.fromLTRB(
          AppSpace.pageInset,
          AppSpace.md,
          AppSpace.pageInset,
          32,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.lg),
            child: Text('设置', style: AppType.pageTitle),
          ),
          // ── 常规 ──────────────────────────────────────────────
          _Section(
            title: '成员',
            subtitle: '决定记录进哪个同步目录，家人之间互不干扰',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: AppSpace.sm,
                  runSpacing: AppSpace.sm,
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
                const SizedBox(height: AppSpace.md),
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
                    const SizedBox(width: AppSpace.sm),
                    FilledButton(
                      onPressed: () => ref
                          .read(settingsProvider.notifier)
                          .renameCustom(_customName.text),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                      child: const Text('应用'),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.sm),
                Text(
                  '当前：${settings.member.label} → ${settings.member.dirName}',
                  style: AppTheme.mono,
                ),
              ],
            ),
          ),
          _Section(
            title: '连接电脑',
            subtitle: '填写手机本机 Syncthing 的地址与 API Key，用于读取真实同步进度',
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
                const SizedBox(height: AppSpace.xs),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _savingSync ? null : _saveSyncthing,
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

          // ── 高级（默认折叠）────────────────────────────────────
          const SizedBox(height: AppSpace.lg),
          InkWell(
            onTap: () =>
                setState(() => _advancedExpanded = !_advancedExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
              child: Row(
                children: [
                  Text('高级', style: AppType.section),
                  const SizedBox(width: AppSpace.sm),
                  Text('诊断 · 引擎 · 存储', style: AppType.footnote),
                  const Spacer(),
                  Icon(
                    _advancedExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    size: 18,
                    color: AppTheme.faint,
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          if (_advancedExpanded) ...[
            const SizedBox(height: AppSpace.lg),
            _Section(
              title: '诊断工具',
              subtitle: '显示离线、或总结回不来时，先点这几个按钮',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _savingSync ? null : _saveSyncthing,
                          icon: const Icon(Icons.wifi_tethering, size: 16),
                          label: const Text('测试连接'),
                        ),
                      ),
                      const SizedBox(width: AppSpace.md),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _scanInbox,
                          icon: const Icon(Icons.inbox_outlined, size: 16),
                          label: const Text('扫描收件箱'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _checkingSearch ? null : _checkSearch,
                          icon: const Icon(Icons.manage_search, size: 16),
                          label: Text(_checkingSearch ? '自检中…' : '检索自检'),
                        ),
                      ),
                      const SizedBox(width: AppSpace.md),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _showLogs,
                          icon: const Icon(Icons.article_outlined, size: 16),
                          label: const Text('查看日志'),
                        ),
                      ),
                    ],
                  ),
                  if (_syncReport.isNotEmpty) ...[
                    const SizedBox(height: AppSpace.lg),
                    Text('连接', style: AppType.section),
                    const SizedBox(height: AppSpace.xs),
                    SelectableText(
                      _syncReport,
                      style: AppTheme.mono.copyWith(fontSize: 11, height: 1.55),
                    ),
                  ],
                  if (_inboxReport.isNotEmpty) ...[
                    const SizedBox(height: AppSpace.lg),
                    Text('收件箱', style: AppType.section),
                    const SizedBox(height: AppSpace.xs),
                    SelectableText(
                      _inboxReport,
                      style: AppTheme.mono.copyWith(fontSize: 11, height: 1.55),
                    ),
                  ],
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
                  const SizedBox(height: AppSpace.md),
                  _StatRow(
                    label: '全文索引',
                    value: services.database.ftsAvailable ? 'FTS5' : 'LIKE 降级',
                    good: services.database.ftsAvailable,
                    note: services.database.ftsAvailable
                        ? '中文按单字 + 二元组切分'
                        : '当前系统 SQLite 未编译 FTS5，检索较慢',
                  ),
                  const SizedBox(height: AppSpace.md),
                  _StatRow(
                    label: '本地数据库',
                    value: _dbSummary,
                    good: true,
                  ),
                ],
              ),
            ),
            _Section(
              title: '存储与同步机制',
              subtitle: '数据实际存放的位置，以及家人之间如何同步',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    '同步根目录\n${services.paths.syncRoot.path}',
                    style: AppTheme.mono.copyWith(fontSize: 11.5),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  SelectableText(
                    '本机数据\n${services.paths.localRoot.path}',
                    style: AppTheme.mono.copyWith(fontSize: 11.5),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  SelectableText(
                    '「所有文件访问」${services.allFilesAccess ? '已授予' : '未授予'}',
                    style: AppTheme.mono.copyWith(
                      fontSize: 11.5,
                      color: services.allFilesAccess
                          ? AppTheme.muted
                          : AppTheme.danger,
                    ),
                  ),
                  if (services.needsAllFilesAccess) ...[
                    const SizedBox(height: AppSpace.md),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '没有这个权限时，App 只能读到自己创建的文件，'
                            'Syncthing 回传的 json 会一直看不见。',
                            style:
                                TextStyle(fontSize: 12, color: AppTheme.danger),
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
                  const SizedBox(height: AppSpace.md),
                  const Divider(height: 1),
                  const SizedBox(height: AppSpace.md),
                  const Text(
                    '待办勾选与手工待办保存在同步目录 todos/ 下，每台设备各写一份，'
                    'Mac 与其它手机会自动同步。待办页下拉，或点右上角图标可重新对账。',
                    style: AppType.caption,
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpace.lg),
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
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(AppSpace.radiusCard),
          border: Border.all(color: AppTheme.hairline, width: 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w500,
                color: AppTheme.ink,
                height: 1.4,
                fontFamily: AppType.titleFontFamily,
                fontFamilyFallback: AppType.titleFontFallback,
              ),
            ),
            const SizedBox(height: 3),
            Text(subtitle, style: AppType.caption),
            const SizedBox(height: AppSpace.lg),
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
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.md,
          vertical: AppSpace.sm,
        ),
        decoration: BoxDecoration(
          color: selected ? AppTheme.surfaceSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(AppSpace.radiusField),
          border: Border.all(
            color: selected ? AppTheme.primaryMid : AppTheme.hairline,
            width: selected ? 1.2 : 0.8,
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
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: TextField(
        controller: controller,
        style: const TextStyle(fontSize: 13.5),
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
          margin: const EdgeInsets.only(top: 6),
          width: 5,
          height: 5,
          decoration: BoxDecoration(
            color: good ? AppTheme.online : AppTheme.accent,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: AppSpace.md),
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
                      color: AppTheme.ink,
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
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
                    style: AppType.caption,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
