# LocalVoiceSync v0.1

本地优先、隐私至上、全家共享的离线语音知识库。

手机负责**极速采集**与**离线检索**，家里的 Mac Mini M4 负责**转写**与**结构化提炼**，
两者之间只通过局域网 Syncthing 点对点同步。全程不经过任何云端服务。

```
┌──────────────────────┐        Syncthing（局域网 P2P）        ┌──────────────────────┐
│  Flutter 客户端       │                                      │  Mac Mini M4          │
│  Android / iOS / macOS│                                      │  mac_processor/       │
│                      │                                      │                      │
│  录音 → .tmp_ 临时文件 │  ──── outbox/memo_*.m4a ───────▶     │  watchdog 监听        │
│  停止 → 原子重命名     │                                      │    ↓                  │
│  入库 SQLite + FTS5   │                                      │  faster-whisper       │
│  本地 ONNX 向量        │  ◀─── inbox/memo_*.json + .md ───   │  → Ollama 提炼        │
│  混合检索（RRF 融合）  │                                      │  → 向量化 → 原子写回   │
└──────────────────────┘                                      └──────────────────────┘
```

---

## 一、目录结构

```
local_voice_sync/
├── lib/
│   ├── main.dart                     入口：先 boot 服务，再起 UI
│   ├── providers.dart                Riverpod 3 状态层
│   ├── theme.dart
│   ├── core/
│   │   ├── app_config.dart           全局常量（模型 id、目录名、轮询节奏）
│   │   ├── app_paths.dart            持久化目录布局 + .stignore 生成
│   │   ├── app_log.dart              控制台 + 按天文件日志
│   │   └── family_member.dart        家庭成员 → 作者标签 → 同步目录
│   ├── models/
│   │   ├── memo.dart                 记录模型（SQLite 行 ↔ 同步契约 JSON）
│   │   ├── search_hit.dart
│   │   └── sync_status.dart
│   ├── services/
│   │   ├── audio_recorder_service.dart   原子录音 + 孤儿文件恢复
│   │   ├── text_note_service.dart        文本随手记
│   │   ├── atomic_io.dart                .part → rename 原子写
│   │   ├── database_service.dart         sqflite + 迁移 + FTS5 + 向量表
│   │   ├── fts_tokenizer.dart            中文单字/二元组切分
│   │   ├── bert_tokenizer.dart           WordPiece 分词（喂 ONNX 用）
│   │   ├── embedding_worker.dart         向量 Isolate 入口（ONNX 推理 + 余弦）
│   │   ├── embedding_isolate.dart        主 Isolate 侧封装
│   │   ├── search_service.dart           混合检索 + RRF 融合
│   │   ├── inbox_watcher_service.dart    解析 Mac 回传 JSON 入库
│   │   ├── syncthing_service.dart        Syncthing REST 探测
│   │   ├── settings_store.dart
│   │   ├── foreground_service.dart       Android 前台服务桥
│   │   └── services.dart                 冷启动编排（boot）
│   ├── views/                        root_shell / home / search / detail / settings
│   └── widgets/                      status_light / record_button / memo_card / todo_list
├── assets/models/                    向量模型（不进 git，用脚本下载）
├── tool/fetch_embedding_model.sh
├── android/  ios/  macos/            三端平台配置
├── mac_processor/                    Mac Mini 端 Python 流水线
│   ├── main.py                       监听 + 调度 + 三步流水线
│   ├── config.py  transcriber.py  extractor.py  embedder.py
│   ├── audio_utils.py                自己解码音频（绕开 PyAV 版本坑）
│   ├── state.py                      sha256 去重
│   ├── writer.py                     原子写 JSON / Markdown
│   ├── requirements.txt  run.sh  .env.example
└── .github/workflows/build_all.yml   三端并行出包
```

### 运行期目录（关键）

同步根与私有区**在两个不同的地方**——这不是洁癖，是 Android 的硬约束。

