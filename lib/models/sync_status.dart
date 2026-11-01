/// 与 Mac Mini 的连接/同步状态。对应 UI 上的那颗小圆点。
enum LinkState {
  /// 灰（浅）：正在探测。冷启动后第一次 TLS 握手要一两秒，
  /// 这段时间**不能**显示成"离线"——那是谎报，用户会以为配置又坏了。
  connecting,

  /// 绿：Syncthing 已连上 Mac，且没有积压。
  connected,

  /// 绿（带脉冲）：已连上，正在传输。
  syncing,

  /// 黄：离线 / 未连上，[SyncStatus.pendingFiles] 是本地待处理条数。
  offline,

  /// 灰：还没配置 Syncthing，属于首次使用状态。
  unconfigured,
}

class SyncStatus {
  const SyncStatus({
    required this.state,
    this.pendingFiles = 0,
    this.detail = '',
    this.checkedAt,
  });

  final LinkState state;

  /// 黄灯时展示"还有几条没处理"，绿灯时展示"正在同步 N 个文件"。
  final int pendingFiles;
  final String detail;
  final DateTime? checkedAt;

  static const SyncStatus unconfigured = SyncStatus(
    state: LinkState.unconfigured,
    detail: '未配置 Syncthing',
  );

  bool get isOnline =>
      state == LinkState.connected || state == LinkState.syncing;

  /// 是否还没得出结论（探测中）。UI 据此避免闪一下"离线"。
  bool get isPending => state == LinkState.connecting;

  /// 状态栏一行短文案。
  String get shortLabel {
    switch (state) {
      case LinkState.connecting:
        return '连接中…';
      case LinkState.connected:
        return pendingFiles > 0 ? '同步中 $pendingFiles' : '已连接';
      case LinkState.syncing:
        return '同步中 $pendingFiles';
      case LinkState.offline:
        return pendingFiles > 0 ? '离线 · 待处理 $pendingFiles' : '离线';
      case LinkState.unconfigured:
        // 灰色 = 还没配置，跟"配置了但连不上"（黄灯）是两回事，
        // 文案上必须区分开，否则用户永远不知道该去填设置。
        return '未配置';
    }
  }

  SyncStatus copyWith({
    LinkState? state,
    int? pendingFiles,
    String? detail,
    DateTime? checkedAt,
  }) => SyncStatus(
    state: state ?? this.state,
    pendingFiles: pendingFiles ?? this.pendingFiles,
    detail: detail ?? this.detail,
    checkedAt: checkedAt ?? this.checkedAt,
  );
}
