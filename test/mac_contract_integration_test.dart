import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_voice_sync/core/app_config.dart';
import 'package:local_voice_sync/models/memo.dart';
import 'package:local_voice_sync/services/inbox_watcher_service.dart';

/// 端到端契约测试。
///
/// `test/fixtures/mac_pipeline_output.json` 不是手写的样例，而是
/// `mac_processor` 真实跑完一段中文语音后产出的文件（Whisper large-v3-turbo
/// + qwen3.5:9b-q4_K_M + bge-small-zh-v1.5）。
///
/// 这个测试的价值在于：它同时校验了 Python 端的输出格式和 Dart 端的解析逻辑，
/// 两边任何一侧改了字段名/类型，这里都会立刻红。
void main() {
  late Map<String, Object?> json;

  setUpAll(() {
    final file = File('test/fixtures/mac_pipeline_output.json');
    final decoded = jsonDecode(file.readAsStringSync());
    json = (decoded as Map).map((key, value) => MapEntry(key.toString(), value));
  });

  test('Mac 流水线的真实输出能被完整解析', () {
    final memo = Memo.fromContractJson(
      json,
      authorDir: 'Dad_Notes',
      deviceId: 'dev_local',
    );

    expect(memo.id, 'memo_20261031_123000');
    expect(memo.kind, MemoKind.audio);
    expect(memo.author, 'Dad');
    expect(memo.audioFilename, 'memo_20261031_123000.m4a');
    expect(memo.status, MemoStatus.processed);
    expect(memo.createdAt, DateTime(2026, 10, 31, 12, 30, 0));
    expect(memo.summary, isNotEmpty);
    expect(memo.todos, isNotEmpty);
    expect(memo.tags, isNotEmpty);
    expect(memo.rawText, contains('太阳能'));
  });

  test('TODO 全部解析成 pending（语音里没有"已完成"的语义）', () {
    final memo = Memo.fromContractJson(
      json,
      authorDir: 'Dad_Notes',
      deviceId: 'dev_local',
    );
    expect(memo.todos.every((todo) => !todo.completed), isTrue);
    expect(memo.todos.first.task, contains('保险丝'));
  });

  test('回传向量维度与归一化正确', () {
    final raw = json['embedding']! as List<dynamic>;
    expect(raw.length, AppConfig.embeddingDim);
    expect(json['embedding_model'], AppConfig.embeddingModelId);
    expect(json['embedding_dim'], AppConfig.embeddingDim);

    final vector = parseFloat32List(raw);
    expect(vector, isNotNull);
    expect(vector!.length, AppConfig.embeddingDim);

    // L2 归一化后范数应为 1（允许浮点误差）
    var sum = 0.0;
    for (final value in vector) {
      sum += value * value;
    }
    expect(sum, closeTo(1.0, 1e-3));
  });

  test('aliases 进入检索文本，但不进标签', () {
    final memo = Memo.fromContractJson(
      json,
      authorDir: 'Dad_Notes',
      deviceId: 'dev_local',
    );
    expect(memo.aliases, isNotEmpty);
    expect(memo.tags, isNot(contains(memo.aliases.first)));
    expect(memo.searchableText, contains(memo.aliases.first));
  });

  test('回写契约时字段名与 Python 端一致', () {
    final memo = Memo.fromContractJson(
      json,
      authorDir: 'Dad_Notes',
      deviceId: 'dev_local',
    );
    final out = memo.toContractJson();

    for (final key in <String>[
      'id',
      'created_at',
      'kind',
      'audio_filename',
      'author',
      'summary',
      'knowledge_points',
      'todos',
      'tags',
      'aliases',
      'raw_transcript',
      'embedding',
      'embedding_model',
      'embedding_dim',
    ]) {
      expect(out.containsKey(key), isTrue, reason: '契约缺少字段 $key');
    }
    expect(out['created_at'], '2026-10-31 12:30:00');
  });
}