```
# Android 同步根（共享存储，Syncthing 才看得见）
/storage/emulated/0/Documents/LocalVoiceSync/
├── .stignore                ← 自动生成，屏蔽临时文件
├── Me_Notes/
│   ├── .incoming/           ← 录音中的半截文件（同步忽略）
│   ├── outbox/              ← 手机 → Mac
│   └── inbox/               ← Mac → 手机
├── Dad_Notes/  Mom_Notes/  <自定义>_Notes/

# 私有区（iOS/macOS 在 <Documents> 下，Android 在 /data/user/0/<pkg>/app_flutter）
LocalVoiceSyncLocal/
├── library.db               ← SQLite（多设备同步会互相覆盖损坏）
└── logs/
```

> **为什么同步根不能在应用私有目录里**
> `getApplicationDocumentsDirectory()` 在 Android 上返回
> `/data/user/0/com.localvoicesync.app/app_flutter`，这是**应用私有沙箱**。
> Syncthing 是另一个 App，无论给什么权限都进不来。
> 所以同步根必须落在共享存储，代价是要 `MANAGE_EXTERNAL_STORAGE`
> （「所有文件访问」）。没授予时 App 会自动退回私有目录：录音、检索、
> 播放全都正常，只是**录音传不到 Mac**——首页会挂一条黄色提示条，不会静默失败。
>
> `getExternalStorageDirectory()` 也不行：它返回
> `/storage/emulated/0/Android/data/<pkg>/files`，Android 11+ 同样把其他 App 挡在外面。

> **为什么数据库必须放在同步目录之外**
> 两台设备各自持有一个 SQLite 文件、由 Syncthing 双向覆盖，是最经典的
> "数据库被撕裂"事故。同步目录里只放**只增不改的文件**（音频、JSON、Markdown），
> 数据库永远留在本机。

---

## 二、快速开始

### 1. 手机端

```bash
flutter pub get
./tool/fetch_embedding_model.sh          # 下载 512 维中文向量模型（约 24MB）
flutter run -d <device>
```

首次启动后到「设置 → 成员」选一下这是谁的手机。

> 国内网络下载模型慢：`HF_ENDPOINT=https://hf-mirror.com ./tool/fetch_embedding_model.sh`

### 1.5 Android 端必做的两个授权

装好 APK 后有两件事不做就等于没装：

| 权限 | 在哪开 | 不开的后果 |
| --- | --- | --- |
| **麦克风** | 首次录音时弹窗，或 设置 → 应用管理 → 语音知识库 → 权限 | 无法录音 |
| **所有文件访问** | 设置 → 隐私保护 → 特殊权限 → 所有文件访问权限 → 语音知识库 | 录音传不到 Mac（首页黄条提示） |

另外把 **省电策略改成「无限制」**（设置 → 应用管理 → 语音知识库 → 省电策略），
HyperOS / MIUI 默认会在息屏后掐掉后台，前台录音服务和 Syncthing 都会被误杀。

### 1.6 本地直接出 APK（不需要 CI）

```bash
export JAVA_HOME="$HOME/Android/jdk-17/Contents/Home"
export ANDROID_HOME="$HOME/Android/sdk"

flutter build apk --release                  # 全 ABI，约 96MB
flutter build apk --release --split-per-abi  # 按 ABI 拆分，arm64 约 40MB
```

本机工具链装法（macOS arm64，不需要 Android Studio）：

```bash
# JDK 17
curl -L "https://api.adoptium.net/v3/binary/latest/17/ga/mac/aarch64/jdk/hotspot/normal/eclipse" -o /tmp/jdk.tar.gz
mkdir -p ~/Android && tar -xzf /tmp/jdk.tar.gz -C ~/Android && mv ~/Android/jdk-17* ~/Android/jdk-17
export JAVA_HOME="$HOME/Android/jdk-17/Contents/Home"   # 注意是 Contents/Home

# Android SDK 命令行工具
curl -L "https://dl.google.com/android/repository/commandlinetools-mac-13114758_latest.zip" -o /tmp/ct.zip
mkdir -p ~/Android/sdk/cmdline-tools && unzip -q /tmp/ct.zip -d /tmp && mv /tmp/cmdline-tools ~/Android/sdk/cmdline-tools/latest

yes | ~/Android/sdk/cmdline-tools/latest/bin/sdkmanager --sdk_root="$HOME/Android/sdk" --licenses
~/Android/sdk/cmdline-tools/latest/bin/sdkmanager --sdk_root="$HOME/Android/sdk" \
  "platform-tools" "platforms;android-36" "build-tools;36.0.0"
flutter config --android-sdk "$HOME/Android/sdk"
```

