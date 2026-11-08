"""标签整理命令的回归测试。

重点不是"合并得多"，而是"绝不误并"：LLM 输出必须逐字段校验，
跨维度分组（停车 + 导航 → 出行）和凭空生造的规范名一律拒绝。
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tag_cleanup import (  # noqa: E402
    build_merge_map,
    normalize_existing_notes,
    validate_groups,
)
from tag_registry import all_tags  # noqa: E402


class StubOllama:
    def __init__(self, groups: list[dict]) -> None:
        self.groups = groups
        self.calls = 0

    def plan_tag_merge(self, tags, counts):  # noqa: ANN001
        self.calls += 1
        return self.groups


class StubEmbedder:
    model_id = "bge-small-zh-v1.5"

    def embed(self, text):  # noqa: ANN001
        return None


def _write_note(root: Path, name: str, tags: list[str], aliases: list[str] | None = None) -> Path:
    inbox = root / "Me_Notes" / "inbox"
    inbox.mkdir(parents=True, exist_ok=True)
    path = inbox / name
    path.write_text(
        json.dumps(
            {
                "id": name[:-5],
                "tags": tags,
                "aliases": aliases or [],
                "summary": "测试",
                "raw_transcript": "测试",
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )
    return path


class ValidateGroupsTest(unittest.TestCase):
    def test_hallucinated_members_are_dropped(self) -> None:
        allowed = {"ASL手语", "手语 AI", "停车"}
        groups = validate_groups(
            [{"canonical": "手语", "members": ["ASL手语", "手语 AI", "不存在的词"]}],
            allowed,
        )
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0][1], ["ASL手语", "手语 AI"])
        self.assertEqual(groups[0][0], "手语")

    def test_cross_dimension_group_is_rejected(self) -> None:
        groups = validate_groups(
            [{"canonical": "出行", "members": ["停车", "导航", "出行准备"]}],
            {"停车", "导航", "出行准备"},
        )
        self.assertEqual(groups, [])

    def test_fabricated_canonical_is_dropped_but_group_kept(self) -> None:
        groups = validate_groups(
            [{"canonical": "数据工程", "members": ["数据众包", "无障碍数据集"]}],
            {"数据众包", "无障碍数据集"},
        )
        # 这一组本身就不该合并（共享的只有泛词"数据"），整组拒绝
        self.assertEqual(groups, [])
        # 换个确实同词的组，但规范名凭空造
        groups = validate_groups(
            [{"canonical": "数据工程", "members": ["ASL手语", "手语 AI"]}],
            {"ASL手语", "手语 AI"},
        )
        self.assertEqual(len(groups), 1)
        self.assertIsNone(groups[0][0])

    def test_duplicate_members_across_groups_are_rejected(self) -> None:
        allowed = {"手语", "ASL手语", "手语 AI"}
        groups = validate_groups(
            [
                {"canonical": "手语", "members": ["手语", "ASL手语"]},
                {"canonical": "手语", "members": ["手语", "手语 AI"]},
            ],
            allowed,
        )
        self.assertEqual(len(groups), 1)


class BuildMergeMapTest(unittest.TestCase):
    def test_established_name_wins_over_llm_shortening(self) -> None:
        tags = ["系统测试", "测试", "版本测试", "手语 AI", "ASL手语"]
        counts = {"系统测试": 2, "测试": 1, "版本测试": 1, "手语 AI": 1, "ASL手语": 1}
        groups = [("测试", ["系统测试", "测试", "版本测试"]), ("手语", ["手语 AI", "ASL手语"])]
        mapping, report = build_merge_map(tags, counts, groups)
        self.assertEqual(mapping["测试"], "系统测试")
        self.assertEqual(mapping["版本测试"], "系统测试")
        self.assertEqual(mapping["手语 AI"], "手语")
        self.assertEqual(len(report), 2)

    def test_deterministic_edges_work_without_llm(self) -> None:
        tags = ["ASL手语", "手语 AI", "QCY", "QCY T20"]
        counts = {"ASL手语": 1, "手语 AI": 1, "QCY": 1, "QCY T20": 2}
        mapping, report = build_merge_map(tags, counts, [])
        self.assertEqual(mapping["ASL手语"], "手语")
        self.assertEqual(mapping["手语 AI"], "手语")
        self.assertEqual(mapping["QCY"], "QCY T20")


class CleanupApplyTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.backup_root = self.root / "backups"
        self.path = _write_note(
            self.root,
            "memo_001.json",
            ["ASL手语", "无障碍设计", "3D打印"],
            ["美国手语"],
        )
        # 另一个成员的同类笔记：共享词根，应该和上面统一到「手语 / 无障碍」
        _write_note(
            self.root,
            "memo_002.json",
            ["手语 AI", "无障碍数据集"],
        )
        self.original = self.path.read_text(encoding="utf-8")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _cfg(self) -> SimpleNamespace:
        return SimpleNamespace(sync_root=self.root)

    def test_dry_run_does_not_touch_files(self) -> None:
        report = normalize_existing_notes(
            self._cfg(),
            StubOllama([]),
            apply=False,
            use_llm=False,
            embedder=StubEmbedder(),
            backup_root=self.backup_root,
        )
        self.assertEqual(self.path.read_text(encoding="utf-8"), self.original)
        self.assertFalse(report.applied)
        self.assertIsNone(report.backup_dir)

    def test_apply_writes_backup_original_tags_and_aliases(self) -> None:
        report = normalize_existing_notes(
            self._cfg(),
            StubOllama([]),
            apply=True,
            use_llm=False,
            embedder=StubEmbedder(),
            backup_root=self.backup_root,
        )
        self.assertTrue(report.applied)
        self.assertEqual(report.changed_notes, 2)
        self.assertIsNotNone(report.backup_dir)
        self.assertEqual(len(list(report.backup_dir.rglob("*.json"))), 2)

        data = json.loads(self.path.read_text(encoding="utf-8"))
        self.assertEqual(data["tags"], ["手语", "无障碍", "3D打印"])
        self.assertEqual(data["original_tags"], ["ASL手语", "无障碍设计", "3D打印"])
        self.assertIn("ASL手语", data["aliases"])
        self.assertIn("美国手语", data["aliases"])
        self.assertTrue(self.path.with_suffix(".md").exists())

    def test_apply_is_idempotent(self) -> None:
        kwargs = dict(
            apply=True,
            use_llm=False,
            embedder=StubEmbedder(),
            backup_root=self.backup_root,
        )
        normalize_existing_notes(self._cfg(), StubOllama([]), **kwargs)
        second = normalize_existing_notes(self._cfg(), StubOllama([]), **kwargs)
        self.assertEqual(second.changed_notes, 0)
        self.assertFalse(second.applied)

    def test_llm_is_consulted_only_when_enabled(self) -> None:
        ollama = StubOllama([])
        normalize_existing_notes(
            self._cfg(), ollama, apply=False, use_llm=False,
            embedder=StubEmbedder(), backup_root=self.backup_root,
        )
        self.assertEqual(ollama.calls, 0)
        normalize_existing_notes(
            self._cfg(), ollama, apply=False, use_llm=True,
            embedder=StubEmbedder(), backup_root=self.backup_root,
        )
        self.assertEqual(ollama.calls, 1)

    def test_tag_count_drops(self) -> None:
        before = len(all_tags(self.root))
        normalize_existing_notes(
            self._cfg(), StubOllama([]), apply=True, use_llm=False,
            embedder=StubEmbedder(), backup_root=self.backup_root,
        )
        self.assertLess(len(all_tags(self.root)), before)


if __name__ == "__main__":
    unittest.main()
