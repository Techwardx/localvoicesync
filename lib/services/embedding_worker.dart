import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:onnxruntime/onnxruntime.dart';

import '../core/app_config.dart';
import 'bert_tokenizer.dart';

/// 命令字常量（主 isolate 与 worker 之间的协议）。
class EmbeddingCmd {
  const EmbeddingCmd._();

  static const String init = 'init';
  static const String embed = 'embed';
  static const String upsert = 'upsert';
  static const String index = 'index';
  static const String search = 'search';
  static const String stats = 'stats';
}

/// 向量 Isolate 的入口函数。
///
/// 为什么一定要单独开 Isolate：
/// - ONNX 推理是同步阻塞的 FFI 调用，跑在主 isolate 上必然掉帧；
/// - 暴力余弦在几千条记录上是 10~30ms 的纯计算，同样不能碰 UI 线程。
///
/// 这个 Isolate 同时持有「模型会话」和「内存向量索引」，
/// 查询时只需要把问题文本传进来，向量不需要来回搬运。
void embeddingWorkerMain(SendPort mainSend) {
  final receive = ReceivePort();
  mainSend.send(receive.sendPort);

  OrtSession? session;
  BertTokenizer? tokenizer;
  List<String> inputNames = const <String>[];
  String? outputName;
  var dim = AppConfig.embeddingDim;
  var modelLoaded = false;

  /// 内存索引：memoId → 已归一化向量。
  final index = <String, Float32List>{};

  /// 串行化消息处理。ONNX Session 不能被并发调用，
  /// 而且 async 回调会交错，必须自己排队。
  Future<void> chain = Future<void>.value();

  Float32List normalize(List<double> raw) {
    var sum = 0.0;
    for (final value in raw) {
      sum += value * value;
    }
    final norm = sum <= 0 ? 1.0 : math.sqrt(sum);
    final out = Float32List(raw.length);
    for (var i = 0; i < raw.length; i++) {
      out[i] = raw[i] / norm;
    }
    return out;
  }

  Float32List runEmbedding(String text) {
    final activeSession = session;
    final activeTokenizer = tokenizer;
    if (activeSession == null || activeTokenizer == null) {
      throw StateError('模型尚未加载');
    }

    final encoded = activeTokenizer.encode(
      text,
      maxLength: AppConfig.maxSequenceLength,
    );
    final shape = <int>[1, encoded.inputIds.length];

    final idTensor = OrtValueTensor.createTensorWithDataList(
      Int64List.fromList(encoded.inputIds),
      shape,
    );
    final maskTensor = OrtValueTensor.createTensorWithDataList(
      Int64List.fromList(encoded.attentionMask),
      shape,
    );
    final typeTensor = OrtValueTensor.createTensorWithDataList(
      Int64List.fromList(encoded.tokenTypeIds),
      shape,
    );

    final inputs = <String, OrtValue>{};
    for (final name in inputNames) {
      switch (name) {
        case 'input_ids':
          inputs[name] = idTensor;
        case 'attention_mask':
          inputs[name] = maskTensor;
        case 'token_type_ids':
          inputs[name] = typeTensor;
        default:
          // 未知输入（有些导出版本带 position_ids）一律喂 attention mask，
          // 比直接报错更能兼容不同导出。
          inputs[name] = maskTensor;
      }
    }

    final runOptions = OrtRunOptions();
    try {
      final outputs = activeSession.run(runOptions, inputs);
      if (outputs.isEmpty || outputs.first == null) {
        throw StateError('模型没有返回结果');
      }
      final value = outputs.first!.value;
      outputs.first!.release();
      // last_hidden_state: [1, seq, dim] → 取 CLS（第 0 个 token）
      final batch = value as List<dynamic>;
      final sequence = batch.first as List<dynamic>;
      final cls = sequence.first as List<dynamic>;
      final raw = <double>[
        for (final item in cls) (item as num).toDouble(),
      ];
      dim = raw.length;
      return normalize(raw);
    } finally {
      idTensor.release();
      maskTensor.release();
      typeTensor.release();
      runOptions.release();
    }
  }

  Future<Object?> handle(Map<Object?, Object?> message) async {
    final cmd = message['cmd'];
    switch (cmd) {
      case EmbeddingCmd.init:
        final modelBytes = message['model'] as Uint8List;
        final vocabText = message['vocab'] as String;
        final threads = (message['threads'] as int?) ?? 2;
        dim = (message['dim'] as int?) ?? AppConfig.embeddingDim;

        OrtEnv.instance.init();
        final options = OrtSessionOptions();
        options.setIntraOpNumThreads(threads);
        session = OrtSession.fromBuffer(modelBytes, options);
        inputNames = List<String>.from(session!.inputNames);
        outputName = session!.outputNames.isEmpty
            ? null
            : session!.outputNames.first;
        tokenizer = BertTokenizer.fromVocabText(vocabText);
        modelLoaded = true;
        return <String, Object?>{
          'inputs': inputNames,
          'output': outputName,
          'dim': dim,
          'vocab': tokenizer!.size,
        };

      case EmbeddingCmd.embed:
        final text = message['text'] as String? ?? '';
        if (!modelLoaded) throw StateError('模型尚未加载');
        return runEmbedding(text);

      case EmbeddingCmd.upsert:
        final memoId = message['id'] as String?;
        final vector = message['vector'] as Float32List?;
        if (memoId != null && vector != null) {
          index[memoId] = vector;
        }
        return index.length;

      case EmbeddingCmd.index:
        index.clear();
        final entries = message['entries'];
        if (entries is List) {
          for (final entry in entries) {
            if (entry is List && entry.length >= 2) {
              final key = entry[0];
              final vec = entry[1];
              if (key is String && vec is Float32List) {
                index[key] = vec;
              }
            }
          }
        }
        return index.length;

      case EmbeddingCmd.search:
        final query = message['vector'] as Float32List?;
        final topK = (message['topK'] as int?) ?? AppConfig.semanticTopK;
        if (query == null || index.isEmpty) return const <List<Object>>[];
        final scored = <MapEntry<String, double>>[];
        for (final entry in index.entries) {
          final vector = entry.value;
          if (vector.length != query.length) continue;
          var dot = 0.0;
          for (var i = 0; i < vector.length; i++) {
            dot += vector[i] * query[i];
          }
          scored.add(MapEntry(entry.key, dot));
        }
        scored.sort((a, b) => b.value.compareTo(a.value));
        return <List<Object>>[
          for (final item in scored.take(topK))
            <Object>[item.key, item.value],
        ];

      case EmbeddingCmd.stats:
        return <String, Object?>{
          'ready': modelLoaded,
          'dim': dim,
          'indexed': index.length,
        };

      default:
        throw ArgumentError('未知命令：$cmd');
    }
  }

  receive.listen((message) {
    if (message is! Map) return;
    final id = message['id'];
    chain = chain.then((_) async {
      try {
        final result = await handle(message);
        mainSend.send(<String, Object?>{
          'id': id,
          'ok': true,
          'data': result,
        });
      } on Object catch (error) {
        mainSend.send(<String, Object?>{
          'id': id,
          'ok': false,
          'error': error.toString(),
        });
      }
    });
  });
}