### 2. Mac Mini 端

```bash
cd mac_processor
cp .env.example .env                     # 改 LVS_SYNC_ROOT 为 Syncthing 文件夹的真实路径
./run.sh --check                         # 环境自检
./run.sh                                 # 常驻监听
```

前置条件：

```bash
brew install ollama && ollama serve
ollama pull qwen3.5:9b-q4_K_M
```

首次转写会自动下载 `large-v3-turbo`（约 1.6GB）到 `~/.cache/localvoicesync/whisper`。

### 3. Syncthing

手机和 Mac 各装一个 Syncthing，把 Mac 上那个目录设成共享文件夹，
**文件夹 ID 记下来填进 App 设置页**，再填手机本机 Syncthing 的 API Key
（`设置 → API 密钥`，地址默认 `http://127.0.0.1:8384`）。

状态灯逻辑：

| 灯 | 含义 |
| --- | --- |
| 🟢 已连接 | Syncthing 可达，且 `needFiles == 0` |
| 🟢 同步中 N | 可达，还有 N 个文件没传完（脉冲动画） |
| 🟡 离线 · 待处理 N | 不可达；N 是本地还没被 Mac 处理过的记录数 |
| ⚪ 离线 | 还没配置 Syncthing（首次使用） |

**点一下状态灯**会立刻重新探测，并弹出「为什么离线」的具体原因
（连不上 / API Key 不对 / 文件夹 ID 不对 / Mac 设备未连接）。

更完整的排查在「设置 → 诊断」：

- **测试连接** — 逐行显示每一步的成败：能否连上、API Key 是否有效、
  文件夹 ID 是否存在、Mac 设备是否在线
- **扫描收件箱** — 显示同步根是否在共享存储、每个成员 `inbox/` 里到底有几个文件、
  最近一次扫描看到/入库了多少、上次错误是什么

> 设备 ID 比较做了归一化（忽略连字符与大小写），手工抄写漏个 `-` 不会误判离线。

> **iOS 的现实限制**：iOS 不允许后台常驻的 Syncthing。iPhone 上需要借助
> Möbius Sync 之类的 App 提供本地文件夹同步，或者只在打开 App 时同步。
> 采集、检索、离线使用完全不受影响——这正是"离线优先"设计的意义。

---

## 三、几个关键工程决策

### 1. 原子录音：把"半截文件"从文件系统层面消除

```
点击录音 → 写入  .incoming/.tmp_memo_20261031_123000.m4a
点击停止 → 校验大小 → rename → outbox/memo_20261031_123000.m4a
```

rename 在同一文件系统内是**原子操作**，Syncthing 只可能看到两种状态：
文件不存在，或文件完整。配合自动生成的 `.stignore`（`(?d).incoming` / `(?d).tmp_*`），
即使代码出 bug 漏了临时文件，也不会被传出去。

App 启动时会扫一遍 `.incoming/`：大于 2KB 的"孤儿"录音会被**救回**并入库
（宁可转写出一段残缺文本，也不让用户觉得"我明明录了"），小于阈值的视为误触删除。

### 2. 零数据丢失

- 全部落在 `getApplicationDocumentsDirectory()`，**不碰 Temporary / Cache**；
- SQLite 用 `onUpgrade` 逐版本迁移，`_migrations` 是「版本号 → SQL 列表」的表，
  加新版本只追加、不改历史条目；
- v1 → v2 已经有一次真实迁移（新增 `aliases` 列），写法可直接参考
  `database_service.dart`。

