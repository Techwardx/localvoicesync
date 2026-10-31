import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../core/app_config.dart';
import '../core/app_log.dart';
import '../core/app_paths.dart';
import '../core/family_member.dart';
import '../models/memo.dart';
import 'atomic_io.dart';
import 'database_service.dart';
import 'foreground_service.dart';

/// 录音机当前阶段，UI 直接据此切换按钮形态。
enum RecorderPhase { idle, recording, saving }

class RecorderException implements Exception {
  RecorderException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 原子录音服务。
///
/// 核心不变量（整个系统最重要的一条）：
/// **录音过程中产生的文件永远以 `.tmp_` 开头，且永远待在 `.incoming/` 里；
/// 只有 `stop()` 成功返回、文件大小校验通过之后，才 rename 到 `outbox/`。**
///
/// 这样后台的 Syncthing 只有两种可观测状态：看不到文件，或看到完整文件。
/// 中间态在文件系统层面被消除了，而不是靠"延时 2 秒再同步"这种碰运气的做法。
class AudioRecorderService {
  AudioRecorderService({required AppPaths paths, required DatabaseService db})
    : _paths = paths,
      _db = db;

  final AppPaths _paths;
  final DatabaseService _db;
  final AudioRecorder _recorder = AudioRecorder();

  final ValueNotifier<RecorderPhase> phase = ValueNotifier<RecorderPhase>(
    RecorderPhase.idle,
  );

  /// 0.0 ~ 1.0 的归一化音量，用于按钮上的呼吸动画。
  final ValueNotifier<double> level = ValueNotifier<double>(0);

  StreamSubscription<Amplitude>? _amplitudeSub;

  String? _tmpPath;
  String? _finalFileName;
  String? _authorDir;
  String? _authorName;
  DateTime? _startedAt;

  bool get isRecording => phase.value == RecorderPhase.recording;

  Future<void> start({
    required FamilyMember member,
    required String deviceId,
  }) async {
    if (phase.value != RecorderPhase.idle) {
      throw RecorderException('正在录音中，请先停止');
    }

    await _ensurePermissions();

    await _paths.ensureMemberLayout(member.dirName);

    final now = DateTime.now();
    final id = await _uniqueId(member.dirName, now);
    final fileName = '$id.m4a';
    final tmp = _paths.temporaryAudioFile(
      member.dirName,
      '${AppConfig.tmpPrefix}$fileName',
    );
    if (await tmp.exists()) {
      await tmp.delete();
    }

    _tmpPath = tmp.path;
    _finalFileName = fileName;
    _authorDir = member.dirName;
    _authorName = member.author;
    _startedAt = now;

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: AppConfig.recordBitRate,
        sampleRate: AppConfig.recordSampleRate,
        numChannels: 1,
        autoGain: true,
        noiseSuppress: true,
      ),
      path: tmp.path,
    );

    _amplitudeSub = _recorder
        .onAmplitudeChanged(AppConfig.amplitudeInterval)
        .listen((amplitude) {
          // dBFS 通常落在 -60 ~ 0，线性映射到 0~1 给 UI 用。
          final normalized = ((amplitude.current + 60) / 60).clamp(0.0, 1.0);
          level.value = normalized;
        });

