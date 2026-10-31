"""处理状态库：保证同一份文件不会因为 Syncthing 抖动被重复转写。

为什么按内容 sha256 去重而不是按文件名：
Syncthing 在冲突时会生成 `xxx.sync-conflict-20261031-123000-ABCDEF.m4a`，
文件名变了但内容没变；反过来，用户也可能覆盖同名文件但内容不同。
只有内容哈希能同时处理这两种情况。
"""

from __future__ import annotations

import hashlib
import sqlite3
import threading
import time
from pathlib import Path

_SCHEMA = """
CREATE TABLE IF NOT EXISTS processed (
    source     TEXT NOT NULL,
    sha256     TEXT NOT NULL,
    status     TEXT NOT NULL,
    note       TEXT NOT NULL DEFAULT '',
    updated_at REAL NOT NULL,
    PRIMARY KEY (source, sha256)
);
CREATE INDEX IF NOT EXISTS idx_processed_sha ON processed(sha256);
"""


def sha256_of(path: Path, chunk_size: int = 1 << 20) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(chunk_size)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


class StateStore:
    """线程安全的去重状态库。"""

    def __init__(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._conn = sqlite3.connect(str(path), check_same_thread=False)
        self._conn.executescript(_SCHEMA)
        self._conn.commit()

    def already_done(self, source: str, sha: str) -> bool:
        with self._lock:
            row = self._conn.execute(
                "SELECT status FROM processed WHERE source = ? AND sha256 = ?",
                (source, sha),
            ).fetchone()
        # 只有成功过的才跳过；失败过的允许重试（模型/服务可能已经修好了）
        return row is not None and row[0] == "ok"

    def mark(self, source: str, sha: str, status: str, note: str = "") -> None:
        with self._lock:
            self._conn.execute(
                """
                INSERT INTO processed (source, sha256, status, note, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(source, sha256) DO UPDATE SET
                    status = excluded.status,
                    note = excluded.note,
                    updated_at = excluded.updated_at
                """,
                (source, sha, status, note[:500], time.time()),
            )
            self._conn.commit()

    def stats(self) -> dict[str, int]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT status, COUNT(*) FROM processed GROUP BY status"
            ).fetchall()
        return {status: count for status, count in rows}

    def close(self) -> None:
        with self._lock:
            self._conn.close()