### 3. 中文 FTS5 没有内置分词怎么办

SQLite 的 `unicode61` 会把「太阳能配线」当成**一个** token，搜「配线」永远搜不到；
`trigram` 分词器能用，但要求 SQLite ≥ 3.34，而 Android 系统自带的 SQLite 版本参差不齐。

所以自己切：**索引时切「单字 + 相邻二元组」，查询时只切二元组**。
「太阳能配线」→ `太 太阳 阳 阳能 能 能配 配 配线 线`，搜「配线」→ `"配线"`，命中。
零扩展依赖，任何 SQLite 版本都能跑。`test/fts_tokenizer_test.dart` 有 9 个用例覆盖。

FTS5 万一不可用（极老系统），自动降级成 `LIKE` 扫描，App 照常能用。

### 4. 混合检索用 RRF，不用加权求和

bm25 分数和余弦相似度**量纲完全不同**，直接加权相加需要反复调参，换个数据规模就失衡。
RRF 只看排名：

```
score(d) = Σ 1 / (k + rank_i(d))        k = 60
```

天然免疫量纲问题，也是 Elasticsearch / Vespa 的默认混合方案。
同时命中两条路的会标成「混合」，用户能看出"为什么这条被搜出来"。

### 5. 向量计算全部在 Isolate

`embedding_worker.dart` 是一个常驻 Isolate，**同时持有 ONNX 会话和内存向量索引**。
主线程只发「文本」进去、收「向量/命中列表」出来，一次阻塞调用都没有。
向量不来回搬运——这是把索引留在 worker 内的主要原因。

模型缺失时 `EmbeddingEngine.start()` 返回 false，搜索页自动退化成纯关键词检索，
设置页显示原因。**不崩溃、不白屏、不阻断录音。**

---

## 四、同步契约

Mac 端写入 `inbox/<id>.json`：

```json
{
  "id": "memo_20261031_123000",
  "created_at": "2026-10-31 12:30:00",
  "kind": "audio",
  "audio_filename": "memo_20261031_123000.m4a",
  "author": "Dad",
  "summary": "检查了太阳能板配线与逆变器接线，需购买两个 50A Class T 保险丝",
  "knowledge_points": ["逆变器接线偏松，需要重新紧固", "Class T 保险丝规格为 50A"],
  "todos": [
    {"task": "购买两个 50A Class T 保险丝", "status": "pending"},
    {"task": "检查逆变器接线", "status": "completed"}
  ],
  "tags": ["太阳能", "配线", "PowMr"],
  "aliases": ["逆变器", "inverter", "变流器", "保险丝", "fuse"],
  "raw_transcript": "今天检查了太阳能板的配线……",
  "embedding": [0.012, -0.045, 0.231],
  "embedding_model": "bge-small-zh-v1.5",
  "embedding_dim": 512,
  "schema_version": 1,
  "processed_at": "2026-10-31 12:31:04",
  "processing": {
    "degraded": false,
    "whisper_model": "large-v3-turbo",
    "language": "zh",
    "duration_seconds": 12.4,
    "llm_model": "qwen3.5:9b-q4_K_M"
  }
}
```

同时写一份人类可读的 `<id>.md`。失败时写 `<id>.error.json`，手机端把记录标成「失败」。

**手机端的三个宽容处理**：

1. `device_id` 不由 Mac 写（Mac 不知道，也不该编造），手机保留自己的原值；
2. `embedding_model` 与本地不一致时**丢弃回传向量、本机重算**——
   跨模型比对毫无意义，宁可多算一次也不能悄悄搜错；
3. 重新同步时按任务文本对齐合并 TODO，**保留用户已勾选的状态**。

Mac 端若 Ollama 挂了，会进入**降级模式**：只回传原始转写 + 截断摘要，
`processing.degraded = true`。用户至少不会丢内容。

---

## 五、CI / 出包

`.github/workflows/build_all.yml`，push 到 `main` 或打 `v*` tag 时触发：

