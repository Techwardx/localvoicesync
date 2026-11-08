"""标签词表的回归测试。

核心保证：同类笔记必须共用同一个标签名，且"新标签"不会无限增殖。
早期版本让 LLM 每条笔记自由造标签，十几篇笔记能长出三十个同义标签。
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tag_registry import (  # noqa: E402
    TagRegistry,
    containment_key,
    core_label,
    deterministic_edges,
    group_is_plausible,
    normalize_tag,
    shared_core,
)


def _write_note(root: Path, name: str, tags: list[str], author: str = "Me") -> None:
    inbox = root / f"{author}_Notes" / "inbox"
    inbox.mkdir(parents=True, exist_ok=True)
    (inbox / name).write_text(
        json.dumps({"id": name[:-5], "tags": tags}, ensure_ascii=False),
        encoding="utf-8",
    )


class NormalizeTest(unittest.TestCase):
    def test_full_width_and_spacing_are_equivalent(self) -> None:
        self.assertEqual(normalize_tag("ＱＣＹ　Ｔ２０"), "qcyt20")
        self.assertEqual(normalize_tag("QCY T20"), "qcyt20")
        self.assertEqual(normalize_tag("Web3 激励"), "web3激励")

    def test_punctuation_is_ignored(self) -> None:
        self.assertEqual(normalize_tag("手语-AI"), normalize_tag("手语 AI"))


class CoreTest(unittest.TestCase):
    def test_containment(self) -> None:
        self.assertTrue(containment_key("qcy", "qcyt20"))
        self.assertTrue(containment_key("手语", "asl手语"))
        self.assertTrue(containment_key("测试", "系统测试"))

    def test_ascii_abbreviations_are_not_merge_evidence(self) -> None:
        # "AI" / "3D" 到处都是，不能因此把两个标签并成一组
        self.assertFalse(containment_key("ai", "手语ai"))
        self.assertFalse(containment_key("数据", "无障碍数据集"))

    def test_shared_core_finds_sign_language(self) -> None:
        self.assertEqual(shared_core("asl手语", "手语ai"), "手语")

    def test_generic_core_does_not_merge_unrelated_topics(self) -> None:
        self.assertIsNone(shared_core("系统测试", "系统优化"))
        self.assertIsNone(shared_core("数据众包", "无障碍数据集"))

    def test_core_label_preserves_original_case(self) -> None:
        self.assertEqual(core_label("qcy", ["QCY", "QCY T20"]), "QCY")
        self.assertEqual(core_label("手语", ["ASL手语", "手语 AI"]), "手语")

    def test_group_is_plausible_rejects_cross_dimension_merge(self) -> None:
        self.assertTrue(group_is_plausible(["ASL手语", "手语 AI"]))
        self.assertFalse(group_is_plausible(["停车", "导航", "出行准备"]))
        self.assertFalse(group_is_plausible(["蓝牙耳机", "硬件维修"]))


class RegistryTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        for index, tags in enumerate(
            [
                ["系统测试", "语音备忘"],
                ["系统测试", "语音记录"],
                ["蓝牙耳机", "QCY T20", "硬件维修"],
                ["蓝牙耳机", "QCY T20", "硬件维修"],
            ]
        ):
            _write_note(self.root, f"memo_{index:03d}.json", tags)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_vocabulary_is_ordered_by_frequency(self) -> None:
        registry = TagRegistry(self.root)
        tags = registry.tags()
        self.assertEqual(len(tags), 6)
        # 出现 2 次的排在只出现 1 次的前面
        self.assertLess(tags.index("系统测试"), tags.index("语音备忘"))
        self.assertLess(tags.index("蓝牙耳机"), tags.index("语音记录"))

    def test_exact_match_is_reused_verbatim(self) -> None:
        registry = TagRegistry(self.root)
        result = registry.resolve(["系统测试", "语音备忘"])
        self.assertEqual(result.tags, ["系统测试", "语音备忘"])
        self.assertFalse(result.changed)

    def test_variant_is_merged_and_kept_as_alias(self) -> None:
        registry = TagRegistry(self.root)
        result = registry.resolve(["QCY", "系统测试"])
        self.assertEqual(result.tags, ["QCY T20", "系统测试"])
        self.assertEqual(result.mapped, {"QCY": "QCY T20"})
        self.assertIn("QCY", result.variants)

    def test_new_tag_cap(self) -> None:
        registry = TagRegistry(self.root, max_new_tags=1)
        result = registry.resolve(["保险丝", "逆变器", "太阳能板"])
        self.assertEqual(result.created, ["保险丝"])
        self.assertEqual(result.tags, ["保险丝"])
        # 被限额砍掉的词仍要能搜到
        self.assertEqual(result.variants, ["逆变器", "太阳能板"])

    def test_cold_start_allows_more_new_tags(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            empty = Path(tmp)
            _write_note(empty, "memo_001.json", ["停车"])
            registry = TagRegistry(empty, max_new_tags=1)
            result = registry.resolve(["万圣节", "要糖", "导航"])
            self.assertEqual(len(result.created), 3)

    def test_spacing_variant_is_normalized_and_kept_as_alias(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_note(root, "memo_001.json", ["Web3 激励"])
            result = TagRegistry(root).resolve(["Web3激励"])
            self.assertEqual(result.tags, ["Web3 激励"])
            self.assertEqual(result.mapped, {"Web3激励": "Web3 激励"})
            self.assertIn("Web3激励", result.variants)

    def test_invalidate_picks_up_newly_written_note(self) -> None:
        registry = TagRegistry(self.root)
        self.assertEqual(len(registry.stats()), 6)
        _write_note(self.root, "memo_099.json", ["万圣节"])
        self.assertEqual(len(registry.stats()), 6)  # 还在 TTL 内
        registry.invalidate()
        self.assertEqual(len(registry.stats()), 7)
        self.assertEqual(registry.lookup("万圣节当晚"), "万圣节")

    def test_error_files_are_ignored(self) -> None:
        inbox = self.root / "Me_Notes" / "inbox"
        (inbox / "memo_bad.error.json").write_text(
            json.dumps({"error": "x", "tags": ["不该出现"]}), encoding="utf-8"
        )
        self.assertNotIn("不该出现", TagRegistry(self.root).tags())


class DeterministicEdgeTest(unittest.TestCase):
    def test_edges_cover_containment_and_shared_core(self) -> None:
        edges = deterministic_edges(
            ["ASL手语", "手语 AI", "QCY", "QCY T20", "蓝牙耳机", "硬件维修"]
        )
        pairs = {frozenset(pair) for pair in edges}
        self.assertIn(frozenset({"ASL手语", "手语 AI"}), pairs)
        self.assertIn(frozenset({"QCY", "QCY T20"}), pairs)
        self.assertNotIn(frozenset({"蓝牙耳机", "硬件维修"}), pairs)


if __name__ == "__main__":
    unittest.main()
