"""热词提示词的回归测试。

重点是两件事：

1. **token 预算**：Whisper 只保留 initial_prompt 的最后 223 个 token，
   超了会静默丢掉前面的词。旧版按"字符数"估算，163 个字符实际是 202 token，
   差一点就撑满。现在必须按真实/保守 token 计数。
2. **不串场**：Me 的录音里不能出现 Dad 的词汇，粘贴的长文笔记里的
   抽象主题标签（"数据众包""多模态大模型训练数据"）也不能进提示词。
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from hotwords import (  # noqa: E402
    build_prompt,
    collect,
    merge_terms,
    _fallback_token_cost,
)


def _write_member(root: Path, dirname: str, notes: list[dict]) -> None:
    inbox = root / dirname / "inbox"
    inbox.mkdir(parents=True, exist_ok=True)
    for index, note in enumerate(notes):
        (inbox / f"memo_{index:03d}.json").write_text(
            json.dumps(note, ensure_ascii=False), encoding="utf-8"
        )


class CollectTest(unittest.TestCase):
    def test_members_are_isolated(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_member(
                root,
                "Me_Notes",
                [{"kind": "audio", "tags": ["停车", "导航"], "raw_transcript": ""}],
            )
            _write_member(
                root,
                "Dad_Notes",
                [{"kind": "audio", "tags": ["保险丝", "逆变器"], "raw_transcript": ""}],
            )
            mine = collect(root, author="Me")
            self.assertIn("停车", mine)
            self.assertNotIn("保险丝", mine)
            self.assertNotIn("逆变器", mine)

    def test_pasted_article_tags_are_dropped(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_member(
                root,
                "Me_Notes",
                [
                    {
                        "kind": "text",
                        "tags": ["数据众包", "多模态大模型训练数据", "QCY T20"],
                        "raw_transcript": "",
                    }
                ],
            )
            terms = collect(root, author="Me")
            self.assertIn("QCY T20", terms)
            self.assertNotIn("数据众包", terms)
            self.assertNotIn("多模态大模型训练数据", terms)

    def test_audio_notes_outweigh_text_notes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_member(
                root,
                "Me_Notes",
                [
                    # 「停车场」在日常专名表里，能通过文字笔记的过滤；
                    # 「导航」来自音频，权重 ×3，应该排在前面。
                    {"kind": "text", "tags": ["停车场"], "raw_transcript": ""},
                    {"kind": "audio", "tags": ["导航"], "raw_transcript": ""},
                ],
            )
            terms = collect(root, author="Me")
            self.assertLess(terms.index("导航"), terms.index("停车场"))

    def test_stoplist_and_digits_filtered(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_member(
                root,
                "Me_Notes",
                [{"kind": "audio", "tags": ["语音备忘", "12345", "停车"], "raw_transcript": ""}],
            )
            terms = collect(root, author="Me")
            self.assertEqual(terms, ["停车"])


class MergeTest(unittest.TestCase):
    def test_manual_terms_come_first(self) -> None:
        merged = merge_terms(["保险丝"], ["停车", "导航"])
        self.assertEqual(merged[0], "保险丝")
        self.assertIn("停车", merged)

    def test_manual_and_auto_are_not_either_or(self) -> None:
        # 旧版 `manual or auto`：手写了词表就完全丢掉自动词。
        merged = merge_terms(["保险丝"], ["停车"])
        self.assertEqual(sorted(merged), ["保险丝", "停车"])

    def test_contained_terms_dropped(self) -> None:
        merged = merge_terms([], ["左耳不亮灯", "左耳不亮"])
        self.assertEqual(len(merged), 1)


class PromptBudgetTest(unittest.TestCase):
    def test_respects_token_budget(self) -> None:
        base = "家庭语音备忘。"
        hotwords = [f"测试词{index}" for index in range(60)]
        prompt = build_prompt(
            base, hotwords, token_cost=len, max_tokens=60
        )
        self.assertLessEqual(len(prompt), 60)
        self.assertTrue(prompt.startswith(base))

    def test_fallback_cost_is_conservative(self) -> None:
        # 中文 3 字词实测 4~5 token，估算必须往高走，不能低估。
        self.assertGreater(_fallback_token_cost("万圣节"), 4)
        self.assertLess(_fallback_token_cost("万圣节"), 8)

    def test_no_terms_returns_base(self) -> None:
        self.assertEqual(build_prompt("家庭语音备忘。", []), "家庭语音备忘。")

    def test_prompt_shape(self) -> None:
        prompt = build_prompt("家庭语音备忘。", ["停车", "导航"], token_cost=len)
        self.assertEqual(prompt, "家庭语音备忘。常提到：停车、导航。")


if __name__ == "__main__":
    unittest.main()
