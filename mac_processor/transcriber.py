"""Whisper 转写池。

设计取舍说明：

1. **为什么用池而不是单实例 + 全局锁**
   faster-whisper 底层是 CTranslate2，同一个模型实例被多线程同时调用并不安全，
   加一把大锁虽然安全但把并行度锁死了。这里改成"最多 N 个实例、每个实例同一
   时刻只服务一个线程"，用信号量约束并发数，既能真并行又不越界。
   两个 int8 的 large-v3-turbo 大约占 1.6GB 统一内存，M4 完全吃得下。

2. **为什么用 BatchedInferencePipeline**
   它把 VAD 切出来的多个语音片段打包成 batch 一起送进编码器，
   在 M4 上单文件吞吐通常能提升 1.5~2.5 倍，且不改变识别结果。

3. **解码参数**
   `beam_size=1`（贪心）+ `condition_on_previous_text=False`：
   语音备忘是短句、口语、可能中途换话题，条件解码容易把上一句的幻觉带进下一句。
"""

from __future__ import annotations

import contextlib
import logging
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

from audio_utils import decode_audio, duration_seconds
from config import Config

LOGGER = logging.getLogger("lvs.transcribe")


@dataclass
class Transcript:
    text: str
    language: str
    language_probability: float
    duration: float
    segment_count: int


class WhisperPool:
    def __init__(self, cfg: Config) -> None:
        self._cfg = cfg
        self._lock = threading.Lock()
        self._idle: list[tuple[object, object]] = []
        self._semaphore = threading.BoundedSemaphore(max(1, cfg.whisper_workers))
        self._created = 0

    # ------------------------------------------------------------- 生命周期

    def _create(self) -> tuple[object, object]:
        # 延迟导入：没装 faster-whisper 时，纯文本流水线仍然能跑
        from faster_whisper import BatchedInferencePipeline, WhisperModel

        LOGGER.info(
            "加载 Whisper 模型 %s（%s，%s 线程）…",
            self._cfg.whisper_model,
            self._cfg.whisper_compute,
            self._cfg.whisper_threads,
        )
        model = WhisperModel(
            self._cfg.whisper_model,
            device="cpu",
            compute_type=self._cfg.whisper_compute,
            cpu_threads=self._cfg.whisper_threads,
            download_root=str(self._cfg.cache_dir / "whisper"),
        )
        pipeline = BatchedInferencePipeline(model=model)
        with self._lock:
            self._created += 1
        LOGGER.info("Whisper 实例已就绪（当前共 %d 个）", self._created)
        return model, pipeline

    @contextlib.contextmanager
    def _borrow(self) -> Iterator[object]:
        self._semaphore.acquire()
        pipeline = None
        try:
            with self._lock:
                if self._idle:
                    _model, pipeline = self._idle.pop()
            if pipeline is None:
                _model, pipeline = self._create()
            yield pipeline
        finally:
            if pipeline is not None:
                with self._lock:
                    self._idle.append((_model, pipeline))
            self._semaphore.release()

    # ------------------------------------------------------------- 转写

    def transcribe(self, audio_path: Path) -> Transcript:
        # 自己解码成 numpy 再送进去：绕开 faster-whisper 内部与 PyAV 19 的
        # `metadata_errors` 参数不兼容问题（详见 audio_utils.py 的说明）。
        audio = decode_audio(audio_path)

        with self._borrow() as pipeline:
            segments, info = pipeline.transcribe(  # type: ignore[attr-defined]
                audio if audio is not None else str(audio_path),
                language=self._cfg.whisper_language or None,
                beam_size=self._cfg.whisper_beam_size,
                batch_size=self._cfg.whisper_batch_size,
                vad_filter=True,
                vad_parameters={"min_silence_duration_ms": 500},
                condition_on_previous_text=False,
            )
            pieces: list[str] = []
            count = 0
            for segment in segments:
                text = segment.text.strip()
                if text:
                    pieces.append(text)
                count += 1

        # 中文不需要空格分词，直接拼接；英文段落之间补一个空格。
        joined = "".join(pieces) if _looks_cjk(pieces) else " ".join(pieces)
        return Transcript(
            text=joined.strip(),
            language=getattr(info, "language", "") or "",
            language_probability=float(getattr(info, "language_probability", 0.0) or 0.0),
            duration=float(getattr(info, "duration", 0.0) or 0.0)
            or (duration_seconds(audio) if audio is not None else 0.0),
            segment_count=count,
        )


def _looks_cjk(pieces: list[str]) -> bool:
    """判断这批文本是不是以中文为主，决定拼接时要不要加空格。"""
    if not pieces:
        return False
    sample = "".join(pieces)[:200]
    cjk = sum(1 for ch in sample if "\u4e00" <= ch <= "\u9fff")
    return cjk > len(sample) * 0.2