    phase.value = RecorderPhase.recording;
    await RecordingForegroundService.start(
      '正在录音',
      '${member.label} 的语音备忘 · 点按回到 App 停止',
    );
    AppLog.i('rec', '开始录音 → ${tmp.path}');
  }

  /// 停止并落盘。返回入库的 [Memo]；录音太短/为空时返回 null。
  Future<Memo?> stop({required String deviceId}) async {
    if (phase.value != RecorderPhase.recording) return null;
    phase.value = RecorderPhase.saving;

    String? recordedPath;
    try {
      recordedPath = await _recorder.stop();
    } on Object catch (error, stack) {
      AppLog.e('rec', '停止录音失败', error, stack);
    }
    await _amplitudeSub?.cancel();
    _amplitudeSub = null;
    level.value = 0;

    final tmpPath = _tmpPath;
    final fileName = _finalFileName;
    final authorDir = _authorDir;
    final authorName = _authorName;
    final startedAt = _startedAt ?? DateTime.now();
    _tmpPath = null;
    _finalFileName = null;
    _authorDir = null;
    _authorName = null;
    _startedAt = null;

    await RecordingForegroundService.stop();

    if (tmpPath == null || fileName == null || authorDir == null) {
      phase.value = RecorderPhase.idle;
      return null;
    }

    final tmpFile = File(recordedPath ?? tmpPath);
    if (!await tmpFile.exists()) {
      AppLog.w('rec', '录音文件不存在：${tmpFile.path}');
      phase.value = RecorderPhase.idle;
      return null;
    }

    final size = await tmpFile.length();
    if (size < AppConfig.minValidAudioBytes) {
      AppLog.w('rec', '录音过短（$size 字节），丢弃');
      await tmpFile.delete();
      phase.value = RecorderPhase.idle;
      return null;
    }

    // 关键一步：校验通过后才让文件"出现在"同步目录里。
    final target = _paths.audioFile(authorDir, fileName);
    await AtomicIo.promote(tmpFile, target);

    final memo = Memo(
      id: p.basenameWithoutExtension(fileName),
      kind: MemoKind.audio,
      author: authorName ?? authorDir,
      authorDir: authorDir,
      deviceId: deviceId,
      createdAt: startedAt,
      updatedAt: DateTime.now(),
      audioFilename: fileName,
      status: MemoStatus.local,
    );
    await _db.upsertMemo(memo);
    phase.value = RecorderPhase.idle;
    AppLog.i('rec', '录音完成 → ${target.path}（$size 字节）');
    return memo;
  }

  /// 取消录音：丢弃当前临时文件。
  Future<void> cancel() async {
    if (phase.value == RecorderPhase.idle) return;
    try {
      await _recorder.cancel();
    } on Object catch (error) {
      AppLog.w('rec', '取消录音异常：$error');
    }
    await _amplitudeSub?.cancel();
    _amplitudeSub = null;
    final tmpPath = _tmpPath;
    _tmpPath = null;
    _finalFileName = null;
    _authorDir = null;
    _authorName = null;
    _startedAt = null;
    level.value = 0;
    await RecordingForegroundService.stop();
    if (tmpPath != null) {
      final file = File(tmpPath);
      if (await file.exists()) {
        await file.delete();
      }
    }
    phase.value = RecorderPhase.idle;
  }

  /// App 启动时清理 `.incoming/`。
  ///
  /// 上次进程被系统杀掉时可能留下半截 `.tmp_` 文件。策略：
  /// - 小于阈值 → 视为误触，删掉；
  /// - 大于阈值 → 提升为正式文件并入库（宁可转写出一段残缺文本，
  ///   也不要让用户觉得"我明明录了"）。
  Future<List<Memo>> recoverOrphans({required String deviceId}) async {
    final recovered = <Memo>[];
    try {
      final members = await _paths.syncRoot
          .list()
          .where((entity) => entity is Directory)
          .cast<Directory>()
          .toList();
      for (final memberDir in members) {
        final incoming = Directory(
          p.join(memberDir.path, AppConfig.incomingDirName),
        );
        if (!await incoming.exists()) continue;
        final dirName = p.basename(memberDir.path);
        await for (final entity in incoming.list()) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          if (!name.startsWith(AppConfig.tmpPrefix)) continue;

          final size = await entity.length();
          if (size < AppConfig.minValidAudioBytes) {
            await entity.delete();
            AppLog.i('rec', '清理空录音 $name（$size 字节）');
            continue;
          }

          final finalName = name.substring(AppConfig.tmpPrefix.length);
          final target = File(
            p.join(memberDir.path, AppConfig.outboxDirName, finalName),
          );
          await AtomicIo.promote(entity, target);

          final id = p.basenameWithoutExtension(finalName);
          final createdAt = _timestampFromId(id) ?? DateTime.now();
          final memo = Memo(
            id: id,
            kind: MemoKind.audio,
            author: _authorFromDir(dirName),
            authorDir: dirName,
            deviceId: deviceId,
            createdAt: createdAt,
            updatedAt: DateTime.now(),
            audioFilename: finalName,
            status: MemoStatus.local,
          );
          await _db.upsertMemo(memo);
          recovered.add(memo);
          AppLog.i('rec', '恢复中断的录音 $finalName');
        }
      }
    } on FileSystemException catch (error) {
      AppLog.w('rec', '扫描孤儿文件失败：$error');
    }
    return recovered;
  }

  /// 权限分两层处理。
  ///
  /// `permission_handler` 能区分"还没问过"和"被永久拒绝"——
  /// 后者再弹系统对话框是没用的，必须引导用户去设置页，
  /// 否则用户只会看到"点了没反应"。
  /// 真正的录音许可仍由 record 插件再确认一次（它最清楚平台差异）。
  Future<void> _ensurePermissions() async {
    final micStatus = await Permission.microphone.request();
    if (micStatus.isPermanentlyDenied) {
      throw RecorderException(
        '麦克风权限被拒绝。请到 系统设置 → 隐私与安全性 → 麦克风 里允许本 App。',
      );
    }

    // Android 13+ 通知权限：不给也能录音，但前台服务的常驻通知会不显示，
    // 用户就不知道"还在录"。所以请求但不阻断。
    if (Platform.isAndroid) {
      final notification = await Permission.notification.status;
      if (notification.isDenied) {
        await Permission.notification.request();
      }
    }

    final granted = await _recorder.hasPermission();
    if (!granted) {
      throw RecorderException('没有麦克风权限，请到系统设置里打开');
    }
  }

  Future<void> dispose() async {
    await _amplitudeSub?.cancel();
    await _recorder.dispose();
    phase.dispose();
    level.dispose();
  }

  // ------------------------------------------------------------- 内部工具

  /// 同一秒内连续录音会撞 id，这里加序号后缀。
  Future<String> _uniqueId(String dirName, DateTime now) async {
    final base = Memo.newId(now);
    var candidate = base;
    var counter = 1;
    while (await _paths
        .audioFile(dirName, '$candidate.m4a')
        .exists()) {
      counter += 1;
      candidate = '${base}_$counter';
    }
    return candidate;
  }

  static DateTime? _timestampFromId(String id) {
    final match = RegExp(r'memo_(\d{8})_(\d{6})').firstMatch(id);
    if (match == null) return null;
    try {
      return DateFormat('yyyyMMdd_HHmmss').parseStrict(
        '${match.group(1)}_${match.group(2)}',
      );
    } on FormatException {
      return null;
    }
  }

  static String _authorFromDir(String dirName) {
    const suffix = '_Notes';
    if (dirName.endsWith(suffix)) {
      return dirName.substring(0, dirName.length - suffix.length);
    }
    return dirName;
  }
}
