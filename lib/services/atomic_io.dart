import 'dart:io';

import '../core/app_log.dart';

/// 原子写文件的小工具。
///
/// 同步目录里"写一半"是最危险的状态：Syncthing 只认文件系统事件，
/// 它不知道你还没写完。所以所有落盘都必须「先写 .part，再 rename」——
/// rename 在同一文件系统内是原子操作，Syncthing 只会看到两种状态：
/// 文件不存在，或者文件完整。
class AtomicIo {
  const AtomicIo._();

  static const String partSuffix = '.part';

  /// 原子写入文本。目标文件要么保持原样，要么变成完整的新内容。
  static Future<File> writeString(File target, String content) async {
    final part = File('${target.path}$partSuffix');
    await part.parent.create(recursive: true);
    final handle = await part.open(mode: FileMode.write);
    try {
      await handle.writeString(content);
      await handle.flush();
    } finally {
      await handle.close();
    }
    return promote(part, target);
  }

  /// 把临时文件重命名为正式文件。同目录内 rename 是原子的。
  static Future<File> promote(File source, File target) async {
    final existing = await target.exists();
    if (existing) {
      await target.delete();
    }
    final renamed = await source.rename(target.path);
    AppLog.d('io', '${source.path} → ${target.path}');
    return renamed;
  }

  /// 等待文件大小稳定（Mac 端用：Syncthing 可能分块写入）。
  static Future<bool> waitUntilStable(
    File file, {
    Duration quietPeriod = const Duration(milliseconds: 1200),
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    int? lastSize;
    DateTime? lastChange;

    while (DateTime.now().isBefore(deadline)) {
      if (!await file.exists()) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        continue;
      }
      final size = await file.length();
      final now = DateTime.now();
      if (lastSize == null || size != lastSize) {
        lastSize = size;
        lastChange = now;
      } else if (now.difference(lastChange!) >= quietPeriod && size > 0) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    return false;
  }
}
