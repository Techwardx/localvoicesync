import 'package:flutter/material.dart';

import '../services/audio_recorder_service.dart';
import '../theme.dart';

/// 录音大按钮。
///
/// 录音时外圈跟着实时音量呼吸——用户不用看时间也知道"它听见我了"。
class RecordButton extends StatelessWidget {
  const RecordButton({
    super.key,
    required this.phase,
    required this.level,
    required this.onPressed,
    this.size = 88,
  });

  final ValueNotifier<RecorderPhase> phase;
  final ValueNotifier<double> level;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<RecorderPhase>(
      valueListenable: phase,
      builder: (context, current, _) {
        final recording = current == RecorderPhase.recording;
        final saving = current == RecorderPhase.saving;

        return ValueListenableBuilder<double>(
          valueListenable: level,
          builder: (context, amplitude, _) {
            final halo = recording ? 6 + amplitude * 14 : 0.0;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: size + halo * 2,
              height: size + halo * 2,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: recording
                    ? AppTheme.danger.withValues(alpha: 0.12)
                    : Colors.transparent,
              ),
              child: Center(
                child: Material(
                  color: recording ? AppTheme.danger : AppTheme.primary,
                  shape: const CircleBorder(),
                  elevation: 0,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: saving ? null : onPressed,
                    child: SizedBox(
                      width: size,
                      height: size,
                      child: Center(
                        child: saving
                            ? const SizedBox(
                                width: 26,
                                height: 26,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white,
                                  ),
                                ),
                              )
                            : AnimatedSwitcher(
                                duration: const Duration(milliseconds: 160),
                                child: Icon(
                                  recording ? Icons.stop_rounded : Icons.mic_none,
                                  key: ValueKey<bool>(recording),
                                  color: Colors.white,
                                  size: recording ? 34 : 38,
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
