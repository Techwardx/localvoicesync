import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/family_member.dart';
import '../models/memo.dart';
import '../providers.dart';
import '../services/audio_recorder_service.dart';
import '../theme.dart';
import '../widgets/memo_card.dart';
import '../widgets/record_button.dart';
import '../widgets/status_light.dart';
import 'memo_detail_page.dart';

/// 录音主页：随手记 + 近期记录 + 底部录音。
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  final TextEditingController _textController = TextEditingController();
  bool _savingNote = false;

  /// 用户刚授予「所有文件访问」后置 true，让横幅立即消失。
  bool _storageGranted = false;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _grantStorageAccess() async {
    final services = ref.read(servicesProvider);
    final ok = await services.enableSharedSyncRoot();
    if (!mounted) return;
    setState(() => _storageGranted = ok);
    if (!ok) {
      // 系统设置页可能只是被打开了、用户还没真的打开开关；
      // 再给一个"直接跳设置"的出口，比让人自己翻菜单靠谱。
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('还没拿到「所有文件访问」权限'),
          action: SnackBarAction(
            label: '打开设置',
            onPressed: () => unawaited(openAppSettings()),
          ),
        ),
      );
      return;
    }
    // MANAGE_EXTERNAL_STORAGE 是进程级的挂载视图，授权后**通常要重启进程**
    // 才完全生效。这里先把话说明白，省得用户以为没起作用。
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('权限已授予。请把 App 从后台划掉再打开，让它生效。'),
        duration: Duration(seconds: 6),
      ),
    );
  }

  Future<void> _submitText() async {
    final content = _textController.text.trim();
    if (content.isEmpty || _savingNote) return;
    setState(() => _savingNote = true);
    ref.read(lastErrorProvider.notifier).clear();
    final memo = await ref
        .read(memoListProvider.notifier)
        .addTextNote(content);
    if (!mounted) return;
    setState(() => _savingNote = false);
    if (memo == null) {
      // 把真实原因带上。只报"保存失败，请重试"等于什么都没说，
      // 用户在手机上又看不到日志，只能来回猜。
      final reason = ref.read(lastErrorProvider);
      _toast(reason.isEmpty ? '保存失败，请重试' : reason);
      return;
    }
    _textController.clear();
    _toast('已保存到本机，等 Mac 提炼');
  }

  Future<void> _toggleRecording() async {
    final recorder = ref.read(servicesProvider).recorder;
    final settings = ref.read(settingsProvider);
    try {
      if (recorder.isRecording) {
        final memo = await recorder.stop(deviceId: settings.deviceId);
        if (!mounted) return;
        if (memo == null) {
          _toast('录音太短，已丢弃');
        } else {
          await ref.read(memoListProvider.notifier).refresh();
          if (!mounted) return;
          _toast('录音已保存');
        }
      } else {
        await recorder.start(
          member: settings.member,
          deviceId: settings.deviceId,
        );
      }
    } on RecorderException catch (error) {
      _toast(error.message);
    } on Object catch (error) {
      _toast('录音出错：$error');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }

  Future<void> _pickMember() async {
    final settings = ref.read(settingsProvider);
    final selected = await showModalBottomSheet<FamilyMember>(
      context: context,
      builder: (context) => _MemberPicker(current: settings.member),
    );
    if (selected == null || !mounted) return;
    await ref.read(settingsProvider.notifier).selectMember(selected);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final memos = ref.watch(memoListProvider);
    final services = ref.read(servicesProvider);
    final recorder = services.recorder;

    // 只要 Android 上没拿到「所有文件访问」就提示。
    // 这里**不能**用 syncRootNeedsPermission：HyperOS 允许写 Documents/
    // 却不给权限，那个条件永远 false，横幅一次都不显示。
    final showStorageBanner =
        !_storageGranted && services.needsAllFilesAccess;

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.pageInset,
              AppSpace.md,
              AppSpace.pageInset,
              AppSpace.sm,
            ),
            child: Row(
              children: [
                Expanded(child: Text('记录', style: AppType.pageTitle)),
                const StatusLight(),
              ],
            ),
          ),
          // 作者是「谁在记」这一件事，做成 quietly 的文字链接即可，
          // 不再用胶囊 + 副文案占两行。
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.pageInset,
            ),
            child: _AuthorLine(
              label: settings.member.label,
              onTap: _pickMember,
            ),
          ),
          if (showStorageBanner)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.pageInset,
                AppSpace.md,
                AppSpace.pageInset,
                0,
              ),
              child: _StorageBanner(onGrant: _grantStorageAccess),
            ),
          Expanded(
            child: memos.when(
              loading: () => const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
              error: (error, _) => _EmptyState(
                icon: Icons.warning_amber_outlined,
                title: '读取记录失败',
                detail: '$error',
              ),
              data: (list) => ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.pageInset,
                  AppSpace.md,
                  AppSpace.pageInset,
                  AppSpace.lg,
                ),
                children: [
                  _QuickNoteCard(
                    controller: _textController,
                    saving: _savingNote,
                    onSubmit: _submitText,
                  ),
                  if (list.isEmpty)
                    const _EmptyState(
                      icon: Icons.graphic_eq,
                      title: '还没有记录',
                      detail: '按下方的按钮开始录音，或者在上面写一句话。\n所有内容只存在你的手机里。',
                    )
                  else ...[
                    const SizedBox(height: AppSpace.xxl),
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpace.xs),
                      child: Row(
                        children: [
                          Text('最近', style: AppType.section),
                          const SizedBox(width: AppSpace.sm),
                          Text('${list.length}', style: AppTheme.mono),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    for (final memo in list)
                      Column(
                        children: [
                          MemoCard(
                            memo: memo,
                            onTap: () => _openDetail(memo),
                          ),
                          const Divider(height: 1),
                        ],
                      ),
                  ],
                ],
              ),
            ),
          ),
          _RecordDock(recorder: recorder, onToggle: _toggleRecording),
        ],
      ),
    );
  }

  void _openDetail(Memo memo) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MemoDetailPage(memoId: memo.id),
      ),
    );
  }
}

