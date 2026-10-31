"""LocalVoiceSync —— Mac Mini M4 处理流水线配置。

所有可调项都能用环境变量覆盖，方便在不同机器/不同负载下微调，
而不用改代码。默认值是按 M4（10 核 CPU / 16GB+ 统一内存）调的。
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

try:  # python-dotenv 是可选依赖，缺了也能跑
    from dotenv import load_dotenv

    load_dotenv(Path(__file__).resolve().parent / ".env")
except Exception:  # pragma: no cover - 仅用于容错
    pass


def _env_str(key: str, default: str) -> str:
    value = os.environ.get(key)
    return default if value is None or value.strip() == "" else value.strip()


def _env_int(key: str, default: int) -> int:
    try:
        return int(_env_str(key, str(default)))
    except ValueError:
        return default


def _env_float(key: str, default: float) -> float:
    try:
        return float(_env_str(key, str(default)))
    except ValueError:
        return default


def _env_bool(key: str, default: bool) -> bool:
    return _env_str(key, "1" if default else "0").lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Config:
    """一次运行所需的全部配置。"""

    # ---------------------------------------------------------------- 目录
    sync_root: Path
    """Syncthing 同步根目录，下面按 <成员>_Notes/{outbox,inbox} 组织。"""

    state_db: Path
    """去重状态库，记录"哪个文件、哪份内容已经处理过"。"""

    cache_dir: Path
    """模型缓存目录（Whisper / fastembed 都会往这里写）。"""

    # ---------------------------------------------------------------- 转写
    whisper_model: str
    whisper_compute: str
    whisper_threads: int
    whisper_workers: int
    whisper_batch_size: int
    whisper_language: str
    whisper_beam_size: int

    # ---------------------------------------------------------------- 提炼
    ollama_url: str
    ollama_model: str
    ollama_timeout: float
    ollama_num_ctx: int

    # ---------------------------------------------------------------- 向量
    embed_model: str
    embed_dim: int

    # ---------------------------------------------------------------- 调度
    concurrency: int
    stability_seconds: float
    stability_timeout: float
    log_level: str
    dry_run: bool

    @classmethod
    def load(cls, sync_root: str | None = None) -> "Config":
        root = Path(
            sync_root
            or _env_str("LVS_SYNC_ROOT", str(Path.home() / "LocalVoiceSync"))
        ).expanduser()

        default_state = Path.home() / ".localvoicesync" / "state.db"
        state = Path(_env_str("LVS_STATE_DB", str(default_state))).expanduser()
        cache = Path(
            _env_str("LVS_CACHE_DIR", str(Path.home() / ".cache" / "localvoicesync"))
        ).expanduser()

        return cls(
            sync_root=root,
            state_db=state,
            cache_dir=cache,
            # large-v3-turbo：turbo 版在中文上几乎不掉点，速度却快 4~5 倍，
            # 是本地批量转写的性价比最优解。
            whisper_model=_env_str("LVS_WHISPER_MODEL", "large-v3-turbo"),
            # CTranslate2 在 Apple Silicon 上走 CPU + Accelerate；
            # int8 量化后模型约 800MB，速度翻倍且精度损失可忽略。
            whisper_compute=_env_str("LVS_WHISPER_COMPUTE", "int8"),
            whisper_threads=_env_int("LVS_WHISPER_THREADS", 8),
            # 两个转写实例 ≈ 1.6GB 内存，换来真正的文件级并行。
            whisper_workers=_env_int("LVS_WHISPER_WORKERS", 2),
            # 单个文件内部的批处理大小：BatchedInferencePipeline 用。
            whisper_batch_size=_env_int("LVS_WHISPER_BATCH_SIZE", 8),
            # 留空 = 自动检测语种；固定 "zh" 可以避免中英混说时来回切换。
            whisper_language=_env_str("LVS_WHISPER_LANGUAGE", ""),
            whisper_beam_size=_env_int("LVS_WHISPER_BEAM_SIZE", 1),
            ollama_url=_env_str("LVS_OLLAMA_URL", "http://127.0.0.1:11434").rstrip("/"),
            ollama_model=_env_str("LVS_OLLAMA_MODEL", "qwen3.5:9b-q4_K_M"),
            ollama_timeout=_env_float("LVS_OLLAMA_TIMEOUT", 300.0),
            ollama_num_ctx=_env_int("LVS_OLLAMA_NUM_CTX", 8192),
            # 必须和手机端 AppConfig.embeddingModelId 完全一致，
            # 否则两边算出来的向量不在同一个空间，语义检索会失效。
            embed_model=_env_str("LVS_EMBED_MODEL", "BAAI/bge-small-zh-v1.5"),
            embed_dim=_env_int("LVS_EMBED_DIM", 512),
            concurrency=_env_int("LVS_CONCURRENCY", 3),
            stability_seconds=_env_float("LVS_STABILITY_SECONDS", 1.5),
            stability_timeout=_env_float("LVS_STABILITY_TIMEOUT", 60.0),
            log_level=_env_str("LVS_LOG_LEVEL", "INFO").upper(),
            dry_run=_env_bool("LVS_DRY_RUN", False),
        )

    def describe(self) -> str:
        return (
            f"同步根目录   {self.sync_root}\n"
            f"状态库       {self.state_db}\n"
            f"缓存目录     {self.cache_dir}\n"
            f"Whisper      {self.whisper_model} / {self.whisper_compute} / "
            f"{self.whisper_workers} 实例 × {self.whisper_threads} 线程\n"
            f"提炼模型     {self.ollama_model} @ {self.ollama_url}\n"
            f"向量模型     {self.embed_model} ({self.embed_dim} 维)\n"
            f"并发度       {self.concurrency}\n"
            f"试运行       {self.dry_run}"
        )
