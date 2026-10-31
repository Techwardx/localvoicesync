# assets/models

这个目录存放手机端语义检索用的 ONNX 模型。

**模型文件不进 git**（体积约 24MB，且会频繁更新），只保留本说明和 `.gitkeep`。
`pubspec.yaml` 里声明了整个目录作为 assets，所以目录必须存在，
否则 `flutter pub get` 之后的资源打包会报警告。

## 怎么获取

```bash
chmod +x tool/fetch_embedding_model.sh
./tool/fetch_embedding_model.sh
```

国内网络建议走镜像：

```bash
HF_ENDPOINT=https://hf-mirror.com ./tool/fetch_embedding_model.sh
```

跑完后目录里应该有两个文件：

| 文件 | 说明 |
| --- | --- |
| `bge-small-zh-v1.5.onnx` | BGE 中文 small 模型，512 维，int8 量化 |
| `vocab.txt` | BERT WordPiece 词表，21128 行 |

## 为什么不是需求里写的 `bge-micro-zh`

HuggingFace / ModelScope 上**不存在**名为 `bge-micro-zh` 的模型。
BGE 官方中文系列最小的一档是 `bge-small-zh-v1.5`（24M 参数，512 维），
它就是中文场景下的"micro"档位，所以这里用它。

模型 id 写死在 `lib/core/app_config.dart` 的 `AppConfig.embeddingModelId`，
同时也会写进数据库和回传 JSON。以后换模型只需要改这一处 + 重跑
`SearchService.rebuildIndex()`，不会污染历史数据。

## 模型缺失时会发生什么

`Services.loadEmbeddingAssets()` 会捕获加载失败，`EmbeddingEngine.start()` 返回 false，
于是：

- 搜索页的"语义"模式返回空结果；
- "混合"模式自动退化成纯 FTS5 关键词检索；
- 设置页显示"语义检索：未启用"以及原因。

**不会崩溃，不会白屏，不会阻断录音。**
