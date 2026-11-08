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
│   │   ├── todo.dart                 待办状态：稳定 key / 合并 / 分组（纯 Dart）
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
│   │   ├── todo_service.dart             待办状态文件读写 + 跨设备对账
│   │   ├── syncthing_service.dart        Syncthing REST 探测
│   │   ├── settings_store.dart
│   │   ├── foreground_service.dart       Android 前台服务桥
│   │   └── services.dart                 冷启动编排（boot）
│   ├── views/                        root_shell / home / todo / search / detail / settings
│   └── widgets/                      status_light / record_button / memo_card / todo_list
├── assets/models/                    向量模型（不进 git，用脚本下载）
├── tool/fetch_embedding_model.sh
├── android/  ios/  macos/            三端平台配置
├── mac_processor/                    Mac Mini 端 Python 流水线
│   ├── main.py                       监听 + 调度 + 三步流水线
│   ├── config.py  transcriber.py  extractor.py  embedder.py
│   ├── hotwords.py                   自动家庭词表（按成员隔离 + token 预算）
│   ├── corrector.py                  离线词典纠错（同音专名）
│   ├── tag_registry.py               现有标签词表 + 确定性归类
│   ├── tag_cleanup.py                一次性整理已有标签（备份 / 预览 / 写回）
│   ├── todo_state.py                 待办状态只读汇总（供给 --todos / --check）
│   ├── lexicon/                      随仓库分发的词库（THUOCL MIT + custom.txt）
│   ├── tests/                        Python 单测（unittest，75 条）
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
├── todos/                       ← 待办勾选状态 + 手工待办（每台设备各写一份）
│   ├── <deviceId-A>.json        ← 手机 A 写且只写这一份
│   └── <deviceId-B>.json        ← 手机 B 写且只写这一份；Mac 只读不写

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
>
> 待办状态是唯一需要**多设备共同修改**的数据，所以也不能用一个共享文件让两台手机
> 对着写（那会生成 `.sync-conflict-*` 副本）。做法是每台设备只写自己那一份
> `todos/<deviceId>.json`，其余设备只读、按时间戳合并——详见第三节第 9 条。

---

## 二、快速开始

### 1. 手机端

```bash
flutter pub get
./tool/fetch_embedding_model.sh          # 下载 512 维中文向量模型（约 24MB）
flutter run -d <device>
```

首次启动后到「设置 → 成员」选一下这是谁的手机。

底部导航共四页：**首页**（录音 / 随手记 / 记录列表）、**待办**、**搜索**、**设置**。
「待办」是独立页面，把**所有笔记里提炼出的待办**汇总到一处，也能脱离笔记单独新建；
已完成的默认折叠在未完成列表下方，点一下标题栏展开。
勾选状态和手工待办会通过 `todos/` 目录与 Mac、其他手机同步（见第三节第 9 条）。

> 国内网络下载模型慢：`HF_ENDPOINT=https://hf-mirror.com ./tool/fetch_embedding_model.sh`

### 1.5 Android 端必做的两个授权

装好 APK 后有两件事不做就等于没装：

| 权限 | 在哪开 | 不开的后果 |
| --- | --- | --- |
| **麦克风** | 首次录音时弹窗，或 设置 → 应用管理 → 语音知识库 → 权限 | 无法录音 |
| **所有文件访问** | 设置 → 隐私保护 → 特殊权限 → 所有文件访问权限 → 语音知识库 | **收不到 Mac 回传的总结**（首页黄条提示） |

⚠️ **「所有文件访问」比看起来更关键，而且失效方式极其隐蔽。**

HyperOS / MIUI 允许 App 往 `Documents/` **写**文件而不需要这个权限，
但**读**别的 App 创建的文件仍然需要。于是会出现一种很难自查的状态：

- App 写的录音/随手记能正常同步到 Mac ✓
- Mac 处理完、Syncthing 把 `inbox/*.json` 写回手机 ✓
- **但 App 一个都读不到** —— `Directory.list()` 返回空数组（不报错），
  `File.exists()` 返回 false，看起来就像"文件根本没到"

授权后**必须把 App 从后台划掉再打开**：`MANAGE_EXTERNAL_STORAGE` 是
进程级的挂载视图，不重启进程通常不生效。

