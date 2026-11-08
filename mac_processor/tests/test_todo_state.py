"""Mac 端待办状态读取的单测。

重点是**跨语言一致性**：`note_key()` 必须和 Dart `TodoKeys.forNote()`
算出完全一样的字符串，否则手机上勾掉的事项在 Mac 总览里会变回未完成。
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from todo_state import (
    TODO_DIR_NAME,
    collect_todos,
    format_report,
    load_state,
    normalize_task,
    note_key,
    state_stats,
)


def _write(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")


def _state_doc(device: str) -> dict:
    return {
        "schema_version": 1,
        "device_id": device,
        "updated_at": 0,
        "states": {},
        "manual": [],
    }


class KeyParityTest(unittest.TestCase):
    def test_normalize_task_matches_dart(self) -> None:
        self.assertEqual(normalize_task("  买  牛奶  "), "买 牛奶")
        self.assertEqual(normalize_task("QCY T20"), "qcy t20")
        self.assertEqual(normalize_task("换\n保险\t丝"), "换 保险 丝")

    def test_note_key_matches_dart(self) -> None:
        self.assertEqual(
            note_key("memo_20261108_153000", "  买  牛奶  "),
            "note:memo_20261108_153000:买 牛奶",
        )
        self.assertEqual(
            note_key("memo_1", "QCY T20"), note_key("memo_1", "  qcy   t20 ")
        )


class LoadStateTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        (self.root / TODO_DIR_NAME).mkdir(parents=True, exist_ok=True)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_missing_dir_returns_empty_state(self) -> None:
        state = load_state(self.root / "不存在")
        self.assertEqual(state.states, {})
        self.assertEqual(state.files, [])

    def test_each_device_writes_its_own_file_and_all_are_merged(self) -> None:
        a = _state_doc("dev_a")
        a["states"] = {
            "note:memo_1:买牛奶": {
                "completed": True,
                "updated_at": 100,
                "memo_id": "memo_1",
                "index": 0,
            }
        }
        b = _state_doc("dev_b")
        b["manual"] = [
            {
                "id": "todo_1",
                "task": "交电费",
                "completed": False,
                "created_at": 200,
                "updated_at": 200,
                "author": "Me",
                "device_id": "dev_b",
            }
        ]
        _write(self.root / TODO_DIR_NAME / "dev_a.json", a)
        _write(self.root / TODO_DIR_NAME / "dev_b.json", b)

        state = load_state(self.root)
        self.assertEqual(set(state.files), {"dev_a.json", "dev_b.json"})
        self.assertTrue(state.states["note:memo_1:买牛奶"].completed)
        self.assertEqual(state.active_manual[0].task, "交电费")

    def test_last_write_wins_regardless_of_file_order(self) -> None:
        older = _state_doc("dev_a")
        older["states"] = {
            "k": {
                "completed": True,
                "updated_at": 100,
                "memo_id": "m1",
                "index": 0,
            }
        }
        newer = _state_doc("dev_b")
        newer["states"] = {
            "k": {
                "completed": False,
                "updated_at": 200,
                "memo_id": "m1",
                "index": 0,
            }
        }
        _write(self.root / TODO_DIR_NAME / "dev_a.json", older)
        _write(self.root / TODO_DIR_NAME / "dev_b.json", newer)
        self.assertFalse(load_state(self.root).states["k"].completed)

    def test_tombstone_beats_older_creation(self) -> None:
        created = _state_doc("dev_a")
        created["manual"] = [
            {
                "id": "todo_1",
                "task": "交电费",
                "completed": False,
                "created_at": 100,
                "updated_at": 100,
            }
        ]
        deleted = _state_doc("dev_b")
        deleted["manual"] = [
            {
                "id": "todo_1",
                "task": "交电费",
                "completed": False,
                "created_at": 100,
                "updated_at": 300,
                "deleted": True,
            }
        ]
        _write(self.root / TODO_DIR_NAME / "dev_a.json", created)
        _write(self.root / TODO_DIR_NAME / "dev_b.json", deleted)
        self.assertEqual(load_state(self.root).active_manual, [])

    def test_conflict_copies_and_part_files_are_skipped(self) -> None:
        doc = _state_doc("dev_a")
        doc["states"] = {
            "k": {
                "completed": True,
                "updated_at": 999,
                "memo_id": "m1",
                "index": 0,
            }
        }
        _write(
            self.root / TODO_DIR_NAME / "dev_a.sync-conflict-20261108.json", doc
        )
        (self.root / TODO_DIR_NAME / "dev_b.json.part").write_text(
            "{半截", encoding="utf-8"
        )
        self.assertEqual(load_state(self.root).states, {})

    def test_broken_json_does_not_break_everything(self) -> None:
        (self.root / TODO_DIR_NAME / "dev_bad.json").write_text(
            "{不是 json", encoding="utf-8"
        )
        good = _state_doc("dev_good")
        good["manual"] = [
            {
                "id": "todo_1",
                "task": "取快递",
                "completed": False,
                "created_at": 1,
                "updated_at": 1,
            }
        ]
        _write(self.root / TODO_DIR_NAME / "dev_good.json", good)
        self.assertEqual(len(load_state(self.root).active_manual), 1)


class CollectTodosTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        (self.root / "Me_Notes" / "inbox").mkdir(parents=True)
        (self.root / TODO_DIR_NAME).mkdir(parents=True)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _note(self, memo_id: str, todos: list) -> None:
        _write(
            self.root / "Me_Notes" / "inbox" / f"{memo_id}.json",
            {
                "id": memo_id,
                "author": "Me",
                "created_at": "2026-11-08 15:00:00",
                "todos": todos,
            },
        )

    def test_all_note_todos_plus_manual_todos(self) -> None:
        self._note(
            "memo_1",
            [
                {"task": "买牛奶", "status": "pending"},
                {"task": "检查接线", "status": "completed"},
            ],
        )
        self._note("memo_2", ["交电费"])
        doc = _state_doc("dev_a")
        doc["manual"] = [
            {
                "id": "todo_1",
                "task": "预约体检",
                "completed": False,
                "created_at": 1,
                "updated_at": 1,
                "author": "Me",
            }
        ]
        _write(self.root / TODO_DIR_NAME / "dev_a.json", doc)

        items = collect_todos(self.root)
        self.assertEqual(
            [item["task"] for item in items],
            ["买牛奶", "检查接线", "交电费", "预约体检"],
        )
        self.assertEqual([item["origin"] for item in items].count("手动"), 1)

    def test_phone_completion_overrides_mac_json(self) -> None:
        self._note("memo_1", [{"task": "买牛奶", "status": "pending"}])
        doc = _state_doc("dev_a")
        doc["states"] = {
            note_key("memo_1", "买牛奶"): {
                "completed": True,
                "updated_at": 500,
                "memo_id": "memo_1",
                "index": 0,
            }
        }
        _write(self.root / TODO_DIR_NAME / "dev_a.json", doc)

        items = collect_todos(self.root)
        self.assertTrue(items[0]["completed"])
        self.assertIn("[x] 买牛奶", format_report(self.root))

    def test_retranscribed_task_text_still_matches_by_memo_and_index(self) -> None:
        self._note("memo_1", [{"task": "买两盒牛奶", "status": "pending"}])
        doc = _state_doc("dev_a")
        doc["states"] = {
            note_key("memo_1", "买牛奶"): {
                "completed": True,
                "updated_at": 500,
                "memo_id": "memo_1",
                "index": 0,
            }
        }
        _write(self.root / TODO_DIR_NAME / "dev_a.json", doc)
        self.assertTrue(collect_todos(self.root)[0]["completed"])

    def test_error_json_is_ignored(self) -> None:
        _write(
            self.root / "Me_Notes" / "inbox" / "memo_bad.error.json",
            {"error": "提炼失败", "todos": [{"task": "不该出现"}]},
        )
        self.assertEqual(collect_todos(self.root), [])

    def test_stats_are_readable(self) -> None:
        _write(self.root / TODO_DIR_NAME / "dev_a.json", _state_doc("dev_a"))
        self.assertIn("1 个设备文件", state_stats(self.root))


if __name__ == "__main__":
    unittest.main()
