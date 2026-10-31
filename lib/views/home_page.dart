import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/family_member.dart';
import '../models/memo.dart';
import '../providers.dart';
import '../services/audio_recorder_service.dart';
import '../theme.dart';
import '../widgets/memo_card.dart';
import '../widgets/record_button.dart';
import '../widgets/status_light.dart';
import 'memo_detail_page.dart';

/// 录音主页：大按钮 + 文本快记 + 最近记录。
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('没有「所有文件访问」权限，录音只能留在这台手机上。'),
        ),
      );
    }
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
      backgroundColor: AppTheme.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
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

    // Android 上没拿到「所有文件访问」时同步根还在私有沙箱里，
    // Syncthing 看不到，录音永远传不到 Mac —— 必须显式提示，不能静默降级。
    final showStorageBanner =
        !_storageGranted && services.paths.syncRootNeedsPermission;

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 12, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '记录',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                const StatusLight(),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                _AuthorChip(
                  label: settings.member.label,
                  onTap: _pickMember,
                ),
                const SizedBox(width: 8),
                Text(
                  '录音与文字都会先存在本机',
                  style: AppTheme.mono,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (showStorageBanner)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
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
                icon: Icons.warning_amber_rounded,
                title: '读取记录失败',
                detail: '$error',
              ),
              data: (list) => ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                children: [
                  _QuickNoteCard(
                    controller: _textController,
                    saving: _savingNote,
                    onSubmit: _submitText,
                  ),
                  const SizedBox(height: 18),
                  if (list.isEmpty)
                    const _EmptyState(
                      icon: Icons.graphic_eq,
                      title: '还没有记录',
                      detail: '按下方的按钮开始录音，或者在上面写一句话。\n所有内容只存在你的手机里。',
                    )
                  else ...[
                    Padding(
                      padding: const EdgeInsets.only(left: 2, bottom: 8),
                      child: Text(
                        '最近 ${list.length} 条',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.muted.withValues(alpha: 0.9),
                          letterSpacing: 0.4,
                        ),
                      ),
                    ),
                    for (final memo in list)
                      MemoCard(
                        memo: memo,
                        onTap: () => _openDetail(memo),
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
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: AppTheme.pending.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.pending.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.folder_off_outlined,
            size: 18,
            color: AppTheme.pending,
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '录音暂时传不到 Mac',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.ink,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  '需要授予「所有文件访问」，同步目录才能被 Syncthing 看到。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: AppTheme.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          TextButton(
            onPressed: onGrant,
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.pending,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
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
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      decoration: const BoxDecoration(
        color: AppTheme.background,
        border: Border(top: BorderSide(color: AppTheme.hairline)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RecordButton(
            phase: widget.recorder.phase,
            level: widget.recorder.level,
            onPressed: () => unawaited(widget.onToggle()),
          ),
          const SizedBox(height: 10),
          Text(
            recording ? '正在录音 $_elapsed · 点击停止' : '点击开始录音',
            style: TextStyle(
              fontSize: 12.5,
              color: recording ? AppTheme.danger : AppTheme.muted,
              fontWeight: recording ? FontWeight.w600 : FontWeight.w400,
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
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.hairline),
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
              style: const TextStyle(fontSize: 14, height: 1.5),
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
          const SizedBox(width: 6),
          IconButton(
            onPressed: saving ? null : () => onSubmit(),
            icon: saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.arrow_upward_rounded),
            style: IconButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
              minimumSize: const Size(34, 34),
              padding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }
}

class _AuthorChip extends StatelessWidget {
  const _AuthorChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppTheme.primarySoft,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.person_outline,
              size: 13,
              color: AppTheme.primary,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Icon(
              Icons.keyboard_arrow_down,
              size: 14,
              color: AppTheme.primary,
            ),
          ],
        ),
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
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '这是谁的记录？',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            const Text(
              '决定文件进入哪个同步目录，家人之间互不干扰',
              style: TextStyle(fontSize: 12, color: AppTheme.muted),
            ),
            const SizedBox(height: 12),
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
                      : AppTheme.idleDot,
                ),
                title: Text(member.label),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 40),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: const BoxDecoration(
              color: AppTheme.primarySoft,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: AppTheme.primary, size: 24),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.6,
              color: AppTheme.muted,
            ),
          ),
        ],
      ),
    );
  }
}