判据在「设置 → 诊断 → 扫描收件箱」里，看这一行：

```
「所有文件访问」已授予 / 未授予 ← 读不到 Syncthing 写的文件
枚举目录找到 N 个 / 按已知 id 直接探到 M 个
```

另外把 **省电策略改成「无限制」**（设置 → 应用管理 → 语音知识库 → 省电策略），
HyperOS / MIUI 默认会在息屏后掐掉后台，前台录音服务和 Syncthing 都会被误杀。

### 1.6 本地直接出 APK（不需要 CI）

```bash
export JAVA_HOME="$HOME/Android/jdk-17/Contents/Home"
export ANDROID_HOME="$HOME/Android/sdk"

flutter build apk --release --split-per-abi  # 按 ABI 拆分，arm64 约 53MB
flutter build apk --release                  # 全 ABI 单包，约 62MB
```

**升级已安装的 App 时，必须用 `--split-per-abi`。**

这不是口味问题，是硬性约束：`--split-per-abi` 会给每个 ABI 的 `versionCode`
加上偏移（arm64 = 2000 + `pubspec.yaml` 里的 build number），
而全 ABI 单包用的是原始值。于是「先装 split 包、再装全 ABI 包」等于
**降级安装**，Android 会直接拒绝，HyperOS 上表现为
**「应用未安装，安装包似乎无效」**——文案完全没提版本号，极难自查。

真机排障：

```bash
BT=$(ls -d "$HOME/Android/sdk/build-tools/"*/ | tail -1)
"${BT}aapt2" dump badging app-arm64-v8a-release.apk | head -1   # 看 versionCode
"${BT}apksigner" verify --print-certs -v app-arm64-v8a-release.apk
```

