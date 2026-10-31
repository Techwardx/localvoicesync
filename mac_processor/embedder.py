"""向量化。

必须和手机端用**同一个模型**（`bge-small-zh-v1.5`，512 维），
否则 Mac 算出来的向量和手机查询向量不在同一个空间，余弦相似度毫无意义。
模型 id 会写进 JSON 的 `embedding_model` 字段，手机端会做一致性校验，
不一致就丢弃回传向量、改由本机重算——宁可多算一次，也不能悄悄搜错。

这里用 fastembed（onnxruntime + tokenizers，不依赖 PyTorch），
在 M4 上冷启动约 1 秒，单条文本 10ms 以内。
"""

from __future__ import annotations

import logging
import math
import threading
from typing import Any

from config import Config

LOGGER = logging.getLogger("lvs.embed")


class Embedder:
    def __init__(self, cfg: Config) -> None:
        self._cfg = cfg
        self._model: Any = None
        self._lock = threading.Lock()
        self._failed = False

    def _ensure(self) -> Any:
        if self._model is not None or self._failed:
            return self._model
        with self._lock:
            if self._model is not None or self._failed:
                return self._model
            try:
                from fastembed import TextEmbedding

                LOGGER.info("加载向量模型 %s …", self._cfg.embed_model)
                self._model = TextEmbedding(
                    model_name=self._cfg.embed_model,
                    cache_dir=str(self._cfg.cache_dir / "fastembed"),
                )
                LOGGER.info("向量模型已就绪")
            except Exception as error:  # noqa: BLE001 - 任何失败都降级
                self._failed = True
                LOGGER.warning("向量模型不可用，将不返回 embedding：%s", error)
            return self._model

    def embed(self, text: str) -> list[float] | None:
        """返回 L2 归一化后的向量；不可用时返回 None（手机端会自己补算）。"""
        if not text.strip():
            return None
        model = self._ensure()
        if model is None:
            return None
        try:
            vectors = list(model.embed([text]))
        except Exception as error:  # noqa: BLE001
            LOGGER.warning("向量化失败：%s", error)
            return None
        if not vectors:
            return None
        raw = [float(value) for value in vectors[0]]
        if len(raw) != self._cfg.embed_dim:
            LOGGER.warning(
                "向量维度不符（期望 %d，实际 %d），丢弃",
                self._cfg.embed_dim,
                len(raw),
            )
            return None
        return _l2_normalize(raw)

    @property
    def model_id(self) -> str:
        """与手机端约定的模型标识。"""
        return "bge-small-zh-v1.5"


def _l2_normalize(vector: list[float]) -> list[float]:
    norm = math.sqrt(sum(value * value for value in vector))
    if norm <= 0:
        return vector
    return [value / norm for value in vector]
