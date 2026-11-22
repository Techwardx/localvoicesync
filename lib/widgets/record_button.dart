import 'package:flutter/material.dart';

import '../services/audio_recorder_service.dart';
import '../theme.dart';

/// 录音大按钮。
///
/// 录音时外圈跟着实时音量轻轻呼吸——不用看时间也知道"它听见我了"。
/// 呼吸用青碧的柔光，不再用高饱和红色铺满底部，避免破坏素雅的基调。
class RecordButton extends StatelessWidget {
  const RecordButton({
    super.key,
    required this.phase,
    required this.level,
    required this.onPressed,
    this.size = 74,
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
            // 呼吸幅度刻意压小：6~12px 足够传达"在听"，不会晃眼。
            final halo = recording ? 5 + amplitude * 9 : 0.0;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: size + halo * 2,
              height: size + halo * 2,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: recording
                    ? AppTheme.primarySoft
                    : Colors.transparent,
              ),
              child: Center(
                child: Material(
                  color: recording ? AppTheme.primary : AppTheme.primary,
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
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white,
                                  ),
                                ),
                              )
                            : AnimatedSwitcher(
                                duration: const Duration(milliseconds: 180),
                                child: Icon(
                                  recording
                                      ? Icons.stop_rounded
                                      : Icons.mic_none,
                                  key: ValueKey<bool>(recording),
                                  color: Colors.white,
                                  size: recording ? 30 : 32,
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