- `versionCode` 必须**大于**手机上已装的版本
- 签名证书必须**完全一致**，否则只能先卸载（会丢本机数据库，但同步目录里的
  json 还在，重装后会重新入库）

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
./run.sh --todos                         # 汇总所有笔记待办 + 手机同步过来的勾选（只读）
./run.sh                                 # 常驻监听
```

前置条件：

```bash
brew install ollama && ollama serve
ollama pull qwen3.5:9b-q4_K_M
```

首次转写会自动下载 `large-v3-turbo`（约 1.6GB）到 `~/.cache/localvoicesync/whisper`。

#### 2.1 开机自启（强烈建议，只需做一次）

```bash
cd mac_processor
./install_autostart.sh            # 安装并立即启动
./install_autostart.sh --status   # 看状态
```

这一步不能省。否则 Syncthing 和处理服务都只是"终端里敲起来的进程"：
电脑一重启、或终端一关就没了——而**手机端完全看不出来**，
只是从此再也不会有总结回传。这是最容易被误判成"App 有 bug"的故障。

必须在**真正的终端**里跑：受限沙箱里 `launchctl bootstrap` 会报
`Input/output error`。

日志：`~/Library/Logs/localvoicesync-syncthing.log`、
`~/Library/Logs/localvoicesync-processor.log`。

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
  文件夹 ID 是否存在、**文件夹是不是双向同步**、Mac 设备是否在线。
  末尾还会附一段「手机端 Syncthing 自述」——它**自己**认为文件夹在哪、
  是 `sendreceive` 还是 `sendonly`、索引里到底有哪些文件。
  排查"Mac 写了结果、手机收不到"时，这一段是决定性证据：
  只要它报的路径跟 App 的同步根不是同一个，问题立刻水落石出。
- **扫描收件箱** — 显示同步根是否在共享存储、`.stfolder` 是否已被认领、
  每个成员 `inbox/` 与 `outbox/` 各有多少文件（带文件名样本）、
  最近一次扫描看到/入库了多少、上次错误是什么，
  以及**本机数据库共几条 / 待处理几条**和一段数据库自检
  （schema 版本、`memos` 的实际列、FTS5 是否可用、按状态分组计数）。
  末尾还有「— 待办状态 —」：本机的 `deviceId`、自己那份状态文件路径、
  目录里读到了几份设备文件、合并后多少条勾选 / 多少条手工待办。
  勾选在别的手机上没同步过来时，先看这一段。

  > 最后这些数字是用来区分几种"看不到"的：
  > 文件在、库里 0 条 → 解析或入库失败；
  > 文件在、库里有条 → 其实已经入库了，只是列表没刷新；
  > schema 版本低于期望 → 迁移没跑，`memos` 会缺列，写库直接报错。

- **枚举 vs 直接探测** — 这一行专治一种很难解释的现象：

  > Syncthing 索引里明明有 `Me_Notes/inbox/memo_xxx.json`、
  > 手机端 `needFiles=0`，但 `Directory.list()` 看那个目录是**空的**，
  > 而同一层级的 `outbox/` 里文件却看得见（那些是 App 自己写的）。

  `枚举目录找到 N 个 / 按已知 id 直接探到 M 个`：
  **N=0 且 M>0** 说明文件确实在，只是 App 列不出目录内容——收件箱扫描
  会自动走"按已知 id 直接读文件"的兜底路径，不依赖目录枚举。
  N=0 且 M=0 才是文件真没到或根本没权限读。

- **查看日志** — 今天日志文件的最后 120 行。手机上拿不到 logcat，
  也进不了应用私有目录，这个按钮往往是唯一能看到真实异常的地方。

> 设备 ID 比较做了归一化（忽略连字符与大小写），手工抄写漏个 `-` 不会误判离线。

> **回到前台会自动对账**：手机被系统冻结时定时器不跑，但 Syncthing 是独立进程，
> 照样在后台落盘。所以每次切回 App 都会立刻扫一遍收件箱、刷新列表、重探连接，
> 保证你看到的是"此刻"的真实状态，而不是十分钟前的快照。

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

FTS5 万一不可用（小米 15 / HyperOS 实测系统 SQLite **没编译 FTS5**），
自动降级成 `LIKE` 扫描。这条降级路径不是边缘情况，必须靠谱，所以：

- 按**命中 token 数**打分（不是所有行一律 `score=1` 再按时间倒序——
  那样等于"谁最新谁第一"，一个「的」字就能把整库翻出来）；
- 查询切出 1~2 个 token 时要求**全中**，更多时至少中一半。

### 4. 混合检索用 RRF，不用加权求和

bm25 分数和余弦相似度**量纲完全不同**，直接加权相加需要反复调参，换个数据规模就失衡。
RRF 只看排名：

```
score(d) = Σ 1 / (k + rank_i(d))        k = 60
```

天然免疫量纲问题，也是 Elasticsearch / Vespa 的默认混合方案。
同时命中两条路的会标成「混合」，用户能看出"为什么这条被搜出来"。

### 4.1 语义检索的两级阈值（这是最容易翻车的地方）

BGE 系中文模型的向量空间是**各向异性**的：无关短句之间本来就有 0.2~0.4 的基线，
长句更是能到 0.5。所以：

- **绝对阈值不能凭直觉设**。最早用 0.35（"余弦相似度低于这个就是噪声"的直觉），
  结果「完全不相关的话题比如量子力学」能拿 0.52，10 条记录里 9 条过线，
  用户看到的就是**"搜什么都返回全部"**。
- **查询必须加 BGE 的检索指令前缀**（`AppConfig.embeddingQueryInstruction`）。
  文档不加、查询加，这是 BGE 的非对称检索约定。同一句无关长句加了前缀
  掉到 0.41（一条都过不了），而真正相关的「耳机」仍稳在 0.54。

实测（10 条真实记录，带前缀）：

| 查询 | 最高分 | 说明 |
| --- | --- | --- |
| 耳机 | 0.54 | 三条耳机故障记录 0.54/0.54/0.50，正确 |
| 今天天气怎么样 | 0.35 | 无关短句 |
| 完全不相关的话题比如量子力学 | 0.41 | 无关长句，最容易被带偏的一类 |

`semanticMinScore = 0.45` 正好落在两簇之间；再叠一层
`semanticRelativeMargin = 0.12`（只留与最高分相差 0.12 以内的），
把"最强命中 0.65 时那条 0.49 的陪跑"挡在外面。

> 设置 → 诊断 → **检索自检** 会跑三条探测查询（一条正例、两条负例），
> 把分数和判定直接摊出来。正例不中 = 模型/索引有问题；负例命中 = 阈值要往上调。
> 换模型或记录量级变化后，用这个按钮重新标定，别再靠猜。

### 5. 向量计算全部在 Isolate

`embedding_worker.dart` 是一个常驻 Isolate，**同时持有 ONNX 会话和内存向量索引**。
主线程只发「文本」进去、收「向量/命中列表」出来，一次阻塞调用都没有。
向量不来回搬运——这是把索引留在 worker 内的主要原因。

模型缺失时 `EmbeddingEngine.start()` 返回 false，搜索页自动退化成纯关键词检索，
设置页显示原因。**不崩溃、不白屏、不阻断录音。**

### 6. Whisper 的 `initial_prompt` 不是指令，是"上下文"

这条踩过坑，写下来免得再犯。同一条 48 秒录音（large-v3-turbo / int8）实测：

| 配置 | 转写字数 | 「万圣节」 |
| --- | --- | --- |
| `beam_size=1` + 无提示词（旧默认） | **33** | 温盛节 ✗ |
| `beam_size=5` + 无提示词 | 85 | 温盛节 ✗ |
| `beam_size=5` + 指令式提示词「以下是普通话的句子，请用简体中文转写…」 | **23** | 整段丢掉 |
| `beam_size=5` + 词表式「家庭语音备忘。常提到：万圣节、要糖、…」 | **119** | 万圣节 ✓ |

三个结论：

1. **`beam_size=1`（贪心）会静默丢内容**，48 秒只出 33 个字，而且不报任何错。
   默认已改 5。代价是单文件 3.3s → 11s，后台批处理完全能接受。
2. **提示词必须写成"转写结果"的样子**。写成指令，模型会把指令本身当音频去
   "转写"，内容掉到 23 个字。这是最反直觉的一条。
3. **词表不会污染内容**。给一份完全无关的词表（股票、基金、区块链…）去转写
   同一条录音，122 个字里一个词都没串进来，只是纠正同音字。

#### 但词表装不下词典：硬上限 223 token

faster-whisper 的 `get_prompt()` 里写死了
`previous_tokens[-(448 // 2 - 1):]`——只保留 initial_prompt 的**最后 223 个
token**，超出的部分被静默丢弃（丢的是**前面**的词）。中文一个 3 字词约
4~5 token，223 token 只够 **40~50 个词**。实测一个 5,000 词的词库是 33,598
token，只有末尾 **0.66%** 能进模型。

所以「把词典直接喂给 Whisper」这条路不成立，也不是"提示词写得不够长"的问题：

- Whisper 的 tokenizer 是固定 51,866 词的 byte-level BPE，**任何汉字组合都能
  编码**。「万圣洁」不是词表里没有，而是解码时在同音字里选错了；
- faster-whisper 1.2.1 确实有 `hotwords=` 参数，但源码里它就是
  `tokenizer.encode(" " + hotwords)` 拼进 prompt，没有 logit bias、没有概率
  加权，同样是 223 token 上限（改成保留前 223）。

词表现在按**真实 Whisper tokenizer 计数**（不是拿字符数硬估——163 个字符
实际是 202 token，差一点就撑满），预算 180 token，实测当前提示词只占 48 token。

词表从哪来（v0.2 重写，旧版会串场）：

- **按成员隔离**：只扫 `<author>_Notes/inbox`，别人的词汇不进这条录音；
- **音频笔记 ×3**：粘贴的长文笔记不再主导词表；
- **时间衰减**：30 天半衰，最近的词优先；
- **从转写正文挖专名**：jieba 词性标注抓 nr/ns/nz/nt，比 LLM 给的抽象
  分类标签（"系统测试""社区服务"）靠谱得多；
- **文字笔记只收两类标签**：日常专名表里的词，和纯英文/数字的名字
  （`QCY T20`、`AilyPods`、`Sam`）。中英混排的「手语 AI」「3D打印」几乎都是
  文章主题词，一律不要；
- **手写 + 自动合并**：旧版 `manual or auto` 是二选一，手写了就丢掉全部自动词。

覆盖方式：

```bash
LVS_WHISPER_HOTWORDS="Sam,QCY T20,保险丝"   # 手动词表，与自动词合并（不是覆盖）
LVS_WHISPER_HOTWORDS=off                    # 关掉词表，只用格式前缀
LVS_WHISPER_PROMPT="家庭语音备忘。"          # 改格式前缀
LVS_WHISPER_BEAM_SIZE=1                     # 回退到贪心（更快但会丢内容）
```

当前生效的提示词和 token 占用可以直接看到——`./run.sh --check` 会打印：

```
转写提示词          家庭语音备忘。常提到：万圣节、AilyPods、蓝牙耳机、停车、导航、QCY T20。
                    词表（手写 0 + 自动 12，实际装入 6），48/223 token
本地词库            ✓  156441 个已知词，309 个高置信专名
```

### 7. 转写之后的两层校正：词典管确定性，LLM 管上下文

既然词典进不了提示词，就放到转写**之后**。两层都只对音频生效，
**文字随手记绝不走**——那是用户亲手打的字，还带 Markdown、英文术语、型号。

**第一层：离线词典（`corrector.py`，确定性、零成本、~10ms）**

词库随仓库分发在 `mac_processor/lexicon/`，见 [lexicon/README.md](mac_processor/lexicon/README.md)：

- `thuocl/`：清华大学开放中文词库（**MIT**，Copyright (c) 2018 THUNLP），
  11 类共 11.2 万条、2.6MB，带 DF 词频。选它是因为按生活领域分类
  （饮食 / 汽车 / 地名 / 人名 / 医学 / IT…），比通用大词典更贴近家庭日常记录。
- `custom.txt`：项目自建的 ~170 条日常专名兜底（节日、家庭称谓、生活场所），
  补 THUOCL 没有的分类，例如 `万圣节`。

分工很重要，这是踩过坑才定下来的：

- **全量 15.6 万词只用来判断「这个片段是不是一个已知词」**。词库越大，
  正常口语被误判成生词的概率越低，纠错越安全。
- **只有高置信专名才允许自动替换**：`custom.txt` + 家庭历史词汇 +
  THUOCL 里 DF ≥ 10 万的地名/人名/饮食/汽车词。

早期版本把整个 THUOCL 当替换候选，结果它是**名词词库**、不收「显示」这类
常用动词，把「显示左右的待办事项」改成了「显式左右」，「设置里」被切成
「置里 → 治理」。改错比不改更伤，所以现在收敛成上面两条。

规则：只处理 2~5 个纯汉字、不在词库里的片段；只接受等长、拼音完全相同
（无声调，自动覆盖同音不同调）的候选；同音候选分数接近时直接放弃；
一条转写最多改 4 处；每处都写进 JSON 的 `corrections`，可审计、可回退。

**第二层：本地 Ollama（`extractor.correct_transcript`，~8s）**

词典改不了「听到棉花糖家 → 停到棉花糖家」这种要看上下文的错。这一层把
转写 + 家庭专名 + 词库检索出的**高置信同音/近音候选**一起交给 LLM。

安全护栏是硬的：长度比必须在 0.9~1.1、相似度 ≥ 0.85、改动字符 ≤ 15%，
任何一项越界就**整体退回原文**。LLM 校正最大的风险不是改错一个字，
而是顺手"润色"甚至补内容，所以宁可整条不采纳。

开关：`LVS_LEXICON_CORRECT=0` / `LVS_LLM_CORRECT=0`。

真实效果（`memo_20261031_212159`，48 秒停车场录音）：

| 阶段 | 文本 |
| --- | --- |
| Whisper 原始 | `Hello。万圣洁。…近可能往里走…听到棉花糖家,不计。` |
| 词典层 | `万圣洁 → 万圣节` |
| LLM 层 | `近可能 → 尽可能`、`听到棉花糖家 → 停到棉花糖家` |

第二次重跑时，因为「万圣节」已经进了词表，**Whisper 自己就转对了**，
词典层都不用出手。这就是自动词表和纠错层互相喂养的闭环。

调完参数想重跑某条旧录音（默认会按内容哈希跳过）：

```bash
./run.sh --file ~/LocalVoiceSync/Me_Notes/outbox/memo_20261031_212159.m4a --force
```

### 8. 标签体系：新标签先查已有，能归类就归类

提炼模型每次只看见**一条**笔记，不知道知识库里已经有哪些标签，于是
「ASL手语 / 手语 AI / 无障碍数据集」「系统测试 / 版本测试 / 测试」
「QCY / QCY T20」会不断增殖——十几篇笔记长出 30 个标签，标签云就废了。
同类笔记必须用同一个标签名，所以标签不能由 LLM 每条自由发挥。

**日常防增量**（`tag_registry.py` + `extractor.py`）：

1. 从所有成员的 `*/inbox/*.json` 汇总现有标签词表（带频次、时间），45 秒
   TTL；每写完一条笔记立刻失效，下一篇马上能看到刚出现的新标签。
2. 提炼时把词表前 40 个塞进提示词，明确要求「**直接照抄已有标签原文**、
   严禁造同义变体、整篇最多新建 1 个」。
3. 代码再做一次确定性兜底，即使模型没听话也不会漏：全角/空格/大小写归一后
   精确匹配 → 包含关系（`QCY` ⊂ `QCY T20`）→ 共享非泛化词根
   （`ASL手语` / `手语 AI` → `手语`）→ 剩下的才允许新建，且受
   `LVS_TAG_MAX_NEW` 限制（冷启动词表 <6 个时自动放宽到 3 个）。
4. 被合并或被限额砍掉的写法**不丢**：补进 `aliases`。手机的 `searchableText`
   包含 aliases，按旧词照样搜得到，Whisper 热词也照样认得。

**一次性清理**（`tag_cleanup.py`）：

```bash
./run.sh --normalize-tags             # 只预览分组和逐篇改动，不写文件
./run.sh --normalize-tags --apply     # 备份后原子写回 JSON + Markdown
./run.sh --normalize-tags --no-llm    # Ollama 没起时只跑确定性规则
```

LLM 只负责**提建议**，代码逐字段校验：组成员必须是真实存在的标签、组内
每一对都得有词汇证据、规范名必须是成员原文或成员里真实出现的片段。
所以它提的「停车 + 导航 + 出行准备 → 出行」会被整组拒绝；而它漏掉的
「ASL手语 / 手语 AI」由确定性词根规则照样并成「手语」。规范名优先用
已经反复出现的老名字（`系统测试` 而不是简化成 `测试`）。

写回前备份到 `~/.localvoicesync/tag-backups/<时间戳>/`，笔记里留
`original_tags` 便于追溯和回退，`aliases` 补上旧标签名，向量按新标签重算。
手机端 `ingest_log` 按 `文件大小 + mtime` 判重，文件一变就会重新入库，
**不用重装 APK**。

真实数据跑完：32 个标签 → 26 个；两条手语笔记现在都带 `手语`、`无障碍`。
`./run.sh --check` 会打印当前词表规模。开关：`LVS_TAG_MERGE=0`（回到旧行为）、
`LVS_TAG_MAX_NEW=2`。

### 9. 待办状态：每台设备只写自己的那份文件

「待办」页要汇总**所有笔记**里的 `todos`，还要能脱离笔记手工新建，
并且勾选状态得让 Mac 和别的手机看见。这里没有动 JSON 契约，也不需要数据库迁移：

- **笔记待办本来就在契约里**：Mac 端 `extractor.py` 提炼、`writer.py` 写进
  `inbox/<id>.json` 的 `todos[]`，手机入库后存在 `memos.todos`，
  详情页的 `TodoList` 早就能勾。缺的只是「汇总」和「把勾同步出去」。
- **不改 `inbox/*.json`**：那些是 Mac 单向产出的只增文件。让手机去回写，
  等于和 Mac 抢同一个文件的写权，重跑一次提炼就把勾选冲掉了。
- **不建一张共享 `todos.json`**：两台手机同时勾，Syncthing 会生成
  `.sync-conflict-*`，用户得手工挑哪份对。

所以改成**每台设备一个写者**：

```
<同步根>/todos/<deviceId>.json     ← 该手机写且只写这一份
```

所有设备（含 Mac）读**全部**状态文件，按 `updated_at` 做 last-write-wins 合并；
`.sync-conflict-*` 和 `.part` 直接跳过，坏 JSON 跳过而不是让整页崩掉。
文件按 `AtomicIo` 的 `.part → rename` 写，避免读到半截内容。

```json
{
  "device_id": "phone-A",
  "updated_at": 1731052800000,
  "states": {
    "note:memo_20261031_123000:买两个 50a class t 保险丝": {
      "completed": true, "updated_at": 1731052800000,
      "memo_id": "memo_20261031_123000", "index": 0
    }
  },
  "manual": {
    "<uuid>": {"id": "<uuid>", "task": "给绿萝浇水", "completed": false,
               "updated_at": 1731052800000, "deleted": false}
  }
}
```

稳定 key 是 `note:<memoId>:<normalizeTask(task)>`——任务文本去空白、折叠空格、
转小写。Mac 重跑提炼可能把任务措辞改了，所以还带 `memo_id + index` 兜底，
按时间戳取最近的一条，勾选不会凭空复活。手工待办的删除用**墓碑**
（`deleted: true`）而不是物理删行，否则另一台设备的旧文件会把它"复活"。
时间戳单调递增（本机时钟回拨时用 `merged.updated_at + 1`），保证刚点的那一下
一定赢过文件里已有的记录。

App 侧 `TodoService` 用串行队列把所有写操作排队，先写本机 SQLite（秒开、
断网也能用），再写共享状态文件；文件写失败只记日志、不回滚本地状态。
冷启动、回到前台、从详情页返回、下拉刷新都会做一次**对账**：把别的设备
同步过来的勾选覆盖回本机 DB，同时把本机历史上的老勾选补种进状态文件。

> 状态文件变化不会产生新的 `inbox/*.json`，收件箱监听感知不到，
> 所以「待办」页另有一个 12 秒轮询（`AppConfig.todoStatePollInterval`）。
> 这是刻意的：宁可多读几个小 JSON，也不能让别的手机勾完这边一直不刷新。

Mac 端是**只读**的：`todo_state.py` 按同样的 key 规则合并状态，
`./run.sh --todos` 打印未完成 / 已完成总览，`./run.sh --check` 多一行
「待办状态 ✓ N 个设备文件 / N 条勾选 / N 条手工待办」。Mac 从不写
`todos/`，避免引入第三个写者。

`./run.sh --todos` 实测（还没手机写过状态文件时）：

```
未完成 7 条
  [ ] 维修 QCY T20 (AilyPods) 左耳故障  ← memo_20261031_155749
  [ ] 前往棉花糖家                       ← memo_20261031_212159
已完成 0 条
```

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
  "corrections": [
    {"from": "万圣洁", "to": "万圣节", "source": "custom"},
    {"from": "听", "to": "停", "source": "llm"}
  ],
  "original_transcript": "今天检查了太阳能板的配线……（Whisper 原始输出，只在改过时才出现）",
  "original_tags": ["太阳能板", "配线", "PowMr"],
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
    "llm_model": "qwen3.5:9b-q4_K_M",
    "correction_count": 2
  }
}
```

**`raw_transcript` 是校正后的最终文本**，手机端一直读这个字段，所以不用重装
APK 就能看到纠错效果。原始 ASR 输出另存 `original_transcript`（只有真的改过
才写，避免每条记录多一份全文副本），改动明细在 `corrections` 里，`source`
取值 `personal` / `custom` / `lexicon` / `llm`。两者都是新增字段，旧客户端
会直接忽略。

`tags` 一律取自现有标签词表（见第三节第 8 条），被合并掉的旧写法补进
`aliases`；执行过标签整理的笔记额外带 `original_tags`，记录整理前的标签，
便于回退。这些都是客户端会忽略的附加字段。

同时写一份人类可读的 `<id>.md`。失败时写 `<id>.error.json`，手机端把记录标成「失败」。

**手机端的三个宽容处理**：

1. `device_id` 不由 Mac 写（Mac 不知道，也不该编造），手机保留自己的原值；
2. `embedding_model` 与本地不一致时**丢弃回传向量、本机重算**——
   跨模型比对毫无意义，宁可多算一次也不能悄悄搜错；
3. 重新同步时按任务文本对齐合并 TODO，**保留用户已勾选的状态**；
   真正跨设备的勾选状态不写回这份契约，而是走 `todos/<deviceId>.json`
   （见第三节第 9 条）。也就是说 `todos[].status` 始终是 Mac 提炼时的初值，
   用户后来勾没勾以状态文件为准——手机和 Mac 都按这个顺序覆盖。

Mac 端若 Ollama 挂了，会进入**降级模式**：只回传原始转写 + 截断摘要，
`processing.degraded = true`。用户至少不会丢内容。

---

## 五、CI / 出包

`.github/workflows/build_all.yml`，**只有手动触发**（Actions → build_all → Run workflow）：

| Job | Runner | 产物 | 签名 |
| --- | --- | --- | --- |
| `quality` | ubuntu | — | 跑 `flutter analyze` + `flutter test`，其余 job 的前置 |
| `android` | ubuntu | `LocalVoiceSync-*.apk` | debug keystore，**可直接安装** |
| `ios` | macos-14 | `LocalVoiceSync-*-unsigned.ipa` | 未签名，需 Sideloadly / AltStore 自签 |
| `macos` | macos-14 | `LocalVoiceSync-*-macos.zip` | 未签名，首次打开需右键「打开」 |

产物在 Actions 页面 Artifacts 区下载，保留 30 天。

> **为什么不再 push 自动触发**：Android 在本地出包更快（几十秒），push 就排队
> 既占额度又拖慢反馈。iOS 必须用 macOS runner（本地不装 Xcode），到时候在网页上
> 点一次 Run workflow 并选 `all` 即可，IPA 与 macOS APP 一起产出。
> 想彻底关掉：仓库 → Actions → 左侧 build_all → "···" → Disable workflow。

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

- **待办勾选按设备时钟做 last-write-wins**，不是 CRDT。两台手机时钟差得离谱、
  又在同一秒勾同一条时，以时间戳大的为准；日常使用不会遇到，但没有冲突提示 UI。
- **iOS 无法后台常驻 Syncthing**，需第三方 App 配合。
- **删除记录不删音频**，音频留在 `outbox/` 作为原始素材。
- **语义检索阈值是按 10 条记录标定的**（`semanticMinScore = 0.45`）。记录上千条后
  建议用「设置 → 诊断 → 检索自检」重新看一眼分布，别再靠猜。
- Mac 端最多 2 个 Whisper 实例，极端批量会排队；Ollama 自身串行处理请求，
  真正的瓶颈通常是 9B 模型的生成速度。
- **LLM 二次校正给每条音频多花约 8 秒**（qwen3.5:9b / M4 实测）。嫌慢就
  `LVS_LLM_CORRECT=0`，词典层仍然生效（它只要 10ms）。

---

## 八、开发命令

```bash
flutter analyze                     # 静态检查（当前 0 issue）
flutter test                        # 71 个单测

