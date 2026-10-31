"""结果落盘。

同步目录里"写一半"是致命问题：Syncthing 只认文件系统事件，它不知道你还没写完，
于是手机可能收到一个截断的 JSON，解析失败后那条记录就永远停在"待处理"。

所以所有写入都走 `write_atomic`：先写 `.part`，fsync，再 `os.replace`。
`os.replace` 在同一文件系统内是原子操作，Syncthing 只会看到完整文件。
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any


def write_atomic(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".part")
    with tmp.open("w", encoding="utf-8") as handle:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)


def render_markdown(payload: dict[str, Any]) -> str:
    """生成人类可读的 Markdown，方便家人直接翻同步目录看。"""
    lines: list[str] = []
    title = payload.get("summary") or "未命名记录"
    lines.append(f"# {title}")
    lines.append("")
    meta = [
        f"**作者** {payload.get('author', '')}",
        f"**时间** {payload.get('created_at', '')}",
    ]
    if payload.get("audio_filename"):
        meta.append(f"**音频** `{payload['audio_filename']}`")
    lines.append("  \n".join(meta))
    lines.append("")

    tags = payload.get("tags") or []
    if tags:
        lines.append(" ".join(f"`{tag}`" for tag in tags))
        lines.append("")

    points = payload.get("knowledge_points") or []
    if points:
        lines.append("## 知识点")
        lines.append("")
        for point in points:
            lines.append(f"- {point}")
        lines.append("")

    todos = payload.get("todos") or []
    if todos:
        lines.append("## 待办")
        lines.append("")
        for todo in todos:
            mark = "x" if todo.get("status") == "completed" else " "
            lines.append(f"- [{mark}] {todo.get('task', '')}")
        lines.append("")

    transcript = (payload.get("raw_transcript") or "").strip()
    if transcript:
        lines.append("## 原始转写")
        lines.append("")
        lines.append(transcript)
        lines.append("")

    lines.append("---")
    lines.append(
        f"`{payload.get('id', '')}` · schema v{payload.get('schema_version', 1)}"
    )
    lines.append("")
    return "\n".join(lines)


def write_result(inbox_dir: Path, memo_id: str, payload: dict[str, Any]) -> None:
    body = json.dumps(payload, ensure_ascii=False, indent=2)
    write_atomic(inbox_dir / f"{memo_id}.json", body + "\n")
    write_atomic(inbox_dir / f"{memo_id}.md", render_markdown(payload))


def write_error(inbox_dir: Path, memo_id: str, message: str, detail: str = "") -> None:
    payload = {
        "id": memo_id,
        "error": message,
        "detail": detail[:2000],
    }
    write_atomic(
        inbox_dir / f"{memo_id}.error.json",
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
    )
