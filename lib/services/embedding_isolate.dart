import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../core/app_config.dart';
import '../core/app_log.dart';
import 'database_service.dart';
import 'embedding_worker.dart';

/// 语义检索命中。
class VectorHit {
  const VectorHit({required this.memoId, required this.score});

  final String memoId;

  /// 余弦相似度，已归一化向量下的点积，范围约 [-1, 1]。
  final double score;
}

/// 向量引擎的主 isolate 侧封装。
///
/// 对上层暴露三个动作：`embed` / `loadIndex` / `search`，
/// 全部异步、全部在后台 isolate 执行，主线程一次阻塞调用都没有。
class EmbeddingEngine {
  Isolate? _isolate;
  SendPort? _sendPort;
  ReceivePort? _receivePort;

  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  int _sequence = 0;

  bool _ready = false;
  String? _lastError;
  int _indexed = 0;
  int _dim = AppConfig.embeddingDim;

  bool get isReady => _ready;
  String? get lastError => _lastError;
  int get indexedCount => _indexed;
  int get dimension => _dim;

  /// 启动 Isolate 并加载模型。模型文件缺失时返回 false（App 继续可用，只是没有语义检索）。
  Future<bool> start({
    required Uint8List modelBytes,
    required String vocabText,
    int threads = 2,
  }) async {
    if (_ready) return true;
    try {
      final receive = ReceivePort();
      _receivePort = receive;
      final handshake = Completer<SendPort>();

      receive.listen((message) {
        if (message is SendPort) {
          if (!handshake.isCompleted) handshake.complete(message);
          return;
        }
        if (message is Map) {
          _handleReply(message);
        }
      });

      _isolate = await Isolate.spawn(
        embeddingWorkerMain,
        receive.sendPort,
        debugName: 'lvs-embedding',
      );

      final send = await handshake.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw StateError('向量 Isolate 握手超时'),
      );
      _sendPort = send;

      final result = await _invoke(<String, Object?>{
        'cmd': EmbeddingCmd.init,
        'model': modelBytes,
        'vocab': vocabText,
        'threads': threads,
        'dim': AppConfig.embeddingDim,
      }, timeout: const Duration(seconds: 90));

      if (result is Map) {
        _ready = true;
        _dim = (result['dim'] as int?) ?? AppConfig.embeddingDim;
        AppLog.i(
          'embed',
          '向量模型就绪：输入 ${result['inputs']}，维度 $_dim，词表 ${result['vocab']}',
        );
      } else {
        _ready = false;
        _lastError = '模型初始化失败';
      }
      return _ready;
    } on Object catch (error, stack) {
      _ready = false;
      _lastError = error.toString();
      AppLog.e('embed', '启动向量引擎失败', error, stack);
      await _shutdownIsolate();
      return false;
    }
  }

  /// 文本 → 归一化向量。失败返回 null。
  ///
  /// 超时给到 90 秒而不是 30 秒：真机上第一次推理（模型刚加载完、
  /// CPU 还没热身）实测能超过 30 秒，一旦超时这条记录就永远没有向量，
  /// 语义检索会静默漏掉它。宁可多等一会儿，也不要留下检索空洞。
  Future<Float32List?> embed(String text) async {
    if (!_ready) return null;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final result = await _invoke(<String, Object?>{
      'cmd': EmbeddingCmd.embed,
      'text': trimmed,
    }, timeout: const Duration(seconds: 90));
    return result is Float32List ? result : null;
  }

  /// 全量重建内存索引（App 启动时调用一次）。
  Future<void> loadIndex(List<VectorRecord> records) async {
    if (!_ready) return;
    final entries = <List<Object>>[
      for (final record in records)
        <Object>[record.memoId, record.vector],
    ];
    final count = await _invoke(<String, Object?>{
      'cmd': EmbeddingCmd.index,
      'entries': entries,
    }, timeout: const Duration(seconds: 30));
    if (count is int) _indexed = count;
  }

  /// 单条增量更新，避免新记录入库就要全量重建。
  Future<void> upsert(String memoId, Float32List vector) async {
    if (!_ready) return;
    final count = await _invoke(<String, Object?>{
      'cmd': EmbeddingCmd.upsert,
      'id': memoId,
      'vector': vector,
    });
    if (count is int) _indexed = count;
  }

  Future<List<VectorHit>> search(Float32List query, {int topK = 30}) async {
    if (!_ready) return const <VectorHit>[];
    final result = await _invoke(<String, Object?>{
      'cmd': EmbeddingCmd.search,
      'vector': query,
      'topK': topK,
    });
    if (result is! List) return const <VectorHit>[];
    final hits = <VectorHit>[];
    for (final item in result) {
      if (item is List && item.length >= 2) {
        final id = item[0];
        final score = item[1];
        if (id is String && score is num) {
          hits.add(VectorHit(memoId: id, score: score.toDouble()));
        }
      }
    }
    return hits;
  }

  Future<void> dispose() async {
    _ready = false;
    _pending.clear();
    await _shutdownIsolate();
    _receivePort?.close();
    _receivePort = null;
  }

  Future<void> _shutdownIsolate() async {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
  }

  void _handleReply(Map<Object?, Object?> message) {
    final id = message['id'];
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    if (message['ok'] == true) {
      completer.complete(message['data']);
    } else {
      final error = message['error']?.toString() ?? '未知错误';
      AppLog.w('embed', '向量命令失败：$error');
      completer.completeError(StateError(error));
    }
  }

  Future<Object?> _invoke(
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final send = _sendPort;
    if (send == null) return null;
    final id = ++_sequence;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    send.send(<String, Object?>{'id': id, ...payload});
    try {
      return await completer.future.timeout(timeout);
    } on Object catch (error) {
      _pending.remove(id);
      AppLog.w('embed', '向量调用超时或失败：$error');
      return null;
    }
  }
}
