"""音频解码。

为什么要自己解码，而不是直接把文件路径丢给 faster-whisper：

faster-whisper 1.2.x 内部调用 `av.open(path, metadata_errors="ignore")`，
而 PyAV 19 已经删掉了这个关键字参数，于是直接抛
`TypeError: open() got an unexpected keyword argument 'metadata_errors'`。
降级 PyAV 也不行——`av<15` 在 Python 3.12 / macOS arm64 上没有预编译轮子，
只能源码编译（要 pkg-config + ffmpeg 开发库）。

而 faster-whisper 的 `transcribe()` 接受 **numpy 数组**，走这条路就完全绕开了
它内部那段解码逻辑，且对 PyAV 版本不再敏感。顺带的好处是：
解码只做一次，`BatchedInferencePipeline` 内部不会重复解码。
"""

from __future__ import annotations

import logging
from pathlib import Path

import numpy as np

LOGGER = logging.getLogger("lvs.audio")

TARGET_SAMPLE_RATE = 16000


class AudioDecodeError(RuntimeError):
    """音频无法解码。"""


def decode_audio(path: Path, sample_rate: int = TARGET_SAMPLE_RATE) -> np.ndarray | None:
    """把任意容器格式解成 16kHz 单声道 float32。

    返回 None 表示 PyAV 不可用，此时让 faster-whisper 自己去解码（可能失败，
    但那是它自己的错误路径，日志更直观）。
    """
    try:
        import av
    except ImportError:
        LOGGER.warning("PyAV 不可用，交给 faster-whisper 自行解码")
        return None

    try:
        with av.open(str(path)) as container:
            if not container.streams.audio:
                raise AudioDecodeError(f"{path.name} 里没有音频流")

            stream = container.streams.audio[0]
            resampler = av.AudioResampler(
                format="flt", layout="mono", rate=sample_rate
            )

            chunks: list[np.ndarray] = []

            def _collect(frames) -> None:
                if not frames:
                    return
                if not isinstance(frames, (list, tuple)):
                    frames = [frames]
                for frame in frames:
                    if frame is None:
                        continue
                    chunks.append(np.asarray(frame.to_ndarray()).reshape(-1))

            for frame in container.decode(stream):
                _collect(resampler.resample(frame))
            # 冲刷重采样器里残留的样本
            _collect(resampler.resample(None))

    except AudioDecodeError:
        raise
    except Exception as error:  # noqa: BLE001 - PyAV 的错误类型跨版本不一致
        raise AudioDecodeError(f"解码 {path.name} 失败：{error}") from error

    if not chunks:
        raise AudioDecodeError(f"{path.name} 解码后没有任何采样")

    audio = np.concatenate(chunks).astype(np.float32, copy=False)
    if audio.size == 0:
        raise AudioDecodeError(f"{path.name} 解码后长度为 0")
    return audio


def duration_seconds(audio: np.ndarray | None, sample_rate: int = TARGET_SAMPLE_RATE) -> float:
    if audio is None or audio.size == 0:
        return 0.0
    return float(audio.size) / float(sample_rate)
