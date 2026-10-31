import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/sync_status.dart';
import '../providers.dart';
import '../theme.dart';

/// 顶部连接指示灯。
///
/// 绿 = 已连上 Mac（或同步中），黄 = 离线（后面跟本地待处理条数）。
/// 点击可以立刻重新探测一次，省得用户干等 8 秒轮询。
class StatusLight extends ConsumerStatefulWidget {
  const StatusLight({super.key});

  @override
  ConsumerState<StatusLight> createState() => _StatusLightState();
}

class _StatusLightState extends ConsumerState<StatusLight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _syncAnimation(LinkState state) {
    final shouldPulse = state == LinkState.syncing;
    if (shouldPulse && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!shouldPulse && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  Color _color(LinkState state) {
    switch (state) {
      case LinkState.connected:
      case LinkState.syncing:
        return AppTheme.online;
      case LinkState.offline:
        return AppTheme.pending;
      case LinkState.unconfigured:
        return AppTheme.idleDot;
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(syncStatusProvider);
    _syncAnimation(status.state);
    final color = _color(status.state);

    return Tooltip(
      message: status.detail.isEmpty ? status.shortLabel : status.detail,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => ref.read(syncStatusProvider.notifier).refresh(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedBuilder(
                animation: _pulse,
                builder: (context, child) {
                  final halo = 0.25 + 0.35 * _pulse.value;
                  return Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: color.withValues(alpha: halo),
                          blurRadius: 7,
                          spreadRadius: 1.5,
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(width: 7),
              Text(
                status.shortLabel,
                style: TextStyle(
                  fontSize: 12,
                  color: color == AppTheme.idleDot ? AppTheme.muted : color,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