/// 未授予「所有文件访问」时的提醒条。
///
/// 这不是可选的贴心提示，而是**功能性阻断**：同步根留在应用私有沙箱里，
/// Syncthing 作为另一个 App 读不到，录音就永远到不了 Mac。
class _StorageBanner extends StatelessWidget {
  const _StorageBanner({required this.onGrant});

  final VoidCallback onGrant;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.md,
        AppSpace.md,
        AppSpace.md,
      ),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(AppSpace.radiusCard),
        border: Border.all(color: AppTheme.hairline, width: 0.8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              Icons.folder_off_outlined,
              size: 18,
              color: AppTheme.pending,
            ),
          ),
          const SizedBox(width: AppSpace.md),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '收不到 Mac 回传的总结',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.ink,
                    height: 1.4,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  '需要授予「所有文件访问」，否则 Syncthing 回传的 json 会一直看不见。',
                  style: AppType.caption,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          TextButton(
            onPressed: onGrant,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('去授权'),
          ),
        ],
      ),
    );
  }
}

class _RecordDock extends StatefulWidget {
  const _RecordDock({required this.recorder, required this.onToggle});

  final AudioRecorderService recorder;
  final Future<void> Function() onToggle;

  @override
  State<_RecordDock> createState() => _RecordDockState();
}

class _RecordDockState extends State<_RecordDock> {
  Timer? _ticker;
  DateTime? _startedAt;

  @override
  void initState() {
    super.initState();
    widget.recorder.phase.addListener(_onPhaseChanged);
    _onPhaseChanged();
  }

  @override
  void dispose() {
    widget.recorder.phase.removeListener(_onPhaseChanged);
    _ticker?.cancel();
    super.dispose();
  }