| Job | Runner | 产物 | 签名 |
| --- | --- | --- | --- |
| `quality` | ubuntu | — | 跑 `flutter analyze` + `flutter test`，其余 job 的前置 |
| `android` | ubuntu | `LocalVoiceSync-*.apk` | debug keystore，**可直接安装** |
| `ios` | macos-14 | `LocalVoiceSync-*-unsigned.ipa` | 未签名，需 Sideloadly / AltStore 自签 |
| `macos` | macos-14 | `LocalVoiceSync-*-macos.zip` | 未签名，首次打开需右键「打开」 |

产物在 Actions 页面 Artifacts 区下载，保留 30 天。

换成正式签名需要：
- Android：`android/key.properties` + keystore，改 `build.gradle.kts` 的 `signingConfig`；
- iOS：Apple Developer 账号（$99/年）+ 证书 p12 + provisioning profile。

---

## 六、与需求文档的差异（都是刻意的）

| 需求原文 | 实际实现 | 原因 |
| --- | --- | --- |
| `onnxruntime_flutter` | `onnxruntime: ^1.4.1` | pub.dev 上**没有** `onnxruntime_flutter` 这个包；`onnxruntime` 是唯一同时支持 Android / iOS / macOS 的 FFI 封装，且能在 Isolate 里跑 |
| `bge-micro-zh` | `bge-small-zh-v1.5`（512 维） | 该模型名在 HuggingFace / ModelScope 上**不存在**。BGE 官方中文系列最小一档就是 small-zh-v1.5，即中文场景的「micro」 |
| `sqlite-vec` 扩展 | 纯 Dart 余弦 + Isolate | sqlite-vec 要 iOS 静态链接、Android ndk 编译 `.so`、macOS dylib，v0.1 构建风险太高。1 万条记录暴力余弦约 10~30ms，够用；`EmbeddingEngine` 已预留换索引实现的接口 |
| `flutter_markdown` | 同左（`^0.7.7+1`） | 该包已标记 discontinued，但仍可正常解析使用；后续可平滑换 `flutter_markdown_plus` |
| 未提及 | `minSdk = 26` | Android 8.0 以下的系统 SQLite 默认没编译 FTS5，装上去会静默降级 |
| 未提及 | 数据库放同步目录**之外** | 见上文，多设备同步 SQLite 必然损坏 |
| 未提及 | 自己解码音频 | faster-whisper 1.2.x 调 `av.open(..., metadata_errors=...)`，PyAV 19 已删掉该参数；`av<15` 在 Python 3.12/macOS 又没有轮子。改为先解成 float32 数组再喂模型，对 PyAV 版本不再敏感 |

---

## 七、已知限制（v0.1 范围外）

- **TODO 勾选只存本机**，不回写给 Mac 的 JSON；下次同步按任务文本合并，
  但两台手机之间不互相同步勾选状态。
- **iOS 无法后台常驻 Syncthing**，需第三方 App 配合。
- **删除记录不删音频**，音频留在 `outbox/` 作为原始素材。
- **语义检索阈值 0.35 是经验值**，记录量大之后建议按实际分布重新标定。
- Mac 端最多 2 个 Whisper 实例，极端批量会排队；Ollama 自身串行处理请求，
  真正的瓶颈通常是 9B 模型的生成速度。

---

## 八、开发命令

```bash
flutter analyze                     # 静态检查（当前 0 issue）
flutter test                        # 24 个单测

# 没有 Xcode / Android SDK 时，用它做真正的 Dart 编译验证（含资产打包）：
flutter build bundle --target-platform=darwin
flutter build apk --release
flutter build ios --release --no-codesign
flutter build macos --release

cd mac_processor
./run.sh --check                    # 环境自检
./run.sh --once                     # 处理完积压就退出（适合 cron）
./run.sh --file path/to/memo.m4a    # 单文件调试
./run.sh --dry-run                  # 只处理不写文件
```

> 若本机配了 HTTP 代理，`flutter test` 会因为 localhost WebSocket 被代理劫持而失败，
> 需要 `NO_PROXY=127.0.0.1,localhost flutter test`。