# 没有 Xcode / Android SDK 时，用它做真正的 Dart 编译验证（含资产打包）：
flutter build bundle --target-platform=darwin
flutter build apk --release
flutter build ios --release --no-codesign
flutter build macos --release

cd mac_processor
./run.sh --check                    # 环境自检（含提示词 token 占用、词库、待办状态）
./run.sh --todos                    # 所有笔记待办 + 手机勾选状态总览（只读）
./run.sh --once                     # 处理完积压就退出（适合 cron）
./run.sh --file path/to/memo.m4a    # 单文件调试
./run.sh --file path/to/memo.m4a --force   # 忽略去重，强制重跑
./run.sh --dry-run                  # 只处理不写文件
./run.sh --normalize-tags           # 预览已有标签的合并方案（不写文件）
./run.sh --normalize-tags --apply   # 备份后写回，统一标签名

# Python 单测（词表预算 / 词典纠错 / LLM 护栏 / 标签归并 / 待办状态，共 75 条）
.venv/bin/python -m unittest discover -s tests -t . -v

# 本地出升级包：versionCode 必须大于手机上已装的（见 1.6）
flutter build apk --release --split-per-abi --build-number 10
```

> 若本机配了 HTTP 代理，`flutter test` 会因为 localhost WebSocket 被代理劫持而失败，
> 需要 `NO_PROXY=127.0.0.1,localhost flutter test`。