  void _onPhaseChanged() {
    final recording = widget.recorder.phase.value == RecorderPhase.recording;
    if (recording && _ticker == null) {
      _startedAt = DateTime.now();
      _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted) setState(() {});
      });
    } else if (!recording) {
      _ticker?.cancel();
      _ticker = null;
      _startedAt = null;
    }
    if (mounted) setState(() {});
  }

  String get _elapsed {
    final start = _startedAt;
    if (start == null) return '';
    final diff = DateTime.now().difference(start);
    final minutes = diff.inMinutes.toString().padLeft(2, '0');
    final seconds = (diff.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final recording = widget.recorder.phase.value == RecorderPhase.recording;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.pageInset,
        AppSpace.lg,
        AppSpace.pageInset,
        AppSpace.lg,
      ),
      decoration: const BoxDecoration(
        color: AppTheme.background,
        border: Border(top: BorderSide(color: AppTheme.hairline, width: 0.8)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RecordButton(
            phase: widget.recorder.phase,
            level: widget.recorder.level,
            onPressed: () => unawaited(widget.onToggle()),
          ),
          const SizedBox(height: AppSpace.md),
          Text(
            recording ? '正在录音 $_elapsed · 点击停止' : '点击开始录音',
            style: TextStyle(
              fontSize: 12.5,
              color: recording ? AppTheme.danger : AppTheme.muted,
              fontWeight: recording ? FontWeight.w600 : FontWeight.w400,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickNoteCard extends StatelessWidget {
  const _QuickNoteCard({
    required this.controller,
    required this.saving,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool saving;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.sm,
        AppSpace.sm,
        AppSpace.sm,
      ),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(AppSpace.radiusCard),
        border: Border.all(color: AppTheme.hairline, width: 0.8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.newline,
              style: const TextStyle(fontSize: 14.5, height: 1.55),
              decoration: const InputDecoration(
                hintText: '随手写点什么…',
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          IconButton(
            onPressed: saving ? null : () => onSubmit(),
            icon: saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.arrow_upward_rounded, size: 19),
            style: IconButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
              minimumSize: const Size(36, 36),
              padding: EdgeInsets.zero,
              disabledBackgroundColor: AppTheme.primarySoft,
            ),
          ),
        ],
      ),
    );
  }
}

/// 作者：一条带下划线的浅色文字链接，点一下切换是谁在记。
class _AuthorLine extends StatelessWidget {
  const _AuthorLine({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person_outline, size: 13, color: AppTheme.faint),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12.5,
              color: AppTheme.muted,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 2),
          const Icon(Icons.expand_more, size: 13, color: AppTheme.faint),
          const SizedBox(width: 8),
          Text('切换成员', style: AppType.footnote),
        ],
      ),
    );
  }
}

class _MemberPicker extends StatelessWidget {
  const _MemberPicker({required this.current});

  final FamilyMember current;

  @override
  Widget build(BuildContext context) {
    final options = <FamilyMember>[
      ...FamilyMember.builtIns,
      FamilyMember.resolve(
        authorId: FamilyMember.customId,
        customName: current.id == FamilyMember.customId
            ? current.label
            : '其他成员',
      ),
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.pageInset,
          AppSpace.xxl,
          AppSpace.pageInset,
          AppSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('这是谁的记录？', style: AppType.title),
            const SizedBox(height: AppSpace.xs),
            const Text(
              '决定文件进入哪个同步目录，家人之间互不干扰',
              style: AppType.caption,
            ),
            const SizedBox(height: AppSpace.lg),
            for (final member in options)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(
                  member.id == current.id
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: member.id == current.id
                      ? AppTheme.primary
                      : AppTheme.faint,
                ),
                title: Text(member.label, style: AppType.body),
                subtitle: Text(
                  member.dirName,
                  style: AppTheme.mono,
                ),
                onTap: () => Navigator.of(context).pop(member),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl, vertical: 48),
      child: Column(
        children: [
          Icon(icon, color: AppTheme.faint, size: 30),
          const SizedBox(height: AppSpace.lg),
          Text(
            title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppTheme.ink,
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: AppType.secondary,
          ),
        ],
      ),
    );
  }
}
