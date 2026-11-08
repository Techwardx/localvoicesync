"""读取手机端同步过来的待办完成状态。

Mac 在这个体系里是**只读方**：

* 笔记里的待办由 `extractor.py` 提炼、写进 `*/inbox/*.json` 的 `todos`；
* 勾选状态和手工新增的待办由每台手机各写一份
  `<同步根>/todos/<deviceId>.json`，Mac 一个字节都不往里写。

为什么坚持「一设备一文件、Mac 只读」：Syncthing 没有行级合并，
两个写入者改同一个 JSON 只会留一份再生成 `*.sync-conflict-*`，
家里人还得手工挑。单写者文件天然没有这个冲突。

合并规则是 last-write-wins：同一条记录取 `updated_at` 最大的那份。
删除手工待办写的是墓碑（`deleted: true`），不是真删，所以旧设备上的
副本不会把它「复活」。

⚠️ `note_key()` 必须跟 Dart `TodoKeys.forNote()` 逐字一致，
否则手机上勾掉的待办在 Mac 总览里会变回未完成。
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

from tag_registry import iter_notes

TODO_DIR_NAME = "todos"
SCHEMA_VERSION = 1


def normalize_task(task: str) -> str:
    """与 Dart `TodoKeys.normalizeTask` 等价：去首尾空白、合并连续空白、小写。"""
    return re.sub(r"\s+", " ", str(task).strip()).lower()


def note_key(memo_id: str, task: str) -> str:
    return f"note:{memo_id}:{normalize_task(task)}"


def _as_int(value: Any) -> int:
    if isinstance(value, bool):
        return 0
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return 0


def _as_bool(value: Any) -> bool:
    return value is True or str(value).strip().lower() == "true"


@dataclass(frozen=True)
class Completion:
    completed: bool
    updated_at: int
    memo_id: str = ""
    index: int = -1


@dataclass(frozen=True)
class ManualTodo:
    id: str
    task: str
    completed: bool
    created_at: int
    updated_at: int
    author: str = ""
    device_id: str = ""
    deleted: bool = False


@dataclass
class TodoState:
    """所有设备状态文件合并后的视图。"""

    states: dict[str, Completion] = field(default_factory=dict)
    manual: dict[str, ManualTodo] = field(default_factory=dict)
    files: list[str] = field(default_factory=list)

    @property
    def active_manual(self) -> list[ManualTodo]:
        return [item for item in self.manual.values() if not item.deleted]

    def completion_for(self, memo_id: str, task: str, index: int) -> Completion | None:
        """先按稳定 key 精确命中；文本被改过则退回同笔记 + 原下标。"""
        exact = self.states.get(note_key(memo_id, task))
        if exact is not None:
            return exact
        candidates = [
            state
            for state in self.states.values()
            if state.memo_id == memo_id and state.index == index
        ]
        if not candidates:
            return None
        return max(candidates, key=lambda state: state.updated_at)


def _parse_doc(raw: Any, fallback_device: str = "") -> tuple[dict[str, Completion], dict[str, ManualTodo]]:
    if not isinstance(raw, dict):
        return {}, {}
    states: dict[str, Completion] = {}
    raw_states = raw.get("states")
    if isinstance(raw_states, dict):
        items: Iterable[tuple[Any, Any]] = raw_states.items()
    elif isinstance(raw_states, list):
        items = ((item.get("key", ""), item) for item in raw_states if isinstance(item, dict))
    else:
        items = ()
    for key, value in items:
        if not isinstance(value, dict) or not str(key):
            continue
        states[str(key)] = Completion(
            completed=_as_bool(value.get("completed")),
            updated_at=_as_int(value.get("updated_at")),
            memo_id=str(value.get("memo_id") or ""),
            index=_as_int(value.get("index")),
        )

    manual: dict[str, ManualTodo] = {}
    raw_manual = raw.get("manual")
    if isinstance(raw_manual, list):
        records: Iterable[tuple[Any, Any]] = (
            (item.get("id", ""), item) for item in raw_manual if isinstance(item, dict)
        )
    elif isinstance(raw_manual, dict):
        records = raw_manual.items()
    else:
        records = ()
    for key, value in records:
        if not isinstance(value, dict):
            continue
        todo_id = str(value.get("id") or key or "").strip()
        task = str(value.get("task") or "").strip()
        if not todo_id or not task:
            continue
        manual[todo_id] = ManualTodo(
            id=todo_id,
            task=task,
            completed=_as_bool(value.get("completed"))
            or str(value.get("status") or "").lower() in {"completed", "done"},
            created_at=_as_int(value.get("created_at")),
            updated_at=_as_int(value.get("updated_at")),
            author=str(value.get("author") or ""),
            device_id=str(value.get("device_id") or fallback_device),
            deleted=_as_bool(value.get("deleted")),
        )
    return states, manual


def load_state(sync_root: Path | str) -> TodoState:
    """读 `<同步根>/todos/*.json` 并按 updated_at 合并。"""
    root = Path(sync_root) / TODO_DIR_NAME
    state = TodoState()
    if not root.exists():
        return state
    for path in sorted(root.glob("*.json")):
        # 冲突副本是同一份数据的旧快照，跳过它比把它算进 LWW 更可预测。
        if ".sync-conflict-" in path.name or path.name.endswith(".part"):
            continue
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        states, manual = _parse_doc(raw, fallback_device=path.stem)
        for key, value in states.items():
            current = state.states.get(key)
            if current is None or value.updated_at >= current.updated_at:
                state.states[key] = value
        for key, value in manual.items():
            current = state.manual.get(key)
            if current is None or value.updated_at >= current.updated_at:
                state.manual[key] = value
        state.files.append(path.name)
    return state


def _todo_task(item: Any) -> str:
    if isinstance(item, str):
        return item.strip()
    if isinstance(item, dict):
        return str(
            item.get("task") or item.get("title") or item.get("content") or ""
        ).strip()
    return ""


def _todo_done(item: Any) -> bool:
    if isinstance(item, dict):
        return _as_bool(item.get("completed")) or str(
            item.get("status") or ""
        ).lower() in {"completed", "done", "finished"}
    return False


def collect_todos(sync_root: Path | str, state: TodoState | None = None) -> list[dict[str, Any]]:
    """汇总所有笔记待办 + 手工待办，并把跨设备的勾选状态套上去。"""
    merged = state if state is not None else load_state(sync_root)
    items: list[dict[str, Any]] = []
    for _, data in iter_notes(sync_root):
        memo_id = str(data.get("id") or "").strip()
        if not memo_id:
            continue
        raw_todos = data.get("todos") or []
        if not isinstance(raw_todos, list):
            continue
        for index, raw in enumerate(raw_todos):
            task = _todo_task(raw)
            if not task:
                continue
            override = merged.completion_for(memo_id, task, index)
            completed = (
                override.completed
                if override is not None
                else _todo_done(raw)
            )
            items.append(
                {
                    "task": task,
                    "completed": completed,
                    "origin": "笔记",
                    "memo_id": memo_id,
                    "author": str(data.get("author") or ""),
                    "created_at": str(data.get("created_at") or ""),
                    "updated_at": override.updated_at if override else 0,
                }
            )
    for record in merged.active_manual:
        items.append(
            {
                "task": record.task,
                "completed": record.completed,
                "origin": "手动",
                "memo_id": "",
                "author": record.author,
                "created_at": "",
                "updated_at": record.updated_at,
            }
        )
    return items


def format_report(sync_root: Path | str) -> str:
    """`./run.sh --todos` 的人类可读输出。"""
    merged = load_state(sync_root)
    items = collect_todos(sync_root, merged)
    pending = [item for item in items if not item["completed"]]
    done = [item for item in items if item["completed"]]
    lines = [
        "=" * 62,
        "LocalVoiceSync 待办总览",
        "=" * 62,
        f"状态文件 {len(merged.files)} 份"
        + (f"（{'、'.join(merged.files)}）" if merged.files else "（还没有设备写过）"),
        f"勾选记录 {len(merged.states)} 条 / 手工待办 {len(merged.active_manual)} 条",
        "-" * 62,
        f"未完成 {len(pending)} 条",
    ]
    if pending:
        for item in pending:
            tail = f"  ← {item['memo_id']}" if item["memo_id"] else ""
            lines.append(f"  [ ] {item['task']}{tail}")
    else:
        lines.append("  （无）")
    lines.append(f"已完成 {len(done)} 条")
    for item in done:
        tail = f"  ← {item['memo_id']}" if item["memo_id"] else ""
        lines.append(f"  [x] {item['task']}{tail}")
    lines.append("-" * 62)
    lines.append(
        "Mac 只读这些状态文件；勾选请在手机 App 的「待办」页操作，"
        "改动会通过 Syncthing 同步回来。"
    )
    return "\n".join(lines)


def state_stats(sync_root: Path | str) -> str:
    merged = load_state(sync_root)
    return (
        f"{len(merged.files)} 个设备文件 / {len(merged.states)} 条勾选"
        f" / {len(merged.active_manual)} 条手工待办"
    )
