import 'package:flutter_test/flutter_test.dart';
import 'package:local_voice_sync/core/app_paths.dart';
import 'package:local_voice_sync/models/sync_status.dart';

/// 两个容易被"看起来正常"掩盖的点，各钉一条回归测试。
void main() {
  group('同步目录的等价路径', () {
    test('/storage/emulated/0 会展开成三种写法', () {
      final aliases = AppPaths.aliasPaths(
        '/storage/emulated/0/Documents/LocalVoiceSync/Me_Notes/inbox/a.json',
      );
      expect(aliases, <String>[
        '/storage/emulated/0/Documents/LocalVoiceSync/Me_Notes/inbox/a.json',
        '/sdcard/Documents/LocalVoiceSync/Me_Notes/inbox/a.json',
        '/storage/self/primary/Documents/LocalVoiceSync/Me_Notes/inbox/a.json',
      ]);
    });

    test('不是主存储的路径原样返回，不会瞎改', () {
      expect(
        AppPaths.aliasPaths('/data/user/0/com.localvoicesync.app/x.db'),
        <String>['/data/user/0/com.localvoicesync.app/x.db'],
      );
    });
  });

  group('状态灯文案', () {
    test('探测中不能谎报"离线"', () {
      // 冷启动后第一次 TLS 握手要一两秒。这段时间如果显示"离线"（黄灯），
      // 用户会以为配置又坏了——这正是真机上被当成"又连不上了"的那一次。
      const status = SyncStatus(state: LinkState.connecting, detail: '正在探测…');
      expect(status.shortLabel, '连接中…');
      expect(status.isPending, isTrue);
      expect(status.isOnline, isFalse);
    });

    test('离线才带待处理条数', () {
      const offline = SyncStatus(state: LinkState.offline, pendingFiles: 2);
      expect(offline.shortLabel, '离线 · 待处理 2');
      const connected = SyncStatus(state: LinkState.connected, pendingFiles: 0);
      expect(connected.shortLabel, '已连接');
    });

    test('未配置和离线必须能区分', () {
      const unconfigured = SyncStatus(state: LinkState.unconfigured);
      expect(unconfigured.shortLabel, '未配置');
      expect(
        unconfigured.shortLabel,
        isNot(const SyncStatus(state: LinkState.offline).shortLabel),
      );
    });
  });
}
